#!/usr/bin/env bash
# transport_docker.sh - Docker transport backend for VerneMQ benchmark scenarios.
#
# Overrides SSH-based transport functions from common.sh with Docker equivalents.
# Sourced automatically when BENCH_TRANSPORT=docker is set.
#
# Expects VMQ_NODES to contain Docker container names (e.g. "vmq1 vmq2 vmq3")
# and BENCH_NODES to contain bench container names (e.g. "bench").

# ---------------------------------------------------------------------------
# Docker-specific defaults
# ---------------------------------------------------------------------------

VMQ_ADMIN="${VMQ_ADMIN:-/opt/vernemq/bin/vmq-admin}"
LOCAL_SCALE="${LOCAL_SCALE:-0.4}"

# ---------------------------------------------------------------------------
# SSH → Docker exec overrides
# ---------------------------------------------------------------------------

ssh_vmq() {
    local node_index="$1"; shift
    local node
    node=$(_node_at VMQ_NODES "$node_index")
    local cmd="$*"

    # Translate systemd commands to Docker equivalents
    if [[ "$cmd" == *"systemctl stop vernemq"* ]]; then
        # Graceful shutdown: SIGTERM with 30s timeout (preserves scenario 08 semantics)
        docker stop --time=30 "$node" 2>/dev/null
        return $?
    elif [[ "$cmd" == *"systemctl start vernemq"* ]]; then
        docker start "$node" 2>/dev/null
        return $?
    elif [[ "$cmd" == *"pkill -9 -f beam"* ]]; then
        # Ungraceful kill: SIGKILL
        docker kill "$node" 2>/dev/null || true
        return 0
    fi

    # Strip sudo prefix (not needed in Docker containers)
    cmd="${cmd#sudo }"
    cmd="${cmd//sudo /}"

    docker exec "$node" sh -c "$cmd"
}

ssh_bench() {
    local node_index="$1"; shift
    local node
    node=$(_node_at BENCH_NODES "$node_index")
    local cmd="$*"

    # Strip sudo prefix
    cmd="${cmd#sudo }"
    cmd="${cmd//sudo /}"

    docker exec "$node" sh -c "$cmd"
}

# ---------------------------------------------------------------------------
# emqtt_bench management (Docker)
# ---------------------------------------------------------------------------

start_emqtt_bench() {
    local bench_node="$1"; shift
    local args="$*"
    local node
    node=$(_node_at BENCH_NODES "$bench_node")

    # Inject auth credentials if configured
    local auth_args=""
    if [[ -n "${BENCH_MQTT_USERNAME:-}" && -n "${BENCH_MQTT_PASSWORD:-}" ]]; then
        auth_args="-u $BENCH_MQTT_USERNAME -P $BENCH_MQTT_PASSWORD"
    fi

    log_info "Starting emqtt_bench on bench node $bench_node ($node): $args${auth_args:+ [auth]}"
    docker exec -d "$node" sh -c "emqtt_bench $args $auth_args > /tmp/emqtt_bench_\$\$.log 2>&1"
}

stop_emqtt_bench() {
    local bench_node="$1"
    local node
    node=$(_node_at BENCH_NODES "$bench_node")
    log_info "Stopping emqtt_bench on bench node $bench_node ($node)"
    docker exec "$node" pkill -f emqtt_bench 2>/dev/null || true
}

stop_all_emqtt_bench() {
    local -a nodes
    read -ra nodes <<< "$BENCH_NODES"
    for i in "${!nodes[@]}"; do
        stop_emqtt_bench "$i" &
    done
    wait
}

# ---------------------------------------------------------------------------
# VerneMQ operations (Docker)
# ---------------------------------------------------------------------------

kill_vmq_node() {
    local node_index="$1"
    local node
    node=$(_node_at VMQ_NODES "$node_index")
    log_info "SIGKILL VerneMQ container $node (node $node_index)"
    docker kill "$node" 2>/dev/null || true
}

start_vmq_node() {
    local node_index="$1"
    local node
    node=$(_node_at VMQ_NODES "$node_index")
    log_info "Starting VerneMQ container $node (node $node_index)"
    docker start "$node"

    # Wait for node to respond to ping
    local elapsed=0
    while (( elapsed < 60 )); do
        if docker exec "$node" /opt/vernemq/bin/vernemq ping 2>/dev/null | grep -q pong; then
            break
        fi
        sleep 5
        (( elapsed += 5 ))
    done

    # Re-apply runtime settings that don't persist through restart
    log_info "Re-applying runtime settings on node $node_index"
    set_vmq_config "allow_subscribe_during_netsplit" "on" "$node_index"
    set_vmq_config "allow_publish_during_netsplit" "on" "$node_index"
    set_vmq_config "allow_register_during_netsplit" "on" "$node_index"
    ssh_vmq "$node_index" "$VMQ_ADMIN plugin enable --name vmq_acl" 2>/dev/null || true
}

check_balance_health() {
    local node_index="$1"
    local node
    node=$(_node_at VMQ_NODES "$node_index")
    docker exec "$node" \
        curl -s -o /dev/null -w '%{http_code}' http://localhost:8888/api/balance-health 2>/dev/null \
        || echo "000"
}

# ---------------------------------------------------------------------------
# Load scaling (Docker)
# ---------------------------------------------------------------------------

scale_load() {
    local base="$1" ref_nodes="$2"
    local actual
    actual=$(vmq_node_count)
    local scale="${LOCAL_SCALE:-0.4}"
    local multiplier="${LOAD_MULTIPLIER:-1}"
    awk "BEGIN { v = int($base * $actual * $scale * $multiplier / $ref_nodes); if (v < 1) v = 1; printf \"%d\", v }"
}

# ---------------------------------------------------------------------------
# Metrics poller (Docker)
# ---------------------------------------------------------------------------

start_metrics_poller() {
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}"
    local poller_script
    poller_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/vmq_metrics_poller_docker.sh"
    if [[ -x "$poller_script" ]]; then
        bash "$poller_script" \
            --containers "$VMQ_NODES" \
            --interval "$METRICS_POLL_INTERVAL" \
            --output "$out_dir/vmq_metrics_timeseries.csv" \
            --vmq-admin "$VMQ_ADMIN" &
        METRICS_POLLER_PID=$!
        log_info "Started docker metrics poller (PID: $METRICS_POLLER_PID, interval: ${METRICS_POLL_INTERVAL}s)"
    else
        log_info "Docker metrics poller not found at $poller_script, skipping"
    fi
}

log_info "Transport: docker (overriding SSH functions with docker exec)"
