defmodule Ravner.Accounts.ApiToken do
  @moduledoc """
  Ash resource representing an Enterprise API Token for machine-to-machine HTTP access.

  ## Security Model

  - Stores only the cryptographic SHA-256 digest (`token_hash`) of the generated secret.
  - Generates secrets using a cryptographically secure random generator with a standardized prefix (`rav_live_...`).
  - Strict least-privilege: defaults to `:viewer` (read-only queries).
  - Network perimeter: optional `allowed_ips` list enforcing remote IP / CIDR allowlists.
  - Path perimeter: optional `allowed_paths` list enforcing HTTP method and route pattern scoping.
  - Instant revocation via `revoked_at` timestamp.
  - All administrative operations strictly guarded by `Ash.Policy.Authorizer` (restricted to `:admin`).
  """

  use Ash.Resource,
    domain: Ravner.Accounts.AshDomain,
    data_layer: AshPostgres.DataLayer,
    extensions: [AshPaperTrail.Resource],
    authorizers: [Ash.Policy.Authorizer]

  paper_trail do
    primary_key_type(:integer)
    change_tracking_mode(:changes_only)
    store_action_name?(true)
    reference_source?(false)
  end

  postgres do
    table("api_tokens")
    repo(Ravner.Repo)
  end

  policies do
    # Only administrators can inspect, create, update, or revoke API tokens
    policy action_type([:read, :create, :update, :destroy]) do
      authorize_if(actor_attribute_equals(:role, :admin))
    end
  end

  actions do
    defaults([:read, :destroy])

    create :create do
      primary?(true)

      accept([
        :name,
        :role,
        :allowed_ips,
        :allowed_paths,
        :expires_at,
        :created_by_user_id
      ])

      argument(:token_raw, :string, allow_nil?: true)

      change(fn changeset, _context ->
        # Generate token raw if not provided
        raw =
          Ash.Changeset.get_argument(changeset, :token_raw) ||
            "rav_live_" <> Base.url_encode64(:crypto.strong_rand_bytes(24), padding: false)

        hash = Base.encode16(:crypto.hash(:sha256, raw), case: :lower)
        prefix = String.slice(raw, 0, 16) <> "..."

        changeset
        |> Ash.Changeset.change_attribute(:token_hash, hash)
        |> Ash.Changeset.change_attribute(:prefix, prefix)
        |> Ash.Changeset.put_context(:generated_raw_token, raw)
      end)
    end

    update :revoke do
      accept([])
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(changeset, :revoked_at, DateTime.utc_now())
      end)
    end

    update :touch_usage do
      accept([:last_used_ip])
      require_atomic?(false)

      change(fn changeset, _context ->
        Ash.Changeset.change_attribute(changeset, :last_used_at, DateTime.utc_now())
      end)
    end
  end

  attributes do
    integer_primary_key(:id)

    attribute :name, :string do
      allow_nil?(false)
    end

    attribute :token_hash, :string do
      allow_nil?(false)
      sensitive?(true)
    end

    attribute :prefix, :string do
      allow_nil?(false)
    end

    attribute :role, :atom do
      constraints(one_of: [:viewer, :editor, :admin])
      default(:viewer)
      allow_nil?(false)
    end

    attribute :allowed_ips, {:array, :string} do
      default([])
    end

    attribute :allowed_paths, {:array, :string} do
      default([])
    end

    attribute :expires_at, :utc_datetime do
      sensitive?(true)
    end

    attribute(:revoked_at, :utc_datetime)
    attribute(:last_used_at, :utc_datetime)
    attribute(:last_used_ip, :string)
    attribute(:created_by_user_id, :integer)

    create_timestamp(:inserted_at, type: :utc_datetime)
    update_timestamp(:updated_at, type: :utc_datetime)
  end

  relationships do
    belongs_to :created_by_user, Ravner.Accounts.UserResource,
      attribute_type: :integer,
      define_attribute?: false,
      source_attribute: :created_by_user_id
  end

  identities do
    identity(:unique_token_hash, [:token_hash])
  end
end
