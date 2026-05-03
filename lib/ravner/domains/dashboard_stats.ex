defmodule Ravner.Domains.DashboardStats do
  @moduledoc """
  Encapsulates the complex aggregation and calculation logic for the dashboard statistics.
  Provides business-critical metrics including SSL status, infrastructure distribution,
  and governance gaps.
  """

  import Ecto.Query

  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata
  alias Ravner.Repo

  @doc """
  Returns aggregate dashboard statistics with business insights.
  """
  def get do
    # One query replaces the previous five (total / total_apex /
    # total_subdomains / lifecycle_apex / lifecycle_sub) by grouping on
    # (type, lifecycle_state) and partitioning the result in memory.
    %{
      total: total,
      total_apex: total_apex,
      total_subdomains: total_subdomains,
      lifecycle_apex: lifecycle_apex,
      lifecycle_sub: lifecycle_sub
    } = get_domain_totals_and_lifecycle()

    now = DateTime.utc_now()
    week_ago = DateTime.add(now, -7 * 24 * 60 * 60, :second)
    month_ago = DateTime.add(now, -30 * 24 * 60 * 60, :second)

    http_stats = get_http_stats(total_apex)

    # 2. SSL Analytics
    ssl_stats = get_ssl_stats(now)
    ssl_alerts = get_ssl_alerts(now)

    # 3. Infrastructure & Hosting
    infra_stats = get_infra_stats()

    # 4. Governance & Risk (Ownership Gaps)
    governance = get_governance_stats()

    # 5. Inventory & Trends
    top_by_subs = get_top_domains_by_subdomains()
    scan_stats = get_scan_freshness_stats(total, week_ago, month_ago)

    %{
      total: total,
      total_apex: total_apex,
      total_subdomains: total_subdomains,
      lifecycle_list: build_lifecycle_list(lifecycle_apex, lifecycle_sub),
      top_by_subs: top_by_subs,
      ssl_alerts: ssl_alerts,
      ssl: ssl_stats,
      http: http_stats,
      infra: infra_stats,
      governance: governance,
      scan: scan_stats
    }
  end

  # --- Data Fetching Helpers ---

  # Single query that returns one row per (type, lifecycle_state) pair
  # with its count, then aggregates everything in memory:
  #   - total                    -> sum of all counts
  #   - total_apex / _subdomains -> sums filtered by type
  #   - lifecycle_apex / _sub    -> %{lifecycle => count} maps
  defp get_domain_totals_and_lifecycle do
    rows =
      Domain
      |> group_by([d], [d.type, d.lifecycle_state])
      |> select([d], {d.type, d.lifecycle_state, count(d.id)})
      |> Repo.all()

    Enum.reduce(
      rows,
      %{
        total: 0,
        total_apex: 0,
        total_subdomains: 0,
        lifecycle_apex: %{},
        lifecycle_sub: %{}
      },
      fn {type, lifecycle, count}, acc ->
        acc = %{acc | total: acc.total + count}

        case type do
          :domain ->
            %{
              acc
              | total_apex: acc.total_apex + count,
                lifecycle_apex: Map.put(acc.lifecycle_apex, lifecycle, count)
            }

          :subdomain ->
            %{
              acc
              | total_subdomains: acc.total_subdomains + count,
                lifecycle_sub: Map.put(acc.lifecycle_sub, lifecycle, count)
            }

          _ ->
            acc
        end
      end
    )
  end

  defp get_http_stats(total_apex) do
    # Compute the buckets entirely in SQL. The "external redirect" decision
    # is the same logic as `external_redirect_dashboard?/2` but expressed
    # against the lower-cased host extracted from `final_url`:
    #
    #   * 4xx/5xx or status 0       -> :http_4xx_5xx
    #   * final-url host (sans "www.") differs from domain name (sans "www.")
    #                               -> :http_3xx
    #   * 2xx (and final-url empty or matching own host)
    #                               -> :http_200
    #   * anything else             -> uncounted (e.g. 1xx)
    #
    # The fragments embed host normalisation inline because Ecto fragments
    # can't be composed via `dynamic/2` inside `select`. The expression:
    #
    #   regexp_replace(split_part(regexp_replace(coalesce(final_url, ''),
    #     '^http(s|)://', ''), '/', 1), '^www\.', '')
    #
    # extracts the host from a URL like "https://www.example.com/path"
    # (-> "example.com") and reduces NULL/missing final_url to ''.
    #
    # NOTE: `^http(s|)://` is used instead of `^https?://` because Ecto's
    # `fragment/2` interprets every `?` in the SQL string as a positional
    # placeholder and would miscount the arguments otherwise.
    %{ok: ok, redirect: redirect, error: error, scanned: scanned} =
      from(d in Domain,
        join: m in DomainMetadata,
        on: m.domain_id == d.id,
        where: d.type == :domain,
        select: %{
          ok:
            sum(
              fragment(
                """
                CASE
                  WHEN ? >= 200 AND ? < 300
                   AND (
                     regexp_replace(split_part(regexp_replace(coalesce(?, ''), '^http(s|)://', ''), '/', 1), '^www\\.', '') = ''
                     OR regexp_replace(split_part(regexp_replace(coalesce(?, ''), '^http(s|)://', ''), '/', 1), '^www\\.', '')
                        = regexp_replace(?, '^www\\.', '')
                   )
                  THEN 1 ELSE 0
                END
                """,
                m.http_status,
                m.http_status,
                m.final_url,
                m.final_url,
                d.name
              )
            ),
          redirect:
            sum(
              fragment(
                """
                CASE
                  WHEN ? < 400 AND ? <> 0
                   AND regexp_replace(split_part(regexp_replace(coalesce(?, ''), '^http(s|)://', ''), '/', 1), '^www\\.', '') <> ''
                   AND regexp_replace(split_part(regexp_replace(coalesce(?, ''), '^http(s|)://', ''), '/', 1), '^www\\.', '')
                       <> regexp_replace(?, '^www\\.', '')
                  THEN 1 ELSE 0
                END
                """,
                m.http_status,
                m.http_status,
                m.final_url,
                m.final_url,
                d.name
              )
            ),
          error:
            sum(
              fragment(
                "CASE WHEN ? >= 400 OR ? = 0 THEN 1 ELSE 0 END",
                m.http_status,
                m.http_status
              )
            ),
          scanned: count(m.id)
        }
      )
      |> Repo.one()
      |> normalize_http_stats()

    %{
      http_200: ok,
      http_3xx: redirect,
      http_4xx_5xx: error,
      http_unscanned: max(0, total_apex - scanned)
    }
  end

  defp normalize_http_stats(nil), do: %{ok: 0, redirect: 0, error: 0, scanned: 0}

  defp normalize_http_stats(row) do
    %{
      ok: row.ok || 0,
      redirect: row.redirect || 0,
      error: row.error || 0,
      scanned: row.scanned || 0
    }
  end

  defp get_ssl_stats(now) do
    # Expiration Buckets — collapsed into a single aggregate query.
    exp_7d = DateTime.add(now, 7 * 24 * 60 * 60, :second)
    exp_30d = DateTime.add(now, 30 * 24 * 60 * 60, :second)

    counts =
      from(m in DomainMetadata,
        select: %{
          total: count(fragment("CASE WHEN ? IS NOT NULL THEN 1 END", m.ssl_valid_until)),
          expired: count(fragment("CASE WHEN ? < ? THEN 1 END", m.ssl_valid_until, ^now)),
          soon_7d:
            count(
              fragment(
                "CASE WHEN ? >= ? AND ? < ? THEN 1 END",
                m.ssl_valid_until,
                ^now,
                m.ssl_valid_until,
                ^exp_7d
              )
            ),
          soon_30d:
            count(
              fragment(
                "CASE WHEN ? >= ? AND ? < ? THEN 1 END",
                m.ssl_valid_until,
                ^exp_7d,
                m.ssl_valid_until,
                ^exp_30d
              )
            )
        }
      )
      |> Repo.one() ||
        %{total: 0, expired: 0, soon_7d: 0, soon_30d: 0}

    # Issuer Distribution — separate query (GROUP BY ssl_issuer).
    issuers =
      DomainMetadata
      |> where([m], not is_nil(m.ssl_issuer))
      |> group_by([m], m.ssl_issuer)
      |> select([m], {m.ssl_issuer, count(m.id)})
      |> order_by([m], desc: count(m.id))
      |> limit(5)
      |> Repo.all()
      |> Enum.map(fn {raw, count} -> {simplify_issuer(raw), count} end)

    Map.put(counts, :issuers, issuers)
  end

  defp get_infra_stats do
    hosting =
      DomainMetadata
      |> where([m], not is_nil(m.hosting_platform))
      |> group_by([m], m.hosting_platform)
      |> select([m], {m.hosting_platform, count(m.id)})
      |> order_by([m], desc: count(m.id))
      |> limit(5)
      |> Repo.all()

    registrars =
      DomainMetadata
      |> where([m], not is_nil(m.registrar))
      |> group_by([m], m.registrar)
      |> select([m], {m.registrar, count(m.id)})
      |> order_by([m], desc: count(m.id))
      |> limit(5)
      |> Repo.all()

    %{
      hosting: hosting,
      registrars: registrars
    }
  end

  defp get_governance_stats do
    # Single-pass aggregate: count rows missing each governance field.
    from(d in Domain,
      select: %{
        missing_pm:
          count(fragment("CASE WHEN ? IS NULL OR ? = '' THEN 1 END", d.pm_email, d.pm_email)),
        missing_po:
          count(fragment("CASE WHEN ? IS NULL OR ? = '' THEN 1 END", d.po_email, d.po_email)),
        missing_project: count(fragment("CASE WHEN ? IS NULL THEN 1 END", d.project_id)),
        missing_brand: count(fragment("CASE WHEN ? IS NULL THEN 1 END", d.brand_id))
      }
    )
    |> Repo.one() ||
      %{missing_pm: 0, missing_po: 0, missing_project: 0, missing_brand: 0}
  end

  defp get_top_domains_by_subdomains do
    Domain
    |> where(type: :domain)
    |> join(:left, [d], s in Domain, on: s.parent_domain_id == d.id)
    |> group_by([d], d.id)
    |> select([d, s], %{name: d.name, count: count(s.id)})
    |> order_by([_d, s], desc: count(s.id))
    |> limit(10)
    |> Repo.all()
    |> Enum.map(&{&1.name, &1.count})
    |> Enum.filter(fn {_, c} -> c > 0 end)
  end

  defp get_scan_freshness_stats(total, week_ago, month_ago) do
    # Collapsed: 3 round-trips → 1 single-row aggregate.
    %{this_week: this_week, this_month: this_month, older: older} =
      from(m in DomainMetadata,
        select: %{
          this_week: count(fragment("CASE WHEN ? >= ? THEN 1 END", m.scanned_at, ^week_ago)),
          this_month:
            count(
              fragment(
                "CASE WHEN ? >= ? AND ? < ? THEN 1 END",
                m.scanned_at,
                ^month_ago,
                m.scanned_at,
                ^week_ago
              )
            ),
          older: count(fragment("CASE WHEN ? < ? THEN 1 END", m.scanned_at, ^month_ago))
        }
      )
      |> Repo.one() ||
        %{this_week: 0, this_month: 0, older: 0}

    %{
      this_week: this_week,
      this_month: this_month,
      older: older,
      never: max(0, total - this_week - this_month - older)
    }
  end

  # --- Utility Helpers ---

  defp simplify_issuer(issuer) when is_binary(issuer) do
    cond do
      String.contains?(issuer, "Let's Encrypt") ->
        "Let's Encrypt"

      String.contains?(issuer, "DigiCert") ->
        "DigiCert"

      String.contains?(issuer, "Cloudflare") ->
        "Cloudflare"

      String.contains?(issuer, "Google") ->
        "Google"

      String.contains?(issuer, "Sectigo") ->
        "Sectigo"

      String.contains?(issuer, "Amazon") ->
        "Amazon"

      issuer |> String.split("O=") |> length() > 1 ->
        issuer |> String.split("O=") |> List.last() |> String.split(",") |> List.first()

      true ->
        issuer |> String.split(",") |> List.first() |> String.replace(~r/^[A-Z]+=/, "")
    end
  end

  defp simplify_issuer(_), do: "Unknown"

  defp build_lifecycle_list(apex_map, sub_map) do
    lifecycle_order = [
      :priority,
      :active,
      :placeholder,
      :under_review,
      :insecure,
      :redirect,
      :deprecated,
      :decommissioned,
      :error,
      :abandoned
    ]

    labels = %{
      priority: "Priority",
      active: "Active",
      placeholder: "Placeholder",
      under_review: "Under review",
      insecure: "Insecure HTTP",
      redirect: "Redirect",
      deprecated: "Deprecated",
      decommissioned: "Decommissioned",
      error: "Error",
      abandoned: "Abandoned"
    }

    lifecycle_order
    |> Enum.map(fn state ->
      apex = Map.get(apex_map, state, 0)
      sub = Map.get(sub_map, state, 0)

      %{
        state: state,
        label: Map.get(labels, state, to_string(state)),
        apex: apex,
        sub: sub,
        total: apex + sub
      }
    end)
    |> Enum.filter(&(&1.total > 0))
  end

  defp get_ssl_alerts(now) do
    soon = DateTime.add(now, 14 * 24 * 60 * 60, :second)

    Repo.all(
      from(m in DomainMetadata,
        join: d in Domain,
        on: m.domain_id == d.id,
        where: m.ssl_valid_until < ^soon,
        order_by: [asc: m.ssl_valid_until],
        select: %{
          id: d.id,
          name: d.name,
          valid_until: m.ssl_valid_until,
          days_remaining: m.ssl_days_remaining
        }
      )
    )
    |> Enum.map(fn alert ->
      status = if DateTime.compare(alert.valid_until, now) == :lt, do: :expired, else: :expiring
      Map.put(alert, :status, status)
    end)
  end
end
