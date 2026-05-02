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
    total = Repo.aggregate(Domain, :count, :id)
    total_apex = Repo.aggregate(from(d in Domain, where: d.type == :domain), :count, :id)
    total_subdomains = Repo.aggregate(from(d in Domain, where: d.type == :subdomain), :count, :id)

    now = DateTime.utc_now()
    week_ago = DateTime.add(now, -7 * 24 * 60 * 60, :second)
    month_ago = DateTime.add(now, -30 * 24 * 60 * 60, :second)

    # 1. Lifecycle & HTTP
    lifecycle_apex = get_lifecycle_map(:domain)
    lifecycle_sub = get_lifecycle_map(:subdomain)
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

  defp get_lifecycle_map(type) do
    Domain
    |> where(type: ^type)
    |> group_by([d], d.lifecycle_state)
    |> select([d], {d.lifecycle_state, count(d.id)})
    |> Repo.all()
    |> Map.new()
  end

  defp get_http_stats(total_apex) do
    metadata =
      Repo.all(
        from(m in DomainMetadata,
          join: d in Domain,
          on: m.domain_id == d.id and d.type == :domain,
          select: %{name: d.name, http_status: m.http_status, final_url: m.final_url}
        )
      )

    {ok, redirect, error} =
      Enum.reduce(metadata, {0, 0, 0}, fn row, {ok, redir, err} ->
        cond do
          row.http_status >= 400 or row.http_status == 0 -> {ok, redir, err + 1}
          external_redirect_dashboard?(row.name, row.final_url) -> {ok, redir + 1, err}
          row.http_status >= 200 and row.http_status < 300 -> {ok + 1, redir, err}
          true -> {ok, redir, err}
        end
      end)

    %{
      http_200: ok,
      http_3xx: redirect,
      http_4xx_5xx: error,
      http_unscanned: max(0, total_apex - Enum.count(metadata))
    }
  end

  defp get_ssl_stats(now) do
    # Expiration Buckets
    exp_7d = DateTime.add(now, 7 * 24 * 60 * 60, :second)
    exp_30d = DateTime.add(now, 30 * 24 * 60 * 60, :second)

    total_with_ssl =
      Repo.aggregate(from(m in DomainMetadata, where: not is_nil(m.ssl_valid_until)), :count, :id)

    expired =
      Repo.aggregate(from(m in DomainMetadata, where: m.ssl_valid_until < ^now), :count, :id)

    soon_7d =
      Repo.aggregate(
        from(m in DomainMetadata,
          where: m.ssl_valid_until >= ^now and m.ssl_valid_until < ^exp_7d
        ),
        :count,
        :id
      )

    soon_30d =
      Repo.aggregate(
        from(m in DomainMetadata,
          where: m.ssl_valid_until >= ^exp_7d and m.ssl_valid_until < ^exp_30d
        ),
        :count,
        :id
      )

    # Issuer Distribution
    issuers =
      DomainMetadata
      |> where([m], not is_nil(m.ssl_issuer))
      |> group_by([m], m.ssl_issuer)
      |> select([m], {m.ssl_issuer, count(m.id)})
      |> order_by([m], desc: count(m.id))
      |> limit(5)
      |> Repo.all()
      |> Enum.map(fn {raw, count} -> {simplify_issuer(raw), count} end)

    %{
      total: total_with_ssl,
      expired: expired,
      soon_7d: soon_7d,
      soon_30d: soon_30d,
      issuers: issuers
    }
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
    no_pm =
      Repo.aggregate(
        from(d in Domain, where: is_nil(d.pm_email) or d.pm_email == ""),
        :count,
        :id
      )

    no_po =
      Repo.aggregate(
        from(d in Domain, where: is_nil(d.po_email) or d.po_email == ""),
        :count,
        :id
      )

    no_project = Repo.aggregate(from(d in Domain, where: is_nil(d.project_id)), :count, :id)
    no_brand = Repo.aggregate(from(d in Domain, where: is_nil(d.brand_id)), :count, :id)

    %{
      missing_pm: no_pm,
      missing_po: no_po,
      missing_project: no_project,
      missing_brand: no_brand
    }
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
    scan_this_week =
      Repo.aggregate(from(m in DomainMetadata, where: m.scanned_at >= ^week_ago), :count, :id)

    scan_this_month =
      Repo.aggregate(
        from(m in DomainMetadata, where: m.scanned_at >= ^month_ago and m.scanned_at < ^week_ago),
        :count,
        :id
      )

    scan_older =
      Repo.aggregate(from(m in DomainMetadata, where: m.scanned_at < ^month_ago), :count, :id)

    %{
      this_week: scan_this_week,
      this_month: scan_this_month,
      older: scan_older,
      never: max(0, total - scan_this_week - scan_this_month - scan_older)
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

  defp external_redirect_dashboard?(domain_name, final_url) when is_binary(final_url) do
    final_host =
      final_url
      |> URI.parse()
      |> Map.get(:host)
      |> Kernel.||("")
      |> String.replace_leading("www.", "")

    own_host = String.replace_leading(domain_name, "www.", "")
    final_host != "" && final_host != own_host
  end

  defp external_redirect_dashboard?(_name, _url), do: false

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
