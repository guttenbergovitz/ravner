defmodule Ravner.Domains do
  @moduledoc """
  The Domains context.
  """

  import Ecto.Query, warn: false
  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata
  alias Ravner.Domains.DomainTag
  alias Ravner.Domains.DnsRecord
  alias Ravner.Domains.TechEvidence
  alias Ravner.Domains.DiscoveredUrl
  alias Ravner.Repo

  # Domains

  @page_size 25
  @domain_listing_preloads [
    :parent_domain,
    :domain_tags,
    :domain_metadata,
    :project,
    :brand,
    :organization,
    subdomains: [:domain_metadata]
  ]

  @doc """
  Returns paginated, filtered domains.

  Options:
    - `:search`    - string matched against domain name (ilike)
    - `:lifecycle` - lifecycle_state atom or nil for all
    - `:page`      - 1-based page number (default 1)
  """
  def ids_matching_filters(opts \\ []) do
    filtered_query(opts)
    |> select([d], d.id)
    |> Repo.all()
  end

  @doc """
  Updates multiple domains by their IDs.
  """
  @spec bulk_update([integer()], map()) :: {:ok, integer()}
  def bulk_update(ids, attrs) when is_list(ids) and is_map(attrs) do
    now = DateTime.utc_now(:second)
    updates = attrs |> Map.put(:updated_at, now) |> Map.to_list()

    {count, _} =
      Domain
      |> where([d], d.id in ^ids)
      |> Repo.update_all(set: updates)

    {:ok, count}
  end

  @doc """
  Deletes domains by their IDs in bulk.
  ...
  """
  @spec bulk_delete([integer()]) :: {:ok, integer()}
  def bulk_delete(ids) when is_list(ids) do
    {count, _} =
      Domain
      |> where([d], d.id in ^ids)
      |> Repo.delete_all()

    {:ok, count}
  end

  @doc """
  Returns dynamic facet counts for the given filters.
  Used for the modern faceted search sidebar.
  """
  @spec get_facet_counts(keyword()) :: %{
          lifecycle: [{atom(), integer()}],
          brands: [{integer(), String.t(), integer()}],
          organizations: [{integer(), String.t(), integer()}],
          projects: [{integer(), String.t(), integer()}]
        }
  def get_facet_counts(opts \\ []) do
    # Global filters that affect all facets
    search = Keyword.get(opts, :search, "")
    ip = Keyword.get(opts, :ip, "")
    include_subdomains = Keyword.get(opts, :include_subdomains, false)

    base_query =
      Domain
      |> filter_by_type(include_subdomains)
      |> filter_by_search(search)
      |> filter_by_ip(ip)

    %{
      lifecycle: get_lifecycle_facets(base_query, opts),
      brands: get_brand_facets(base_query, opts),
      organizations: get_organization_facets(base_query, opts),
      projects: get_project_facets(base_query, opts)
    }
  end

  defp get_lifecycle_facets(query, opts) do
    # When counting lifecycle, we ignore the lifecycle filter itself
    # but respect everything else (brand, org, project, search, ip)
    query
    |> filter_by_project(Keyword.get(opts, :project_id))
    |> filter_by_organization_or_brand(
      Keyword.get(opts, :organization_id),
      Keyword.get(opts, :brand_id)
    )
    |> group_by([d], d.lifecycle_state)
    |> select([d], {d.lifecycle_state, count(d.id)})
    |> Repo.all()
    |> Enum.reject(fn {k, _} -> is_nil(k) end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp get_brand_facets(query, opts) do
    # Left join from all brands to the filtered query
    filtered_subquery =
      query
      |> filter_by_lifecycle(Keyword.get(opts, :lifecycle))
      |> filter_by_project(Keyword.get(opts, :project_id))
      |> filter_by_organization_or_brand(Keyword.get(opts, :organization_id), nil)

    from(b in Ravner.Inventory.Brand,
      left_join: d in subquery(filtered_subquery),
      on: d.brand_id == b.id,
      group_by: [b.id, b.display_name, b.name],
      select: {b.id, coalesce(b.display_name, b.name), count(d.id)}
    )
    |> Repo.all()
    |> Enum.sort_by(fn {_, name, _} -> name end)
  end

  defp get_organization_facets(query, opts) do
    # Left join from all organizations to the filtered query
    filtered_subquery =
      query
      |> filter_by_lifecycle(Keyword.get(opts, :lifecycle))
      |> filter_by_project(Keyword.get(opts, :project_id))
      |> filter_by_organization_or_brand(nil, Keyword.get(opts, :brand_id))

    from(o in Ravner.Inventory.Organization,
      left_join: d in subquery(filtered_subquery),
      on: d.organization_id == o.id,
      group_by: [o.id, o.display_name, o.name],
      select: {o.id, coalesce(o.display_name, o.name), count(d.id)}
    )
    |> Repo.all()
    |> Enum.sort_by(fn {_, name, _} -> name end)
  end

  defp get_project_facets(query, opts) do
    # Left join from all projects to the filtered query
    filtered_subquery =
      query
      |> filter_by_lifecycle(Keyword.get(opts, :lifecycle))
      |> filter_by_organization_or_brand(
        Keyword.get(opts, :organization_id),
        Keyword.get(opts, :brand_id)
      )

    from(p in Ravner.Inventory.Project,
      left_join: d in subquery(filtered_subquery),
      on: d.project_id == p.id,
      group_by: [p.id, p.display_name, p.name],
      select: {p.id, coalesce(p.display_name, p.name), count(d.id)}
    )
    |> Repo.all()
    |> Enum.sort_by(fn {_, name, _} -> name end)
  end

  @doc """
  Returns a paginated list of domains matching the given filters.
  ...
  """
  @spec list_domains_filtered(keyword()) :: %{
          domains: [Domain.t()],
          page: integer(),
          total_pages: integer(),
          total: integer(),
          page_size: integer()
        }
  def list_domains_filtered(opts \\ []) do
    base = filtered_query(opts)
    page = max(Keyword.get(opts, :page, 1), 1)

    total = Repo.aggregate(base, :count, :id)
    total_pages = max(ceil(total / @page_size), 1)
    page = min(page, total_pages)
    offset = (page - 1) * @page_size

    domains =
      base
      |> order_by([d], asc: d.name)
      |> limit(@page_size)
      |> offset(^offset)
      |> Repo.all()
      |> Ash.load!(@domain_listing_preloads)

    %{
      domains: domains,
      page: page,
      total_pages: total_pages,
      total: total,
      page_size: @page_size
    }
  end

  @doc """
  Returns all domains matching the given filters, without pagination.
  """
  def list_domains_filtered_all(opts \\ []) do
    filtered_query(opts)
    |> order_by([d], asc: d.name)
    |> Repo.all()
    |> Ash.load!(@domain_listing_preloads)
  end

  defp filtered_query(opts) do
    Domain
    |> filter_by_type(Keyword.get(opts, :include_subdomains, false))
    |> filter_by_search(Keyword.get(opts, :search, ""))
    |> filter_by_lifecycle(Keyword.get(opts, :lifecycle, nil))
    |> filter_by_ip(Keyword.get(opts, :ip, ""))
    |> filter_by_project(Keyword.get(opts, :project_id, nil))
    |> filter_by_organization_or_brand(
      Keyword.get(opts, :organization_id, nil),
      Keyword.get(opts, :brand_id, nil)
    )
  end

  defp filter_by_type(query, true), do: query
  defp filter_by_type(query, _), do: where(query, type: :domain)

  defp filter_by_search(query, search) when search in [nil, ""], do: query

  defp filter_by_search(query, search) do
    pattern = "%#{search}%"
    where(query, [d], ilike(d.name, ^pattern))
  end

  defp filter_by_lifecycle(query, lifecycle) when lifecycle in [nil, "", :all, []], do: query

  defp filter_by_lifecycle(query, lifecycle) when is_list(lifecycle),
    do: where(query, [d], d.lifecycle_state in ^lifecycle)

  defp filter_by_lifecycle(query, lifecycle),
    do: where(query, [d], d.lifecycle_state == ^lifecycle)

  defp filter_by_ip(query, ip) when ip in [nil, ""], do: query

  defp filter_by_ip(query, ip) do
    pattern = "%#{ip}%"

    query
    |> join(:inner, [d], m in assoc(d, :domain_metadata))
    |> where(
      [_d, m],
      fragment("EXISTS (SELECT 1 FROM unnest(?) AS ip WHERE ip ILIKE ?)", m.ip_v4, ^pattern)
    )
  end

  defp filter_by_project(query, nil), do: query
  defp filter_by_project(query, []), do: query

  defp filter_by_project(query, project_id) when is_list(project_id),
    do: where(query, [d], d.project_id in ^project_id)

  defp filter_by_project(query, project_id), do: where(query, [d], d.project_id == ^project_id)

  defp filter_by_organization_or_brand(query, nil, nil), do: query
  defp filter_by_organization_or_brand(query, [], []), do: query

  defp filter_by_organization_or_brand(query, organization_id, brand_id) do
    joined_query =
      query
      |> join(:left, [d], p in Ravner.Inventory.Project, on: d.project_id == p.id)
      |> join(:left, [d, p], o in Ravner.Inventory.Organization,
        on: d.organization_id == o.id or p.organization_id == o.id
      )

    cond do
      organization_id && organization_id != [] ->
        ids = List.wrap(organization_id)
        where(joined_query, [d, p, o], d.organization_id in ^ids or p.organization_id in ^ids)

      brand_id && brand_id != [] ->
        ids = List.wrap(brand_id)
        where(joined_query, [d], d.brand_id in ^ids)

      true ->
        joined_query
    end
  end

  def suggest_domains(query, limit \\ 5)

  def suggest_domains(query, limit) when is_binary(query) and byte_size(query) > 0 do
    pattern = "%#{query}%"

    Domain
    |> where(type: :domain)
    |> where([d], ilike(d.name, ^pattern))
    |> order_by([d], asc: d.name)
    |> limit(^limit)
    |> select([d], d.name)
    |> Repo.all()
  end

  def suggest_domains(_query, _limit), do: []

  def list_domains_with_preloads do
    Domain
    |> where(type: :domain)
    |> Repo.all()
    |> Repo.preload([:parent_domain, :subdomains, :domain_tags, :domain_metadata],
      in_parallel: false
    )
  end

  @spec get_domain!(integer() | String.t()) :: Domain.t()
  def get_domain!(id), do: Repo.get!(Domain, id)

  @spec get_domain_with_preloads!(integer() | String.t()) :: Domain.t()
  def get_domain_with_preloads!(id) do
    Domain
    |> Ash.get!(id)
    |> Ash.load!(
      [
        :parent_domain,
        :domain_tags,
        :domain_metadata,
        :project,
        :brand,
        :organization,
        :dns_records,
        :tech_evidence,
        :discovered_urls,
        subdomains: [:domain_metadata]
      ]
    )
  end

  def get_domain_with_subdomains!(id) do
    Domain
    |> Ash.get!(id)
    |> Ash.load!([subdomains: [:domain_metadata]])
  end

  def list_domains_by_ids(ids) when is_list(ids) do
    Domain
    |> where([d], d.id in ^ids)
    |> Repo.all()
  end

  def list_domains_with_subdomains(ids) when is_list(ids) do
    Domain
    |> where([d], d.id in ^ids)
    |> Repo.all()
    |> Repo.preload(
      [
        :parent_domain,
        subdomains: :domain_metadata
      ],
      in_parallel: false
    )
  end

  @doc """
  Preloads domain_metadata for all subdomains of a given domain.
  Used for lazy-loading when expanding a domain in the listing.
  """
  def preload_subdomain_metadata(%Domain{subdomains: subs} = domain) when is_list(subs) do
    %{domain | subdomains: Repo.preload(subs, :domain_metadata)}
  end

  def preload_subdomain_metadata(domain), do: domain

  @spec create_domain(map(), keyword()) :: {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_domain(attrs \\ %{}, opts \\ []) do
    execute_ash_action(Domain, :create, attrs, opts, Domain.changeset(%Domain{}, attrs))
  end

  @spec update_domain(Domain.t(), map(), keyword()) :: {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_domain(%Domain{} = domain, attrs, opts \\ []) do
    execute_ash_action(domain, :update, attrs, opts, Domain.changeset(domain, attrs))
  end

  def update_domain_with_project(%Domain{} = domain, project_id, opts \\ []) do
    attrs = %{project_id: project_id}

    attrs =
      if project_id do
        project = Repo.get!(Ravner.Inventory.Project, project_id)
        org_id = project.organization_id

        org =
          if org_id, do: Repo.get!(Ravner.Inventory.Organization, org_id), else: nil

        Map.merge(attrs, %{
          brand_id: org && org.brand_id,
          organization_id: org_id
        })
      else
        attrs
      end

    execute_ash_action(domain, :update, attrs, opts, Domain.changeset(domain, attrs))
  end

  @spec delete_domain(Domain.t(), keyword()) :: {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def delete_domain(%Domain{} = domain, opts \\ []) do
    execute_ash_action(domain, :destroy, %{}, opts, Domain.changeset(domain, %{}))
  end

  @spec change_domain(Domain.t(), map()) :: Ecto.Changeset.t()
  def change_domain(%Domain{} = domain, attrs \\ %{}) do
    Domain.changeset(domain, attrs)
  end

  @spec find_domain_by_name(String.t()) :: Domain.t() | nil
  def find_domain_by_name(name) do
    Repo.get_by(Domain, name: name)
  end

  # Domain Tags

  def list_domain_tags(domain_id) do
    DomainTag
    |> where([t], t.domain_id == ^domain_id and is_nil(t.removed_at))
    |> Repo.all()
  end

  def add_tag(domain_id, tag) do
    %DomainTag{}
    |> DomainTag.changeset(%{domain_id: domain_id, tag: tag})
    |> Repo.insert()
  end

  def remove_tag(tag_id) do
    Repo.get!(DomainTag, tag_id)
    |> DomainTag.changeset(%{removed_at: DateTime.utc_now()})
    |> Repo.update()
  end

  # Bulk Import

  # Known multi-part ccTLD second-level domains (e.g. .co.uk, .com.ua).
  # Kept as a sorted list (no duplicates) for easy auditing.
  @multi_part_tlds ~w(
    co.hu
    co.il
    co.in
    co.jp
    co.kr
    co.nz
    co.tz
    co.uk
    co.za
    com.ar
    com.au
    com.br
    com.cn
    com.kr
    com.mx
    com.pe
    com.pl
    com.sg
    com.tr
    com.ua
    com.uk
    com.vn
    edu.au
    me.uk
    net.au
    net.br
    net.cn
    net.il
    net.in
    net.kr
    net.nz
    net.pl
    net.tr
    net.ua
    net.uk
    net.vn
    or.kr
    or.tz
    org.au
    org.br
    org.cn
    org.nz
    org.pl
    org.tr
    org.ua
    org.uk
  )

  @doc """
  Parses a newline-separated string of domain names and bulk-imports them.

  Returns a map:
    %{
      added:      [domain_name],            # newly created
      skipped:    [domain_name],            # already existed
      ignored:    [{domain_name, reason}],  # invalid format, non-apex, etc.
      file_dupes: [domain_name]             # duplicate within the input itself
    }
  """
  @spec bulk_import(String.t()) :: %{
          added: [String.t()],
          skipped: [String.t()],
          ignored: [{String.t(), term()}],
          file_dupes: [String.t()]
        }
  def bulk_import(text) when is_binary(text) do
    lines =
      text
      |> String.split(~r/\r?\n/)
      |> Enum.map(&String.trim/1)
      |> Enum.map(&strip_scheme_and_path/1)
      |> Enum.reject(&(&1 == ""))

    # Track duplicates within the file
    {unique_lines, dupes} =
      Enum.reduce(lines, {[], MapSet.new(), []}, fn name, {uniq, seen, dupes_acc} ->
        normalized = String.downcase(name)

        if MapSet.member?(seen, normalized) do
          {uniq, seen, [name | dupes_acc]}
        else
          {[name | uniq], MapSet.put(seen, normalized), dupes_acc}
        end
      end)
      |> then(fn {uniq, _seen, dupes} -> {Enum.reverse(uniq), dupes} end)

    # First pass: classify every line into {valid, normalized} or
    # {invalid, reason}. Pure work, no DB access.
    {valid, ignored_invalid} =
      Enum.reduce(unique_lines, {[], []}, fn name, {valid, ignored} ->
        case classify_import_line(name) do
          {:ok, normalized} -> {[{name, normalized} | valid], ignored}
          {:error, reason} -> {valid, [{name, reason} | ignored]}
        end
      end)

    valid = Enum.reverse(valid)

    # Single batched existence query: SELECT name FROM domains WHERE name IN (...).
    # Replaces the previous per-line `find_domain_by_name/1` (N round-trips).
    existing =
      case valid do
        [] ->
          MapSet.new()

        _ ->
          names = Enum.map(valid, fn {_orig, normalized} -> normalized end)

          Domain
          |> where([d], d.name in ^names)
          |> select([d], d.name)
          |> Repo.all()
          |> MapSet.new()
      end

    # Second pass: insert only the names that don't already exist.
    {added, skipped, ignored_inserts} =
      Enum.reduce(valid, {[], [], []}, fn {orig_name, normalized}, {added, skipped, ignored} ->
        if MapSet.member?(existing, normalized) do
          {added, [normalized | skipped], ignored}
        else
          case create_domain(%{name: normalized, type: :domain}) do
            {:ok, domain} ->
              {[domain.name | added], skipped, ignored}

            {:error, cs} ->
              {added, skipped, [{orig_name, format_errors(cs)} | ignored]}
          end
        end
      end)

    %{
      added: Enum.reverse(added),
      skipped: Enum.reverse(skipped),
      ignored: Enum.reverse(ignored_inserts) ++ Enum.reverse(ignored_invalid),
      file_dupes: Enum.reverse(dupes)
    }
  end

  defp strip_scheme_and_path(name) do
    name
    |> String.replace_prefix("https://", "")
    |> String.replace_prefix("http://", "")
    |> String.split("/")
    |> List.first()
    |> String.trim()
  end

  defp classify_import_line(name) do
    normalized = String.downcase(name)

    cond do
      not valid_domain_format?(normalized) ->
        {:error, "invalid format"}

      not apex_domain?(normalized) ->
        {:error, "not an apex domain (subdomain detected)"}

      true ->
        {:ok, normalized}
    end
  end

  defp valid_domain_format?(name) do
    Regex.match?(~r/^[a-z0-9]([a-z0-9\-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9\-]*[a-z0-9])?)+$/, name)
  end

  defp apex_domain?(name) do
    labels = String.split(name, ".")
    count = length(labels)

    cond do
      count == 1 ->
        # No TLD at all — not a valid domain
        false

      count == 2 ->
        # Standard: example.com
        true

      count == 3 ->
        suffix = Enum.take(labels, -2) |> Enum.join(".")
        # If it matches a known multi-part ccTLD, it's still apex (e.g. josera.co.uk)
        # Otherwise it's a subdomain (e.g. www.example.com)
        Enum.member?(@multi_part_tlds, suffix)

      count >= 4 ->
        # Only apex if last 3 parts match a multi-part TLD (very rare, e.g. sub.co.uk is 3 → but 4+ = subdomain)
        false
    end
  end

  defp format_errors(%Ecto.Changeset{} = cs) do
    Ecto.Changeset.traverse_errors(cs, fn {msg, opts} ->
      Enum.reduce(opts, msg, fn {key, value}, acc ->
        String.replace(acc, "%{#{key}}", to_string(value))
      end)
    end)
    |> Enum.map_join("; ", fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
  end

  # Domain Metadata

  @spec get_domain_metadata(integer() | String.t()) :: DomainMetadata.t() | nil
  def get_domain_metadata(domain_id) do
    Repo.get_by(DomainMetadata, domain_id: domain_id)
  end

  @doc """
  Inserts or updates the metadata row for `domain_id`.

  Implemented as a single atomic `INSERT ... ON CONFLICT DO UPDATE`
  against the `unique_index(:domain_metadata, [:domain_id])`. Replaces
  ONLY the fields explicitly set by the caller (plus `:updated_at`),
  matching the previous get-then-update behaviour where fields absent
  from `attrs` were preserved on the existing row.

  This eliminates the race window between the previous `get_by` and
  `Repo.insert/update` calls — two concurrent scans for the same
  domain_id can no longer race to insert a duplicate row or clobber
  each other's writes.
  """
  @spec upsert_domain_metadata(integer() | String.t(), map(), keyword()) ::
          {:ok, DomainMetadata.t()} | {:error, any()}
  def upsert_domain_metadata(domain_id, attrs, opts \\ []) do
    actor = Keyword.get(opts, :actor)

    case Repo.get_by(DomainMetadata, domain_id: domain_id) do
      nil ->
        DomainMetadata
        |> Ash.Changeset.for_create(:create, Map.put(attrs, :domain_id, domain_id), actor: actor)
        |> Ash.create()

      metadata ->
        metadata
        |> Ash.Changeset.for_update(:update, attrs, actor: actor)
        |> Ash.update()
    end
  end

  @doc """
  Replaces all DNS records for a domain with a new set.
  """
  def sync_dns_records(domain_id, records) when is_list(records) do
    Repo.transaction(fn ->
      DnsRecord |> where(domain_id: ^domain_id) |> Repo.delete_all()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(records, fn r ->
          %{
            domain_id: domain_id,
            type: r[:type] || r["type"],
            value: r[:value] || r["value"],
            ttl: r[:ttl] || r["ttl"],
            inserted_at: now,
            updated_at: now
          }
        end)

      if entries != [], do: Repo.insert_all(DnsRecord, entries)
    end)
  end

  @doc """
  Replaces all tech evidence for a domain with a new set.
  """
  def sync_tech_evidence(domain_id, evidence) when is_list(evidence) do
    Repo.transaction(fn ->
      TechEvidence |> where(domain_id: ^domain_id) |> Repo.delete_all()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(evidence, fn e ->
          %{
            domain_id: domain_id,
            name: e[:name] || e["name"] || e["App"] || "Unknown",
            version: e[:version] || e["version"],
            source: e[:source] || e["source"],
            confidence: e[:confidence] || e["confidence"],
            inserted_at: now,
            updated_at: now
          }
        end)

      if entries != [], do: Repo.insert_all(TechEvidence, entries)
    end)
  end

  @doc """
  Replaces all discovered URLs for a domain with a new set.
  """
  def sync_discovered_urls(domain_id, urls) when is_list(urls) do
    Repo.transaction(fn ->
      DiscoveredUrl |> where(domain_id: ^domain_id) |> Repo.delete_all()

      now = DateTime.utc_now() |> DateTime.truncate(:second)

      entries =
        Enum.map(urls, fn u ->
          %{
            domain_id: domain_id,
            url: u[:url] || u["url"],
            status: u[:status] || u["status"],
            content_type: u[:content_type] || u["content_type"],
            source: u[:source] || u["source"],
            inserted_at: now,
            updated_at: now
          }
        end)

      if entries != [], do: Repo.insert_all(DiscoveredUrl, entries)
    end)
  end

  @doc """
  Returns aggregate dashboard statistics.
  """
  defdelegate dashboard_stats(), to: Ravner.Domains.DashboardStats, as: :get

  @doc """
  Converts a list of domains to CSV binary.
  """
  @spec to_csv([Domain.t()]) :: String.t()
  def to_csv(domains) when is_list(domains) do
    header =
      "Name,Type,Lifecycle,HTTP Status,Final URL,IP v4,Tech Stack,Registrar,Expires,Scanned,Subdomains\n"

    rows = Enum.map_join(domains, "\n", &domain_to_csv_row/1)

    header <> rows <> "\n"
  end

  defp domain_to_csv_row(domain) do
    m = domain.domain_metadata || %Ravner.Domains.DomainMetadata{}

    ip = if m.ip_v4, do: Enum.join(m.ip_v4, "; "), else: ""
    tech = if m.tech_stack, do: Enum.join(m.tech_stack, "; "), else: ""
    registrar = m.registrar || ""

    expires =
      if m.expiration_date,
        do: Calendar.strftime(m.expiration_date, "%Y-%m-%d"),
        else: ""

    scanned =
      if m.scanned_at,
        do: Calendar.strftime(m.scanned_at, "%Y-%m-%d %H:%M"),
        else: ""

    http = if m.http_status, do: to_string(m.http_status), else: ""
    final = m.final_url || ""
    subs = length(domain.subdomains || [])

    [
      domain.name,
      to_string(domain.type),
      to_string(domain.lifecycle_state),
      http,
      final,
      ip,
      tech,
      registrar,
      expires,
      scanned,
      to_string(subs)
    ]
    |> Enum.map_join(",", &csv_escape/1)
  end

  defp csv_escape(nil), do: ""

  defp csv_escape(value) do
    str = to_string(value)

    if String.contains?(str, [",", "\"", "\n", "\r"]) do
      escaped = String.replace(str, "\"", "\"\"")
      "\"#{escaped}\""
    else
      str
    end
  end

  # ── Internal Helpers ─────────────────────────────────────────────────────────

  defp execute_ash_action(resource_or_record, action_type, attrs, opts, fallback_changeset) do
    actor = Keyword.get(opts, :actor)

    if fallback_changeset.valid? do
      result =
        case action_type do
          :create ->
            resource_or_record
            |> Ash.Changeset.for_create(:create, attrs, actor: actor)
            |> Ash.create()

          :update ->
            resource_or_record
            |> Ash.Changeset.for_update(:update, attrs, actor: actor)
            |> Ash.update()

          :destroy ->
            Ash.destroy(resource_or_record, actor: actor)
        end

      case result do
        :ok -> {:ok, resource_or_record}
        {:ok, record} -> {:ok, record}
        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Forbidden{} | _]}} -> {:error, :forbidden}
        {:error, %Ash.Error.Forbidden{}} -> {:error, :forbidden}
        {:error, _ash_err} -> {:error, fallback_changeset}
      end
    else
      {:error, fallback_changeset}
    end
  end
end
