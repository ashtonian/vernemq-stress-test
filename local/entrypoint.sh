#!/usr/bin/env bash
# VerneMQ Docker entrypoint — generates config, starts node, joins cluster.
set -euo pipefail

VMQ_NODENAME="${VMQ_NODENAME:-VerneMQ@$(hostname)}"
VMQ_DISCOVERY_NODE="${VMQ_DISCOVERY_NODE:-}"
VMQ_COOKIE="${VMQ_COOKIE:-vmqlocalbench}"

# Version family: "2.x" (default) or "integration"
# Controls whether integration-only config keys are written to vernemq.conf.
# Set VMQ_VERSION_FAMILY=integration for integration_test builds.
VMQ_VERSION_FAMILY="${VMQ_VERSION_FAMILY:-2.x}"

VMQ_DIR="/opt/vernemq"
VMQ_CONF="${VMQ_DIR}/etc/vernemq.conf"

# ---------------------------------------------------------------------------
# Tunable defaults — match profiles/default.yaml so entrypoint works standalone.
# When launched via generate_compose.sh, env vars are injected from the profile.
# ---------------------------------------------------------------------------

# Erlang VM
VMQ_ERLANG_ASYNC_THREADS="${VMQ_ERLANG_ASYNC_THREADS:-64}"
VMQ_ERLANG_MAX_PORTS="${VMQ_ERLANG_MAX_PORTS:-1048576}"
VMQ_ERLANG_MAX_PROCESSES="${VMQ_ERLANG_MAX_PROCESSES:-1048576}"
VMQ_ERLANG_DISTRIBUTION_BUFFER_SIZE="${VMQ_ERLANG_DISTRIBUTION_BUFFER_SIZE:-32768}"

# Listeners
VMQ_MQTT_LISTENER_MAX_CONNECTIONS="${VMQ_MQTT_LISTENER_MAX_CONNECTIONS:-500000}"
VMQ_MQTT_LISTENER_NR_OF_ACCEPTORS="${VMQ_MQTT_LISTENER_NR_OF_ACCEPTORS:-200}"
VMQ_LISTENER_MAX_CONNECTIONS="${VMQ_LISTENER_MAX_CONNECTIONS:-50000}"
VMQ_LISTENER_NR_OF_ACCEPTORS="${VMQ_LISTENER_NR_OF_ACCEPTORS:-200}"
VMQ_TCP_LISTEN_OPTIONS="${VMQ_TCP_LISTEN_OPTIONS:-[{nodelay, true}, {linger, {true, 8}}, {send_timeout, 5000}, {send_timeout_close, true}, {backlog, 3072}, {exit_on_close, true}, {keepalive, true}]}"
VMQ_LISTENER_TCP_ALLOWED_PROTOCOL_VERSIONS="${VMQ_LISTENER_TCP_ALLOWED_PROTOCOL_VERSIONS:-3,4,5}"
VMQ_LISTENER_TCP_PROXY_PROTOCOL="${VMQ_LISTENER_TCP_PROXY_PROTOCOL:-off}"
VMQ_LISTENER_WS_ALLOWED_PROTOCOL_VERSIONS="${VMQ_LISTENER_WS_ALLOWED_PROTOCOL_VERSIONS:-3,4,5}"
VMQ_LISTENER_WS_PROXY_PROTOCOL="${VMQ_LISTENER_WS_PROXY_PROTOCOL:-off}"

# Queue / message settings
VMQ_MAX_INFLIGHT_MESSAGES="${VMQ_MAX_INFLIGHT_MESSAGES:-50}"
VMQ_MAX_ONLINE_MESSAGES="${VMQ_MAX_ONLINE_MESSAGES:-10000}"
VMQ_MAX_OFFLINE_MESSAGES="${VMQ_MAX_OFFLINE_MESSAGES:-10000}"
VMQ_QUEUE_DELIVER_MODE="${VMQ_QUEUE_DELIVER_MODE:-fanout}"
VMQ_QUEUE_TYPE="${VMQ_QUEUE_TYPE:-fifo}"
VMQ_MAX_MESSAGE_RATE="${VMQ_MAX_MESSAGE_RATE:-0}"
VMQ_MAX_MESSAGE_SIZE="${VMQ_MAX_MESSAGE_SIZE:-0}"
VMQ_UPGRADE_OUTGOING_QOS="${VMQ_UPGRADE_OUTGOING_QOS:-on}"

