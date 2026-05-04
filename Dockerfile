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
#   • whois                 — Ravner.Scans (WHOIS lookup)
# ─────────────────────────────────────────────────────────────────────────────

ARG ELIXIR_VERSION=1.18.4
ARG OTP_VERSION=27.3.4
ARG DEBIAN_VERSION=bookworm-20260421-slim
ARG PG_MAJOR=16
ARG DNSX_VERSION=1.2.3

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
      whois curl gnupg; \
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

# dnsx binary from the fetch stage and the OTP release from the builder.
COPY --from=dnsx    /usr/local/bin/dnsx              /usr/local/bin/dnsx
COPY --from=builder --chown=ravner:ravner /app/_build/prod/rel/ravner ./

EXPOSE 4000

# tini = proper PID 1 so signals reach the BEAM cleanly.
ENTRYPOINT ["/usr/bin/tini", "--"]
CMD ["/app/bin/server"]
