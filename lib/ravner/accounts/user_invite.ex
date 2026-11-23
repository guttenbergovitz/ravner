defmodule Ravner.Accounts.UserInvite do
  @moduledoc """
  Ecto schema representing a time-limited team invitation.
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles Ravner.Accounts.User.roles()

  @type t :: %__MODULE__{
          id: integer() | nil,
          token: String.t() | nil,
          email: String.t() | nil,
          role: Ravner.Accounts.User.role(),
          name: String.t() | nil,
          target_brand_id: integer() | nil,
          target_organization_id: integer() | nil,
          target_project_id: integer() | nil,
          supervisor_id: integer() | nil,
          accepted_at: DateTime.t() | nil,
          expires_at: DateTime.t() | nil,
          invited_by_id: integer() | nil,
          invited_by: Ravner.Accounts.User.t() | term(),
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "user_invites" do
    field(:token, :string)
    field(:email, :string)
    field(:role, Ecto.Enum, values: @roles, default: :viewer)
    field(:name, :string)
    field(:target_brand_id, :integer)
    field(:target_organization_id, :integer)
    field(:target_project_id, :integer)
    field(:supervisor_id, :integer)
    field(:accepted_at, :utc_datetime)
    field(:expires_at, :utc_datetime)

    belongs_to(:invited_by, Ravner.Accounts.User)

    belongs_to(:supervisor, Ravner.Accounts.User,
      foreign_key: :supervisor_id,
      define_field: false
    )

    timestamps(type: :utc_datetime)
  end

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [
      :email,
      :role,
      :name,
      :invited_by_id,
      :target_brand_id,
      :target_organization_id,
      :target_project_id,
      :supervisor_id,
      :expires_at
    ])
    |> validate_required([:email, :role, :expires_at])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_inclusion(:role, @roles)
    |> unique_constraint(:token)
  end

  def accept_changeset(invite) do
    change(invite, accepted_at: DateTime.utc_now(:second))
  end
end
