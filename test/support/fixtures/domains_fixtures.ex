defmodule Ravner.DomainsFixtures do
  @moduledoc """
  This module defines test helpers for creating domain entities.
  """

  alias Ravner.Domains

  def domain_fixture(attrs \\ %{}) do
    {:ok, domain} =
      attrs
      |> Enum.into(%{
        name: "example-#{System.unique_integer([:positive])}.com",
        type: :domain,
        lifecycle_state: :active
      })
      |> Domains.create_domain()

    domain
  end
end
