defmodule Ravner.Scans.DnsTest do
  use ExUnit.Case, async: true

  alias Ravner.Scans.Dns

  describe "format_record/2" do
    test "formats IPv4 addresses" do
      assert Dns.format_record(:a, {93, 184, 216, 34}) == "93.184.216.34"
    end

    test "formats IPv6 addresses" do
      assert Dns.format_record(:aaaa, {0x2606, 0x2800, 0x220, 1, 0x248, 0x1893, 0x25C8, 0x1946}) ==
               "2606:2800:220:1:248:1893:25c8:1946"
    end

    test "formats MX records with preference" do
      assert Dns.format_record(:mx, {10, ~c"mail.example.com"}) == "10 mail.example.com"
    end

    test "joins TXT record segments" do
      assert Dns.format_record(:txt, [~c"v=spf1 ", ~c"include:_spf.example.com ~all"]) ==
               "v=spf1 include:_spf.example.com ~all"
    end

    test "formats NS and CNAME records" do
      assert Dns.format_record(:ns, ~c"ns1.example.com") == "ns1.example.com"
      assert Dns.format_record(:cname, ~c"target.example.com") == "target.example.com"
    end
  end
end
