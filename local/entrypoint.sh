#!/usr/bin/env bash
# VerneMQ Docker entrypoint — generates config, starts node, joins cluster.
set -euo pipefail

VMQ_NODENAME="${VMQ_NODENAME:-VerneMQ@$(hostname)}"
VMQ_DISCOVERY_NODE="${VMQ_DISCOVERY_NODE:-}"
VMQ_COOKIE="${VMQ_COOKIE:-vmqlocalbench}"

VMQ_DIR="/opt/vernemq"
VMQ_CONF="${VMQ_DIR}/etc/vernemq.conf"

# ---------------------------------------------------------------------------
# 1. Write vernemq.conf
# ---------------------------------------------------------------------------
cat > "$VMQ_CONF" <<EOF
nodename = ${VMQ_NODENAME}
distributed_cookie = ${VMQ_COOKIE}

listener.tcp.default = 0.0.0.0:1883
listener.vmq.clustering = 0.0.0.0:44053
listener.http.default = 0.0.0.0:8888

allow_anonymous = on
plugins.vmq_passwd = off
plugins.vmq_acl = off

metadata_plugin = vmq_swc

log.console = both
log.console.level = info

erlang.distribution.port_range.minimum = 6000
erlang.distribution.port_range.maximum = 7999
EOF

echo "==> Config written to ${VMQ_CONF}"
cat "$VMQ_CONF"

# ---------------------------------------------------------------------------
# 2. Start VerneMQ (background — Cuttlefish generates app.config)
# ---------------------------------------------------------------------------
echo "==> Starting VerneMQ as ${VMQ_NODENAME} ..."
"${VMQ_DIR}/bin/vernemq" start

# Wait for node to become responsive
echo "==> Waiting for VerneMQ to respond to ping ..."
TRIES=0
MAX_TRIES=60
while ! "${VMQ_DIR}/bin/vernemq" ping 2>/dev/null | grep -q pong; do
    TRIES=$((TRIES + 1))
    if (( TRIES >= MAX_TRIES )); then
        echo "ERROR: VerneMQ did not start within ${MAX_TRIES}s"
        cat "${VMQ_DIR}/log/console.log" 2>/dev/null || true
        exit 1
    fi
    sleep 1
done
echo "==> VerneMQ started (pong received after ~${TRIES}s)"

# ---------------------------------------------------------------------------
# 3. Cluster join (if VMQ_DISCOVERY_NODE is set)
# ---------------------------------------------------------------------------
if [[ -n "$VMQ_DISCOVERY_NODE" ]]; then
    echo "==> Joining cluster via discovery node: ${VMQ_DISCOVERY_NODE}"

    JOIN_TRIES=0
    JOIN_MAX=30
    while (( JOIN_TRIES < JOIN_MAX )); do
        if "${VMQ_DIR}/bin/vmq-admin" cluster join discovery-node="$VMQ_DISCOVERY_NODE" 2>&1; then
            echo "==> Cluster join initiated"
            break
        fi
        JOIN_TRIES=$((JOIN_TRIES + 1))
        echo "==> Join attempt ${JOIN_TRIES}/${JOIN_MAX} failed, retrying in 2s..."
        sleep 2
    done

    if (( JOIN_TRIES >= JOIN_MAX )); then
        echo "WARNING: Could not join cluster after ${JOIN_MAX} attempts"
    fi
fi

# ---------------------------------------------------------------------------
# 4. Keep container alive
# ---------------------------------------------------------------------------
echo "==> VerneMQ running. Tailing console log..."
exec tail -f "${VMQ_DIR}/log/console.log"
