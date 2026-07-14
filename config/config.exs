# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :ravner, :scopes,
  user: [
    default: true,
    module: Ravner.Accounts.Scope,
    assign_key: :current_scope,
    access_path: [:user, :id],
    schema_key: :user_id,
    schema_type: :id,
    schema_table: :users,
    test_data_fixture: Ravner.AccountsFixtures,
    test_setup_helper: :register_and_log_in_user
  ]

# Load .env file in dev and test
if config_env() in [:dev, :test] do
  env_path = Path.expand("../.env", __DIR__)

  if File.exists?(env_path) do
    env_path
    |> File.read!()
    |> String.split("\n")
    |> Enum.each(fn line ->
      case String.split(line, "=", parts: 2) do
        [key, value] -> System.put_env(String.trim(key), String.trim(value))
        _ -> :ok
      end
    end)
  end
end

config :ravner,
  ecto_repos: [Ravner.Repo],
  generators: [timestamp_type: :utc_datetime],
  scan_max_concurrency: 5

# Configure the endpoint
config :ravner, RavnerWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RavnerWeb.ErrorHTML, json: RavnerWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Ravner.PubSub,
  live_view: [signing_salt: "Mu7QwvHt"]

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :ravner, Ravner.Mailer, adapter: Swoosh.Adapters.Local

# Configure Oban
config :ravner, Oban,
  repo: Ravner.Repo,
  plugins: [
    {Oban.Plugins.Cron,
     crontab: [
       {"* * * * *", Ravner.Workers.HeartbeatDispatcher},
       {"0 * * * *", Ravner.Workers.SecurityScanDispatcher},
       {"0 3 * * *", Ravner.Workers.SslCheckDispatcher},
       {"30 * * * *", Ravner.Workers.HttpxScanDispatcher},
       {"45 * * * *", Ravner.Workers.DnsxScanDispatcher},
       {"0 5 * * *", Ravner.Workers.A11yScanDispatcher}
     ]}
  ],
  queues: [
    heartbeats: 50,
    ssl_checks: 20,
    scans: 5,
    deep_tech: 2,
    default: 10
  ]

# Configure Ash
config :ravner,
  ash_domains: [
    Ravner.Accounts.AshDomain,
    Ravner.Inventory.AshDomain,
    Ravner.Domains.AshDomain
  ]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  ravner: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.1.12",
  ravner: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# ── Detection heuristics ───────────────────────────────────────────────────────
# Overridable in config/heuristics.local.exs (gitignored).
# See documentation/specs/heuristics.md for details.

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

local_heuristics = Path.join(__DIR__, "heuristics.local.exs")

if File.exists?(local_heuristics) do
  Code.eval_file(local_heuristics)
end

config :ravner, :heuristics,
  ns_registrar_patterns: ns_registrar_patterns,
  tech_stack_patterns: [
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
  ],
  server_tech_map: %{
    "nginx" => "nginx",
    "Apache" => "Apache",
    "IIS" => "IIS",
    "Caddy" => "Caddy",
    "LiteSpeed" => "LiteSpeed"
  },
  hosting_platform_headers: [
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

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
