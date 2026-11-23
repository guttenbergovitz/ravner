defmodule Ravner.Scans.TlsHeaderAuditTest do
  use ExUnit.Case, async: true

  alias Ravner.Scans.TlsHeaderAudit

  describe "audit_headers/2" do
    test "detects missing HSTS, CSP, and X-Frame-Options on HTTPS" do
      target_url = "https://example.com"
      headers = %{"content-type" => "text/html; charset=utf-8"}

      findings = TlsHeaderAudit.audit_headers(target_url, headers)
      titles = Enum.map(findings, & &1.title)

      assert "Missing HTTP Strict Transport Security (HSTS)" in titles
      assert "Missing Content Security Policy (CSP)" in titles
      assert "Missing Clickjacking Protection (X-Frame-Options)" in titles
      assert "Missing X-Content-Type-Options: nosniff" in titles
    end

    test "recognizes secure headers and produces no findings" do
      target_url = "https://example.com"

      headers = %{
        "strict-transport-security" => "max-age=31536000; includeSubDomains; preload",
        "content-security-policy" => "default-src 'self'; frame-ancestors 'self';",
        "x-frame-options" => "SAMEORIGIN",
        "x-content-type-options" => "nosniff"
      }

      findings = TlsHeaderAudit.audit_headers(target_url, headers)
      assert findings == []
    end

    test "flags short HSTS duration" do
      target_url = "https://example.com"

      headers = %{
        "strict-transport-security" => "max-age=3600",
        "content-security-policy" => "default-src 'self';",
        "x-frame-options" => "DENY",
        "x-content-type-options" => "nosniff"
      }

      findings = TlsHeaderAudit.audit_headers(target_url, headers)
      titles = Enum.map(findings, & &1.title)

      assert "Short HSTS max-age Duration (< 180 days)" in titles
    end

    test "flags information-disclosing headers" do
      target_url = "https://example.com"

      headers = %{
        "server" => "Apache/2.4.41 (Ubuntu)",
        "x-powered-by" => "PHP/8.1.2",
        "strict-transport-security" => "max-age=31536000",
        "content-security-policy" => "default-src 'self';",
        "x-frame-options" => "SAMEORIGIN",
        "x-content-type-options" => "nosniff"
      }

      findings = TlsHeaderAudit.audit_headers(target_url, headers)
      titles = Enum.map(findings, & &1.title)

      assert "Server Version Information Disclosure" in titles
      assert "X-Powered-By Header Discloses Technology" in titles
    end
  end

  describe "audit/2" do
    test "runs with skip_tls: true and processes provided headers" do
      {:ok, findings} =
        TlsHeaderAudit.audit("example.com",
          headers: %{"server" => "nginx/1.18.0"},
          skip_tls: true
        )

      assert is_list(findings)
      assert Enum.any?(findings, &(&1.title == "Server Version Information Disclosure"))
    end
  end
end
