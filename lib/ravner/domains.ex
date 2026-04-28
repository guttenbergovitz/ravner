defmodule Ravner.Domains do
  @moduledoc """
  The Domains context.
  """

  import Ecto.Query, warn: false
  alias Ravner.Repo

  alias Ravner.Domains.Domain
  alias Ravner.Domains.DomainTag
  alias Ravner.Domains.DomainMetadata

  # Domains

  def list_domains do
    Repo.all(Domain)
  end

  @page_size 25

  @doc """
  Returns paginated, filtered domains.

  Options:
    - `:search`    - string matched against domain name (ilike)
    - `:lifecycle` - lifecycle_state atom or nil for all
    - `:page`      - 1-based page number (default 1)
  """
  def ids_matching_filters(opts \\ []) do
    search = Keyword.get(opts, :search, "")
    lifecycle = Keyword.get(opts, :lifecycle, nil)

    Domain
    |> where(type: :domain)
    |> then(fn q ->
      if search && search != "" do
        pattern = "%#{search}%"
        where(q, [d], ilike(d.name, ^pattern))
      else
        q
      end
    end)
    |> then(fn q ->
      if lifecycle && lifecycle != "" && lifecycle != :all do
        where(q, [d], d.lifecycle_state == ^lifecycle)
      else
        q
      end
    end)
    |> select([d], d.id)
    |> Repo.all()
  end

  def bulk_delete(ids) when is_list(ids) do
    {count, _} =
      Domain
      |> where([d], d.id in ^ids)
      |> Repo.delete_all()

    {:ok, count}
  end

  def list_domains_filtered(opts \\ []) do
    search = Keyword.get(opts, :search, "")
    lifecycle = Keyword.get(opts, :lifecycle, nil)
    page = max(Keyword.get(opts, :page, 1), 1)

    base =
      Domain
      |> where(type: :domain)
      |> then(fn q ->
        if search && search != "" do
          pattern = "%#{search}%"
          where(q, [d], ilike(d.name, ^pattern))
        else
          q
        end
      end)
      |> then(fn q ->
        if lifecycle && lifecycle != "" && lifecycle != :all do
          where(q, [d], d.lifecycle_state == ^lifecycle)
        else
          q
        end
      end)

    total = Repo.aggregate(base, :count, :id)
    total_pages = max(ceil(total / @page_size), 1)
    page = min(page, total_pages)
    offset = (page - 1) * @page_size

    domains =
      base
      |> order_by([d], asc: d.name)
      |> limit(@page_size)
      |> offset(^offset)
      |> preload([:parent_domain, :domain_tags, :domain_metadata, :subdomains])
      |> Repo.all()

    %{
      domains: domains,
      page: page,
      total_pages: total_pages,
      total: total,
      page_size: @page_size
    }
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
    |> preload([:parent_domain, :subdomains, :domain_tags, :domain_metadata])
    |> Repo.all()
  end

  def get_domain!(id), do: Repo.get!(Domain, id)

  def get_domain_with_preloads!(id) do
    Domain
    |> preload([:parent_domain, :domain_tags, :domain_metadata, subdomains: :domain_metadata])
    |> Repo.get!(id)
  end

  @doc """
  Preloads domain_metadata for all subdomains of a given domain.
  Used for lazy-loading when expanding a domain in the listing.
  """
  def preload_subdomain_metadata(%Domain{subdomains: subs} = domain) when is_list(subs) do
    %{domain | subdomains: Repo.preload(subs, :domain_metadata)}
  end

  def preload_subdomain_metadata(domain), do: domain

  def create_domain(attrs \\ %{}) do
    %Domain{}
    |> Domain.changeset(attrs)
    |> Repo.insert()
  end

  def update_domain(%Domain{} = domain, attrs) do
    domain
    |> Domain.changeset(attrs)
    |> Repo.update()
  end

  def delete_domain(%Domain{} = domain) do
    Repo.delete(domain)
  end

  def change_domain(%Domain{} = domain, attrs \\ %{}) do
    Domain.changeset(domain, attrs)
  end

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

  # Known multi-part ccTLD second-level domains (e.g. .co.uk, .com.ua)
  @multi_part_tlds ~w(
    co.uk com.uk net.uk org.uk me.uk
    co.nz net.nz org.nz
    com.au net.au org.au edu.au
    com.ua net.ua org.ua
    co.kr com.kr net.kr or.kr
    com.cn net.cn org.cn
    com.pl net.pl org.pl
    com.tr net.tr org.tr
    com.br net.br org.br
    com.vn net.vn
    co.il net.il
    co.tz or.tz
    co.hu
    co.za
    co.jp
    com.sg
    co.in net.in
    com.au
    com.pe
    com.mx
    com.ar
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

    {added, skipped, ignored} =
      Enum.reduce(unique_lines, {[], [], []}, fn name, {added_acc, skipped_acc, ignored_acc} ->
        case classify_import_line(name) do
          {:ok, normalized} ->
            case find_domain_by_name(normalized) do
              nil ->
                case create_domain(%{name: normalized, type: :domain}) do
                  {:ok, domain} ->
                    {[domain.name | added_acc], skipped_acc, ignored_acc}

                  {:error, cs} ->
                    {added_acc, skipped_acc, [{name, format_errors(cs)} | ignored_acc]}
                end

              _existing ->
                {added_acc, [normalized | skipped_acc], ignored_acc}
            end

          {:error, reason} ->
            {added_acc, skipped_acc, [{name, reason} | ignored_acc]}
        end
      end)

    %{
      added: Enum.reverse(added),
      skipped: Enum.reverse(skipped),
      ignored: Enum.reverse(ignored),
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
    |> Enum.map(fn {field, msgs} -> "#{field}: #{Enum.join(msgs, ", ")}" end)
    |> Enum.join("; ")
  end

  # Domain Metadata

  def get_domain_metadata(domain_id) do
    Repo.get_by(DomainMetadata, domain_id: domain_id)
  end

  def upsert_domain_metadata(domain_id, attrs) do
    case get_domain_metadata(domain_id) do
      nil ->
        %DomainMetadata{}
        |> DomainMetadata.changeset(Map.put(attrs, :domain_id, domain_id))
        |> Repo.insert()

      metadata ->
        metadata
        |> DomainMetadata.changeset(attrs)
        |> Repo.update()
    end
  end
end
