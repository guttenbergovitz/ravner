defmodule Ravner.SecurityScansTest do
  @moduledoc """
  Tests for the Ravner.SecurityScans context.
  """
  use Ravner.DataCase, async: true

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

    test "create_scan/1 creates a light security scan", %{domain: domain} do
      assert {:ok, %SecurityScan{} = scan} =
               SecurityScans.create_scan(%{
                 domain_id: domain.id,
                 tool: "light_scan",
                 status: "pending",
                 target: domain.name
               })

      assert scan.tool == "light_scan"
      assert scan.status == "pending"
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

    test "latest_security_scan/1 and latest_breach_scan/1 distinguish scan types", %{
      scan: sec_scan
    } do
      domain_id = sec_scan.domain_id

      # Complete initial security scan
      {:ok, sec_scan} =
        SecurityScans.update_scan(sec_scan, %{status: "completed", progress: 100})

      # Create and complete a dark web breach scan
      {:ok, breach_scan} =
        SecurityScans.create_scan(%{
          domain_id: domain_id,
          tool: "breach_lookup",
          status: "completed",
          target: "example.com"
        })

      # latest_security_scan returns the security scan, NOT the breach scan
      fetched_sec = SecurityScans.latest_security_scan(domain_id)
      assert fetched_sec.id == sec_scan.id
      assert fetched_sec.tool == sec_scan.tool

      # latest_breach_scan returns the breach scan
      fetched_breach = SecurityScans.latest_breach_scan(domain_id)
      assert fetched_breach.id == breach_scan.id
      assert fetched_breach.tool == "breach_lookup"

      # Pruning preserves both tool families
      SecurityScans.prune_old_scans(domain_id)
      assert SecurityScans.latest_security_scan(domain_id).id == sec_scan.id
      assert SecurityScans.latest_breach_scan(domain_id).id == breach_scan.id
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

  describe "parse_lonkero_output/1" do
    test "parses lonkero JSON output" do
      output = """
      [
        {
          "type": "Invisible Prompt Injection in README",
          "severity": "High",
          "confidence": "High",
          "category": "Supply Chain",
          "cwe": "CWE-1059",
          "evidence": "Fake evidence",
          "url": "https://example.com/readme",
          "timestamp": "2026-07-17T12:38:00Z"
        }
      ]
      """

      findings = SecurityScans.parse_lonkero_output(output)
      assert length(findings) == 1
      finding = hd(findings)
      assert finding.severity == "high"
      assert finding.title == "Invisible Prompt Injection in README"
      assert finding.target == "https://example.com/readme"
      assert finding.detail["confidence"] == "High"
      assert finding.detail["cwe"] == "CWE-1059"
    end

    test "returns empty list for empty or invalid output" do
      assert SecurityScans.parse_lonkero_output("") == []
      assert SecurityScans.parse_lonkero_output("{}") == []
    end
  end

  describe "portfolio_security_summary/0" do
    test "returns zeroed summary when no completed scans exist" do
      summary = SecurityScans.portfolio_security_summary()

      assert summary.scanned_domains_count == 0
      assert summary.critical == 0
      assert summary.high == 0
      assert summary.medium == 0
      assert summary.low == 0
      assert summary.info == 0
      assert summary.total_findings == 0
      assert summary.domains_at_risk_count == 0
      assert summary.exposed_secrets_count == 0
      assert summary.breach_findings_count == 0
      assert summary.top_vulnerable_domains == []
      assert summary.recent_critical_findings == []
    end

    test "ranks domains by weighted severity instead of finding count" do
      critical_domain = domain_fixture(%{name: "critical-weighted.example.com"})
      medium_domain = domain_fixture(%{name: "medium-weighted.example.com"})

      {:ok, critical_scan} =
        SecurityScans.create_scan(%{
          domain_id: critical_domain.id,
          tool: "security_scan",
          status: "completed",
          target: critical_domain.name
        })

      {:ok, medium_scan} =
        SecurityScans.create_scan(%{
          domain_id: medium_domain.id,
          tool: "security_scan",
          status: "completed",
          target: medium_domain.name
        })

      SecurityScans.create_findings_batch(critical_scan.id, [
        %{
          severity: "critical",
          title: "Critical issue",
          target: critical_domain.name,
          detail: %{}
        }
      ])

      SecurityScans.create_findings_batch(medium_scan.id, [
        %{severity: "medium", title: "Medium issue 1", target: medium_domain.name, detail: %{}},
        %{severity: "medium", title: "Medium issue 2", target: medium_domain.name, detail: %{}},
        %{severity: "medium", title: "Medium issue 3", target: medium_domain.name, detail: %{}}
      ])

      [top | _] = SecurityScans.portfolio_security_summary().top_vulnerable_domains

      assert top.domain_id == critical_domain.id
      assert top.risk_weight == 10
    end

    test "aggregates findings across latest security and breach scans" do
      domain1 = domain_fixture(%{name: "alpha-corp.com"})
      domain2 = domain_fixture(%{name: "beta-corp.com"})

      # Domain 1: completed security scan with critical & high findings
      {:ok, scan1} =
        SecurityScans.create_scan(%{
          domain_id: domain1.id,
          tool: "security_scan",
          status: "completed",
          target: domain1.name
        })

      SecurityScans.create_findings_batch(scan1.id, [
        %{
          severity: "critical",
          title: "Exposed .env file with AWS secrets",
          target: "https://alpha-corp.com/.env",
          detail: %{"cve" => "CWE-200"}
        },
        %{
          severity: "high",
          title: "SQL Injection on /api/search",
          target: "https://alpha-corp.com/api/search",
          detail: %{"cve" => "CWE-89"}
        },
        %{
          severity: "medium",
          title: "Missing CSP Header",
          target: "https://alpha-corp.com",
          detail: %{}
        }
      ])

      # Domain 1: completed breach scan
      {:ok, breach_scan} =
        SecurityScans.create_scan(%{
          domain_id: domain1.id,
          tool: "breach_lookup",
          status: "completed",
          target: domain1.name
        })

      SecurityScans.create_findings_batch(breach_scan.id, [
        %{
          severity: "high",
          title: "Dark Web Leak: admin@alpha-corp.com",
          target: "admin@alpha-corp.com",
          detail: %{"source" => "BreachDirectory"}
        }
      ])

      # Domain 2: completed scan with info finding only
      {:ok, scan2} =
        SecurityScans.create_scan(%{
          domain_id: domain2.id,
          tool: "light_scan",
          status: "completed",
          target: domain2.name
        })

      SecurityScans.create_findings_batch(scan2.id, [
        %{
          severity: "info",
          title: "Open Port 443",
          target: "beta-corp.com:443",
          detail: %{}
        }
      ])

      summary = SecurityScans.portfolio_security_summary()

      assert summary.scanned_domains_count == 2
      assert summary.critical == 1
      assert summary.high == 2
      assert summary.medium == 1
      assert summary.low == 0
      assert summary.info == 1
      assert summary.total_findings == 5
      assert summary.domains_at_risk_count == 1
      assert summary.exposed_secrets_count == 1
      assert summary.breach_findings_count == 1

      # Check top vulnerable domains
      assert length(summary.top_vulnerable_domains) == 1
      top = hd(summary.top_vulnerable_domains)
      assert top.domain_id == domain1.id
      assert top.domain_name == "alpha-corp.com"
      assert top.critical_count == 1
      assert top.high_count == 2
      assert top.medium_count == 1

      # Check recent critical findings
      assert length(summary.recent_critical_findings) == 3
      titles = Enum.map(summary.recent_critical_findings, & &1.title)
      assert "Exposed .env file with AWS secrets" in titles
      assert "SQL Injection on /api/search" in titles
      assert "Dark Web Leak: admin@alpha-corp.com" in titles
    end
  end
end
