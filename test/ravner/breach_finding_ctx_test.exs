defmodule Ravner.BreachFindingCtxTest do
  use Ravner.DataCase, async: true

  alias Ravner.BreachFindingCtx

  describe "upsert_finding/1" do
    test "inserts new finding" do
      attrs = %{
        domain: "example.com",
        title: "Credential leak",
        severity: "high",
        detail: %{"email" => "user@example.com"},
        source: "dehashed"
      }

      assert {:ok, finding} = BreachFindingCtx.upsert_finding(attrs)
      assert finding.domain == "example.com"
      assert finding.title == "Credential leak"
      assert finding.severity == "high"
      assert finding.status == "new"
      assert finding.source == "dehashed"
    end

    test "preserves existing status on conflict" do
      attrs = %{
        domain: "example.com",
        title: "Credential leak",
        severity: "high",
        detail: %{"email" => "user@example.com"},
        source: "dehashed"
      }

      {:ok, finding} = BreachFindingCtx.upsert_finding(attrs)
      {:ok, _} = BreachFindingCtx.set_status(finding.id, "resolved")

      # Upsert again with updated severity
      updated_attrs = %{attrs | severity: "critical", detail: %{"email" => "new@example.com"}}
      {:ok, updated} = BreachFindingCtx.upsert_finding(updated_attrs)

      # Status should remain resolved, but severity/detail updated
      assert updated.status == "resolved"
      assert updated.severity == "critical"
    end

    test "requires domain, title, severity, detail, source" do
      assert {:error, changeset} = BreachFindingCtx.upsert_finding(%{})
      errors = errors_on(changeset)

      assert "can't be blank" in errors.domain
      assert "can't be blank" in errors.title
      assert "can't be blank" in errors.severity
      assert "can't be blank" in errors.source
    end
  end

  describe "set_status/2" do
    setup do
      {:ok, finding} =
        BreachFindingCtx.upsert_finding(%{
          domain: "test.com",
          title: "Test finding",
          severity: "medium",
          detail: %{},
          source: "test"
        })

      {:ok, finding: finding}
    end

    test "updates status to resolved", %{finding: finding} do
      assert {:ok, updated} = BreachFindingCtx.set_status(finding.id, "resolved")
      assert updated.status == "resolved"
    end

    test "updates status to false_positive", %{finding: finding} do
      assert {:ok, updated} = BreachFindingCtx.set_status(finding.id, "false_positive")
      assert updated.status == "false_positive"
    end

    test "updates status to ignored", %{finding: finding} do
      assert {:ok, updated} = BreachFindingCtx.set_status(finding.id, "ignored")
      assert updated.status == "ignored"
    end

    test "can reopen by setting status to new", %{finding: finding} do
      {:ok, _} = BreachFindingCtx.set_status(finding.id, "resolved")
      assert {:ok, updated} = BreachFindingCtx.set_status(finding.id, "new")
      assert updated.status == "new"
    end

    test "returns error for non-existent finding" do
      assert {:error, :not_found} = BreachFindingCtx.set_status(999_999, "resolved")
    end

    test "rejects invalid status" do
      finding =
        BreachFindingCtx.upsert_finding(%{
          domain: "test2.com",
          title: "Test",
          severity: "low",
          detail: %{},
          source: "test"
        })
        |> elem(1)

      assert_raise FunctionClauseError, fn ->
        BreachFindingCtx.set_status(finding.id, "invalid_status")
      end
    end
  end
end
