defmodule Ravner.Integrations.VCSTest do
  use Ravner.DataCase, async: true

  alias Ravner.Integrations.VCS
  alias Ravner.Integrations.VcsIntegration

  describe "URL parsing & detection" do
    test "detect_provider_from_url/1 identifies known git hosts" do
      assert VCS.detect_provider_from_url("https://bitbucket.org/workspace/repo") == "bitbucket"
      assert VCS.detect_provider_from_url("git@bitbucket.org:workspace/repo.git") == "bitbucket"
      assert VCS.detect_provider_from_url("https://github.com/org/repo") == "github"
      assert VCS.detect_provider_from_url("git@github.com:org/repo.git") == "github"
      assert VCS.detect_provider_from_url("https://gitlab.com/group/project") == "gitlab"
      assert VCS.detect_provider_from_url("https://example.com/custom/repo.git") == "other"
      assert VCS.detect_provider_from_url(nil) == "other"
    end

    test "extract_slug_from_url/1 extracts repo slug" do
      assert VCS.extract_slug_from_url("https://bitbucket.org/acme/ravner") == "ravner"

      assert VCS.extract_slug_from_url("https://bitbucket.org/acme/ravner.git") ==
               "ravner"

      assert VCS.extract_slug_from_url("https://bitbucket.org/acme/ravner/") == "ravner"
      assert VCS.extract_slug_from_url("git@bitbucket.org:acme/ravner.git") == "ravner"
      assert VCS.extract_slug_from_url("https://github.com/elixir-lang/elixir") == "elixir"
      assert VCS.extract_slug_from_url(nil) == nil
      assert VCS.extract_slug_from_url("") == nil
    end
  end

  describe "VCS Integrations CRUD" do
    @valid_attrs %{
      name: "Bitbucket Team",
      provider: "bitbucket",
      workspace: "acme",
      token_type: "workspace",
      token: "secret_app_password_123",
      active: true,
      settings: %{"sync_commits" => true}
    }

    test "create_integration/1 creates a valid integration" do
      assert {:ok, %VcsIntegration{} = integration} = VCS.create_integration(@valid_attrs)
      assert integration.name == "Bitbucket Team"
      assert integration.provider == "bitbucket"
      assert integration.workspace == "acme"
      assert integration.token_type == "workspace"
      assert integration.token == "secret_app_password_123"
      assert integration.active == true
    end

    test "create_integration/1 validates required fields" do
      assert {:error, changeset} = VCS.create_integration(%{})
      assert "can't be blank" in errors_on(changeset).name
      assert "can't be blank" in errors_on(changeset).workspace
      assert "can't be blank" in errors_on(changeset).token
    end

    test "token is redacted in inspect to prevent credential leakage" do
      {:ok, integration} = VCS.create_integration(@valid_attrs)
      inspected = inspect(integration)
      refute String.contains?(inspected, "secret_app_password_123")
      refute String.contains?(inspected, "token:")
    end

    test "list_integrations/0 returns all integrations sorted by name" do
      {:ok, _i1} = VCS.create_integration(@valid_attrs)

      {:ok, _i2} =
        VCS.create_integration(%{@valid_attrs | name: "Alpha Bitbucket", workspace: "alpha"})

      integrations = VCS.list_integrations()
      assert length(integrations) == 2
      assert hd(integrations).name == "Alpha Bitbucket"
    end

    test "update_integration/2 updates integration fields" do
      {:ok, integration} = VCS.create_integration(@valid_attrs)

      assert {:ok, updated} =
               VCS.update_integration(integration, %{active: false, name: "Disabled BB"})

      assert updated.active == false
      assert updated.name == "Disabled BB"
    end

    test "delete_integration/1 removes the integration" do
      {:ok, integration} = VCS.create_integration(@valid_attrs)
      assert {:ok, _deleted} = VCS.delete_integration(integration)
      assert VCS.list_integrations() == []
    end

    test "resolve_credentials/1 returns DB integration if active" do
      {:ok, _integration} = VCS.create_integration(@valid_attrs)
      resolved = VCS.resolve_credentials("bitbucket")

      assert resolved != nil
      assert resolved.workspace == "acme"
      assert resolved.token_type == "workspace"
      assert resolved.token == "secret_app_password_123"
    end

    test "status/1 returns configuration source and details with redacted token" do
      assert %{configured?: false, source: :none, token_configured?: false} =
               VCS.status("bitbucket")

      {:ok, _integration} = VCS.create_integration(@valid_attrs)

      status = VCS.status("bitbucket")
      assert status.configured? == true
      assert status.source == :database
      assert status.workspace == "acme"
      assert status.token_configured? == true
      assert String.starts_with?(status.token_preview, "••••••••")
      # Active integration returned in status has token nil for security
      assert status.active_integration.token == nil
    end

    test "update_integration/2 preserves token when blank string or nil is supplied" do
      {:ok, integration} = VCS.create_integration(@valid_attrs)

      assert {:ok, updated} =
               VCS.update_integration(integration, %{name: "Updated Name", token: ""})

      assert updated.token == "secret_app_password_123"
      assert updated.name == "Updated Name"

      assert {:ok, updated2} = VCS.update_integration(updated, %{token: nil})
      assert updated2.token == "secret_app_password_123"
    end

    test "mask_token/1 masks credentials safely" do
      assert VCS.mask_token(nil) == nil
      assert VCS.mask_token("") == nil
      assert VCS.mask_token("short") == "••••••••"
      masked = VCS.mask_token("super_secret_token_12345")
      assert String.starts_with?(masked, "••••••••")
      assert String.ends_with?(masked, "2345")
      refute String.contains?(masked, "super_secret_token")
    end

    test "safe_active_vcs/1 exposes only workspace and token_type without secret token" do
      assert VCS.safe_active_vcs("bitbucket") == nil

      {:ok, _integration} = VCS.create_integration(@valid_attrs)

      safe = VCS.safe_active_vcs("bitbucket")
      assert safe != nil
      assert safe.workspace == "acme"
      assert safe.token_type == "workspace"
      refute Map.has_key?(safe, :token)
    end

    test "resolve_credentials/1 returns nil when no integration or env vars exist" do
      # In test environment without active integration and without env vars
      resolved = VCS.resolve_credentials("nonexistent_provider")
      assert resolved == nil
    end
  end

  describe "Bitbucket Client Authentication" do
    alias Ravner.Integrations.VCS.Bitbucket

    test "uses Bearer authentication when username is nil, blank, or auth_type is bearer" do
      client_token_only = Bitbucket.build_client(token: "repo_access_token_xyz")
      assert client_token_only.options[:auth] == {:bearer, "repo_access_token_xyz"}

      client_blank_user = Bitbucket.build_client(username: "  ", token: "repo_access_token_xyz")
      assert client_blank_user.options[:auth] == {:bearer, "repo_access_token_xyz"}

      client_bearer_explicit =
        Bitbucket.build_client(
          username: "krzys",
          token: "repo_access_token_xyz",
          auth_type: "bearer"
        )

      assert client_bearer_explicit.options[:auth] == {:bearer, "repo_access_token_xyz"}
    end

    test "uses Basic authentication when username and token are both provided" do
      client_basic = Bitbucket.build_client(username: "krzys", token: "app_password_abc")
      assert client_basic.options[:auth] == {:basic, "krzys:app_password_abc"}
    end
  end

  describe "Bitbucket Tech Stack Detection" do
    alias Ravner.Integrations.VCS.Bitbucket

    test "detects technologies from file list and package.json" do
      files = [
        "mix.exs",
        "package.json",
        "Dockerfile",
        "docker-compose.yml",
        "tsconfig.json"
      ]

      package_json = %{
        "dependencies" => %{
          "react" => "^18.2.0",
          "tailwindcss" => "^3.4.0"
        },
        "devDependencies" => %{
          "typescript" => "^5.0.0"
        }
      }

      techs = Bitbucket.detect_technologies(files, package_json)

      assert "Elixir" in techs
      assert "Phoenix" in techs
      assert "Docker" in techs
      assert "Docker Compose" in techs
      assert "React" in techs
      assert "TypeScript" in techs
      assert "Tailwind CSS" in techs
    end
  end

  describe "Multi-Provider VCS Adapters" do
    alias Ravner.Integrations.VCS.{GitHub, GitLab}

    test "adapter_for/1 returns matching provider module" do
      assert VCS.adapter_for("bitbucket") == Ravner.Integrations.VCS.Bitbucket
      assert VCS.adapter_for(:bitbucket) == Ravner.Integrations.VCS.Bitbucket
      assert VCS.adapter_for("github") == GitHub
      assert VCS.adapter_for(:github) == GitHub
      assert VCS.adapter_for("gitlab") == GitLab
      assert VCS.adapter_for(:gitlab) == GitLab
      assert VCS.adapter_for("unknown") == Ravner.Integrations.VCS.Bitbucket
    end

    test "GitHub.build_client/1 configures Bearer token authorization" do
      client = GitHub.build_client(workspace: "acme", token: "ghp_secret_pat_123")
      assert is_struct(client, Req.Request)

      # Check auth header
      headers = Map.new(client.headers)
      assert headers["authorization"] == ["Bearer ghp_secret_pat_123"]
      assert headers["accept"] == ["application/vnd.github+json"]
    end

    test "GitLab.build_client/1 configures Private-Token and custom base_url" do
      client_default = GitLab.build_client(workspace: "acme", token: "glpat-token-456")
      assert is_struct(client_default, Req.Request)
      headers_default = Map.new(client_default.headers)
      assert headers_default["private-token"] == ["glpat-token-456"]

      client_custom =
        GitLab.build_client(
          workspace: "acme",
          token: "glpat-token-456",
          settings: %{"base_url" => "https://gitlab.custom.internal/api/v4"}
        )

      assert client_custom.options[:base_url] == "https://gitlab.custom.internal/api/v4"
    end
  end
end
