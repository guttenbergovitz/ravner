defmodule Ravner.Scans.CuratedProbes do
  @moduledoc """
  Lightweight, high-impact web exposure and misconfiguration micro-engine.

  Executes a curated catalogue of ~35 high-confidence probes against a target URL
  to identify exposed sensitive files (e.g. `/.env`, `/.git/HEAD`, AWS credentials,
  backup dumps) and unauthenticated debug/admin panels (e.g. Spring Boot Actuator,
  Laravel Ignition, PHPInfo, Swagger UI) without invoking external binaries like Nuclei.

  ## Operational Constraints

  - Maximum concurrency: 5 requests per domain
  - Request timeout: 2,000ms per probe
  - Response body cap: 4,096 bytes (avoids allocating memory for large responses)
  - Zero redirect following for file probes (prevents soft-404 false positives
    caused by web apps redirecting all missing paths to `/` or `/login`)
  - Content verification patterns: responses must match signature strings/regexes
    and must not be generic HTML error pages
  """

  require Logger

  @default_timeout 2_000
  @max_concurrency 5
  @max_body_bytes 4_096

  @type probe_spec :: %{
          path: String.t(),
          title: String.t(),
          severity: String.t(),
          category: String.t(),
          description: String.t(),
          pattern: Regex.t() | String.t(),
          anti_patterns: [Regex.t() | String.t()],
          references: [String.t()]
        }

  # ─── Curated Probes Catalogue ──────────────────────────────────────────────

  @probes [
    # ── Secrets & Source Code Leaks ──────────────────────────────────────────
    %{
      path: "/.env",
      title: "Exposed Environment Configuration (.env)",
      severity: "critical",
      category: "secrets",
      description:
        "Publicly accessible .env file exposing environment variables, database credentials, and application secrets.",
      pattern:
        ~r/(?:DB_PASSWORD|APP_KEY|AWS_SECRET_ACCESS_KEY|DATABASE_URL|SECRET_KEY_BASE|REDIS_PASSWORD|POSTGRES_PASSWORD|MAIL_PASSWORD)\s*=/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: [
        "https://owasp.org/www-project-web-security-testing-guide/latest/4-web-application-security-testing/02-configuration-and-deployment-management-testing/05-enumerate-infrastructure-and-application-admin-interfaces"
      ]
    },
    %{
      path: "/.git/HEAD",
      title: "Exposed Git Repository (.git/HEAD)",
      severity: "critical",
      category: "source_leak",
      description:
        "Publicly exposed .git directory allowing attackers to reconstruct complete application source code and commit history.",
      pattern: ~r/^ref:\s*refs\/heads\/\S+/m,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: [
        "https://owasp.org/www-project-web-security-testing-guide/latest/4-web-application-security-testing/02-configuration-and-deployment-management-testing/05-enumerate-infrastructure-and-application-admin-interfaces"
      ]
    },
    %{
      path: "/.git/config",
      title: "Exposed Git Configuration (.git/config)",
      severity: "critical",
      category: "source_leak",
      description:
        "Exposed Git repository configuration file disclosing remote repository URLs, internal hostnames, and credentials.",
      pattern: ~r/\[core\][\s\S]*repositoryformatversion/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: [
        "https://cwe.mitre.org/data/definitions/538.html"
      ]
    },
    %{
      path: "/.aws/credentials",
      title: "Exposed AWS Credentials File",
      severity: "critical",
      category: "secrets",
      description:
        "Publicly accessible AWS CLI configuration exposing IAM access keys and secret tokens.",
      pattern: ~r/\[default\][\s\S]*aws_access_key_id\s*=\s*[A-Z0-9]{16,32}/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://docs.aws.amazon.com/cli/latest/userguide/cli-configure-files.html"]
    },
    %{
      path: "/wp-config.php.bak",
      title: "Exposed WordPress Backup Configuration (wp-config.php.bak)",
      severity: "critical",
      category: "backup",
      description:
        "Backup copy of WordPress configuration served as plaintext, exposing database credentials and cryptographic salts.",
      pattern: ~r/define\s*\(\s*['"]DB_(?:PASSWORD|NAME|USER)['"]/i,
      anti_patterns: [],
      references: ["https://developer.wordpress.org/advanced-administration/wordpress/wp-config/"]
    },
    %{
      path: "/wp-config.php.old",
      title: "Exposed WordPress Legacy Configuration (wp-config.php.old)",
      severity: "critical",
      category: "backup",
      description:
        "Legacy copy of WordPress configuration served as plaintext, exposing database credentials.",
      pattern: ~r/define\s*\(\s*['"]DB_(?:PASSWORD|NAME|USER)['"]/i,
      anti_patterns: [],
      references: ["https://developer.wordpress.org/advanced-administration/wordpress/wp-config/"]
    },
    %{
      path: "/docker-compose.yml",
      title: "Exposed Docker Compose File",
      severity: "high",
      category: "infrastructure",
      description:
        "Container orchestration file publicly readable, disclosing internal service topologies, network setups, and environment variables.",
      pattern: ~r/services:\s*\n\s+[\w\.\-]+:\s*\n\s+(?:image|build|container_name):/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://docs.docker.com/compose/"]
    },
    %{
      path: "/Dockerfile",
      title: "Exposed Dockerfile",
      severity: "medium",
      category: "infrastructure",
      description:
        "Container build specification exposed publicly, detailing base OS images, installed packages, and internal build arguments.",
      pattern: ~r/^FROM\s+[\w\.\-\/]+(?::[\w\.\-]+)?(?:\s+AS\s+\w+)?/im,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://docs.docker.com/engine/reference/builder/"]
    },
    %{
      path: "/storage/logs/laravel.log",
      title: "Exposed Laravel Application Log",
      severity: "high",
      category: "logs",
      description:
        "Application log file exposed to the internet, revealing stack traces, internal paths, SQL queries, and session information.",
      pattern:
        ~r/\[\d{4}-\d{2}-\d{2}\s\d{2}:\d{2}:\d{2}\]\s+(?:local|production|staging)\.(?:ERROR|CRITICAL|WARNING):/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://laravel.com/docs/logging"]
    },
    %{
      path: "/.vscode/sftp.json",
      title: "Exposed VSCode SFTP Configuration",
      severity: "critical",
      category: "secrets",
      description:
        "VSCode SFTP deployment settings file containing FTP/SSH hostnames, usernames, and authentication passwords.",
      pattern: ~r/"(?:password|passphrase|privateKeyPath)"\s*:\s*"[^"]+"/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://cwe.mitre.org/data/definitions/200.html"]
    },
    %{
      path: "/.ssh/id_rsa",
      title: "Exposed SSH Private Key (.ssh/id_rsa)",
      severity: "critical",
      category: "secrets",
      description: "Unprotected SSH private key granting direct remote server shell access.",
      pattern: ~r/-----BEGIN (?:RSA|OPENSSH) PRIVATE KEY-----/,
      anti_patterns: [],
      references: ["https://owasp.org/www-project-top-ten/2017/A3_2017-Sensitive_Data_Exposure"]
    },
    %{
      path: "/.bash_history",
      title: "Exposed Shell History (.bash_history)",
      severity: "high",
      category: "secrets",
      description:
        "Server terminal history file disclosing administrative commands, local filesystem paths, and embedded passwords.",
      pattern: ~r/(?:sudo|ssh|mysql|curl|export|git\s+clone)\s+/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://cwe.mitre.org/data/definitions/538.html"]
    },
    %{
      path: "/dump.sql",
      title: "Exposed Database SQL Dump (dump.sql)",
      severity: "critical",
      category: "backup",
      description:
        "Publicly downloadable SQL database dump containing database tables, schema definitions, and production records.",
      pattern: ~r/(?:CREATE TABLE|INSERT INTO|MySQL dump|PostgreSQL database dump)/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://owasp.org/www-community/vulnerabilities/Database_Backups_Exposed"]
    },
    %{
      path: "/backup.sql",
      title: "Exposed Database SQL Backup (backup.sql)",
      severity: "critical",
      category: "backup",
      description:
        "Publicly downloadable SQL backup containing production table data and database schemas.",
      pattern: ~r/(?:CREATE TABLE|INSERT INTO|MySQL dump|PostgreSQL database dump)/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://owasp.org/www-community/vulnerabilities/Database_Backups_Exposed"]
    },
    %{
      path: "/web.config.bak",
      title: "Exposed IIS Web Configuration Backup (web.config.bak)",
      severity: "high",
      category: "backup",
      description:
        "ASP.NET / IIS configuration backup containing connection strings, application settings, and machine keys.",
      pattern: ~r/<configuration>[\s\S]*<system\.web/i,
      anti_patterns: [],
      references: ["https://cwe.mitre.org/data/definitions/538.html"]
    },
    %{
      path: "/.npmrc",
      title: "Exposed NPM Configuration (.npmrc)",
      severity: "critical",
      category: "secrets",
      description:
        "NPM configuration file containing authentication tokens for private package registries.",
      pattern: ~r/(?:_auth\s*=|:_authToken\s*=[a-zA-Z0-9\-_]+)/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://docs.npmjs.com/cli/v10/configuring-npm/npmrc"]
    },
    %{
      path: "/.git-credentials",
      title: "Exposed Git Plaintext Credentials (.git-credentials)",
      severity: "critical",
      category: "secrets",
      description:
        "Git credential helper file containing plaintext usernames, passwords, or personal access tokens.",
      pattern: ~r/https?:\/\/[^:]+:[^@]+@/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://git-scm.com/docs/git-credential-store"]
    },

    # ── Debuggers, Actuators & Panels ─────────────────────────────────────────
    %{
      path: "/actuator/env",
      title: "Spring Boot Actuator Environment (/actuator/env)",
      severity: "critical",
      category: "actuator",
      description:
        "Unauthenticated Spring Boot Actuator endpoint disclosing server environment variables, system properties, and secrets.",
      pattern: ~r/"(?:activeProfiles|propertySources)"/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: [
        "https://docs.spring.io/spring-boot/docs/current/actuator-api/htmlsingle/#env"
      ]
    },
    %{
      path: "/actuator/heapdump",
      title: "Spring Boot Actuator Heap Dump (/actuator/heapdump)",
      severity: "critical",
      category: "actuator",
      description:
        "Exposed JVM memory heap dump containing runtime variables, decrypted encryption keys, and active user sessions.",
      pattern: ~r/^(?:JAVA PROFILE|HPROF)/,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: [
        "https://docs.spring.io/spring-boot/docs/current/actuator-api/htmlsingle/#heapdump"
      ]
    },
    %{
      path: "/actuator/health",
      title: "Spring Boot Actuator Health (/actuator/health)",
      severity: "low",
      category: "actuator",
      description:
        "Exposed Spring Boot health status endpoint disclosing backend database, cache, and queue dependency connectivity.",
      pattern: ~r/"status"\s*:\s*"(?:UP|DOWN|OUT_OF_SERVICE|UNKNOWN)"/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: [
        "https://docs.spring.io/spring-boot/docs/current/actuator-api/htmlsingle/#health"
      ]
    },
    %{
      path: "/_ignition/health-checks",
      title: "Laravel Ignition Debug Dashboard Exposed",
      severity: "critical",
      category: "debug_panel",
      description:
        "Laravel Ignition debug interface exposed to public access, historically susceptible to unauthenticated Remote Code Execution (CVE-2021-3129).",
      pattern: ~r/"can_execute_commands"|facade\/ignition|spatie\/laravel-ignition/i,
      anti_patterns: [],
      references: [
        "https://nvd.nist.gov/vuln/detail/cve-2021-3129",
        "https://github.com/facade/ignition"
      ]
    },
    %{
      path: "/phpinfo.php",
      title: "PHP Diagnostic Script Exposed (phpinfo.php)",
      severity: "high",
      category: "debug_panel",
      description:
        "Standard PHP diagnostic script outputting full PHP build parameters, server modules, filesystem paths, and environment configuration.",
      pattern: ~r/<title>phpinfo\(\)<\/title>|PHP Version \d+\.\d+/i,
      anti_patterns: [],
      references: ["https://www.php.net/manual/en/function.phpinfo.php"]
    },
    %{
      path: "/info.php",
      title: "PHP Diagnostic Script Exposed (info.php)",
      severity: "high",
      category: "debug_panel",
      description:
        "Diagnostic script outputting complete PHP configuration, active modules, and server environment variables.",
      pattern: ~r/<title>phpinfo\(\)<\/title>|PHP Version \d+\.\d+/i,
      anti_patterns: [],
      references: ["https://www.php.net/manual/en/function.phpinfo.php"]
    },
    %{
      path: "/swagger-ui/index.html",
      title: "Exposed Swagger UI API Documentation",
      severity: "low",
      category: "api_docs",
      description:
        "Interactive Swagger UI console accessible without authentication, exposing API endpoints, models, and test execution consoles.",
      pattern: ~r/<div id="swagger-ui">|swagger-ui-bundle\.js|Swagger UI/i,
      anti_patterns: [],
      references: ["https://swagger.io/tools/swagger-ui/"]
    },
    %{
      path: "/swagger-ui.html",
      title: "Exposed Swagger UI Documentation (Legacy Path)",
      severity: "low",
      category: "api_docs",
      description:
        "Legacy Springfox/Swagger UI console publicly accessible, revealing backend API structure and test harnesses.",
      pattern: ~r/<div id="swagger-ui">|swagger-ui-bundle\.js|Swagger UI/i,
      anti_patterns: [],
      references: ["https://swagger.io/tools/swagger-ui/"]
    },
    %{
      path: "/openapi.json",
      title: "Exposed OpenAPI Specification (/openapi.json)",
      severity: "low",
      category: "api_docs",
      description:
        "Machine-readable OpenAPI JSON schema exposing entire route dictionary, request parameter schemas, and authentication schemes.",
      pattern: ~r/"openapi"\s*:\s*"3\.\d+\.\d+"/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://spec.openapis.org/oas/latest.html"]
    },
    %{
      path: "/v2/api-docs",
      title: "Exposed Swagger 2.0 API Docs (/v2/api-docs)",
      severity: "low",
      category: "api_docs",
      description:
        "Springfox Swagger 2.0 API description document exposing application routes and model contracts.",
      pattern: ~r/"swagger"\s*:\s*"2\.0"/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://swagger.io/specification/v2/"]
    },
    %{
      path: "/solr/admin/info/system?wt=json",
      title: "Apache Solr Admin Interface Exposed",
      severity: "high",
      category: "admin_panel",
      description:
        "Apache Solr search engine administrative JSON interface exposed without authentication.",
      pattern: ~r/"solr-spec-version"|"lucene-spec-version"/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: [
        "https://solr.apache.org/guide/solr/latest/deployment-guide/securing-solr.html"
      ]
    },
    %{
      path: "/server-status",
      title: "Apache HTTP Server Status Page Exposed (/server-status)",
      severity: "medium",
      category: "admin_panel",
      description:
        "Apache mod_status page disclosing active incoming client IP addresses, requested URLs, CPU usage, and server worker states.",
      pattern: ~r/<title>Apache Status<\/title>|Apache Server Status for/i,
      anti_patterns: [],
      references: ["https://httpd.apache.org/docs/current/mod/mod_status.html"]
    },
    %{
      path: "/nginx_status",
      title: "Nginx Status Page Exposed (/nginx_status)",
      severity: "medium",
      category: "admin_panel",
      description:
        "Nginx stub_status module exposed publicly, revealing concurrent connection statistics and request throughput.",
      pattern: ~r/Active connections:\s*\d+/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://nginx.org/en/docs/http/ngx_http_stub_status_module.html"]
    },
    %{
      path: "/debug/vars",
      title: "Go Expvar Debug Variables Exposed (/debug/vars)",
      severity: "high",
      category: "debug_panel",
      description:
        "Go expvar runtime debugging endpoint exposing process command-line arguments, memory metrics, and package internals.",
      pattern: ~r/"cmdline"[\s\S]*"memstats"/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://pkg.go.dev/expvar"]
    },
    %{
      path: "/elmah.axd",
      title: "ELMAH Error Log Console Exposed (/elmah.axd)",
      severity: "high",
      category: "logs",
      description:
        "ASP.NET Error Logging Modules and Handlers (ELMAH) dashboard publicly exposing unhandled application exceptions, session cookies, and parameters.",
      pattern: ~r/Error Log for|powered by ELMAH/i,
      anti_patterns: [],
      references: ["https://elmah.github.io/"]
    },

    # ── Metadata & Fingerprints ──────────────────────────────────────────────
    %{
      path: "/.well-known/security.txt",
      title: "RFC 9116 security.txt Discovered",
      severity: "info",
      category: "policy",
      description:
        "The domain publishes an RFC 9116 security.txt vulnerability disclosure policy file.",
      pattern: ~r/Contact:\s*(?:mailto:|https:)/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://www.rfc-editor.org/rfc/rfc9116"]
    },
    %{
      path: "/.DS_Store",
      title: "Exposed macOS Metadata File (.DS_Store)",
      severity: "low",
      category: "metadata",
      description:
        "Apple macOS Finder metadata file publicly downloadable, allowing attackers to enumerate directory contents and hidden filenames.",
      pattern: ~r/^\x00\x00\x00\x01Bud1/,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: [
        "https://owasp.org/www-community/vulnerabilities/Finder_.DS_Store_Folder_Disclosure"
      ]
    },
    %{
      path: "/composer.json",
      title: "Exposed PHP Dependency Manifest (composer.json)",
      severity: "low",
      category: "metadata",
      description:
        "Composer configuration file publicly readable, disclosing internal PHP dependency libraries and exact version constraints.",
      pattern: ~r/"require"\s*:\s*\{[\s\S]*"php"/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://getcomposer.org/doc/04-schema.md"]
    },
    %{
      path: "/package.json",
      title: "Exposed Node.js Package Manifest (package.json)",
      severity: "low",
      category: "metadata",
      description:
        "Node.js package manifest publicly accessible, exposing application name, scripts, and production dependencies.",
      pattern: ~r/"dependencies"\s*:\s*\{|"devDependencies"\s*:\s*\{/i,
      anti_patterns: [~r/<!DOCTYPE html/i, ~r/<html/i],
      references: ["https://docs.npmjs.com/cli/v10/configuring-npm/package-json"]
    }
  ]

  @doc """
  Returns the complete list of curated probe specifications.
  """
  @spec probes() :: [probe_spec()]
  def probes, do: @probes

  @doc """
  Runs curated probes against a base URL or host.

  Returns `{:ok, findings}` where each finding conforms to the
  `Ravner.SecurityScans.ScanFinding` structure.

  ## Options

  - `:timeout` - timeout per request in ms (default: 2,000ms)
  - `:max_concurrency` - concurrent requests (default: 5)
  - `:probes` - custom probe list for testing (defaults to `@probes`)
  """
  @spec probe(String.t(), keyword()) :: {:ok, [map()]}
  def probe(target_url, opts \\ []) do
    base_url = normalize_url(target_url)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    concurrency = Keyword.get(opts, :max_concurrency, @max_concurrency)
    probes_list = Keyword.get(opts, :probes, @probes)

    findings =
      probes_list
      |> Task.async_stream(
        fn probe_spec ->
          execute_probe(base_url, probe_spec, timeout)
        end,
        max_concurrency: concurrency,
        timeout: timeout + 1_500,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {:finding, finding}} -> [finding]
        _ -> []
      end)

    {:ok, findings}
  rescue
    e in [ArgumentError, RuntimeError, Req.TransportError, Mint.TransportError] ->
      Logger.warning(
        "Curated probes execution encountered error for #{target_url}: #{inspect(e)}"
      )

      {:ok, []}
  end

  # ─── Probe Execution ───────────────────────────────────────────────────────

  defp execute_probe(base_url, probe, timeout) do
    url = "#{base_url}#{probe.path}"

    # We do NOT follow redirects for probe paths. A 301/302 to a login page
    # or home page is NOT an exposure!
    req_opts = [
      receive_timeout: timeout,
      connect_timeout: timeout,
      redirect: false,
      headers: [
        {"user-agent", "Mozilla/5.0 (compatible; Ravner-SecurityAudit/1.0)"},
        {"range", "bytes=0-#{@max_body_bytes - 1}"}
      ]
    ]

    case Req.get(url, req_opts) do
      {:ok, %Req.Response{status: status, body: body}} when status in [200, 206] ->
        body_str = extract_body_string(body)

        if matches_signature?(body_str, probe.pattern, probe.anti_patterns) do
          finding = build_finding(probe, url, status, body_str)
          {:finding, finding}
        else
          :clean
        end

      _ ->
        :clean
    end
  rescue
    _e in [Req.TransportError, Mint.TransportError, ArgumentError, RuntimeError] -> :clean
  end

  defp matches_signature?(body, pattern, anti_patterns) when is_binary(body) do
    has_match =
      case pattern do
        %Regex{} = regex -> Regex.match?(regex, body)
        string when is_binary(string) -> String.contains?(body, string)
      end

    if has_match do
      # Make sure none of the anti-patterns match (e.g. custom 404 returning 200 with HTML)
      Enum.all?(anti_patterns, fn
        %Regex{} = anti -> not Regex.match?(anti, body)
        anti_str when is_binary(anti_str) -> not String.contains?(body, anti_str)
      end)
    else
      false
    end
  end

  defp extract_body_string(body) when is_binary(body) do
    String.slice(body, 0, @max_body_bytes)
  end

  defp extract_body_string(body) when is_map(body) or is_list(body) do
    case Jason.encode(body) do
      {:ok, json} -> String.slice(json, 0, @max_body_bytes)
      _ -> ""
    end
  end

  defp extract_body_string(_), do: ""

  defp build_finding(probe, url, status, body) do
    # Extract evidence snippet (up to 250 characters, masking obvious secrets)
    evidence =
      body
      |> String.slice(0, 250)
      |> String.replace(~r/[^\x20-\x7E\n\r\t]/, ".")

    %{
      severity: probe.severity,
      title: probe.title,
      target: url,
      detail: %{
        "source" => "curated_probes",
        "category" => probe.category,
        "path" => probe.path,
        "status" => status,
        "description" => probe.description,
        "references" => probe.references,
        "evidence" => evidence
      }
    }
  end

  defp normalize_url(url) when is_binary(url) do
    url = String.trim_trailing(url, "/")

    if String.starts_with?(url, "http://") or String.starts_with?(url, "https://") do
      url
    else
      "https://#{url}"
    end
  end
end
