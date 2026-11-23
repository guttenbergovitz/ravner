defmodule Ravner.Inventory.ProjectRepository do
  @moduledoc """
  Ash resource representing a repository attached to a project.
  """
  use Ash.Resource,
    domain: Ravner.Inventory.AshDomain,
    data_layer: AshPostgres.DataLayer,
    authorizers: [Ash.Policy.Authorizer]

  import Ecto.Changeset

  @kinds ~w(website portal ecommerce cms landing app api library tool documentation config other)

  postgres do
    table("project_repositories")
    repo(Ravner.Repo)
  end

  policies do
    policy action_type(:read) do
      authorize_if({Ravner.Accounts.ScopeReadCheck, []})
    end

    policy action_type([:create, :update, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
      authorize_if(actor_attribute_equals(:role, :editor))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :url,
        :kind,
        :main_language,
        :technology,
        :notes,
        :project_id,
        :domain_id,
        :provider,
        :external_id,
        :default_branch,
        :last_commit_hash,
        :last_commit_message,
        :last_commit_author,
        :last_commit_at,
        :is_primary,
        :scan_status,
        :last_scanned_at,
        :vulnerability_count,
        :critical_vuln_count,
        :high_vuln_count,
        :medium_vuln_count,
        :low_vuln_count,
        :secrets_count
      ])
    end

    update :update do
      primary?(true)

      accept([
        :url,
        :kind,
        :main_language,
        :technology,
        :notes,
        :project_id,
        :domain_id,
        :application_id,
        :provider,
        :external_id,
        :default_branch,
        :last_commit_hash,
        :last_commit_message,
        :last_commit_author,
        :last_commit_at,
        :is_primary,
        :scan_status,
        :last_scanned_at,
        :vulnerability_count,
        :critical_vuln_count,
        :high_vuln_count,
        :medium_vuln_count,
        :low_vuln_count,
        :secrets_count
      ])
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :url, :string do
      allow_nil?(false)
    end

    attribute :kind, :string do
      default("website")
      allow_nil?(false)
    end

    attribute :provider, :string do
      default("other")
      allow_nil?(false)
    end

    attribute(:external_id, :string)
    attribute(:default_branch, :string, default: "main")
    attribute(:main_language, :string)
    attribute(:technology, :string)
    attribute(:notes, :string)
    attribute(:last_commit_hash, :string)
    attribute(:last_commit_message, :string)
    attribute(:last_commit_author, :string)
    attribute(:last_commit_at, :utc_datetime)
    attribute(:is_primary, :boolean, default: false)
    attribute(:scan_status, :string, default: "unscanned")
    attribute(:last_scanned_at, :utc_datetime)
    attribute(:vulnerability_count, :integer, default: 0)
    attribute(:critical_vuln_count, :integer, default: 0)
    attribute(:high_vuln_count, :integer, default: 0)
    attribute(:medium_vuln_count, :integer, default: 0)
    attribute(:low_vuln_count, :integer, default: 0)
    attribute(:secrets_count, :integer, default: 0)
    attribute(:application_id, :integer)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :project, Ravner.Inventory.Project, attribute_type: :integer
    belongs_to :domain, Ravner.Domains.Domain, attribute_type: :integer

    belongs_to :application, Ravner.Inventory.Application,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :application_id
  end

  # Keep Ecto changeset for UI compatibility during migration Phase 2-4
  def changeset(repo, attrs) do
    repo
    |> cast(attrs, [
      :url,
      :kind,
      :main_language,
      :technology,
      :notes,
      :project_id,
      :domain_id,
      :application_id,
      :provider,
      :external_id,
      :default_branch,
      :last_commit_hash,
      :last_commit_message,
      :last_commit_author,
      :last_commit_at,
      :is_primary,
      :scan_status,
      :last_scanned_at,
      :vulnerability_count,
      :critical_vuln_count,
      :high_vuln_count,
      :medium_vuln_count,
      :low_vuln_count,
      :secrets_count
    ])
    |> validate_required([:url, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_project_or_domain()
  end

  defp validate_project_or_domain(changeset) do
    project_id = get_field(changeset, :project_id)
    domain_id = get_field(changeset, :domain_id)

    if is_nil(project_id) and is_nil(domain_id) do
      add_error(changeset, :project_id, "either project or domain must be specified")
    else
      changeset
    end
  end

  def kinds, do: @kinds
end
