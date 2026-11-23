defmodule Ravner.Accounts.Scope do
  @moduledoc """
  Defines the resolved hierarchical scope of the caller to be used throughout the app.

  The `Ravner.Accounts.Scope` allows public interfaces to receive
  information about the caller, such as if the call is initiated from an
  end-user, and if so, which user and their resolved access boundaries.

  Fields:
    * `:user` - The authenticated `User` record
    * `:person` - The matching `Person` governance record (if linked)
    * `:role` - The primary role atom of the user
    * `:admin?` - True if user is a system admin
    * `:editor?` - True if user is admin or global editor
    * `:viewer?` - True if user is global read-only viewer
    * `:global?` - True if user has unrestricted cross-system access (admin, editor, viewer)
    * `:brand_ids` - List of accessible brand IDs
    * `:organization_ids` - List of accessible organization IDs
    * `:project_ids` - List of accessible project IDs
    * `:domain_ids` - List of accessible domain IDs
    * `:supervised_pm_ids` - List of user IDs of supervised PMs
  """

  alias Ravner.Accounts.User
  alias Ravner.Inventory.Person

  @type t :: %__MODULE__{
          user: User.t() | nil,
          person: Person.t() | nil,
          role: User.role() | nil,
          admin?: boolean(),
          editor?: boolean(),
          viewer?: boolean(),
          global?: boolean(),
          brand_ids: [integer()],
          organization_ids: [integer()],
          project_ids: [integer()],
          domain_ids: [integer()],
          supervised_pm_ids: [integer()]
        }

  defstruct user: nil,
            person: nil,
            role: nil,
            admin?: false,
            editor?: false,
            viewer?: false,
            global?: false,
            brand_ids: [],
            organization_ids: [],
            project_ids: [],
            domain_ids: [],
            supervised_pm_ids: []

  @doc """
  Creates a resolved scope for the given user via `Ravner.Accounts.ScopeResolver`.

  Returns nil if no user is given.
  """
  def for_user(%User{} = user) do
    Ravner.Accounts.ScopeResolver.resolve(user)
  end

  def for_user(nil), do: nil
end
