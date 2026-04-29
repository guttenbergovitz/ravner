import Config

# ── Nameserver → Registrar heuristics ──────────────────────────────────────────
# Format: {nameserver_suffix, registrar_name}
# Used when RDAP/WHOIS scans fail and we only have nameservers.
# Add custom entries below, they merge with (and override) the built-in list.

ns_registrar_patterns = [
  {"domaincontrol.com", "GoDaddy"},
  {"godaddy.com", "GoDaddy"},
  {"namecheaphosting.com", "Namecheap"},
  {"namecheap.com", "Namecheap"},
  {"cloudflare.com", "Cloudflare"},
  {"name-services.com", "Enom"},
  {"enom.com", "Enom"},
  {"registrar-servers.com", "Namecheap"},
  {"ovh.net", "OVH"},
  {"ovh.com", "OVH"},
  {"hichina.com", "Alibaba Cloud"},
  {"aliyun.com", "Alibaba Cloud"},
  {"awsdns", "Amazon Route 53"},
  {"azure-dns.com", "Azure DNS"},
  {"azure-dns.net", "Azure DNS"},
  {"azure-dns.org", "Azure DNS"},
  {"azure-dns.info", "Azure DNS"},
  {"googledomains.com", "Google Domains"},
  {"dns.google.com", "Google"},
  {"1and1.com", "IONOS"},
  {"ionos.com", "IONOS"},
  {"wpengine.com", "WP Engine"},
  {"netlify.com", "Netlify"},
  {"nsone.net", "NS1"},
  {"dnsimple.com", "DNSimple"},
  {"hover.com", "Hover"},
  {"gandi.net", "Gandi"},
  {"sav.com", "SAV"},
  {"dynadot.com", "Dynadot"},
  {"porkbun.com", "Porkbun"},
  {"name.com", "Name.com"},
  {"register.com", "Register.com"},
  {"networksolutions.com", "Network Solutions"},
  {"uniregistry.net", "Uniregistry"},
  {"fastly.net", "Fastly"},
  {"dns.com", "DNS.com"},
  {"rcode0.net", "RcodeZero"},
  {"dnsnode.net", "Netnod"},
  {"home.pl", "home.pl"},
  {"aftermarket.pl", "AfterMarket.pl"},
  {"kei.pl", "KEI"},
  {"nazwa.pl", "nazwa.pl"},
  {"dogado.de", "dogado"}
]

# ── Tech stack heuristics (body regex patterns) ────────────────────────────────
# Format: {regex_pattern, detected_tech_name}
# Use :capture instead of a name to extract the version from the regex capture group.
tech_stack_patterns = [
  {~r/<meta[^>]+name="generator"[^>]+content="([^"]+)"/i, :capture},
  {~r/wp-content\//i, "WordPress"},
  {~r/wp-includes\//i, "WordPress"},
  {~r/cdn\.shopify\.com/i, "Shopify"},
  {~r/Shopify\.theme/i, "Shopify"},
  {~r/__nuxt/i, "Nuxt.js"},
  {~r/__NEXT_DATA__/i, "Next.js"},
  {~r/ng-version=/i, "Angular"},
  {~r/data-reactroot/i, "React"},
  {~r/window\.Squarespace/i, "Squarespace"},
  {~r/static\.wixstatic\.com/i, "Wix"},
  {~r/drupal\.js|drupalSettings/i, "Drupal"},
  {~r/Joomla!/i, "Joomla"},
  {~r/ghost\.org|ghost-theme/i, "Ghost"},
  {~r/webflow\.com/i, "Webflow"}
]

# ── Server header → tech name ──────────────────────────────────────────────────
server_tech_map = %{
  "nginx" => "nginx",
  "Apache" => "Apache",
  "IIS" => "IIS",
  "Caddy" => "Caddy",
  "LiteSpeed" => "LiteSpeed"
}

# ── Hosting platform heuristics (HTTP response headers) ────────────────────────
# Format: {header_name, platform_name}
hosting_platform_headers = [
  {"cf-ray", "Cloudflare"},
  {"cf-cache-status", "Cloudflare"},
  {"x-amz-cf-id", "AWS CloudFront"},
  {"x-amz-request-id", "AWS"},
  {"x-vercel-id", "Vercel"},
  {"x-nf-request-id", "Netlify"},
  {"x-github-request-id", "GitHub Pages"},
  {"x-fastly-request-id", "Fastly"},
  {"x-azure-ref", "Azure"},
  {"x-wix-request-id", "Wix"}
]

# ── Merge with optional local overrides ────────────────────────────────────────
local_heuristics_path = Path.join(Path.dirname(__ENV__.file), "heuristics.local.exs")

if File.exists?(local_heuristics_path) do
  import_config "heuristics.local.exs"
end

# ── Persist to application config ─────────────────────────────────────────────
config :ravner, :heuristics,
  ns_registrar_patterns: ns_registrar_patterns,
  tech_stack_patterns: tech_stack_patterns,
  server_tech_map: server_tech_map,
  hosting_platform_headers: hosting_platform_headers
