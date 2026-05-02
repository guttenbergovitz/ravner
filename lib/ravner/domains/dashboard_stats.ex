defmodule Ravner.Domains.DashboardStats do
  @moduledoc """
  Encapsulates the complex aggregation and calculation logic for the dashboard statistics.
  """

  import Ecto.Query

  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata
  alias Ravner.Repo

  @doc """
  Returns aggregate dashboard statistics.
  """
  def get do
    total = Repo.aggregate(Domain, :count, :id)
    total_apex = Repo.aggregate(from(d in Domain, where: d.type == :domain), :count, :id)
    total_subdomains = Repo.aggregate(from(d in Domain, where: d.type == :subdomain), :count, :id)

    lifecycle_apex =
      Domain
      |> where(type: :domain)
      |> group_by([d], d.lifecycle_state)
      |> select([d], {d.lifecycle_state, count(d.id)})
      |> Repo.all()
      |> Map.new()

    lifecycle_sub =
      Domain
      |> where(type: :subdomain)
      |> group_by([d], d.lifecycle_state)
      |> select([d], {d.lifecycle_state, count(d.id)})
      |> Repo.all()
      |> Map.new()

    now = DateTime.utc_now()
    week_ago = DateTime.add(now, -7 * 24 * 60 * 60, :second)
    month_ago = DateTime.add(now, -30 * 24 * 60 * 60, :second)

    # Fetch all apex metadata to compute proper counts
    # (redirects are detected by comparing final_url to domain name,
    #  since httpx follows redirects and stores the final status)
    metadata_with_name =
      Repo.all(
        from(m in DomainMetadata,
          join: d in Domain,
          on: m.domain_id == d.id and d.type == :domain,
          select: %{name: d.name, http_status: m.http_status, final_url: m.final_url}
        )
      )

    {http_200, http_3xx, http_4xx_5xx} =
      metadata_with_name
      |> Enum.map(fn row ->
        cond do
          row.http_status >= 200 and row.http_status < 400 and
              external_redirect_dashboard?(row.name, row.final_url) ->
            {:redirect, 1}

          row.http_status >= 200 and row.http_status < 300 ->
            {:ok, 1}

          row.http_status == 0 or row.http_status >= 400 ->
            {:error, 1}

          true ->
            {:ok, 0}
        end
      end)
      |> Enum.reduce({0, 0, 0}, fn
        {:ok, _}, {ok, redir, err} -> {ok + 1, redir, err}
        {:redirect, _}, {ok, redir, err} -> {ok, redir + 1, err}
        {:error, _}, {ok, redir, err} -> {ok, redir, err + 1}
      end)

    http_unscanned = max(0, total_apex - Enum.count(metadata_with_name))

    scan_this_week =
      from(m in DomainMetadata,
        where: m.scanned_at >= ^week_ago
      )
      |> Repo.aggregate(:count, :id)

    scan_this_month =
      from(m in DomainMetadata,
        where: m.scanned_at >= ^month_ago and m.scanned_at < ^week_ago
      )
      |> Repo.aggregate(:count, :id)

    scan_older =
      from(m in DomainMetadata,
        where: m.scanned_at < ^month_ago
      )
      |> Repo.aggregate(:count, :id)

    scan_never = max(0, total - scan_this_week - scan_this_month - scan_older)

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

    lifecycle_labels = %{
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

    lifecycle_list =
      lifecycle_order
      |> Enum.map(fn state ->
        apex = Map.get(lifecycle_apex, state, 0)
        sub = Map.get(lifecycle_sub, state, 0)

        %{
          state: state,
          label: Map.get(lifecycle_labels, state, Atom.to_string(state)),
          apex: apex,
          sub: sub,
          total: apex + sub
        }
      end)
      |> Enum.filter(&(&1.total > 0))

    top_by_subs =
      Domain
      |> where(type: :domain)
      |> join(:left, [d], s in Domain, on: s.parent_domain_id == d.id)
      |> group_by([d], d.id)
      |> select([d, s], %{name: d.name, count: count(s.id)})
      |> order_by([_d, s], desc: count(s.id))
      |> limit(20)
      |> Repo.all()
      |> Enum.map(&{&1.name, &1.count})
      |> Enum.filter(fn {_, c} -> c > 0 end)

    %{
      total: total,
      total_apex: total_apex,
      total_subdomains: total_subdomains,
      lifecycle_list: lifecycle_list,
      top_by_subs: top_by_subs,
      http: %{
        http_200: http_200,
        http_3xx: http_3xx,
        http_4xx_5xx: http_4xx_5xx,
        http_unscanned: http_unscanned
      },
      scan: %{
        this_week: scan_this_week,
        this_month: scan_this_month,
        older: scan_older,
        never: scan_never
      }
    }
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
end
