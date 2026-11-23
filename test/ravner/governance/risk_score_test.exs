defmodule Ravner.Governance.RiskScoreTest do
  use Ravner.DataCase, async: true

  alias Ravner.Domains
  alias Ravner.DomainsFixtures
  alias Ravner.Governance.RiskScore
  alias Ravner.Inventory
  alias Ravner.Repo
  alias Ravner.Scans.ProjectRepositorySecret

  describe "calculate/1 pure formula" do
    test "returns perfect 100 A+ for clean baseline" do
      result =
        RiskScore.calculate(%{
          critical_vulns: 0,
          high_vulns: 0,
          medium_vulns: 0,
          active_secrets: 0,
          ssl_days_remaining: 90,
          ssl_expired?: false,
          security_headers: %{
            "strict-transport-security" => "max-age=31536000",
            "content-security-policy" => "default-src 'self'",
            "x-frame-options" => "DENY"
          },
          uptime_ratio: 0.9995,
          is_up: true,
          open_ports: [80, 443]
        })

      assert result.overall_score == 100
      assert result.grade == "A+"
      assert result.deductions.vulnerabilities == 0
      assert result.deductions.secrets == 0
      assert result.deductions.ssl == 0
      assert result.deductions.headers == 0
      assert result.deductions.uptime == 0
      assert result.deductions.ports == 0
      assert result.drivers == []
    end

    test "deducts points for critical, high, and medium CVEs" do
      result =
        RiskScore.calculate(%{
          critical_vulns: 1,
          high_vulns: 2,
          medium_vulns: 3,
          ssl_days_remaining: 100,
          security_headers: %{
            "strict-transport-security" => "max-age=31536000",
            "content-security-policy" => "default-src 'self'",
            "x-frame-options" => "DENY"
          },
          is_up: true
        })

      # 1 crit (-25) + 2 high (-20) + 3 med (-9) = 54 deduction -> score 46
      assert result.deductions.vulnerabilities == 54
      assert result.overall_score == 46
      assert result.grade == "F"
      assert Enum.any?(result.drivers, &String.contains?(&1, "Critical CVE"))
      assert Enum.any?(result.drivers, &String.contains?(&1, "High-severity CVE"))
      assert Enum.any?(result.drivers, &String.contains?(&1, "Medium-severity CVE"))
    end

    test "deducts points for active leaked secrets" do
      result =
        RiskScore.calculate(%{
          active_secrets: 2,
          ssl_days_remaining: 60,
          security_headers: %{
            "strict-transport-security" => "max-age=31536000",
            "content-security-policy" => "default-src 'self'",
            "x-frame-options" => "DENY"
          },
          is_up: true
        })

      # 2 secrets * 20 = 40 pts deduction -> score 60
      assert result.deductions.secrets == 40
      assert result.overall_score == 60
      assert result.grade == "D"
      assert Enum.any?(result.drivers, &String.contains?(&1, "secret/credential leak"))
    end

    test "evaluates SSL certificate expiration brackets" do
      # Expired: -30 pts
      expired =
        RiskScore.calculate(%{
          ssl_days_remaining: -2,
          ssl_expired?: true,
          security_headers: %{
            "strict-transport-security" => "max-age=31536000",
            "content-security-policy" => "default-src 'self'",
            "x-frame-options" => "DENY"
          }
        })

      assert expired.deductions.ssl == 30
      assert expired.overall_score == 70
      assert expired.grade == "C"

      # Urgent expiry (<= 14 days): -15 pts
      urgent =
        RiskScore.calculate(%{
          ssl_days_remaining: 7,
          security_headers: %{
            "strict-transport-security" => "max-age=31536000",
            "content-security-policy" => "default-src 'self'",
            "x-frame-options" => "DENY"
          }
        })

      assert urgent.deductions.ssl == 15
      assert urgent.overall_score == 85
      assert urgent.grade == "B"

      # Warning expiry (<= 30 days): -5 pts
      warning =
        RiskScore.calculate(%{
          ssl_days_remaining: 25,
          security_headers: %{
            "strict-transport-security" => "max-age=31536000",
            "content-security-policy" => "default-src 'self'",
            "x-frame-options" => "DENY"
          }
        })

      assert warning.deductions.ssl == 5
      assert warning.overall_score == 95
      assert warning.grade == "A+"
    end

    test "evaluates missing security headers" do
      # Missing all 3 headers: -15 pts (score 85, grade B)
      no_headers =
        RiskScore.calculate(%{
          security_headers: %{},
          ssl_days_remaining: 100,
          is_up: true
        })

      assert no_headers.deductions.headers == 15
      assert no_headers.overall_score == 85
      assert no_headers.grade == "B"

      # Frame ancestors in CSP satisfies clickjacking requirement
      csp_frame =
        RiskScore.calculate(%{
          security_headers: %{
            "strict-transport-security" => "max-age=31536000",
            "content-security-policy" => "frame-ancestors 'self'"
          },
          ssl_days_remaining: 100,
          is_up: true
        })

      assert csp_frame.deductions.headers == 0
      assert csp_frame.overall_score == 100
    end

    test "evaluates downtime and availability SLA ratios" do
      down =
        RiskScore.calculate(%{
          is_up: false,
          uptime_ratio: 0.92,
          ssl_days_remaining: 90,
          security_headers: %{
            "strict-transport-security" => "max-age=31536000",
            "content-security-policy" => "default-src 'self'",
            "x-frame-options" => "DENY"
          }
        })

      # is_up: false (-15) + ratio < 0.95 (-10) = 25 pts deduction
      assert down.deductions.uptime == 25
      assert down.overall_score == 75
      assert down.grade == "C"
    end

    test "evaluates exposed sensitive database and administration ports" do
      exposed =
        RiskScore.calculate(%{
          open_ports: [22, 3306, 5432, 6379],
          ssl_days_remaining: 90,
          security_headers: %{
            "strict-transport-security" => "max-age=31536000",
            "content-security-policy" => "default-src 'self'",
            "x-frame-options" => "DENY"
          }
        })

      # 4 ports * 5 pts = 20, capped at 15 pts max
      assert exposed.deductions.ports == 15
      assert exposed.overall_score == 85
      assert exposed.grade == "B"

      assert Enum.any?(
               exposed.drivers,
               &String.contains?(&1, "Exposed sensitive/administrative port")
             )
    end

    test "clamps total score between 0 and 100" do
      catastrophic =
        RiskScore.calculate(%{
          critical_vulns: 10,
          active_secrets: 5,
          ssl_expired?: true,
          is_up: false,
          uptime_ratio: 0.80,
          open_ports: [21, 22, 23, 3306, 5432]
        })

      assert catastrophic.overall_score == 0
      assert catastrophic.grade == "F"
    end
  end

  describe "score_to_grade/1 and badge_classes/1" do
    test "maps score thresholds to executive letter grades" do
      assert RiskScore.score_to_grade(100) == "A+"
      assert RiskScore.score_to_grade(95) == "A+"
      assert RiskScore.score_to_grade(94) == "A"
      assert RiskScore.score_to_grade(90) == "A"
      assert RiskScore.score_to_grade(89) == "B"
      assert RiskScore.score_to_grade(80) == "B"
      assert RiskScore.score_to_grade(79) == "C"
      assert RiskScore.score_to_grade(65) == "C"
      assert RiskScore.score_to_grade(64) == "D"
      assert RiskScore.score_to_grade(50) == "D"
      assert RiskScore.score_to_grade(49) == "F"
      assert RiskScore.score_to_grade(0) == "F"
      assert RiskScore.score_to_grade(nil) == "N/A"
    end

    test "returns distinct styling classes per grade" do
      assert String.contains?(RiskScore.badge_classes("A+"), "emerald")
      assert String.contains?(RiskScore.badge_classes("A"), "emerald")
      assert String.contains?(RiskScore.badge_classes("B"), "blue")
      assert String.contains?(RiskScore.badge_classes("C"), "amber")
      assert String.contains?(RiskScore.badge_classes("D"), "orange")
      assert String.contains?(RiskScore.badge_classes("F"), "red")
      assert String.contains?(RiskScore.badge_classes("N/A"), "neutral")
    end
  end

  describe "recalculate_for_domain/1 and calculate_for_project/1" do
    setup do
      admin = %{role: :admin}
      suffix = System.unique_integer([:positive])

      {:ok, brand} =
        Inventory.create_brand(
          %{name: "RiskBrand #{suffix}", slug: "risk-brand-#{suffix}"},
          actor: admin
        )

      {:ok, org} =
        Inventory.create_organization(
          %{
            name: "RiskOrg #{suffix}",
            slug: "risk-org-#{suffix}",
            brand_id: brand.id,
            type: :internal
          },
          actor: admin
        )

      {:ok, project} =
        Inventory.create_project(
          %{
            name: "RiskProject #{suffix}",
            slug: "risk-proj-#{suffix}",
            organization_id: org.id
          },
          actor: admin
        )

      domain =
        DomainsFixtures.domain_fixture(%{
          name: "risk-domain-#{suffix}.example.com",
          project_id: project.id,
          organization_id: org.id
        })

      {:ok, project: project, domain: domain, admin: admin}
    end

    test "recalculates and persists risk score in domain_metadata", %{
      project: project,
      domain: domain,
      admin: admin
    } do
      # 1. Initialize metadata with missing headers and 12 days SSL
      Domains.upsert_domain_metadata(domain.id, %{
        ssl_days_remaining: 12,
        security_headers: %{
          "strict-transport-security" => "max-age=31536000"
        },
        open_ports: [80, 443]
      })

      # 2. Add an attached repository with 1 high CVE
      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            project_id: project.id,
            domain_id: domain.id,
            url: "https://bitbucket.org/example/risk-repo",
            external_id: "example/risk-repo",
            provider: "bitbucket",
            high_vuln_count: 1
          },
          actor: admin
        )

      # 3. Add 1 active secret finding in this repository
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.insert!(%ProjectRepositorySecret{
        project_repository_id: repo.id,
        project_id: project.id,
        file_path: "config/secrets.env",
        line_number: 10,
        rule_id: "generic_api_key",
        rule_name: "Generic API Key",
        severity: "high",
        fingerprint_sha256:
          :crypto.hash(:sha256, "secret-value-#{System.unique_integer()}") |> Base.encode16(),
        masked_value: "secr***123",
        status: "active",
        inserted_at: now,
        updated_at: now
      })

      # 4. Trigger recalculation
      assert {:ok, result} = RiskScore.recalculate_for_domain(domain.id)

      # Deductions breakdown:
      # - High CVE: -10
      # - Active Secret: -20
      # - SSL <= 14 days: -15
      # - Missing CSP & Frame: -10 (5 each)
      # Total deductions: 55 -> score 45, grade "F"
      assert result.overall_score == 45
      assert result.grade == "F"
      assert result.deductions.vulnerabilities == 10
      assert result.deductions.secrets == 20
      assert result.deductions.ssl == 15
      assert result.deductions.headers == 10

      # Verify persistence in database
      reloaded = Domains.get_domain_with_preloads!(domain.id)
      assert reloaded.domain_metadata.risk_score == 45
      assert reloaded.domain_metadata.risk_grade == "F"
      assert is_map(reloaded.domain_metadata.risk_deductions)
      assert length(reloaded.domain_metadata.risk_drivers) >= 3
    end

    test "calculates aggregated posture for an entire project", %{
      project: project,
      domain: domain,
      admin: admin
    } do
      # Setup clean metadata for domain
      Domains.upsert_domain_metadata(domain.id, %{
        ssl_days_remaining: 120,
        security_headers: %{
          "strict-transport-security" => "max-age=31536000",
          "content-security-policy" => "default-src 'self'",
          "x-frame-options" => "DENY"
        },
        open_ports: [80, 443]
      })

      # Add a clean repo
      {:ok, _repo} =
        Inventory.create_project_repository(
          %{
            project_id: project.id,
            domain_id: domain.id,
            url: "https://bitbucket.org/example/clean-repo",
            external_id: "example/clean-repo",
            provider: "bitbucket",
            critical_vuln_count: 0,
            high_vuln_count: 0
          },
          actor: admin
        )

      result = RiskScore.calculate_for_project(project.id)
      assert result.overall_score == 100
      assert result.grade == "A+"
      assert result.drivers == []
    end

    test "returns N/A and pending posture when domain has never been scanned", %{
      domain: domain
    } do
      assert {:ok, result} = RiskScore.recalculate_for_domain(domain.id)

      assert result.overall_score == nil
      assert result.grade == "N/A"
      assert result.deductions.vulnerabilities == 0

      assert Enum.any?(
               result.drivers,
               &String.contains?(&1, "No scans or probes have been recorded yet")
             )

      reloaded = Domains.get_domain_with_preloads!(domain.id)
      assert reloaded.domain_metadata.risk_score == nil
      assert reloaded.domain_metadata.risk_grade == "N/A"
    end

    test "returns N/A for project when no domains or repos have readings", %{
      project: project
    } do
      result = RiskScore.calculate_for_project(project.id)

      assert result.overall_score == nil
      assert result.grade == "N/A"

      assert Enum.any?(
               result.drivers,
               &String.contains?(&1, "No scans or probes have been recorded yet")
             )
    end
  end
end