# MQTT protocol
VMQ_MQTT_CONNECT_TIMEOUT="${VMQ_MQTT_CONNECT_TIMEOUT:-30000}"
VMQ_DISCONNECT_ON_UNAUTH_PUB_V3="${VMQ_DISCONNECT_ON_UNAUTH_PUB_V3:-on}"
VMQ_PERSISTENT_CLIENT_EXPIRATION="${VMQ_PERSISTENT_CLIENT_EXPIRATION:-72h}"

# Session / registration
VMQ_COORDINATE_REGISTRATIONS="${VMQ_COORDINATE_REGISTRATIONS:-on}"
VMQ_SHARED_SUBSCRIPTION_POLICY="${VMQ_SHARED_SUBSCRIPTION_POLICY:-prefer_local}"

# Netsplit behavior
VMQ_ALLOW_REGISTER_DURING_NETSPLIT="${VMQ_ALLOW_REGISTER_DURING_NETSPLIT:-on}"
VMQ_ALLOW_PUBLISH_DURING_NETSPLIT="${VMQ_ALLOW_PUBLISH_DURING_NETSPLIT:-on}"
VMQ_ALLOW_SUBSCRIBE_DURING_NETSPLIT="${VMQ_ALLOW_SUBSCRIBE_DURING_NETSPLIT:-on}"
VMQ_ALLOW_UNSUBSCRIBE_DURING_NETSPLIT="${VMQ_ALLOW_UNSUBSCRIBE_DURING_NETSPLIT:-on}"

# Storage
VMQ_LEVELDB_MAX_MEM_PCT="${VMQ_LEVELDB_MAX_MEM_PCT:-20}"

# Clustering buffer (2.x+)
VMQ_OUTGOING_CLUSTERING_BUFFER_SIZE="${VMQ_OUTGOING_CLUSTERING_BUFFER_SIZE:-10000}"

# Docker-specific vm.args overrides
VMQ_SBWT="${VMQ_SBWT:-none}"
VMQ_SWT="${VMQ_SWT:-very_low}"
VMQ_FULLSWEEP_AFTER="${VMQ_FULLSWEEP_AFTER:-0}"

# ---------------------------------------------------------------------------
# 1. Write vernemq.conf — base config (all versions)
# ---------------------------------------------------------------------------
cat > "$VMQ_CONF" <<EOF
nodename = ${VMQ_NODENAME}
distributed_cookie = ${VMQ_COOKIE}

## Listeners
listener.tcp.default = 0.0.0.0:1883
listener.tcp.default.max_connections = ${VMQ_MQTT_LISTENER_MAX_CONNECTIONS}
listener.tcp.default.nr_of_acceptors = ${VMQ_MQTT_LISTENER_NR_OF_ACCEPTORS}
listener.vmq.clustering = 0.0.0.0:44053
listener.http.default = 0.0.0.0:8888
listener.max_connections = ${VMQ_LISTENER_MAX_CONNECTIONS}
listener.nr_of_acceptors = ${VMQ_LISTENER_NR_OF_ACCEPTORS}
listener.tcp.allowed_protocol_versions = ${VMQ_LISTENER_TCP_ALLOWED_PROTOCOL_VERSIONS}
listener.tcp.proxy_protocol = ${VMQ_LISTENER_TCP_PROXY_PROTOCOL}
listener.ws.allowed_protocol_versions = ${VMQ_LISTENER_WS_ALLOWED_PROTOCOL_VERSIONS}
listener.ws.proxy_protocol = ${VMQ_LISTENER_WS_PROXY_PROTOCOL}
tcp_listen_options = ${VMQ_TCP_LISTEN_OPTIONS}

## Auth (overridden below if VMQ_AUTH_ENABLED)
allow_anonymous = on
plugins.vmq_passwd = off
plugins.vmq_acl = off

## Plugins
plugins.vmq_diversity = off

