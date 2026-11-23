defmodule Ravner.Scans.PortProbe do
  @moduledoc """
  Lightweight in-BEAM TCP port scanner for sensitive infrastructure and database exposures.

  Uses native `:gen_tcp` sockets with bounded concurrency and short timeouts
  to identify publicly exposed databases (MySQL, PostgreSQL, Redis, MongoDB,
  Elasticsearch) and remote management services (Telnet, RDP, VNC, FTP) without
  invoking external binaries like Naabu.
  """

  require Logger

  @default_timeout 800
  @max_concurrency 10

  # {port, service_name, severity, description, references, is_vulnerability?}
  @probed_ports [
    # Databases & Caches
    {3306, "MySQL", "high",
     "Relational database server exposed to public internet without network isolation",
     ["https://dev.mysql.com/doc/refman/8.0/en/security-guidelines.html"], true},
    {5432, "PostgreSQL", "high",
     "Relational database server exposed to public internet without network isolation",
     ["https://www.postgresql.org/docs/current/auth-pg-hba-conf.html"], true},
    {6379, "Redis", "critical",
     "In-memory key-value store exposed to public internet (often unauthenticated, high risk of RCE)",
     ["https://redis.io/docs/latest/operate/oss_and_stack/management/security/"], true},
    {27017, "MongoDB", "critical",
     "NoSQL document database exposed to public internet (risk of data breach / ransomware)",
     ["https://www.mongodb.com/docs/manual/security/"], true},
    {9200, "Elasticsearch", "high", "Search cluster HTTP API exposed to public internet",
     ["https://www.elastic.co/guide/en/elasticsearch/reference/current/secure-cluster.html"],
     true},
    {9300, "Elasticsearch Transport", "high",
     "Search cluster inter-node transport exposed to public internet",
     ["https://www.elastic.co/guide/en/elasticsearch/reference/current/secure-cluster.html"],
     true},
    {11211, "Memcached", "high",
     "Memory object caching daemon exposed to public internet (risk of DDoS amplification & data exposure)",
     [
       "https://www.cisa.gov/news-events/alerts/2018/03/01/memcached-udp-and-tcp-traffic-amplification-attacks"
     ], true},
    {28017, "MongoDB Web", "high",
     "MongoDB legacy HTTP admin interface exposed to public internet",
     ["https://www.mongodb.com/docs/manual/security/"], true},

    # Remote administration & Legacy protocols
    {21, "FTP", "medium", "File Transfer Protocol exposed with cleartext credential risk",
     ["https://csrc.nist.gov/publications/detail/sp/800-123/final"], true},
    {22, "SSH", "low", "Secure Shell remote access port open", [], false},
    {23, "Telnet", "critical", "Unencrypted Telnet terminal service exposed to public internet",
     ["https://owasp.org/www-community/attacks/Insecure_Transport"], true},
    {3389, "RDP", "high",
     "Remote Desktop Protocol exposed to public internet (frequent brute-force and ransomware vector)",
     [
       "https://www.cisa.gov/news-events/alerts/2019/06/27/remediation-guidance-bluekeep-vulnerability"
     ], true},
    {5900, "VNC", "high", "VNC remote desktop exposed to public internet",
     ["https://csrc.nist.gov/publications/detail/sp/800-123/final"], true},

    # Alternative web & management interfaces
    {8080, "HTTP-Alt", "low", "Alternative HTTP service or administrative interface", [], false},
    {8443, "HTTPS-Alt", "low", "Alternative HTTPS service or administrative interface", [],
     false},
    {9000, "FastCGI/Portainer", "medium",
     "PHP-FPM FastCGI or Portainer container management exposed",
     ["https://docs.portainer.io/admin/settings"], true}
  ]

  @doc """
  Probes a host for sensitive open ports.

  Returns `{:ok, open_ports, findings}` where:
  - `open_ports` is a list of open port numbers (integers) including `base_ports`
  - `findings` is a list of security finding maps for sensitive exposed services
  """
  @spec probe(String.t(), keyword()) :: {:ok, [integer()], [map()]}
  def probe(host, opts \\ []) when is_binary(host) do
    clean = clean_host(host)
    timeout = Keyword.get(opts, :timeout, @default_timeout)
    concurrency = Keyword.get(opts, :concurrency, @max_concurrency)
    base_ports = Keyword.get(opts, :base_ports, [])
    port_specs = Keyword.get(opts, :port_specs, @probed_ports)

    results =
      port_specs
      |> Task.async_stream(
        fn {port, service, severity, description, references, is_vuln} ->
          if port_open?(clean, port, timeout) do
            finding =
              if is_vuln do
                build_finding(clean, port, service, severity, description, references)
              else
                nil
              end

            {port, finding}
          else
            nil
          end
        end,
        max_concurrency: concurrency,
        timeout: timeout + 500,
        on_timeout: :kill_task
      )
      |> Enum.flat_map(fn
        {:ok, {port, finding}} -> [{port, finding}]
        _ -> []
      end)

    probed_open_ports = Enum.map(results, &elem(&1, 0))
    findings = Enum.map(results, &elem(&1, 1)) |> Enum.reject(&is_nil/1)

    all_ports = (base_ports ++ probed_open_ports) |> Enum.uniq() |> Enum.sort()

    {:ok, all_ports, findings}
  rescue
    e in [ArgumentError, ErlangError, RuntimeError] ->
      Logger.warning("Port probe failed for #{host}: #{inspect(e)}")
      {:ok, Keyword.get(opts, :base_ports, []), []}
  end

  @doc """
  Returns the list of probed port specifications.
  """
  def probed_ports, do: @probed_ports

  defp clean_host(host) do
    host = String.trim(host)

    cond do
      String.starts_with?(host, "http://") or String.starts_with?(host, "https://") ->
        uri = URI.parse(host)
        uri.host || host

      String.contains?(host, "/") ->
        host |> String.split("/") |> List.first()

      String.contains?(host, ":") ->
        host |> String.split(":") |> List.first()

      true ->
        host
    end
  end

  defp port_open?(host, port, timeout) do
    char_host = to_charlist(host)

    case :gen_tcp.connect(char_host, port, [:binary, active: false], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        true

      _ ->
        false
    end
  rescue
    _e in [ArgumentError, ErlangError] -> false
  end

  defp build_finding(host, port, service, severity, description, references) do
    %{
      severity: severity,
      title: "Exposed #{service}: port #{port} is publicly accessible",
      target: "#{host}:#{port}",
      detail: %{
        "service" => service,
        "port" => port,
        "summary" => "Exposed #{service} service on port #{port}",
        "description" => description,
        "references" => references,
        "source" => "port_probe"
      }
    }
  end
end
