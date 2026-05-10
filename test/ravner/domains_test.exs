defmodule Ravner.DomainsTest do
  use Ravner.DataCase

  alias Ravner.Domains
  alias Ravner.DomainsFixtures

  describe "technical status" do
    test "scanner technical status does not overwrite governance lifecycle" do
      domain = DomainsFixtures.domain_fixture(%{lifecycle_state: :deprecated})

      assert {:ok, 1} = Domains.record_technical_status(domain, :error)

      domain = Domains.get_domain!(domain.id)
      assert domain.lifecycle_state == :deprecated
      assert domain.technical_status == :error
    end
  end
end