## MQTT protocol
metadata_plugin = vmq_swc
mqtt_connect_timeout = ${VMQ_MQTT_CONNECT_TIMEOUT}
disconnect_on_unauthorized_publish_v3 = ${VMQ_DISCONNECT_ON_UNAUTH_PUB_V3}
persistent_client_expiration = ${VMQ_PERSISTENT_CLIENT_EXPIRATION}
upgrade_outgoing_qos = ${VMQ_UPGRADE_OUTGOING_QOS}

## Queue settings
max_inflight_messages = ${VMQ_MAX_INFLIGHT_MESSAGES}
max_online_messages = ${VMQ_MAX_ONLINE_MESSAGES}
max_offline_messages = ${VMQ_MAX_OFFLINE_MESSAGES}
queue_deliver_mode = ${VMQ_QUEUE_DELIVER_MODE}
queue_type = ${VMQ_QUEUE_TYPE}
EOF

# Conditional: only emit max_message_rate if > 0
if (( VMQ_MAX_MESSAGE_RATE > 0 )); then
    echo "max_message_rate = ${VMQ_MAX_MESSAGE_RATE}" >> "$VMQ_CONF"
fi

# Conditional: only emit max_message_size if > 0
if (( VMQ_MAX_MESSAGE_SIZE > 0 )); then
    echo "max_message_size = ${VMQ_MAX_MESSAGE_SIZE}" >> "$VMQ_CONF"
fi

cat >> "$VMQ_CONF" <<EOF

## Session / registration
coordinate_registrations = ${VMQ_COORDINATE_REGISTRATIONS}
shared_subscription_policy = ${VMQ_SHARED_SUBSCRIPTION_POLICY}

## Netsplit behavior
allow_register_during_netsplit = ${VMQ_ALLOW_REGISTER_DURING_NETSPLIT}
allow_publish_during_netsplit = ${VMQ_ALLOW_PUBLISH_DURING_NETSPLIT}
allow_subscribe_during_netsplit = ${VMQ_ALLOW_SUBSCRIBE_DURING_NETSPLIT}
allow_unsubscribe_during_netsplit = ${VMQ_ALLOW_UNSUBSCRIBE_DURING_NETSPLIT}

## Storage
leveldb.maximum_memory.percent = ${VMQ_LEVELDB_MAX_MEM_PCT}

## Logging (Docker-specific)
log.console = both
log.console.level = info

## Erlang VM tuning
erlang.async_threads = ${VMQ_ERLANG_ASYNC_THREADS}
erlang.max_ports = ${VMQ_ERLANG_MAX_PORTS}
erlang.process_limit = ${VMQ_ERLANG_MAX_PROCESSES}
erlang.distribution_buffer_size = ${VMQ_ERLANG_DISTRIBUTION_BUFFER_SIZE}
erlang.distribution.port_range.minimum = 6000
erlang.distribution.port_range.maximum = 7999
erlang.schedulers.force_wakeup_interval = 500
erlang.schedulers.compaction_of_load = false

## Clustering buffer (valid in 2.x+)
outgoing_clustering_buffer_size = ${VMQ_OUTGOING_CLUSTERING_BUFFER_SIZE}
EOF

# ---------------------------------------------------------------------------
# 1a. Append integration-only settings (when VMQ_VERSION_FAMILY=integration)
# ---------------------------------------------------------------------------
if [[ "$VMQ_VERSION_FAMILY" == "integration" ]]; then
    # All values come from env vars (injected by generate_compose.sh from profiles/default.yaml).
    # If running standalone, these still need to be set via -e flags.
    cat >> "$VMQ_CONF" <<EOF

## Clustering connections (integration)
outgoing_clustering_connection_count = ${VMQ_OUTGOING_CLUSTERING_CONNECTION_COUNT}
outgoing_clustering_reconnect_base_delay = ${VMQ_OUTGOING_CLUSTERING_RECONNECT_BASE_DELAY}
outgoing_clustering_reconnect_max_delay = ${VMQ_OUTGOING_CLUSTERING_RECONNECT_MAX_DELAY}
outgoing_clustering_buffer_drop_policy = ${VMQ_OUTGOING_CLUSTERING_BUFFER_DROP_POLICY}

## Registry (integration)
reg_trie_workers = ${VMQ_REG_TRIE_WORKERS}
reg_sync_shards = ${VMQ_REG_SYNC_SHARDS}

