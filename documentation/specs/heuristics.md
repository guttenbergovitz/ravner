# Heuristics Configuration

This document describes how registrar, tech stack and hosting platform
detection heuristics work and how to customize them.

## Architecture

Heuristics are loaded from `config/heuristics.exs` at application startup.
A local override file at `config/heuristics.local.exs` (gitignored) can
add or override entries without affecting the shared config.

## Registrar Detection (3-tier fallback)

1. **RDAP** — `rdap.org` → IANA bootstrap → parse `entities` with `registrar` role
2. **WHOIS** — system `whois` command → parse `Registrar:` field
3. **NS heuristics** — map nameserver suffix to known registrar

### NS → Registrar patterns

Defined in `config/heuristics.exs` under `ns_registrar_patterns`.
Format: `{nameserver_suffix, registrar_name}`

Example:
```elixir
ns_registrar_patterns = [
  {"domaincontrol.com", "GoDaddy"},
  {"cloudflare.com", "Cloudflare"}
]
```

## Tech Stack Detection

Scans HTTP response headers (`X-Powered-By`, `X-Generator`, `Server`) and
HTML body for known CMS and framework patterns.

### Body regex patterns

Defined in `config/heuristics.exs` under `tech_stack_patterns`.
Format: `{Regex.t(), detected_name | :capture}`

Use `:capture` to extract dynamic values (e.g. generator version).

### Server header → tech

Defined in `config/heuristics.exs` under `server_tech_map`.
Format: `%{substring => detected_name}`

## Hosting Platform Detection

Defined in `config/heuristics.exs` under `hosting_platform_headers`.
Format: `{http_header_name, platform_name}`

Example:
```elixir
hosting_platform_headers = [
  {"cf-ray", "Cloudflare"},
  {"x-vercel-id", "Vercel"}
]
```

## Local Overrides

Create `config/heuristics.local.exs` (see `heuristics.local.exs.example`):

```elixir
ns_registrar_patterns = ns_registrar_patterns ++ [
  {"mycustomdns.com", "My Registrar"}
]
```

This file is gitignored, safe for private/custom heuristics.
