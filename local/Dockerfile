# Multi-stage VerneMQ build + runtime (Alpine — native ARM64, fast on macOS)
# Build: docker build -t vmq-local-bench -f bench/local/Dockerfile .
# (run from project root)

# ---------------------------------------------------------------------------
# Build stage
# ---------------------------------------------------------------------------
# Alpine 3.19 = OTP 26; Alpine 3.20+ = OTP 27 (breaks riak_sysmon_filter)
FROM alpine:3.19 AS builder

RUN apk --no-cache --update --available upgrade && \
    apk add git alpine-sdk erlang-dev snappy-dev bsd-compat-headers \
            openssl-dev tzdata procps

COPY . /build
WORKDIR /build

# Clean stale _build from host (may be compiled with different OTP version)
RUN rm -rf _build

# Build release (rebar3 may exit 1 even on success — known bug)
RUN make rel || true

# Verify the release binary actually exists
RUN test -f _build/default/rel/vernemq/bin/vernemq \
    || (echo "ERROR: VerneMQ release binary not found" && exit 1)

# ---------------------------------------------------------------------------
# Runtime stage
# ---------------------------------------------------------------------------
FROM alpine:3.19

RUN apk --no-cache --update --available upgrade && \
    apk add --no-cache ncurses-libs openssl libstdc++ jq curl bash \
            snappy-dev ca-certificates erlang-dev procps

COPY --from=builder /build/_build/default/rel/vernemq /opt/vernemq
COPY bench/local/entrypoint.sh /opt/vernemq/entrypoint.sh
RUN chmod +x /opt/vernemq/entrypoint.sh

# Create data and log directories
RUN mkdir -p /opt/vernemq/data /opt/vernemq/log

# MQTT, cluster, HTTP API
EXPOSE 1883 44053 8888

ENV WAIT_FOR_ERLANG=60

ENTRYPOINT ["/opt/vernemq/entrypoint.sh"]
