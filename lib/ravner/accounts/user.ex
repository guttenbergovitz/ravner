defmodule Ravner.Accounts.User do
  @moduledoc """
  Ecto schema representing a system user account.

  Serves as the primary authentication identity for Phoenix session plugs,
  password hashing, and scope resolution (`Ravner.Accounts.Scope`).
  """
  use Ecto.Schema
  import Ecto.Changeset

  @roles [
    :admin,
    :editor,
    :viewer,
    :brand_manager,
    :organization_manager,
    :product_owner,
    :delivery_head,
    :pm_supervisor,
    :project_manager
  ]

  @doc "Returns all supported user roles."
  def roles, do: @roles

  @doc "Returns a human-readable label for a given role."
  def role_label(role) do
    case role do
      :admin -> "Administrator"
      :editor -> "Editor"
      :viewer -> "Viewer"
      :brand_manager -> "Brand Manager"
      :organization_manager -> "Company Manager"
      :product_owner -> "Product Owner"
      :delivery_head -> "Delivery Head"
      :pm_supervisor -> "PM Supervisor"
      :project_manager -> "Project Manager"
      other -> other |> to_string() |> String.replace("_", " ") |> String.capitalize()
    end
  end

  @type role ::
          :admin
          | :editor
          | :viewer
          | :brand_manager
          | :organization_manager
          | :product_owner
          | :delivery_head
          | :pm_supervisor
          | :project_manager

  @type t :: %__MODULE__{
          id: integer() | nil,
          email: String.t() | nil,
          password: String.t() | nil,
          hashed_password: String.t() | nil,
          confirmed_at: DateTime.t() | nil,
          authenticated_at: DateTime.t() | nil,
          role: role(),
          name: String.t() | nil,
          active: boolean(),
          supervisor_id: integer() | nil,
          inserted_at: DateTime.t() | nil,
          updated_at: DateTime.t() | nil
        }

  schema "users" do
    field(:email, :string)
    field(:password, :string, virtual: true, redact: true)
    field(:hashed_password, :string, redact: true)
    field(:confirmed_at, :utc_datetime)
    field(:authenticated_at, :utc_datetime, virtual: true)
    field(:role, Ecto.Enum, values: @roles, default: :viewer)
    field(:name, :string)
    field(:active, :boolean, default: true)

    belongs_to(:supervisor, Ravner.Accounts.User, foreign_key: :supervisor_id)
    has_many(:supervised_users, Ravner.Accounts.User, foreign_key: :supervisor_id)
    has_many(:subordinates, Ravner.Accounts.User, foreign_key: :supervisor_id)
    has_one(:person, Ravner.Inventory.Person, foreign_key: :user_id)

    timestamps(type: :utc_datetime)
  end

  @doc """
  A user changeset for registering or changing the email.

  It requires the email to change otherwise an error is added.

  ## Options

    * `:validate_unique` - Set to false if you don't want to validate the
      uniqueness of the email, useful when displaying live validations.
      Defaults to `true`.
  """
  def email_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email])
    |> validate_email(opts)
  end

  defp validate_email(changeset, opts) do
    changeset =
      changeset
      |> validate_required([:email])
      |> validate_format(:email, ~r/^[^@,;\s]+@[^@,;\s]+$/,
        message: "must have the @ sign and no spaces"
      )
      |> validate_length(:email, max: 160)

    if Keyword.get(opts, :validate_unique, true) do
      changeset
      |> unsafe_validate_unique(:email, Ravner.Repo)
      |> unique_constraint(:email)
      |> validate_email_changed()
    else
      changeset
    end
  end

  defp validate_email_changed(changeset) do
    if get_field(changeset, :email) && get_change(changeset, :email) == nil do
      add_error(changeset, :email, "did not change")
    else
      changeset
    end
  end

  @doc """
  A user changeset for changing the password.

  It is important to validate the length of the password, as long passwords may
  be very expensive to hash for certain algorithms.

  ## Options

    * `:hash_password` - Hashes the password so it can be stored securely
      in the database and ensures the password field is cleared to prevent
      leaks in the logs. If password hashing is not needed and clearing the
      password field is not desired (like when using this changeset for
      validations on a LiveView form), this option can be set to `false`.
      Defaults to `true`.
  """
  def password_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:password])
    |> validate_confirmation(:password, message: "does not match password")
    |> validate_password(opts)
  end

  defp validate_password(changeset, opts) do
    changeset
    |> validate_required([:password])
    |> validate_length(:password, min: 12, max: 72)
    # Examples of additional password validation:
    # |> validate_format(:password, ~r/[a-z]/, message: "at least one lower case character")
    # |> validate_format(:password, ~r/[A-Z]/, message: "at least one upper case character")
    # |> validate_format(:password, ~r/[!?@#$%^&*_0-9]/, message: "at least one digit or punctuation character")
    |> maybe_hash_password(opts)
  end

  defp maybe_hash_password(changeset, opts) do
    hash_password? = Keyword.get(opts, :hash_password, true)
    password = get_change(changeset, :password)

    if hash_password? && password && changeset.valid? do
      changeset
      # If using Bcrypt, then further validate it is at most 72 bytes long
      |> validate_length(:password, max: 72, count: :bytes)
      # Hashing could be done with `Ecto.Changeset.prepare_changes/2`, but that
      # would keep the database transaction open longer and hurt performance.
      |> put_change(:hashed_password, Bcrypt.hash_pwd_salt(password))
      |> delete_change(:password)
    else
      changeset
    end
  end

  @doc """
  Confirms the account by setting `confirmed_at`.
  """
  def confirm_changeset(user) do
    now = DateTime.utc_now(:second)
    change(user, confirmed_at: now)
  end

  @doc """
  Verifies the password.

  If there is no user or the user doesn't have a password, we call
  `Bcrypt.no_user_verify/0` to avoid timing attacks.
  """
  def valid_password?(%Ravner.Accounts.User{hashed_password: hashed_password}, password)
      when is_binary(hashed_password) and byte_size(password) > 0 do
    Bcrypt.verify_pass(password, hashed_password)
  end

  def valid_password?(_, _) do
    Bcrypt.no_user_verify()
    false
  end

  @doc """
  Changeset for admin creating or editing a user manually.
  """
  def admin_changeset(user, attrs, opts \\ []) do
    user
    |> cast(attrs, [:email, :name, :role, :active, :supervisor_id])
    |> validate_required([:email, :role])
    |> validate_inclusion(:role, @roles)
    |> validate_email(opts)
  end

  @doc """
  Changeset for admin updating only role/name/active/supervisor.
  """
  def role_changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :role, :active, :supervisor_id])
    |> validate_required([:role])
    |> validate_inclusion(:role, @roles)
  end
end
