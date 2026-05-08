# syntax=docker/dockerfile:1.7

# ─────────────────────────────────────────────────────────────────────────────
# Multi-stage Dockerfile for the Ravner Phoenix app.
#
# Goals:
#   • Smallest practical runtime image (slim Debian + an OTP release; no Mix,
#     no Hex, no compilers, no source).
#   • Reproducible, cache-friendly builds (deps before source, assets before
#     compile, runtime config copied last).
#   • Easy to maintain — every base image and tool version is pinned via ARGs
#     at the top of this file.
#
# Runtime CLI dependencies bundled into the image:
#   • pg_dump / pg_restore  — Ravner.Admin.Backups
#   • dnsx                  — Ravner.Scans (subdomain DNS resolution)
#   • httpx                 — Ravner.Scans (HTTP probing)
#   • katana                — Ravner.Scans (deep URL crawling)
#   • webanalyze            — Ravner.Scans (deep tech fingerprinting)
#   • whois                 — Ravner.Scans (WHOIS lookup)
# ─────────────────────────────────────────────────────────────────────────────

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20260421-slim
ARG PG_MAJOR=16
ARG DNSX_VERSION=1.2.3
ARG NAABU_VERSION=2.6.0
ARG NUCLEI_VERSION=3.8.0
ARG NUCLEI_TEMPLATES_VERSION=10.4.3
ARG HTTPX_VERSION=1.9.0
ARG KATANA_VERSION=1.6.1
ARG WEBANALYZE_VERSION=0.4.3

ARG BUILDER_IMAGE="hexpm/elixir:${ELIXIR_VERSION}-erlang-${OTP_VERSION}-debian-${DEBIAN_VERSION}"
ARG RUNNER_IMAGE="debian:${DEBIAN_VERSION}"

# ─── Builder: compile the Elixir release ─────────────────────────────────────
FROM ${BUILDER_IMAGE} AS builder

RUN apt-get update -y \
 && apt-get install -y --no-install-recommends build-essential git ca-certificates \
 && apt-get clean \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /app

ENV MIX_ENV=prod \
    LANG=C.UTF-8

RUN mix local.hex --force \
 && mix local.rebar --force

# 1. Dependencies — copy manifests first so the layer caches unless they change.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only ${MIX_ENV}
RUN mix deps.compile

# 2. Application source + assets.
COPY priv priv
COPY lib lib
COPY assets assets

# Compile first so Phoenix LiveView emits colocated hooks under
# _build/.../phoenix-colocated/<app>, which esbuild then imports during
# `mix assets.deploy`.
RUN mix compile
RUN mix assets.deploy

# 3. Runtime config last — changing it shouldn't bust the dep/assets cache.
COPY config/runtime.exs config/

# 4. Release overlays (bin/server, bin/migrate) and assemble the OTP release.
COPY rel rel
RUN mix release

