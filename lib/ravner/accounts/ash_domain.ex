defmodule Ravner.Accounts.AshDomain do
  @moduledoc """
  Ash domain for account governance resources.
  """
  use Ash.Domain,
    extensions: [AshPaperTrail.Domain, AshAi]

  paper_trail do
    include_versions?(true)
  end

  authorization do
    authorize(:always)
  end

  resources do
    resource(Ravner.Accounts.UserResource)
    resource(Ravner.Accounts.UserTokenResource)
    resource(Ravner.Accounts.UserInviteResource)
    resource(Ravner.Accounts.ApiToken)
    resource(Ravner.Accounts.UserResource.Version)
    resource(Ravner.Accounts.UserTokenResource.Version)
    resource(Ravner.Accounts.UserInviteResource.Version)
    resource(Ravner.Accounts.ApiToken.Version)
  end

  tools do
    tool(:list_users, Ravner.Accounts.UserResource, :read,
      select: [:id, :email, :name, :role, :active, :supervisor_id],
      description: "List governance users and their roles (requires admin or editor role)"
    )

    tool(:get_user, Ravner.Accounts.UserResource, :read,
      get_by: :id,
      select: [:id, :email, :name, :role, :active, :supervisor_id],
      description: "Get user details by ID (requires admin or editor role)"
    )
  end
end
