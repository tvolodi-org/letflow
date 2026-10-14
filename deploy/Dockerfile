# ── Stage 1: Build the Elixir release ──────────────────────────────────────
# Pinned to match this project's `mix.exs` (elixir: "~> 1.18") and
# `.tool-versions` (elixir 1.20.3-otp-29, erlang 29.0.5).
FROM elixir:1.20.3-otp-29 AS builder

ENV MIX_ENV=prod \
    LANG=C.UTF-8

WORKDIR /app

RUN mix local.hex --force && mix local.rebar --force

# Fetch and compile deps first so dependency changes don't bust the cache
# for every source change.
COPY mix.exs mix.lock ./
COPY config config
RUN mix deps.get --only prod
RUN mix deps.compile

COPY lib lib
COPY priv priv
RUN mix compile

RUN mix release

# ── Stage 2: minimal runtime image ──────────────────────────────────────────
# Must track the builder's Debian generation (glibc version) — the compiled
# OTP release links dynamically against the builder's glibc, and an older
# runtime base (e.g. bookworm's glibc 2.36 vs. trixie's 2.41) fails at
# startup with "GLIBC_2.38 not found" for epmd/beam.smp.
FROM debian:trixie-slim AS runtime

# openssl/libncurses/locales are the standard runtime deps for a compiled
# Erlang/OTP release; ca-certificates for outbound TLS (OIDC provider
# discovery over HTTPS once a real issuer replaces the placeholder).
RUN apt-get update -y && \
    apt-get install -y --no-install-recommends \
      libstdc++6 openssl libncurses6 locales ca-certificates && \
    apt-get clean && rm -f /var/lib/apt/lists/*_*

RUN sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen && locale-gen
ENV LANG=en_US.UTF-8 \
    LANGUAGE=en_US:en \
    LC_ALL=en_US.UTF-8

# Non-root user to run the release.
RUN groupadd --gid 1000 letflow && \
    useradd --uid 1000 --gid letflow --shell /bin/sh --create-home letflow

WORKDIR /app
RUN chown -R letflow:letflow /app

COPY --from=builder --chown=letflow:letflow /app/_build/prod/rel/letflow ./

USER letflow

# ISS-1043: the git commit this image was built from, reported by the public
# GET /health as `sha` (config/runtime.exs -> Letflow.BuildInfo). Passed by
# deploy/redeploy-*.sh as --build-arg GIT_SHA="$(git rev-parse HEAD)". Declared
# here in the runtime stage, after the apt/locale/user layers and the release
# COPY, because an ARG's value is part of the cache key of every RUN after it:
# placed earlier, each new commit would bust the cached apt-get layers. Empty
# when not passed; config/runtime.exs then reports null.
ARG GIT_SHA=
ENV LETFLOW_BUILD_SHA=${GIT_SHA}

# RELEASE_NAME is exported automatically by the generated bin/letflow boot
# script (standard Mix.Release behavior) — this is what
# Letflow.Application.skip_migrations?/0 checks to run Ecto.Migrator only
# inside a release, not in local `mix run`/`mix test`. Nothing to set here.

# Internal port the app listens on (hardcoded in lib/letflow/application.ex's
# Bandit child, not env-configurable today). nginx on the host reverse-proxies
# to this via the compose file's host-port binding — see
# deploy/docker-compose.*.yml and deploy/nginx/*.conf.
EXPOSE 4000

CMD ["bin/letflow", "start"]
