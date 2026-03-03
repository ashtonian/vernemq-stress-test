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

## Listeners
listener.tcp.default = 0.0.0.0:1883
listener.tcp.default.max_connections = 500000
listener.tcp.default.nr_of_acceptors = 200
listener.vmq.clustering = 0.0.0.0:44053
listener.http.default = 0.0.0.0:8888
listener.nr_of_acceptors = 200
listener.tcp.allowed_protocol_versions = 3,4,5
listener.tcp.proxy_protocol = off
listener.ws.allowed_protocol_versions = 3,4,5
listener.ws.proxy_protocol = off
tcp_listen_options = [{nodelay, true}, {linger, {true, 8}}, {send_timeout, 5000}, {send_timeout_close, true}, {backlog, 3072}, {exit_on_close, true}, {keepalive, true}]

## Auth (overridden below if VMQ_AUTH_ENABLED)
allow_anonymous = on
plugins.vmq_passwd = off
plugins.vmq_acl = off

## MQTT protocol
metadata_plugin = vmq_swc
mqtt_connect_timeout = 30000
disconnect_on_unauthorized_publish_v3 = on
persistent_client_expiration = 72h
upgrade_outgoing_qos = on

## Queue settings
max_inflight_messages = 50
max_online_messages = 10000
max_offline_messages = 10000

## Netsplit behavior
allow_register_during_netsplit = on
allow_publish_during_netsplit = on
allow_subscribe_during_netsplit = on
allow_unsubscribe_during_netsplit = on

## Storage
leveldb.maximum_memory.percent = 20

## Logging
log.console = both
log.console.level = info

## Erlang VM tuning
erlang.async_threads = 64
erlang.max_ports = 262144
erlang.process_limit = 262144
erlang.distribution_buffer_size = 32768
erlang.distribution.port_range.minimum = 6000
erlang.distribution.port_range.maximum = 7999
erlang.schedulers.force_wakeup_interval = 500
erlang.schedulers.compaction_of_load = false

## Clustering buffer (valid in 2.x+)
outgoing_clustering_buffer_size = 10000
EOF

# ---------------------------------------------------------------------------
# 1b. Configure authentication if enabled
# ---------------------------------------------------------------------------
if [[ "${VMQ_AUTH_ENABLED:-}" == "true" && -n "${VMQ_AUTH_USERNAME:-}" && -n "${VMQ_AUTH_PASSWORD:-}" ]]; then
    # Override the permissive defaults written above (in-place only, no append)
    sed -i 's/^allow_anonymous = on/allow_anonymous = off/' "$VMQ_CONF"
    sed -i 's/^plugins.vmq_passwd = off/plugins.vmq_passwd = on/' "$VMQ_CONF"
    sed -i 's/^plugins.vmq_acl = off/plugins.vmq_acl = on/' "$VMQ_CONF"
fi

# Write vm.args overrides for scheduler tuning
# In Docker: use +sbwt none to avoid busy-waiting on shared CPU
VMQ_ARGS="${VMQ_DIR}/etc/vm.args"
cat > "$VMQ_ARGS" <<EOF
+sbt db
+sbwt none
+swt very_low
+sbwtdcpu none
+sbwtdio none
+zdbbl 32768
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
# 2b. Generate passwd and ACL files if auth is enabled
# ---------------------------------------------------------------------------
if [[ "${VMQ_AUTH_ENABLED:-}" == "true" && -n "${VMQ_AUTH_USERNAME:-}" && -n "${VMQ_AUTH_PASSWORD:-}" ]]; then
    echo "==> Configuring MQTT authentication for user: ${VMQ_AUTH_USERNAME}"
    # Generate passwd file using vmq-passwd
    printf '%s\n%s\n' "$VMQ_AUTH_PASSWORD" "$VMQ_AUTH_PASSWORD" \
        | "${VMQ_DIR}/bin/vmq-passwd" -c "${VMQ_DIR}/etc/vmq.passwd" "$VMQ_AUTH_USERNAME" 2>/dev/null || {
        echo "WARNING: Could not generate password hash via vmq-passwd, auth may not work"
    }

    # Generate ACL file
    cat > "${VMQ_DIR}/etc/vmq.acl" <<ACL_EOF
user ${VMQ_AUTH_USERNAME}
topic #
ACL_EOF

    # Reload passwd plugin
    "${VMQ_DIR}/bin/vmq-admin" plugin enable --name vmq_passwd 2>/dev/null || true
    echo "==> MQTT authentication configured"
fi

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
