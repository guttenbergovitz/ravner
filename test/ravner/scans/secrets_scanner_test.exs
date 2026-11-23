defmodule Ravner.Scans.SecretsScannerTest do
  use Ravner.DataCase, async: true

  alias Ravner.AccountsFixtures
  alias Ravner.Inventory
  alias Ravner.Repo
  alias Ravner.Scans.SecretsScanner

  defp create_project_and_admin(attrs) do
    admin = AccountsFixtures.user_fixture(%{role: :admin})
    suffix = System.unique_integer([:positive])

    {:ok, brand} =
      Inventory.create_brand(
        %{name: "Brand #{suffix}", slug: "brand-#{suffix}"},
        actor: admin
      )

    {:ok, org} =
      Inventory.create_organization(
        %{name: "Org #{suffix}", slug: "org-#{suffix}", type: :internal, brand_id: brand.id},
        actor: admin
      )

    name = Map.get(attrs, :name, "Project #{suffix}")
    slug = Map.get(attrs, :slug, "proj-#{suffix}")

    {:ok, project} =
      Inventory.create_project(
        %{name: name, slug: slug, organization_id: org.id},
        actor: admin
      )

    {project, admin}
  end

  describe "shannon_entropy/1" do
    test "calculates 0.0 for empty string" do
      assert SecretsScanner.shannon_entropy("") == 0.0
    end

    test "calculates 0.0 for single repeated character" do
      assert SecretsScanner.shannon_entropy("aaaaaaaaaaaaaaaaaaaa") == 0.0
    end

    test "calculates high entropy for random base64 / token strings" do
      entropy = SecretsScanner.shannon_entropy("K7j9P#m2$vL1@xR8!zQ5^wT0&yN3*bF6")
      assert entropy > 4.5
    end
  end

  describe "mask_secret/1" do
    test "masks short and long credentials properly" do
      assert SecretsScanner.mask_secret("12345") == "1******5"
      assert SecretsScanner.mask_secret("AKIAIOSFODNN7EXAMPLE") == "AKIA************MPLE"

      assert SecretsScanner.mask_secret("ghp_123456789012345678901234567890123456") ==
               "ghp_************3456"
    end
  end

  describe "fingerprint/2" do
    test "produces consistent sha256 hex string" do
      fp1 = SecretsScanner.fingerprint("AKIA1234567890ABCDEF", ".env")
      fp2 = SecretsScanner.fingerprint("AKIA1234567890ABCDEF", ".env")
      fp3 = SecretsScanner.fingerprint("AKIA1234567890ABCDEF", "config.json")

      assert fp1 == fp2
      assert is_binary(fp1) and byte_size(fp1) == 64
      refute fp1 == fp3
    end
  end

  describe "ignored_path?/1" do
    test "correctly excludes documentation, sample files, lockfiles, and fixtures" do
      assert SecretsScanner.ignored_path?(".env.sample")
      assert SecretsScanner.ignored_path?("config.example")
      assert SecretsScanner.ignored_path?("test/fixtures/keys.env")
      assert SecretsScanner.ignored_path?("README.md")
      assert SecretsScanner.ignored_path?("mix.lock")
      assert SecretsScanner.ignored_path?("node_modules/pkg/index.js")
    end

    test "does not exclude production configuration files" do
      refute SecretsScanner.ignored_path?(".env")
      refute SecretsScanner.ignored_path?(".env.production")
      refute SecretsScanner.ignored_path?("config/runtime.exs")
      refute SecretsScanner.ignored_path?("docker-compose.yml")
      refute SecretsScanner.ignored_path?("settings.py")
    end
  end

  describe "scan_content/3" do
    test "detects AWS Access Key IDs" do
      content = """
      export AWS_ACCESS_KEY_ID="AKIAIOSFODNN7EXAMPLE"
      export AWS_DEFAULT_REGION="us-east-1"
      """

      findings = SecretsScanner.scan_content(content, ".env")
      assert length(findings) == 1
      [f] = findings
      assert f.rule_id == "aws_access_key"
      assert f.severity == "critical"
      assert f.line_number == 1
      assert f.masked_value == "AKIA************MPLE"
    end

    test "detects GitHub Classic and Fine-Grained Personal Access Tokens" do
      content = """
      GITHUB_TOKEN=ghp_123456789012345678901234567890123456
      GH_FINE_PAT=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O2P3
      """

      findings = SecretsScanner.scan_content(content, ".env")
      assert length(findings) == 2
      rule_ids = Enum.map(findings, & &1.rule_id)
      assert "github_pat" in rule_ids
      assert "github_fine_grained_pat" in rule_ids
    end

    test "detects GitLab Personal Access Tokens" do
      content = "GITLAB_AUTH=glpat-abcdef1234567890-_xyz123456"
      findings = SecretsScanner.scan_content(content, ".env")
      assert length(findings) == 1
      assert hd(findings).rule_id == "gitlab_pat"
    end

    test "detects Slack tokens and webhooks" do
      slack_token = "xoxb-" <> "123456789012-1234567890123-abcdefghijklmnopqrstuvwx"

      slack_webhook =
        "https://hooks.slack.com/" <> "services/T012AB34CDE/B012CD34EFG/abCDeFgHiJkLmNoPqRsTuVwX"

      content = """
      SLACK_BOT_TOKEN="#{slack_token}"
      SLACK_WEBHOOK_URL="#{slack_webhook}"
      """

      findings = SecretsScanner.scan_content(content, "config.json")
      assert length(findings) == 2
      rule_ids = Enum.map(findings, & &1.rule_id)
      assert "slack_token" in rule_ids
      assert "slack_webhook" in rule_ids
    end

    test "detects Private Keys" do
      content = """
      -----BEGIN RSA PRIVATE KEY-----
      MIIEowIBAAKCAQEA0Y3rYvL3D...
      -----END RSA PRIVATE KEY-----
      """

      findings = SecretsScanner.scan_content(content, "server.key")
      assert length(findings) >= 1
      assert Enum.any?(findings, &(&1.rule_id == "private_key"))
    end

    test "detects Database Connection URIs" do
      content = """
      DATABASE_URL="postgres://admin_usr:SuperS3cr3tP@ss!@prod-db.internal:5432/main_db"
      """

      findings = SecretsScanner.scan_content(content, ".env.production")
      assert length(findings) == 1
      assert hd(findings).rule_id == "db_connection_uri"
      assert hd(findings).severity == "critical"
    end

    test "detects high-entropy assigned API keys and ignores mock/sample placeholders" do
      content = """
      api_key = "YOUR_API_KEY_HERE_SAMPLE"
      password = "aaaaaaaaaaaaaaaaaaaa"
      auth_token = "9kQ#m2$vL1@xR8!zQ5^wT0&yN3*bF6p"
      """

      findings = SecretsScanner.scan_content(content, "application.yml")
      assert length(findings) == 1
      assert hd(findings).rule_id == "high_entropy_secret"
      assert hd(findings).line_number == 3
    end
  end

  describe "scan_repository/2, list_repository_secrets/2, and mark_secret_status/2" do
    test "scans repository files, records secrets, updates count, and supports status transitions" do
      {project, admin} = create_project_and_admin(%{name: "Secrets Test Project"})

      {:ok, repo} =
        Inventory.create_project_repository(
          %{
            url: "https://bitbucket.org/testorg/secrets-repo.git",
            external_id: "testorg/secrets-repo",
            kind: "api",
            provider: "bitbucket",
            project_id: project.id,
            last_commit_hash: "c0ffee1234"
          },
          actor: admin
        )

      mock_files = %{
        ".env" => """
        AWS_ACCESS_KEY_ID=AKIAIOSFODNN7EXAMPLE
        DATABASE_URL=postgres://dbuser:s3cr3tP@ss@db.internal:5432/prod
        """,
        "config/runtime.exs" => """
        config :my_app,
          secret_key_base: "9kQ#m2$vL1@xR8!zQ5^wT0&yN3*bF6pX"
        """
      }

      {:ok, %{repository: updated_repo, secrets: secrets}} =
        SecretsScanner.scan_repository(repo, files: mock_files)

      assert updated_repo.secrets_count == 3
      assert length(secrets) == 3

      rule_ids = Enum.map(secrets, & &1.rule_id)
      assert "aws_access_key" in rule_ids
      assert "db_connection_uri" in rule_ids
      assert "high_entropy_secret" in rule_ids

      # Verify all secrets are masked
      for s <- secrets do
        refute s.masked_value =~ "AKIAIOSFODNN7EXAMPLE"
        assert s.status == "active"
        assert s.commit_sha == "c0ffee1234"
      end

      # Mark one secret as false positive
      [first | _] = secrets
      assert {:ok, updated_secret} = SecretsScanner.mark_secret_status(first.id, "false_positive")
      assert updated_secret.status == "false_positive"

      # Active count should now be 2
      reloaded_repo = Repo.get!(Ravner.Inventory.ProjectRepository, repo.id)
      assert reloaded_repo.secrets_count == 2

      # List active secrets only
      active_secrets = SecretsScanner.list_repository_secrets(repo.id, status: :active)
      assert length(active_secrets) == 2

      # List project secrets
      proj_secrets = SecretsScanner.list_project_secrets(project.id)
      assert length(proj_secrets) == 3

      # Inventory facade functions test
      assert length(Inventory.list_repository_secrets(repo.id)) == 3
      assert length(Inventory.list_project_secrets(project.id)) == 3
    end
  end
end
