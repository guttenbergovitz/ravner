defmodule Ravner.AshErrorHelpersTest do
  use Ravner.DataCase, async: true

  alias Ravner.AccountsFixtures
  alias Ravner.AshErrorHelpers
  alias Ravner.Domains
  alias Ravner.Domains.Domain

  test "to_ecto_changeset/2 populates field errors and marks changeset invalid on duplicate domain" do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    name = "dup-#{System.unique_integer([:positive])}.example.com"

    assert {:ok, _domain} = Domains.create_domain(%{name: name}, actor: admin)

    assert {:error, %Ecto.Changeset{} = changeset} =
             Domains.create_domain(%{name: name}, actor: admin)

    refute changeset.valid?
    assert changeset.errors != []
  end

  test "to_ecto_changeset/2 handles generic error term gracefully" do
    base_changeset = Domain.changeset(%Domain{}, %{name: "valid.example.com"})
    assert base_changeset.valid?

    invalid_changeset = AshErrorHelpers.to_ecto_changeset("custom error", base_changeset)
    refute invalid_changeset.valid?
    assert {:base, {"validation failed", []}} in invalid_changeset.errors
  end
end