# ─── Fetch dnsx (ProjectDiscovery) — kept tiny and parallelisable ────────────
FROM debian:${DEBIAN_VERSION} AS dnsx
ARG DNSX_VERSION
ARG TARGETARCH
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates \
 && curl -fsSL -o /tmp/dnsx.zip \
      "https://github.com/projectdiscovery/dnsx/releases/download/v${DNSX_VERSION}/dnsx_${DNSX_VERSION}_linux_${TARGETARCH}.zip" \
 && unzip /tmp/dnsx.zip -d /tmp/dnsx \
 && install -m 0755 /tmp/dnsx/dnsx /usr/local/bin/dnsx \
 && rm -rf /var/lib/apt/lists/* /tmp/dnsx /tmp/dnsx.zip

# ─── Fetch naabu (ProjectDiscovery) ──────────────────────────────────────────
FROM debian:${DEBIAN_VERSION} AS naabu
ARG NAABU_VERSION
ARG TARGETARCH
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates \
 && curl -fsSL -o /tmp/naabu.zip \
      "https://github.com/projectdiscovery/naabu/releases/download/v${NAABU_VERSION}/naabu_${NAABU_VERSION}_linux_${TARGETARCH}.zip" \
 && unzip /tmp/naabu.zip -d /tmp/naabu \
 && install -m 0755 /tmp/naabu/naabu /usr/local/bin/naabu \
 && rm -rf /var/lib/apt/lists/* /tmp/naabu /tmp/naabu.zip

# ─── Fetch nuclei (ProjectDiscovery) ─────────────────────────────────────────
FROM debian:${DEBIAN_VERSION} AS nuclei
ARG NUCLEI_VERSION
ARG NUCLEI_TEMPLATES_VERSION
ARG TARGETARCH
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates \
 && curl -fsSL -o /tmp/nuclei.zip \
      "https://github.com/projectdiscovery/nuclei/releases/download/v${NUCLEI_VERSION}/nuclei_${NUCLEI_VERSION}_linux_${TARGETARCH}.zip" \
 && unzip /tmp/nuclei.zip -d /tmp/nuclei \
 && install -m 0755 /tmp/nuclei/nuclei /usr/local/bin/nuclei \
 && rm -rf /var/lib/apt/lists/* /tmp/nuclei /tmp/nuclei.zip

RUN curl -fsSL -o /tmp/nuclei-templates.tar.gz \
      "https://github.com/projectdiscovery/nuclei-templates/archive/refs/tags/v${NUCLEI_TEMPLATES_VERSION}.tar.gz" \
 && tar -xzf /tmp/nuclei-templates.tar.gz -C /root/ \
 && mv /root/nuclei-templates-${NUCLEI_TEMPLATES_VERSION} /root/.nuclei-templates \
 && rm /tmp/nuclei-templates.tar.gz

# ─── Fetch httpx (ProjectDiscovery) ──────────────────────────────────────────
FROM debian:${DEBIAN_VERSION} AS httpx
ARG HTTPX_VERSION
ARG TARGETARCH
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates \
 && curl -fsSL -o /tmp/httpx.zip \
      "https://github.com/projectdiscovery/httpx/releases/download/v${HTTPX_VERSION}/httpx_${HTTPX_VERSION}_linux_${TARGETARCH}.zip" \
 && unzip /tmp/httpx.zip -d /tmp/httpx \
 && install -m 0755 /tmp/httpx/httpx /usr/local/bin/httpx \
 && rm -rf /var/lib/apt/lists/* /tmp/httpx /tmp/httpx.zip

# ─── Fetch katana (ProjectDiscovery) ─────────────────────────────────────────
FROM debian:${DEBIAN_VERSION} AS katana
ARG KATANA_VERSION
ARG TARGETARCH
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends curl unzip ca-certificates \
 && curl -fsSL -o /tmp/katana.zip \
      "https://github.com/projectdiscovery/katana/releases/download/v${KATANA_VERSION}/katana_${KATANA_VERSION}_linux_${TARGETARCH}.zip" \
 && unzip /tmp/katana.zip -d /tmp/katana \
 && install -m 0755 /tmp/katana/katana /usr/local/bin/katana \
 && rm -rf /var/lib/apt/lists/* /tmp/katana /tmp/katana.zip

# ─── Fetch webanalyze + pinned technologies.json ─────────────────────────────
# Upstream `webanalyze -update` is broken against the current Wappalyzer
# schema, so we pull the technologies.json file shipped in the same release
# tag — that guarantees the binary and its app definitions stay in sync.
FROM debian:${DEBIAN_VERSION} AS webanalyze
ARG WEBANALYZE_VERSION
ARG TARGETARCH
RUN apt-get update -y \
 && apt-get install -y --no-install-recommends curl ca-certificates \
 && case "${TARGETARCH}" in \
      amd64) wa_arch=x86_64 ;; \
      arm64) wa_arch=arm64  ;; \
      *) echo "unsupported TARGETARCH: ${TARGETARCH}" >&2; exit 1 ;; \
    esac \
 && curl -fsSL -o /tmp/webanalyze.tgz \
      "https://github.com/rverton/webanalyze/releases/download/v${WEBANALYZE_VERSION}/webanalyze_Linux_${wa_arch}.tar.gz" \
 && tar -xzf /tmp/webanalyze.tgz -C /tmp \
 && install -m 0755 /tmp/webanalyze /usr/local/bin/webanalyze \
 && install -d /usr/local/share/webanalyze \
 && curl -fsSL -o /usr/local/share/webanalyze/technologies.json \
      "https://raw.githubusercontent.com/rverton/webanalyze/v${WEBANALYZE_VERSION}/technologies.json" \
 && rm -rf /var/lib/apt/lists/* /tmp/webanalyze /tmp/webanalyze.tgz

# ─── Runtime ─────────────────────────────────────────────────────────────────
FROM ${RUNNER_IMAGE} AS runner
ARG PG_MAJOR

# Bare minimum to run the BEAM + the CLI tools the app shells out to.
# PostgreSQL client matched to the server major version is installed from the
# official PGDG apt repo; bootstrap tools (curl, gnupg) are removed afterwards
# so they don't bloat the final image.
RUN set -eux; \
    apt-get update -y; \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 ca-certificates locales tini \
      bash whois curl gnupg; \
    install -d /usr/share/keyrings; \
    curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc \
      | gpg --dearmor -o /usr/share/keyrings/pgdg.gpg; \
    echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt bookworm-pgdg main" \
      > /etc/apt/sources.list.d/pgdg.list; \
    apt-get update -y; \
    apt-get install -y --no-install-recommends "postgresql-client-${PG_MAJOR}"; \
    apt-get purge -y --auto-remove curl gnupg; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*; \
    install -d /usr/local/share/webanalyze; \
    sed -i 's/# en_US.UTF-8/en_US.UTF-8/' /etc/locale.gen; \
    locale-gen

ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8 \
    MIX_ENV=prod \
    PHX_SERVER=true \
    PORT=4000

# Drop privileges — never run BEAM as root in production.
RUN groupadd --system --gid 1000 ravner \
 && useradd  --system --uid 1000 --gid ravner --create-home --home-dir /app ravner

WORKDIR /app
USER ravner:ravner

# Security scanner binaries from fetch stages and the OTP release from the builder.
COPY --from=dnsx    /usr/local/bin/dnsx              /usr/local/bin/dnsx
COPY --from=naabu   /usr/local/bin/naabu             /usr/local/bin/naabu
COPY --from=nuclei  /usr/local/bin/nuclei            /usr/local/bin/nuclei
COPY --from=nuclei  /root/.nuclei-templates          /home/ravner/.nuclei-templates
COPY --from=httpx   /usr/local/bin/httpx             /usr/local/bin/httpx
COPY --from=katana  /usr/local/bin/katana            /usr/local/bin/katana
COPY --from=webanalyze /usr/local/bin/webanalyze     /usr/local/bin/webanalyze
COPY --from=webanalyze /usr/local/share/webanalyze/technologies.json /usr/local/share/webanalyze/technologies.json
COPY --from=builder --chown=ravner:ravner /app/_build/prod/rel/ravner ./

EXPOSE 4000

# tini = proper PID 1 so signals reach the BEAM cleanly.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]
