# Multi-stage VerneMQ build + runtime
# Build: docker build -t vmq-local-bench -f bench/local/Dockerfile .
# (run from project root)

# ---------------------------------------------------------------------------
# Build stage
# ---------------------------------------------------------------------------
FROM erlang:27.2 AS builder

RUN apt-get update && apt-get install -y --no-install-recommends \
    git make gcc g++ cmake libsnappy-dev ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY . /build
WORKDIR /build

# Clean stale _build from host (may be compiled with different OTP version)
RUN rm -rf _build

# Generate vars.generated (mirrors Makefile `make rel` target)
RUN cat vars.config > vars.generated \
    && echo '{app_version, "docker-local"}.' >> vars.generated

# rebar3 release — exit code 1 is a known rebar3 bug even on success
RUN ./rebar3 release || true

# Verify the release binary actually exists
RUN test -f _build/default/rel/vernemq/bin/vernemq \
    || (echo "ERROR: VerneMQ release binary not found" && exit 1)

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM debian:bookworm-slim

RUN apt-get update && apt-get install -y --no-install-recommends \
    libsnappy1v5 openssl libncurses6 procps curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /build/_build/default/rel/vernemq /opt/vernemq
COPY bench/local/entrypoint.sh /opt/vernemq/entrypoint.sh
RUN chmod +x /opt/vernemq/entrypoint.sh

# Create data and log directories
RUN mkdir -p /opt/vernemq/data /opt/vernemq/log

# MQTT, cluster, HTTP API
EXPOSE 1883 44053 8888

# VerneMQ takes >15s to start on fresh nodes
ENV WAIT_FOR_ERLANG=60

ENTRYPOINT ["/opt/vernemq/entrypoint.sh"]
