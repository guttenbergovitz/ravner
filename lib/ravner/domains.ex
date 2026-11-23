defmodule Ravner.Domains do
  @moduledoc """
  Core domain inventory and lifecycle management context.

  This module serves as the primary boundary for digital asset governance and discovery data.
  It strictly follows Ravner's **Stop Line** hybrid architecture:

  - **Governance Operations (Ash Layer)**:
    Domain creation (`create_domain/2`), updates (`update_domain/3`), deletion (`delete_domain/2`),
    ownership assignments (`assign_domain_brand/3`, `assign_domain_organization/3`, `assign_domain_project/3`),
    and lifecycle transitions (`set_domain_lifecycle/3`, `bulk_set_lifecycle/3`) are routed through
    Ash Framework actions. These enforce RBAC policies (`Ash.Policy.Authorizer`) and produce compliance
    audit records (`AshPaperTrail.Resource`).

  - **Runtime & High-Volume Paths (Pure Ecto / Repo Layer)**:
    Technical scanner status (`record_technical_status/2`), facet counts (`facets/1`), paginated filtering,
    and bulk discovery ingestion (`sync_dns_records/2`, `sync_tech_evidence/2`, `sync_discovered_urls/2`)
    bypass Ash entirely to ensure high I/O throughput and eliminate object allocation overhead.
  """

  require Logger
  require Ash.Query

  import Ecto.Query, warn: false
  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainMetadata
  alias Ravner.Domains.DomainTag
  alias Ravner.Domains.ContactResolver
  alias Ravner.Domains.SyncCoordinator
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
  Returns all domain IDs matching the given filter criteria without pagination.

  Used for bulk operations (bulk scan, bulk assignment, bulk lifecycle transitions)
  and select-all operations.

  ## Options
    - `:search` - string pattern matched against domain name
    - `:lifecycle` - lifecycle_state atom or list of atoms
    - `:technical_status` - technical_status atom or list
    - `:ip` - IP address string
    - `:brand_id` - brand ID or list of IDs
    - `:organization_id` / `:org_id` - organization ID or list of IDs
    - `:project_id` - project ID or list of IDs
    - `:include_subdomains` - boolean flag
  """
  @spec ids_matching_filters(keyword()) :: [integer()]
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
  Sets a domain lifecycle state through the governance action layer.
  """
  @spec set_domain_lifecycle(Domain.t(), atom() | String.t(), keyword()) ::
          {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def set_domain_lifecycle(%Domain{} = domain, lifecycle, opts \\ []) do
    attrs = %{lifecycle_state: normalize_atom(lifecycle)}
    execute_ash_action(domain, :set_lifecycle, attrs, opts, Domain.changeset(domain, attrs))
  end

  @doc """
  Assigns a domain to a project and derives organization/brand ownership.
  """
  @spec assign_domain_project(Domain.t() | integer() | String.t(), integer() | nil, keyword()) ::
          {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def assign_domain_project(%Domain{} = domain, project_id, opts) do
    attrs = project_assignment_attrs(project_id)
    execute_ash_action(domain, :assign_project, attrs, opts, Domain.changeset(domain, attrs))
  end

  def assign_domain_project(domain_id, project_id, opts)
      when is_integer(domain_id) or is_binary(domain_id) do
    domain = get_domain!(domain_id)
    assign_domain_project(domain, project_id, opts)
  end

  def assign_domain_project(domain_or_id, project_id),
    do: assign_domain_project(domain_or_id, project_id, [])

  @doc """
  Assigns a domain to a brand and clears lower-level ownership when needed.
  """
  @spec assign_domain_brand(Domain.t(), integer() | nil, keyword()) ::
          {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def assign_domain_brand(%Domain{} = domain, brand_id, opts \\ []) do
    attrs = %{brand_id: brand_id, organization_id: nil, project_id: nil}
    execute_ash_action(domain, :assign_brand, attrs, opts, Domain.changeset(domain, attrs))
  end

  @doc """
  Assigns a domain to an organization and derives brand ownership.
  """
  @spec assign_domain_organization(Domain.t(), integer() | nil, keyword()) ::
          {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def assign_domain_organization(%Domain{} = domain, organization_id, opts \\ []) do
    attrs = organization_assignment_attrs(organization_id)

    execute_ash_action(
      domain,
      :assign_organization,
      attrs,
      opts,
      Domain.changeset(domain, attrs)
    )
  end

  @doc """
  Sets lifecycle for multiple domains through Ash governance actions.
  """
  @spec bulk_set_lifecycle([integer()], atom(), keyword()) :: {:ok, integer()} | {:error, any()}
  def bulk_set_lifecycle(ids, lifecycle, opts \\ []) when is_list(ids) do
    bulk_apply(ids, fn domain -> set_domain_lifecycle(domain, lifecycle, opts) end)
  end

  @doc """
  Assigns ownership for multiple domains through Ash governance actions.
  """
  @spec bulk_assign([integer()], :brand | :org | :project, integer(), keyword()) ::
          {:ok, integer()} | {:error, any()}
  def bulk_assign(ids, type, target_id, opts \\ []) when is_list(ids) do
    bulk_apply(ids, fn domain ->
      case type do
        :brand -> assign_domain_brand(domain, target_id, opts)
        :org -> assign_domain_organization(domain, target_id, opts)
        :project -> assign_domain_project(domain, target_id, opts)
      end
    end)
  end

  @domain_action_atoms [
    :create,
    :update,
    :destroy,
    :set_lifecycle,
    :assign_brand,
    :assign_organization,
    :assign_project,
    :assign_contacts
  ]

  @doc """
  Assigns project manager and product owner contacts to a domain through Ash governance actions.
  """
  @spec assign_domain_contacts(Domain.t(), map(), keyword()) ::
          {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def assign_domain_contacts(%Domain{} = domain, attrs, opts \\ []) do
    attrs_to_save =
      attrs
      |> Map.take([:pm_email, :po_email, "pm_email", "po_email"])
      |> Enum.into(%{}, fn
        {k, v} when is_binary(k) -> {String.to_existing_atom(k), v}
        {k, v} -> {k, v}
      end)

    execute_ash_action(
      domain,
      :assign_contacts,
      attrs_to_save,
      opts,
      Domain.changeset(domain, attrs_to_save)
    )
  end

  # ─── Contact Resolution (delegated to ContactResolver) ──────────────────────

  @doc "Resolves candidate team members (PM, PO, full team) from assigned project."
  @spec project_team_candidates(Domain.t() | integer() | String.t() | nil) :: %{
          pm: [map()],
          po: [map()],
          all: [map()]
        }
  defdelegate project_team_candidates(domain_or_project_id), to: ContactResolver

  @doc "Returns PM/PO candidates including project team, org members, and users."
  @spec contact_candidates(Domain.t() | integer() | String.t() | nil) :: %{
          pm_candidates: [map()],
          po_candidates: [map()],
          all_candidates: [map()]
        }
  defdelegate contact_candidates(domain_or_id), to: ContactResolver

  @doc "Finds a Person entity matching the given email address."
  @spec find_person_by_email(String.t() | nil) :: Ravner.Inventory.Person.t() | nil
  defdelegate find_person_by_email(email), to: ContactResolver

  @doc """
  Lists all governance audit versions recorded by AshPaperTrail for the specified domain.
  Returns versions ordered from newest to oldest.
  """
  @spec list_domain_versions(Domain.t() | integer() | String.t()) :: [map()]
  def list_domain_versions(%Domain{id: id}), do: list_domain_versions(id)

  def list_domain_versions(domain_id) when is_binary(domain_id) do
    list_domain_versions(String.to_integer(domain_id))
  end

  def list_domain_versions(domain_id) when is_integer(domain_id) do
    _ = @domain_action_atoms

    Domain.Version
    |> Ash.Query.filter(version_source_id == ^domain_id)
    |> Ash.Query.sort(version_inserted_at: :desc)
    |> Ash.read!(authorize?: false)
  rescue
    _ -> []
  end

  @doc """
  Records scanner-observed technical status without changing governance lifecycle.
  """
  @spec record_technical_status(Domain.t() | integer() | String.t(), atom()) :: {:ok, integer()}
  def record_technical_status(%Domain{id: id}, status), do: record_technical_status(id, status)

  def record_technical_status(id, status)
      when status in [:unknown, :reachable, :redirect, :insecure, :error] do
    record_scanner_domain_update(id, %{technical_status: status})
  end

  @doc """
  Records scanner-maintained domain fields without invoking governance actions.
  """
  @spec record_scanner_domain_update(Domain.t() | integer() | String.t(), map()) ::
          {:ok, integer()}
  def record_scanner_domain_update(%Domain{id: id}, attrs),
    do: record_scanner_domain_update(id, attrs)

  def record_scanner_domain_update(id, attrs) when is_map(attrs) do
    allowed_attrs =
      attrs
      |> Map.take([
        :technical_status,
        :url,
        :parent_domain_id,
        :lifecycle_state,
        :redirect_target_url,
        :redirect_target_domain_id
      ])
      |> Map.put(:updated_at, DateTime.utc_now(:second))
      |> Map.to_list()

    {count, _} =
      Domain
      |> where([d], d.id == ^id)
      |> Repo.update_all(set: allowed_attrs)

    {:ok, count}
  end

  @doc """
  Records redirect lifecycle state from scanner detection.

  Determines if redirect is internal (target exists in our DB) or external.
  Only updates if domain is not already in a redirect state (avoids overwriting manual assignments).
  """
  def record_redirect_lifecycle(%Domain{} = domain, final_url) when is_binary(final_url) do
    # Skip if already in a redirect state (user may have manually set it)
    if domain.lifecycle_state in [:redirect_internal, :redirect_external] do
      {:ok, :already_redirect}
    else
      target_host = extract_host_from_url(final_url)

      case get_domain_by_hostname(target_host) do
        %Domain{id: target_id} ->
          record_scanner_domain_update(domain, %{
            lifecycle_state: :redirect_internal,
            redirect_target_url: final_url,
            redirect_target_domain_id: target_id
          })

        nil ->
          record_scanner_domain_update(domain, %{
            lifecycle_state: :redirect_external,
            redirect_target_url: final_url,
            redirect_target_domain_id: nil
          })
      end
    end
  end

  def record_redirect_lifecycle(_domain, _final_url), do: {:ok, :no_url}

  @doc """
  Gets a domain by its hostname (name field).
  """
  def get_domain_by_hostname(nil), do: nil
  def get_domain_by_hostname(""), do: nil

  def get_domain_by_hostname(hostname) when is_binary(hostname) do
    # Normalize: remove www. prefix
    normalized = String.replace_prefix(hostname, "www.", "")

    Domain
    |> where([d], d.name == ^normalized or d.name == ^hostname)
    |> limit(1)
    |> Repo.one()
  end

  defp extract_host_from_url(url) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) -> host
      _ -> nil
    end
  end

  defp extract_host_from_url(_), do: nil

  @doc """
  Deletes domains by their IDs in bulk.
  ...
  """
  @spec bulk_delete([integer()], keyword()) :: {:ok, integer()} | {:error, :actor_required}
  def bulk_delete(ids, opts \\ []) when is_list(ids) do
    actor = Keyword.get(opts, :actor)

    if is_nil(actor) do
      {:error, :actor_required}
    else
      scope = Ravner.Accounts.Scope.for_user(actor)
      permitted_ids = ids |> list_domains_by_ids(scope: scope) |> Enum.map(& &1.id)

      {count, _} =
        Domain
        |> where([d], d.id in ^permitted_ids)
        |> Repo.delete_all()

      {:ok, count}
    end
  end

  @doc """
  Returns dynamic facet counts for the given filters.
  Used for the modern faceted search sidebar.
  """
  @spec get_facet_counts(keyword()) :: %{
          lifecycle: [{atom(), integer()}],
          technical_status: [{atom(), integer()}],
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
      |> filter_by_scope(Keyword.get(opts, :scope))

    %{
      lifecycle: get_lifecycle_facets(base_query, opts),
      technical_status: get_technical_status_facets(base_query, opts),
      brands: get_brand_facets(base_query, opts),
      organizations: get_organization_facets(base_query, opts),
      projects: get_project_facets(base_query, opts),
      technologies: get_technology_facets(base_query, opts)
    }
  end

  defp get_lifecycle_facets(query, opts) do
    # When counting lifecycle, we ignore the lifecycle filter itself
    # but respect everything else (brand, org, project, search, ip)
    query
    |> filter_by_project(Keyword.get(opts, :project_id))
    |> filter_by_organization(Keyword.get(opts, :organization_id) || Keyword.get(opts, :org_id))
    |> filter_by_brand(Keyword.get(opts, :brand_id))
    |> group_by([d], d.lifecycle_state)
    |> select([d], {d.lifecycle_state, count(d.id)})
    |> Repo.all()
    |> Enum.reject(fn {k, _} -> is_nil(k) end)
    |> Enum.sort_by(fn {k, _} -> k end)
  end

  defp get_technical_status_facets(query, opts) do
    query
    |> filter_by_lifecycle(Keyword.get(opts, :lifecycle))
    |> filter_by_project(Keyword.get(opts, :project_id))
    |> filter_by_organization(Keyword.get(opts, :organization_id) || Keyword.get(opts, :org_id))
    |> filter_by_brand(Keyword.get(opts, :brand_id))
    |> group_by([d], d.technical_status)
    |> select([d], {d.technical_status, count(d.id)})
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
      |> filter_by_organization(Keyword.get(opts, :organization_id) || Keyword.get(opts, :org_id))

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
      |> filter_by_brand(Keyword.get(opts, :brand_id))

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
      |> filter_by_organization(Keyword.get(opts, :organization_id) || Keyword.get(opts, :org_id))
      |> filter_by_brand(Keyword.get(opts, :brand_id))

    from(p in Ravner.Inventory.Project,
      left_join: d in subquery(filtered_subquery),
      on: d.project_id == p.id,
      group_by: [p.id, p.display_name, p.name],
      select: {p.id, coalesce(p.display_name, p.name), count(d.id)}
    )
    |> Repo.all()
    |> Enum.sort_by(fn {_, name, _} -> name end)
  end

  defp get_technology_facets(query, opts) do
    # Get technology counts from domain_metadata.tech_stack array
    # Exclude the technology filter itself, respect other filters
    filtered_subquery =
      query
      |> filter_by_lifecycle(Keyword.get(opts, :lifecycle))
      |> filter_by_project(Keyword.get(opts, :project_id))
      |> filter_by_organization(Keyword.get(opts, :organization_id) || Keyword.get(opts, :org_id))
      |> filter_by_brand(Keyword.get(opts, :brand_id))

    # Unnest tech_stack and count occurrences
    raw_tech =
      from(m in DomainMetadata,
        join: d in subquery(filtered_subquery),
        on: d.id == m.domain_id,
        where: not is_nil(m.tech_stack) and m.tech_stack != [],
        select: %{tech_stack: m.tech_stack}
      )
      |> Repo.all()
      |> Enum.flat_map(& &1.tech_stack)
      |> Enum.flat_map(&split_comma_tech/1)
      |> Enum.reject(&junk_tech?/1)

    # Build hierarchical structure: %{base => %{versions: %{ver => count}, total: count}}
    raw_tech
    |> Enum.map(&normalize_tech/1)
    |> Enum.group_by(fn {base, _ver, _orig} -> base end)
    |> Enum.map(fn {base, items} ->
      versions =
        items
        |> Enum.group_by(fn {_b, ver, _orig} -> ver end, fn {_b, _ver, orig} -> orig end)
        |> Enum.reject(fn {ver, _} -> is_nil(ver) end)
        |> Enum.map(fn {ver, origs} -> {ver, length(origs), hd(origs)} end)
        |> Enum.sort_by(fn {ver, _, _} -> parse_version_tuple(ver) end, :desc)

      total = length(items)
      originals = Enum.map(items, fn {_, _, orig} -> orig end) |> Enum.uniq()

      {base, %{total: total, versions: versions, originals: originals}}
    end)
    |> Enum.sort_by(fn {base, _} -> String.downcase(base) end)
  end

  # Split comma-separated tech strings: "Next.js, Payload" → ["Next.js", "Payload"]
  defp split_comma_tech(name) do
    if String.contains?(name, ", ") and not String.contains?(name, "(") do
      String.split(name, ", ") |> Enum.map(&String.trim/1)
    else
      [name]
    end
  end

  # Junk tech entries to filter out (long descriptions, marketing text, company names)
  defp junk_tech?(name) do
    # Elementor/plugin setting fragments
    String.length(name) > 60 or
      String.contains?(name, "Powered by") or
      String.contains?(name, "Page Builder") or
      String.contains?(name, "features:") or
      String.contains?(name, "GmbH") or
      String.contains?(name, "Inc.") or
      String.contains?(name, "Ltd.") or
      String.contains?(name, "Corp.") or
      String.contains?(name, "Site Kit by") or
      String.starts_with?(name, "e_") or
      String.starts_with?(name, "css_") or
      String.contains?(name, "_loading") or
      String.contains?(name, "-enabled") or
      String.contains?(name, "-auto") or
      String.contains?(name, "font_display")
  end

  # Normalize tech string to {base_name, version, original}
  # Patterns: "PHP/7.4.33", "WordPress 6.6.5", "Astro v5.14.1", "Drupal 9 (url)"
  defp normalize_tech(name) do
    cond do
      # Pattern: Name/Version (PHP/7.4.33, Sulu/1.6.44)
      String.contains?(name, "/") and not String.contains?(name, "://") ->
        case String.split(name, "/", parts: 2) do
          [base, ver] -> {String.trim(base), String.trim(ver), name}
          _ -> {name, nil, name}
        end

      # Pattern: Name:Version (Astro:5.13.3, Shoelace:2.8.0)
      Regex.match?(~r/^[\w.-]+:\d/, name) ->
        case String.split(name, ":", parts: 2) do
          [base, ver] -> {String.trim(base), String.trim(ver), name}
          _ -> {name, nil, name}
        end

      # Pattern: Name vVersion (Astro v5.14.1)
      Regex.match?(~r/ v\d/, name) ->
        case Regex.run(~r/^(.+?) v([\d.]+)/, name) do
          [_, base, ver] -> {String.trim(base), ver, name}
          _ -> {name, nil, name}
        end

      # Pattern: Name Version (URL) - Drupal 9 (https://...)
      Regex.match?(~r/ \d.* \(http/, name) ->
        case Regex.run(~r/^(.+?) ([\d.]+) \(/, name) do
          [_, base, ver] -> {String.trim(base), ver, name}
          _ -> {name, nil, name}
        end

      # Pattern: Name Version at end (WordPress 6.6.5)
      Regex.match?(~r/ [\d.]+$/, name) ->
        case Regex.run(~r/^(.+?) ([\d.]+)$/, name) do
          [_, base, ver] -> {String.trim(base), ver, name}
          _ -> {name, nil, name}
        end

      true ->
        {name, nil, name}
    end
  end

  # Parse version string to tuple for sorting (descending by version)
  defp parse_version_tuple(nil), do: {0, 0, 0, 0}

  defp parse_version_tuple(ver) do
    ver
    |> String.split(".")
    |> Enum.take(4)
    |> Enum.map(fn s ->
      case Integer.parse(s) do
        {n, _} -> n
        :error -> 0
      end
    end)
    |> then(fn parts ->
      parts ++ List.duplicate(0, 4 - length(parts))
    end)
    |> List.to_tuple()
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
      |> Ash.load!(@domain_listing_preloads, authorize?: false)

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
  @spec list_domains_filtered_all(keyword()) :: [Domain.t()]
  def list_domains_filtered_all(opts \\ []) do
    filtered_query(opts)
    |> order_by([d], asc: d.name)
    |> Repo.all()
    |> Ash.load!(@domain_listing_preloads, authorize?: false)
  end

  defp filtered_query(opts) do
    lifecycle_filter = Keyword.get(opts, :lifecycle, nil)
    show_archived = Keyword.get(opts, :show_archived, false)
    hide_placeholders = Keyword.get(opts, :hide_placeholders, false)

    Domain
    |> filter_by_type(Keyword.get(opts, :include_subdomains, false))
    |> filter_by_search(Keyword.get(opts, :search, ""))
    |> filter_by_lifecycle(lifecycle_filter)
    |> filter_exclude_archived(show_archived, lifecycle_filter)
    |> filter_exclude_placeholders(hide_placeholders, lifecycle_filter)
    |> filter_by_technical_status(Keyword.get(opts, :technical_status, nil))
    |> filter_by_ip(Keyword.get(opts, :ip, ""))
    |> filter_by_project(Keyword.get(opts, :project_id, nil))
    |> filter_by_organization(Keyword.get(opts, :organization_id) || Keyword.get(opts, :org_id))
    |> filter_by_brand(Keyword.get(opts, :brand_id, nil))
    |> filter_by_monitored(Keyword.get(opts, :monitored_only, false))
    |> filter_by_technology(Keyword.get(opts, :technology))
    |> filter_by_scope(Keyword.get(opts, :scope))
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

  # Exclude archived states unless show_archived=true OR user explicitly filtered by lifecycle
  defp filter_exclude_archived(query, true, _lifecycle_filter), do: query

  defp filter_exclude_archived(query, _show, lifecycle) when lifecycle not in [nil, "", :all, []],
    do: query

  defp filter_exclude_archived(query, _show, _lifecycle) do
    archived = Domain.archived_states()
    where(query, [d], d.lifecycle_state not in ^archived)
  end

  # Exclude placeholders when hide_placeholders=true AND no explicit lifecycle filter
  defp filter_exclude_placeholders(query, false, _lifecycle_filter), do: query

  defp filter_exclude_placeholders(query, _hide, lifecycle)
       when lifecycle not in [nil, "", :all, []], do: query

  defp filter_exclude_placeholders(query, _hide, _lifecycle) do
    where(query, [d], d.lifecycle_state != :placeholder)
  end

  defp filter_by_technical_status(query, technical_status)
       when technical_status in [nil, "", :all, []],
       do: query

  defp filter_by_technical_status(query, technical_status) when is_list(technical_status),
    do: where(query, [d], d.technical_status in ^technical_status)

  defp filter_by_technical_status(query, technical_status),
    do: where(query, [d], d.technical_status == ^technical_status)

  defp filter_by_ip(query, ip) when ip in [nil, ""], do: query

  defp filter_by_ip(query, ip) do
    trimmed_ip = String.trim(ip)

    if trimmed_ip == "" do
      query
    else
      pattern = "%#{trimmed_ip}%"

      where(
        query,
        [d],
        d.id in subquery(
          from(m in DomainMetadata,
            where:
              fragment(
                "EXISTS (SELECT 1 FROM unnest(?) AS ip WHERE ip ILIKE ?)",
                m.ip_v4,
                ^pattern
              ),
            select: m.domain_id
          )
        )
      )
    end
  end

  defp filter_by_project(query, nil), do: query
  defp filter_by_project(query, []), do: query

  defp filter_by_project(query, project_id) when is_list(project_id),
    do: where(query, [d], d.project_id in ^project_id)

  defp filter_by_project(query, project_id), do: where(query, [d], d.project_id == ^project_id)

  defp filter_by_organization(query, org_id) when org_id in [nil, "", []], do: query

  defp filter_by_organization(query, org_id) do
    ids = List.wrap(org_id)

    where(
      query,
      [d],
      d.organization_id in ^ids or
        d.project_id in subquery(
          from(p in Ravner.Inventory.Project,
            where: p.organization_id in ^ids,
            select: p.id
          )
        )
    )
  end

  defp filter_by_brand(query, brand_id) when brand_id in [nil, "", []], do: query

  defp filter_by_brand(query, brand_id) do
    ids = List.wrap(brand_id)
    where(query, [d], d.brand_id in ^ids)
  end

  defp filter_by_monitored(query, true) do
    where(
      query,
      [d],
      d.id in subquery(
        from(m in DomainMetadata,
          where: not is_nil(m.heartbeat_interval_minutes),
          select: m.domain_id
        )
      )
    )
  end

  defp filter_by_monitored(query, _), do: query

  defp filter_by_scope(query, nil), do: query
  defp filter_by_scope(query, %Ravner.Accounts.Scope{global?: true}), do: query

  defp filter_by_scope(query, %Ravner.Accounts.Scope{domain_ids: domain_ids}) do
    where(query, [d], d.id in ^domain_ids)
  end

  defp filter_by_scope(query, %Ravner.Accounts.User{} = user) do
    filter_by_scope(query, Ravner.Accounts.Scope.for_user(user))
  end

  defp filter_by_technology(query, tech) when tech in [nil, "", []], do: query

  defp filter_by_technology(query, technologies) do
    tech_list = List.wrap(technologies)

    # Build patterns for each tech: "PHP" matches "PHP", "PHP/7.4", "PHP 8.1", etc.
    patterns =
      Enum.flat_map(tech_list, fn t ->
        if is_base_tech?(t) do
          # Base tech name → match variations
          [t, "#{t}/%", "#{t} %", "#{t}:%"]
        else
          # Specific version string → exact match only
          [t]
        end
      end)

    where(
      query,
      [d],
      d.id in subquery(
        from(m in DomainMetadata,
          where:
            fragment(
              "EXISTS (SELECT 1 FROM unnest(?) AS tech WHERE tech = ANY(?) OR tech LIKE ANY(?))",
              m.tech_stack,
              ^Enum.reject(patterns, &String.contains?(&1, "%")),
              ^Enum.filter(patterns, &String.contains?(&1, "%"))
            ),
          select: m.domain_id
        )
      )
    )
  end

  # Check if tech name is a base name (no version) vs versioned string
  defp is_base_tech?(name) do
    not (String.contains?(name, "/") or
           String.contains?(name, ":") or
           Regex.match?(~r/ v?\d/, name))
  end

  @spec suggest_domains(String.t() | term(), integer() | keyword(), keyword()) :: [String.t()]
  def suggest_domains(query, limit_or_opts \\ 5, opts \\ [])

  def suggest_domains(query, limit, opts) when is_integer(limit) do
    do_suggest_domains(query, limit, opts)
  end

  def suggest_domains(query, opts, _) when is_list(opts) do
    limit = Keyword.get(opts, :limit, 5)
    do_suggest_domains(query, limit, opts)
  end

  defp do_suggest_domains(query, limit, opts) when is_binary(query) and byte_size(query) > 0 do
    pattern = "%#{query}%"
    include_subdomains = Keyword.get(opts, :include_subdomains, false)

    Domain
    |> then(fn q ->
      if include_subdomains, do: q, else: where(q, type: :domain)
    end)
    |> where([d], ilike(d.name, ^pattern))
    |> order_by([d], asc: d.name)
    |> limit(^limit)
    |> select([d], d.name)
    |> Repo.all()
  end

  defp do_suggest_domains(_query, _limit, _opts), do: []

  @spec list_domains_with_preloads() :: [Domain.t()]
  def list_domains_with_preloads do
    Domain
    |> where(type: :domain)
    |> Repo.all()
    |> Ash.load!([:parent_domain, :subdomains, :domain_tags, :domain_metadata], authorize?: false)
  end

  @spec get_domain!(integer() | String.t()) :: Domain.t()
  def get_domain!(id), do: Repo.get!(Domain, id)

  @spec get_domain_with_preloads!(integer() | String.t()) :: Domain.t()
  def get_domain_with_preloads!(id) do
    Domain
    |> Ash.get!(id, authorize?: false)
    |> Ash.load!(
      [
        :parent_domain,
        :domain_tags,
        :domain_metadata,
        :dns_records,
        :tech_evidence,
        :discovered_urls,
        :registrar,
        application: [:hosting_environment, :datastores],
        project: [:project_manager, :product_owner],
        brand: [:brand_manager],
        organization: [:manager],
        subdomains: [:domain_metadata]
      ],
      authorize?: false
    )
  end

  @doc "Builds 3-tier governance escalation hierarchy (Project → Organization → Brand)."
  defdelegate domain_escalation_chain(domain), to: ContactResolver

  @spec get_domain_with_subdomains!(integer() | String.t()) :: Domain.t()
  def get_domain_with_subdomains!(id) do
    Domain
    |> Ash.get!(id, authorize?: false)
    |> Ash.load!([subdomains: [:domain_metadata]], authorize?: false)
  end

  @spec list_domains_by_ids([integer()], keyword()) :: [Domain.t()]
  def list_domains_by_ids(ids, opts \\ []) when is_list(ids) do
    scope = Keyword.get(opts, :scope)

    Domain
    |> where([d], d.id in ^ids)
    |> filter_by_scope(scope)
    |> Repo.all()
    |> Ash.load!([:subdomains], authorize?: false)
  end

  @spec list_domains_with_subdomains([integer()]) :: [Domain.t()]
  def list_domains_with_subdomains(ids) when is_list(ids) do
    Domain
    |> where([d], d.id in ^ids)
    |> Repo.all()
    |> Ash.load!([:parent_domain, subdomains: :domain_metadata], authorize?: false)
  end

  @doc """
  Preloads domain_metadata for all subdomains of given domain(s).
  Used for lazy-loading when expanding domains in the listing.
  """
  @spec preload_subdomain_metadata([Domain.t()] | Domain.t()) :: [Domain.t()] | Domain.t()
  def preload_subdomain_metadata(domains) when is_list(domains) do
    Ash.load!(domains, [subdomains: :domain_metadata], authorize?: false)
  end

  def preload_subdomain_metadata(%Domain{} = domain) do
    Ash.load!(domain, [subdomains: :domain_metadata], authorize?: false)
  end

  @spec create_domain(map(), keyword()) ::
          {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def create_domain(attrs \\ %{}, opts \\ []) do
    execute_ash_action(Domain, :create, attrs, opts, Domain.changeset(%Domain{}, attrs))
  end

  @spec update_domain(Domain.t(), map(), keyword()) ::
          {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_domain(%Domain{} = domain, attrs, opts \\ []) do
    execute_ash_action(domain, :update, attrs, opts, Domain.changeset(domain, attrs))
  end

  @spec update_domain_with_project(Domain.t(), integer() | nil, keyword()) ::
          {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
  def update_domain_with_project(%Domain{} = domain, project_id, opts \\ []) do
    assign_domain_project(domain, project_id, opts)
  end

  @spec delete_domain(Domain.t(), keyword()) ::
          {:ok, Domain.t()} | {:error, Ecto.Changeset.t() | atom()}
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

  @spec list_domain_tags(integer()) :: [DomainTag.t()]
  def list_domain_tags(domain_id) do
    DomainTag
    |> where([t], t.domain_id == ^domain_id and is_nil(t.removed_at))
    |> Repo.all()
  end

  @spec add_tag(integer(), String.t()) :: {:ok, DomainTag.t()} | {:error, Ecto.Changeset.t()}
  def add_tag(domain_id, tag) do
    %DomainTag{}
    |> DomainTag.changeset(%{domain_id: domain_id, tag: tag})
    |> Repo.insert()
  end

  @spec remove_tag(integer()) :: {:ok, DomainTag.t()} | {:error, Ecto.Changeset.t()}
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
  @spec bulk_import(String.t(), keyword()) :: %{
          added: [String.t()],
          skipped: [String.t()],
          ignored: [{String.t(), term()}],
          file_dupes: [String.t()]
        }
  def bulk_import(text, opts \\ []) when is_binary(text) do
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
          case create_domain(%{name: normalized, type: :domain}, opts) do
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
        # If it matches a known multi-part ccTLD, it's still apex (e.g. example.co.uk)
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
  def upsert_domain_metadata(domain_id, attrs, opts \\ [])

  def upsert_domain_metadata(domain_id, attrs, _opts) when is_map(attrs) do
    now = DateTime.utc_now(:second)

    attrs =
      attrs
      |> Map.put(:domain_id, domain_id)
      |> Map.put(:inserted_at, now)
      |> Map.put(:updated_at, now)

    changeset = DomainMetadata.changeset(%DomainMetadata{}, attrs)

    if changeset.valid? do
      # Ensure all explicitly provided attrs are persisted and included in replace_fields on conflict,
      # even if the value matches the struct default (which Ecto cast would otherwise drop).
      known_fields = DomainMetadata.__schema__(:fields)

      explicit_attrs =
        known_fields
        |> Enum.reject(&(&1 in [:id, :domain_id, :inserted_at, :updated_at]))
        |> Enum.filter(fn field ->
          Map.has_key?(attrs, field) or Map.has_key?(attrs, to_string(field))
        end)
        |> Map.new(fn field ->
          val =
            case Map.fetch(changeset.changes, field) do
              {:ok, v} ->
                v

              :error ->
                v =
                  case Map.fetch(attrs, field) do
                    {:ok, raw} -> raw
                    :error -> Map.get(attrs, to_string(field))
                  end

                case v do
                  %DateTime{} = dt -> DateTime.truncate(dt, :second)
                  other -> other
                end
            end

          {field, val}
        end)

      changes =
        changeset.changes
        |> Map.merge(explicit_attrs)
        |> Map.put(:inserted_at, now)
        |> Map.put(:updated_at, now)

      replace_fields =
        changes
        |> Map.keys()
        |> Enum.reject(&(&1 in [:id, :domain_id, :inserted_at]))

      Repo.insert_all(DomainMetadata, [changes],
        on_conflict: {:replace, replace_fields},
        conflict_target: [:domain_id]
      )

      {:ok, Repo.get_by!(DomainMetadata, domain_id: domain_id)}
    else
      {:error, changeset}
    end
  end

  @doc """
  Recalculates cyber risk posture and executive grade for a domain by aggregating
  vulnerabilities, hardcoded secret findings, SSL expiry, headers, and uptime metrics.
  """
  @spec recalculate_risk_score(Domain.t() | integer()) ::
          {:ok, Ravner.Governance.RiskScore.risk_result()} | {:error, term()}
  def recalculate_risk_score(domain_or_id) do
    Ravner.Governance.RiskScore.recalculate_for_domain(domain_or_id)
  end

  # ─── Sync Operations (delegated to SyncCoordinator) ─────────────────────────

  @doc "Replaces all DNS records for a domain with a newly discovered set."
  defdelegate sync_dns_records(domain_id, records), to: SyncCoordinator

  @doc "Replaces all tech evidence for a domain with a newly discovered set."
  defdelegate sync_tech_evidence(domain_id, evidence), to: SyncCoordinator

  @doc "Merges VCS-discovered technologies into a domain's tech evidence."
  defdelegate merge_vcs_tech_evidence(domain_id, technologies, provider \\ "bitbucket"),
    to: SyncCoordinator

  @doc "Collects technologies from all repositories and updates domain tech stack."
  defdelegate sync_all_vcs_tech_evidence_for_domain(domain_id), to: SyncCoordinator

  @doc "Replaces all discovered URLs for a domain with a newly discovered set."
  defdelegate sync_discovered_urls(domain_id, urls), to: SyncCoordinator

  @doc """
  Returns aggregate dashboard statistics.
  """
  @spec dashboard_stats() :: map()
  defdelegate dashboard_stats(), to: Ravner.Domains.DashboardStats, as: :get

  @doc """
  Converts a list of domains to CSV binary.
  """
  @spec to_csv([Domain.t()]) :: String.t()
  def to_csv(domains) when is_list(domains) do
    header =
      "Name,Type,Lifecycle,Technical Status,HTTP Status,Final URL,IP v4,Tech Stack,Registrar,Expires,Scanned,Subdomains\n"

    rows = Enum.map_join(domains, "\n", &domain_to_csv_row/1)

    header <> rows <> "\n"
  end

  defp domain_to_csv_row(domain) do
    m =
      case domain.domain_metadata do
        %Ravner.Domains.DomainMetadata{} = meta -> meta
        _ -> %Ravner.Domains.DomainMetadata{}
      end

    subdomains_count =
      case domain.subdomains do
        subs when is_list(subs) -> length(subs)
        _ -> 0
      end

    [
      domain.name,
      to_string(domain.type),
      to_string(domain.lifecycle_state),
      to_string(domain.technical_status || :unknown),
      format_http_status(m.http_status),
      m.final_url || "",
      format_list(m.ip_v4),
      format_list(m.tech_stack),
      m.registrar || "",
      format_date(m.expiration_date, "%Y-%m-%d"),
      format_date(m.scanned_at, "%Y-%m-%d %H:%M"),
      to_string(subdomains_count)
    ]
    |> Enum.map_join(",", &csv_escape/1)
  end

  defp format_list(nil), do: ""
  defp format_list(list) when is_list(list), do: Enum.join(list, "; ")

  defp format_date(nil, _format), do: ""
  defp format_date(date, format), do: Calendar.strftime(date, format)

  defp format_http_status(nil), do: ""
  defp format_http_status(status), do: to_string(status)

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

  defp normalize_atom(value) when is_atom(value), do: value
  defp normalize_atom(value) when is_binary(value), do: String.to_existing_atom(value)

  defp project_assignment_attrs(nil), do: %{project_id: nil, organization_id: nil, brand_id: nil}

  defp project_assignment_attrs(project_id) do
    project = Repo.get!(Ravner.Inventory.Project, project_id)
    org_id = project.organization_id
    org = if org_id, do: Repo.get!(Ravner.Inventory.Organization, org_id), else: nil

    %{
      project_id: project_id,
      brand_id: org && org.brand_id,
      organization_id: org_id
    }
  end

  defp organization_assignment_attrs(nil), do: %{organization_id: nil, project_id: nil}

  defp organization_assignment_attrs(organization_id) do
    org = Repo.get!(Ravner.Inventory.Organization, organization_id)
    %{organization_id: organization_id, brand_id: org.brand_id, project_id: nil}
  end

  defp bulk_apply(ids, fun) when is_function(fun, 1) do
    ids
    |> list_domains_by_ids()
    |> Enum.reduce_while({:ok, 0}, fn domain, {:ok, count} ->
      case fun.(domain) do
        {:ok, _domain} -> {:cont, {:ok, count + 1}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

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

          action
          when action in [
                 :set_lifecycle,
                 :assign_project,
                 :assign_brand,
                 :assign_organization,
                 :assign_contacts
               ] ->
            resource_or_record
            |> Ash.Changeset.for_update(action, attrs, actor: actor)
            |> Ash.update()

          :destroy ->
            Ash.destroy(resource_or_record, actor: actor)
        end

      case result do
        :ok ->
          {:ok, resource_or_record}

        {:ok, record} ->
          {:ok, record}

        {:error, %Ash.Error.Invalid{errors: [%Ash.Error.Forbidden{} | _]}} ->
          {:error, :forbidden}

        {:error, %Ash.Error.Forbidden{}} ->
          {:error, :forbidden}

        {:error, ash_err} ->
          Logger.warning(
            "Ravner.Domains: Ash #{action_type} action failed, falling back to changeset: " <>
              inspect(ash_err, limit: :infinity, printable_limit: 4096)
          )

          {:error, Ravner.AshErrorHelpers.to_ecto_changeset(ash_err, fallback_changeset)}
      end
    else
      {:error, fallback_changeset}
    end
  end
end
