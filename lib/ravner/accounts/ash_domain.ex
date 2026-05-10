defmodule Ravner.Accounts.AshDomain do
  @moduledoc """
  Ash domain for account governance resources.
  """
  use Ash.Domain

  authorization do
    authorize(:always)
  end

  resources do
    resource(Ravner.Accounts.UserResource)
    resource(Ravner.Accounts.UserTokenResource)
    resource(Ravner.Accounts.UserInviteResource)
  end
end
