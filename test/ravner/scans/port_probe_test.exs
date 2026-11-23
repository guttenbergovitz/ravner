defmodule Ravner.Scans.PortProbeTest do
  use ExUnit.Case, async: true

  alias Ravner.Scans.PortProbe

  describe "probed_ports/0" do
    test "returns list of known sensitive ports including databases and admin services" do
      ports = PortProbe.probed_ports()
      assert is_list(ports)
      refute Enum.empty?(ports)

      port_numbers = Enum.map(ports, &elem(&1, 0))

      # Verifies critical databases and management ports are probed
      assert 3306 in port_numbers
      assert 5432 in port_numbers
      assert 6379 in port_numbers
      assert 27017 in port_numbers
      assert 9200 in port_numbers
      assert 11211 in port_numbers
      assert 23 in port_numbers
      assert 3389 in port_numbers
    end
  end

  describe "probe/2" do
    test "preserves base_ports even when no probed ports are open" do
      {:ok, open_ports, findings} =
        PortProbe.probe("127.0.0.1",
          base_ports: [80, 443],
          port_specs: [],
          timeout: 50
        )

      assert open_ports == [80, 443]
      assert findings == []
    end

    test "detects open port, distinguishes vulnerabilities, and formats finding" do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, local_port} = :inet.port(listen_socket)

      custom_specs = [
        {local_port, "TestRedis", "critical", "In-memory store exposed",
         ["https://redis.io/docs/latest/operate/oss_and_stack/management/security/"], true}
      ]

      {:ok, open_ports, findings} =
        PortProbe.probe("127.0.0.1",
          base_ports: [443],
          port_specs: custom_specs,
          timeout: 300
        )

      :gen_tcp.close(listen_socket)

      assert local_port in open_ports
      assert 443 in open_ports
      assert [finding] = findings
      assert finding.severity == "critical"
      assert finding.title == "Exposed TestRedis: port #{local_port} is publicly accessible"
      assert finding.target == "127.0.0.1:#{local_port}"
      assert finding.detail["service"] == "TestRedis"
      assert finding.detail["port"] == local_port

      assert finding.detail["references"] == [
               "https://redis.io/docs/latest/operate/oss_and_stack/management/security/"
             ]

      assert finding.detail["source"] == "port_probe"
    end

    test "detects open port marked as non-vulnerability without generating security finding" do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, local_port} = :inet.port(listen_socket)

      custom_specs = [
        {local_port, "SSH", "low", "SSH service open", [], false}
      ]

      {:ok, open_ports, findings} =
        PortProbe.probe("127.0.0.1",
          port_specs: custom_specs,
          timeout: 300
        )

      :gen_tcp.close(listen_socket)

      assert open_ports == [local_port]
      assert findings == []
    end

    test "handles closed ports gracefully without timeout crash" do
      # Use an arbitrary closed high ephemeral port
      custom_specs = [
        {59999, "TestClosed", "high", "Closed service", [], true}
      ]

      {:ok, open_ports, findings} =
        PortProbe.probe("127.0.0.1",
          port_specs: custom_specs,
          timeout: 50
        )

      refute 59999 in open_ports
      assert findings == []
    end

    test "cleans host with URL schemes and trailing paths" do
      {:ok, listen_socket} = :gen_tcp.listen(0, [:binary, active: false, reuseaddr: true])
      {:ok, local_port} = :inet.port(listen_socket)

      custom_specs = [
        {local_port, "TestDB", "high", "Database exposed", [], true}
      ]

      {:ok, open_ports, [finding]} =
        PortProbe.probe("https://127.0.0.1/admin/dashboard",
          port_specs: custom_specs,
          timeout: 300
        )

      :gen_tcp.close(listen_socket)

      assert local_port in open_ports
      assert finding.target == "127.0.0.1:#{local_port}"
    end
  end
end
