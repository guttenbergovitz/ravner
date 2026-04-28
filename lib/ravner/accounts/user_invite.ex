defmodule Ravner.Accounts.UserInvite do
  use Ecto.Schema
  import Ecto.Changeset

  schema "user_invites" do
    field(:token, :string)
    field(:email, :string)
    field(:role, Ecto.Enum, values: [:admin, :editor, :viewer], default: :viewer)
    field(:name, :string)
    field(:accepted_at, :utc_datetime)
    field(:expires_at, :utc_datetime)

    belongs_to(:invited_by, Ravner.Accounts.User)

    timestamps(type: :utc_datetime)
  end

  def changeset(invite, attrs) do
    invite
    |> cast(attrs, [:email, :role, :name, :invited_by_id, :expires_at])
    |> validate_required([:email, :role, :expires_at])
    |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
      message: "must have the @ sign and no spaces"
    )
    |> validate_inclusion(:role, [:admin, :editor, :viewer])
    |> unique_constraint(:token)
  end

  def accept_changeset(invite) do
    change(invite, accepted_at: DateTime.utc_now(:second))
  end
end
