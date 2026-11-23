defmodule Ravner.Domains.ContactResolver do
  @moduledoc """
  Resolves contact candidates, team members, and escalation chains for domains.

  Provides lookup functions for PM/PO assignments, project team members,
  and multi-level escalation paths (Project → Organization → Brand).
  """

  import Ecto.Query
  alias Ravner.Repo
  alias Ravner.Domains.Domain

  # ─── Project Team Candidates ────────────────────────────────────────────────

  @doc """
  Returns project team candidates categorized by role (PM/PO).
  """
  @spec project_team_candidates(Domain.t() | integer() | String.t() | nil) :: %{
          pm: [map()],
          po: [map()],
          all: [map()]
        }
  def project_team_candidates(nil), do: %{pm: [], po: [], all: []}
  def project_team_candidates(%Domain{project_id: nil}), do: %{pm: [], po: [], all: []}

  def project_team_candidates(%Domain{project_id: project_id}),
    do: project_team_candidates(project_id)

  def project_team_candidates(project_id) when is_binary(project_id) do
    case Integer.parse(project_id) do
      {id, ""} -> project_team_candidates(id)
      _ -> %{pm: [], po: [], all: []}
    end
  end

  def project_team_candidates(project_id) when is_integer(project_id) do
    roles = Ravner.Inventory.list_project_roles(project_id)

    all_people =
      roles
      |> Enum.map(& &1.person)
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq_by(& &1.id)

    pms = filter_by_role(roles, ["project manager", "pm"])
    pos = filter_by_role(roles, ["product owner", "po"])

    %{pm: pms, po: pos, all: all_people}
  rescue
    _ -> %{pm: [], po: [], all: []}
  end

  # ─── Contact Candidates ─────────────────────────────────────────────────────

  @doc """
  Returns a structured map of candidates for PM and PO assignment on a domain,
  including project team members, organization members, and registered scoped users.
  """
  @spec contact_candidates(Domain.t() | integer() | String.t() | nil) :: %{
          pm_candidates: [map()],
          po_candidates: [map()],
          all_candidates: [map()]
        }
  def contact_candidates(domain_or_id) do
    domain = resolve_domain(domain_or_id)
    project_id = domain && domain.project_id
    org_id = domain && domain.organization_id

    project = resolve_project(domain, project_id)
    project_lead_pm = project && project.project_manager
    project_lead_po = project && project.product_owner

    # 1. Project team members if project is assigned
    project_roles = if project_id, do: Ravner.Inventory.list_project_roles(project_id), else: []
    project_pms = filter_by_role(project_roles, ["project manager", "pm"])
    project_pos = filter_by_role(project_roles, ["product owner", "po"])

    # 2. People from the domain's organization
    org_people = if org_id, do: Ravner.Inventory.list_people(organization_id: org_id), else: []

    # 3. All people in inventory
    all_people = Ravner.Inventory.list_people()

    # 4. Registered users
    users = Ravner.Accounts.list_users()

    # Build candidate lists
    lead_pm_candidates =
      if project_lead_pm, do: [format_person(project_lead_pm, "Project PM (Lead)")], else: []

    lead_po_candidates =
      if project_lead_po, do: [format_person(project_lead_po, "Project PO (Lead)")], else: []

    user_pms =
      users
      |> Enum.filter(&(&1.role in [:project_manager, :pm_supervisor, :delivery_head]))
      |> Enum.map(&format_user/1)

    user_pos =
      users
      |> Enum.filter(&(&1.role in [:product_owner, :organization_manager, :brand_manager]))
      |> Enum.map(&format_user/1)

    pm_list =
      (lead_pm_candidates ++
         Enum.map(project_pms, &format_person(&1, "Project PM")) ++
         user_pms ++
         Enum.map(org_people, &format_person(&1, "Org Member")) ++
         Enum.map(all_people, &format_person(&1, "Team Member")))
      |> dedupe_by_email()

    po_list =
      (lead_po_candidates ++
         Enum.map(project_pos, &format_person(&1, "Project PO")) ++
         user_pos ++
         Enum.map(org_people, &format_person(&1, "Org Member")) ++
         Enum.map(all_people, &format_person(&1, "Team Member")))
      |> dedupe_by_email()

    all_list =
      (pm_list ++ po_list ++ Enum.map(users, &format_user/1))
      |> dedupe_by_email()

    %{pm_candidates: pm_list, po_candidates: po_list, all_candidates: all_list}
  rescue
    _ -> %{pm_candidates: [], po_candidates: [], all_candidates: []}
  end

  # ─── Person Lookup ──────────────────────────────────────────────────────────

  @doc """
  Finds a Person entity in the inventory matching the given email address.
  """
  @spec find_person_by_email(String.t() | nil) :: Ravner.Inventory.Person.t() | nil
  def find_person_by_email(nil), do: nil
  def find_person_by_email(""), do: nil

  def find_person_by_email(email) when is_binary(email) do
    trimmed = String.trim(email)

    Ravner.Inventory.Person
    |> where([p], ilike(p.email, ^trimmed))
    |> limit(1)
    |> Repo.one()
  rescue
    _ -> nil
  end

  # ─── Escalation Chain ───────────────────────────────────────────────────────

  @doc """
  Returns a multi-level escalation chain for a domain:
  - Level 1: Project (PM, PO)
  - Level 2: Organization (Manager)
  - Level 3: Brand (Brand Manager)
  """
  @spec domain_escalation_chain(Domain.t()) :: %{
          level_1_project: map(),
          level_2_organization: map(),
          level_3_brand: map()
        }
  def domain_escalation_chain(%Domain{} = domain) do
    project = resolve_project(domain, domain.project_id)

    has_pm_email = is_binary(domain.pm_email) and domain.pm_email != ""

    pm_person =
      cond do
        has_pm_email -> find_person_by_email(domain.pm_email)
        project && project.project_manager -> project.project_manager
        true -> nil
      end

    pm_email = if has_pm_email, do: domain.pm_email, else: pm_person && pm_person.email

    has_po_email = is_binary(domain.po_email) and domain.po_email != ""

    po_person =
      cond do
        has_po_email -> find_person_by_email(domain.po_email)
        project && project.product_owner -> project.product_owner
        true -> nil
      end

    po_email = if has_po_email, do: domain.po_email, else: po_person && po_person.email

    org = resolve_organization(domain)
    brand = resolve_brand(domain)

    %{
      level_1_project: %{
        project: project,
        pm_email: pm_email,
        pm_person: pm_person,
        pm_inherited?: not has_pm_email and pm_person != nil,
        po_email: po_email,
        po_person: po_person,
        po_inherited?: not has_po_email and po_person != nil
      },
      level_2_organization: %{
        organization: org,
        manager: org && org.manager
      },
      level_3_brand: %{
        brand: brand,
        brand_manager: brand && brand.brand_manager
      }
    }
  rescue
    _ ->
      %{
        level_1_project: %{
          project: nil,
          pm_email: domain.pm_email,
          pm_person: nil,
          pm_inherited?: false,
          po_email: domain.po_email,
          po_person: nil,
          po_inherited?: false
        },
        level_2_organization: %{organization: nil, manager: nil},
        level_3_brand: %{brand: nil, brand_manager: nil}
      }
  end

  # ─── Private Helpers ────────────────────────────────────────────────────────

  defp resolve_domain(%Domain{} = d), do: d

  defp resolve_domain(id) when is_integer(id), do: Repo.get(Domain, id)

  defp resolve_domain(id) when is_binary(id) do
    case Integer.parse(id) do
      {parsed, ""} -> Repo.get(Domain, parsed)
      _ -> nil
    end
  end

  defp resolve_domain(_), do: nil

  defp resolve_project(domain, project_id) do
    cond do
      domain && domain.project && is_struct(domain.project, Ravner.Inventory.Project) ->
        domain.project

      project_id ->
        try do
          Ravner.Inventory.get_project!(project_id)
        rescue
          _ -> nil
        end

      true ->
        nil
    end
  end

  defp resolve_organization(domain) do
    cond do
      domain.organization && is_struct(domain.organization, Ravner.Inventory.Organization) ->
        domain.organization

      domain.organization_id ->
        Ravner.Inventory.get_organization!(domain.organization_id)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp resolve_brand(domain) do
    cond do
      domain.brand && is_struct(domain.brand, Ravner.Inventory.Brand) ->
        domain.brand

      domain.brand_id ->
        Ravner.Inventory.get_brand!(domain.brand_id)

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  defp filter_by_role(roles, keywords) do
    roles
    |> Enum.filter(fn r ->
      role_lower = String.downcase(r.role || "")
      Enum.any?(keywords, &String.contains?(role_lower, &1))
    end)
    |> Enum.map(& &1.person)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq_by(& &1.id)
  end

  defp format_person(person, default_badge) do
    name = "#{person.first_name} #{person.last_name}"
    label = if person.first_name || person.last_name, do: name, else: person.email

    %{
      id: "person-#{person.id}",
      name: String.trim(label),
      email: person.email,
      badge: person.title || default_badge,
      source: :person
    }
  end

  defp format_user(user) do
    %{
      id: "user-#{user.id}",
      name: user.name || user.email,
      email: user.email,
      badge: Ravner.Accounts.User.role_label(user.role),
      source: :user
    }
  end

  defp dedupe_by_email(list) do
    list
    |> Enum.reject(&(is_nil(&1.email) or &1.email == ""))
    |> Enum.uniq_by(&String.downcase(&1.email))
  end
end
