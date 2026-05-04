defmodule Ravner.SecurityScansTest do
  @moduledoc """
  Tests for the Ravner.SecurityScans context.
  """
  use Ravner.DataCase

  alias Ravner.SecurityScans
  alias Ravner.SecurityScans.ScanFinding
  alias Ravner.SecurityScans.SecurityScan

  import Ravner.DomainsFixtures

  describe "security_scans" do
    setup do
      domain = domain_fixture()
      {:ok, domain: domain}
    end

    test "create_scan/1 creates a security scan", %{domain: domain} do
      assert {:ok, %SecurityScan{} = scan} =
               SecurityScans.create_scan(%{
                 domain_id: domain.id,
                 tool: "naabu",
                 status: "running",
                 target: domain.name
               })

      assert scan.tool == "naabu"
      assert scan.status == "running"
      assert scan.target == domain.name
    end

    test "create_scan/1 validates tool inclusion", %{domain: domain} do
      assert {:error, %Ecto.Changeset{}} =
               SecurityScans.create_scan(%{
                 domain_id: domain.id,
                 tool: "invalid",
                 status: "running"
               })
    end

    test "update_scan/2 updates scan attributes", %{domain: domain} do
      {:ok, scan} =
        SecurityScans.create_scan(%{
          domain_id: domain.id,
          tool: "naabu",
          status: "running",
          target: domain.name
        })

      assert {:ok, %SecurityScan{} = updated} =
               SecurityScans.update_scan(scan, %{status: "completed", progress: 100})

      assert updated.status == "completed"
      assert updated.progress == 100
    end

    test "list_scans_for_domain/1 returns scans ordered by insertion time", %{domain: domain} do
      {:ok, scan1} =
        SecurityScans.create_scan(%{
          domain_id: domain.id,
          tool: "naabu",
          status: "completed",
          target: domain.name
        })

      {:ok, scan2} =
        SecurityScans.create_scan(%{
          domain_id: domain.id,
          tool: "nuclei",
          status: "completed",
          target: domain.name
        })

      scans = SecurityScans.list_scans_for_domain(domain.id)
      assert length(scans) == 2
      assert Enum.map(scans, & &1.id) == Enum.sort([scan1.id, scan2.id], :desc)
    end

    test "get_scan!/1 returns scan with preloaded findings", %{domain: domain} do
      {:ok, scan} =
        SecurityScans.create_scan(%{
          domain_id: domain.id,
          tool: "naabu",
          status: "completed",
          target: domain.name
        })

      assert %SecurityScan{} = fetched = SecurityScans.get_scan!(scan.id)
      assert fetched.id == scan.id
      assert fetched.findings == []
    end
  end

  describe "scan_findings" do
    setup do
      domain = domain_fixture()

      {:ok, scan} =
        SecurityScans.create_scan(%{
          domain_id: domain.id,
          tool: "nuclei",
          status: "completed",
          target: domain.name
        })

      {:ok, domain: domain, scan: scan}
    end

    test "create_finding/1 creates a finding", %{scan: scan} do
      assert {:ok, %ScanFinding{} = finding} =
               SecurityScans.create_finding(%{
                 security_scan_id: scan.id,
                 severity: "high",
                 title: "Test finding",
                 target: "example.com:443",
                 detail: %{"template-id" => "test"}
               })

      assert finding.severity == "high"
      assert finding.title == "Test finding"
    end

    test "list_findings_for_scan/1 returns findings ordered by severity", %{scan: scan} do
      SecurityScans.create_finding(%{
        security_scan_id: scan.id,
        severity: "low",
        title: "Low finding"
      })

      SecurityScans.create_finding(%{
        security_scan_id: scan.id,
        severity: "critical",
        title: "Critical finding"
      })

      findings = SecurityScans.list_findings_for_scan(scan.id)
      assert length(findings) == 2
      severities = Enum.map(findings, & &1.severity)
      assert "critical" in severities
      assert "low" in severities
    end

    test "count_findings_by_severity/1 returns counts grouped by severity", %{scan: scan} do
      SecurityScans.create_finding(%{
        security_scan_id: scan.id,
        severity: "high",
        title: "High 1"
      })

      SecurityScans.create_finding(%{
        security_scan_id: scan.id,
        severity: "high",
        title: "High 2"
      })

      SecurityScans.create_finding(%{
        security_scan_id: scan.id,
        severity: "low",
        title: "Low 1"
      })

      counts = SecurityScans.count_findings_by_severity(scan.id)
      assert counts["high"] == 2
      assert counts["low"] == 1
    end
  end

  describe "parse_naabu_output/1" do
    test "parses naabu JSON output" do
      output = ~s({"host":"example.com","ip":"93.184.216.34","port":80}\n)

      findings = SecurityScans.parse_naabu_output(output)
      assert length(findings) == 1
      assert hd(findings).severity == "info"
      assert hd(findings).title == "Open port 80 on example.com"
      assert hd(findings).target == "example.com:80"
    end

    test "returns empty list for empty output" do
      assert SecurityScans.parse_naabu_output("") == []
    end
  end

  describe "parse_nuclei_output/1" do
    test "parses nuclei JSONL output" do
      output =
        ~s({"template-id":"test","info":{"name":"Test Vuln","severity":"high"},"host":"example.com","matched-at":"https://example.com"}\n)

      findings = SecurityScans.parse_nuclei_output(output)
      assert length(findings) == 1
      assert hd(findings).severity == "high"
      assert hd(findings).title == "Test Vuln"
      assert hd(findings).target == "example.com"
    end

    test "returns empty list for empty output" do
      assert SecurityScans.parse_nuclei_output("") == []
    end
  end

  describe "parse_httpx_output/1" do
    test "parses httpx JSON output" do
      output =
        ~s({"url":"https://example.com","status-code":200,"title":"Example","tech":["nginx"],"host":"example.com","ip":"93.184.216.34"}\n)

      findings = SecurityScans.parse_httpx_output(output)
      assert length(findings) == 1
      assert hd(findings).severity == "info"
      assert hd(findings).title == "HTTP 200 — https://example.com"
      assert hd(findings).target == "https://example.com"
    end

    test "returns empty list for empty output" do
      assert SecurityScans.parse_httpx_output("") == []
    end
  end
end