## Cluster health (integration)
cluster_ready_quorum = ${VMQ_CLUSTER_READY_QUORUM}
cluster_ready_rpc_timeout = ${VMQ_CLUSTER_READY_RPC_TIMEOUT}
dead_node_cleanup_timeout = ${VMQ_DEAD_NODE_CLEANUP_TIMEOUT}

## Balance (integration)
balance_enabled = ${VMQ_BALANCE_ENABLED}
balance_reject_enabled = ${VMQ_BALANCE_REJECT_ENABLED}
balance_threshold = ${VMQ_BALANCE_THRESHOLD}
balance_hysteresis = ${VMQ_BALANCE_HYSTERESIS}
balance_min_connections = ${VMQ_BALANCE_MIN_CONNECTIONS}
balance_check_interval = ${VMQ_BALANCE_CHECK_INTERVAL}

## Rebalance (integration)
rebalance_enabled = ${VMQ_REBALANCE_ENABLED}
rebalance_threshold = ${VMQ_REBALANCE_THRESHOLD}
rebalance_batch_size = ${VMQ_REBALANCE_BATCH_SIZE}
rebalance_cooldown = ${VMQ_REBALANCE_COOLDOWN}
rebalance_on_node_join = ${VMQ_REBALANCE_ON_NODE_JOIN}
rebalance_stable_interval = ${VMQ_REBALANCE_STABLE_INTERVAL}
rebalance_auto_interval = ${VMQ_REBALANCE_AUTO_INTERVAL}

## Gossip tuning (integration — vmq_swc)
vmq_swc.gossip_interval = ${VMQ_SWC_GOSSIP_INTERVAL}
vmq_swc.fast_gossip_interval = ${VMQ_SWC_FAST_GOSSIP_INTERVAL}
vmq_swc.fast_gossip_duration = ${VMQ_SWC_FAST_GOSSIP_DURATION}
EOF
    echo "==> Integration-only config appended (VMQ_VERSION_FAMILY=integration)"
else
    echo "==> Skipping integration-only config (VMQ_VERSION_FAMILY=${VMQ_VERSION_FAMILY})"
fi

# ---------------------------------------------------------------------------
# 1b. Configure authentication if enabled
# ---------------------------------------------------------------------------
if [[ "${VMQ_AUTH_ENABLED:-}" == "true" && -n "${VMQ_AUTH_USERNAME:-}" && -n "${VMQ_AUTH_PASSWORD:-}" ]]; then
    sed -i 's/^allow_anonymous = on/allow_anonymous = off/' "$VMQ_CONF"
    sed -i 's/^plugins.vmq_passwd = off/plugins.vmq_passwd = on/' "$VMQ_CONF"
    sed -i 's/^plugins.vmq_acl = off/plugins.vmq_acl = on/' "$VMQ_CONF"
fi

# Write vm.args — must include -name for distribution, otherwise sys_dist
# table won't exist and riak_sysmon_filter crashes.
# In Docker: use +sbwt none to avoid busy-waiting on shared CPU.
VMQ_ARGS="${VMQ_DIR}/etc/vm.args"
cat > "$VMQ_ARGS" <<EOF
-name ${VMQ_NODENAME}
-setcookie ${VMQ_COOKIE}
+sbt db
+sbwt ${VMQ_SBWT}
+swt ${VMQ_SWT}
+sbwtdcpu none
+sbwtdio none
+zdbbl ${VMQ_ERLANG_DISTRIBUTION_BUFFER_SIZE}
+e ${VMQ_FULLSWEEP_AFTER}
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
    printf '%s\n%s\n' "$VMQ_AUTH_PASSWORD" "$VMQ_AUTH_PASSWORD" \
        | "${VMQ_DIR}/bin/vmq-passwd" -c "${VMQ_DIR}/etc/vmq.passwd" "$VMQ_AUTH_USERNAME" 2>/dev/null || {
        echo "WARNING: Could not generate password hash via vmq-passwd, auth may not work"
    }

    cat > "${VMQ_DIR}/etc/vmq.acl" <<ACL_EOF
user ${VMQ_AUTH_USERNAME}
topic #
ACL_EOF

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
