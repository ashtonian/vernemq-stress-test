#!/usr/bin/env bash
# common.sh - Shared helper functions for VerneMQ benchmark scenarios.
# Source this file from each scenario script.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration defaults (override via environment)
# ---------------------------------------------------------------------------

# Space-separated lists of node IPs/hostnames read from Ansible inventory.
BENCH_NODES="${BENCH_NODES:-}"
VMQ_NODES="${VMQ_NODES:-}"
RESULTS_DIR="${RESULTS_DIR:-./results}"
SCENARIO_TAG="${SCENARIO_TAG:-default}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-${HOME}/.ssh/vernemq-bench-home-ops.pem}"
MONITOR_HOST="${MONITOR_HOST:-}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=10 -i ${SSH_KEY}}"

# If MONITOR_HOST is set and nodes are on private subnets, add ProxyJump
if [[ -n "$MONITOR_HOST" ]]; then
    SSH_OPTS="${SSH_OPTS} -o ProxyJump=${SSH_USER}@${MONITOR_HOST}"
fi

PROMETHEUS_URL="${PROMETHEUS_URL:-http://${MONITOR_HOST:-localhost}:9090}"
VMQ_ADMIN="${VMQ_ADMIN:-sudo /usr/sbin/vmq-admin}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_nodes_array() {
    local var="$1"
    # shellcheck disable=SC2086
    echo ${!var}
}

_node_at() {
    local var="$1" idx="$2"
    local -a nodes
    read -ra nodes <<< "${!var}"
    if (( idx < 0 || idx >= ${#nodes[@]} )); then
        echo "ERROR: node index $idx out of range for $var (${#nodes[@]} nodes)" >&2
        return 1
    fi
    echo "${nodes[$idx]}"
}

_ts() {
    date -u '+%Y-%m-%dT%H:%M:%SZ'
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

log_phase() {
    local phase="$1" description="$2"
    local ts
    ts=$(_ts)
    echo "=== [$ts] PHASE: $phase - $description ==="
    echo "$ts,$phase,$description" >> "${RESULTS_DIR}/${SCENARIO_TAG}/phases.csv"
}

log_info() {
    echo "[INFO $(_ts)] $*"
}

log_error() {
    echo "[ERROR $(_ts)] $*" >&2
}

# ---------------------------------------------------------------------------
# SSH wrappers
# ---------------------------------------------------------------------------

ssh_vmq() {
    local node_index="$1"; shift
    local node
    node=$(_node_at VMQ_NODES "$node_index")
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${SSH_USER}@${node}" "$@"
}

ssh_bench() {
    local node_index="$1"; shift
    local node
    node=$(_node_at BENCH_NODES "$node_index")
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${SSH_USER}@${node}" "$@"
}

# ---------------------------------------------------------------------------
# emqtt_bench management
# ---------------------------------------------------------------------------

start_emqtt_bench() {
    local bench_node="$1"; shift
    local args="$*"
    local node
    node=$(_node_at BENCH_NODES "$bench_node")
    log_info "Starting emqtt_bench on bench node $bench_node ($node): $args"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${SSH_USER}@${node}" \
        "nohup emqtt_bench $args > /tmp/emqtt_bench_\$\$.log 2>&1 & echo \$!"
}

stop_emqtt_bench() {
    local bench_node="$1"
    local node
    node=$(_node_at BENCH_NODES "$bench_node")
    log_info "Stopping emqtt_bench on bench node $bench_node ($node)"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${SSH_USER}@${node}" \
        "pkill -f emqtt_bench || true"
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
# VerneMQ operations
# ---------------------------------------------------------------------------

# Get a single metric value from a node (returns 0 if not found)
get_vmq_metric() {
    local node_index="$1" metric_name="$2"
    ssh_vmq "$node_index" "$VMQ_ADMIN metrics show" 2>/dev/null \
        | grep "^counter\.${metric_name}\|^gauge\.${metric_name}" \
        | awk -F' = ' '{print $2}' | head -1 || echo "0"
}

# Get a metric summed across all nodes
get_vmq_metric_sum() {
    local metric_name="$1"
    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    local total=0
    for i in "${!nodes[@]}"; do
        local val
        val=$(get_vmq_metric "$i" "$metric_name") || val=0
        total=$(( total + val ))
    done
    echo "$total"
}

# ---------------------------------------------------------------------------
# Cluster health assertions
# ---------------------------------------------------------------------------

# Full cluster health check: node count + metrics stability + no active drops
assert_cluster_healthy() {
    local label="${1:-pre-phase}"
    local expected_nodes
    expected_nodes=$(vmq_node_count)
    local max_wait="${2:-60}"

    log_info "Asserting cluster health ($label)..."

    # 1. All nodes must be running
    wait_cluster_ready "$expected_nodes" "$max_wait"

    # 2. cluster_bytes_dropped must not be increasing
    local drops_before drops_after
    drops_before=$(get_vmq_metric_sum "cluster_bytes_dropped")
    sleep 3
    drops_after=$(get_vmq_metric_sum "cluster_bytes_dropped")
    if (( drops_after > drops_before )); then
        log_error "HEALTH FAIL ($label): cluster_bytes_dropped increasing ($drops_before -> $drops_after)"
        return 1
    fi

    log_info "Cluster healthy ($label): ${expected_nodes} nodes, drops stable at $drops_after"
}

# Wait until all emqtt_bench connections are fully drained from VerneMQ
wait_connections_drained() {
    local target="${1:-0}"  # expected active connections (default 0)
    local max_wait="${2:-120}"
    local interval=5
    local elapsed=0

    log_info "Waiting for connections to drain to $target (timeout: ${max_wait}s)..."

    while (( elapsed < max_wait )); do
        local active
        active=$(get_vmq_metric_sum "mqtt_socket_active" 2>/dev/null) || active="-1"
        # Some VerneMQ versions use different metric names
        if (( active < 0 )); then
            active=$(get_vmq_metric_sum "socket_open")
            local closed
            closed=$(get_vmq_metric_sum "socket_close")
            active=$(( active - closed ))
        fi

        if (( active <= target )); then
            log_info "Connections drained: $active active (target: $target)"
            return 0
        fi
        log_info "Draining connections: $active active, waiting..."
        sleep "$interval"
        (( elapsed += interval ))
    done

    local final
    final=$(get_vmq_metric_sum "mqtt_socket_active" 2>/dev/null || echo "unknown")
    log_error "Connections not drained within ${max_wait}s (still $final active)"
    return 1
}

# Wait until router_subscriptions is stable across all nodes (converged)
wait_subscriptions_converged() {
    local max_wait="${1:-120}"
    local stable_for="${2:-10}"  # must be stable for this many seconds
    local interval=5
    local elapsed=0
    local last_total=-1
    local stable_elapsed=0

    log_info "Waiting for subscription convergence (stable for ${stable_for}s, timeout: ${max_wait}s)..."

    while (( elapsed < max_wait )); do
        local total
        total=$(get_vmq_metric_sum "router_subscriptions")

        if (( total == last_total )); then
            (( stable_elapsed += interval ))
            if (( stable_elapsed >= stable_for )); then
                log_info "Subscriptions converged: $total total (stable for ${stable_elapsed}s)"
                return 0
            fi
        else
            stable_elapsed=0
        fi
        last_total=$total
        sleep "$interval"
        (( elapsed += interval ))
    done

    log_error "Subscriptions not converged within ${max_wait}s (last total: $last_total)"
    return 1
}

# Verify clean state before a phase: low/zero residual connections and stable metrics
verify_clean_state() {
    local label="${1:-pre-phase}"
    local max_conns="${2:-100}"  # threshold for "clean" connection count

    log_info "Verifying clean state ($label)..."

    # Check active connections are near zero
    local open closed active
    open=$(get_vmq_metric_sum "socket_open") || open=0
    closed=$(get_vmq_metric_sum "socket_close") || closed=0
    active=$(( open - closed ))
    # Clamp to 0 (cumulative counters can be slightly off)
    (( active < 0 )) && active=0

    if (( active > max_conns )); then
        log_error "DIRTY STATE ($label): $active active connections (threshold: $max_conns)"
        log_error "Consider restarting VerneMQ nodes for a clean benchmark"
        return 1
    fi

    # Check cluster_bytes_dropped is not increasing
    local drops1 drops2
    drops1=$(get_vmq_metric_sum "cluster_bytes_dropped")
    sleep 2
    drops2=$(get_vmq_metric_sum "cluster_bytes_dropped")
    if (( drops2 > drops1 )); then
        log_error "DIRTY STATE ($label): cluster_bytes_dropped still increasing ($drops1 -> $drops2)"
        return 1
    fi

    log_info "State clean ($label): ~$active active connections, drops stable"
    return 0
}

# Inter-phase cleanup: stop bench, wait for drain, verify clean
phase_cleanup() {
    local label="${1:-between-phases}"
    local drain_timeout="${2:-60}"

    log_info "Phase cleanup ($label)..."
    stop_all_emqtt_bench

    # Give VerneMQ time to process pending disconnections
    sleep 5

    # Wait for connection drain (best-effort, don't fail the run)
    wait_connections_drained 100 "$drain_timeout" || \
        log_error "WARNING: connections did not fully drain, continuing..."

    # Short stabilization pause
    sleep 3
    log_info "Phase cleanup complete ($label)"
}

collect_metrics() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    log_info "Collecting metrics snapshot: $tag"

    # Per-node VerneMQ metrics
    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    for i in "${!nodes[@]}"; do
        ssh_vmq "$i" "$VMQ_ADMIN metrics show" \
            > "$out_dir/vmq_metrics_node${i}.txt" 2>/dev/null || true
    done

    # Prometheus snapshot
    if [[ -n "$PROMETHEUS_URL" ]]; then
        curl -s "${PROMETHEUS_URL}/api/v1/query?query=up" \
            > "$out_dir/prom_up.json" 2>/dev/null || true
        curl -s "${PROMETHEUS_URL}/api/v1/query?query=mqtt_publish_received_total" \
            > "$out_dir/prom_publish.json" 2>/dev/null || true
        curl -s "${PROMETHEUS_URL}/api/v1/query?query=mqtt_connack_sent_total" \
            > "$out_dir/prom_connack.json" 2>/dev/null || true
        curl -s "${PROMETHEUS_URL}/api/v1/query?query=process_resident_memory_bytes" \
            > "$out_dir/prom_memory.json" 2>/dev/null || true
        curl -s "${PROMETHEUS_URL}/api/v1/query?query=process_cpu_seconds_total" \
            > "$out_dir/prom_cpu.json" 2>/dev/null || true
    fi

    log_info "Metrics saved to $out_dir"
}

wait_cluster_ready() {
    local expected_nodes="$1"
    local max_wait="${2:-120}"
    local interval=5
    local elapsed=0

    log_info "Waiting for cluster to have $expected_nodes running nodes (timeout: ${max_wait}s)"

    while (( elapsed < max_wait )); do
        local running
        running=$(ssh_vmq 0 "$VMQ_ADMIN cluster show" 2>/dev/null \
            | grep -c "true" || echo 0)
        if (( running >= expected_nodes )); then
            log_info "Cluster ready: $running/$expected_nodes nodes running"
            return 0
        fi
        log_info "Cluster: $running/$expected_nodes nodes running, waiting..."
        sleep "$interval"
        (( elapsed += interval ))
    done

    log_error "Cluster did not reach $expected_nodes nodes within ${max_wait}s"
    return 1
}

kill_vmq_node() {
    local node_index="$1"
    log_info "SIGKILL VerneMQ on node $node_index"
    ssh_vmq "$node_index" "sudo pkill -9 -f beam.smp || true"
}

start_vmq_node() {
    local node_index="$1"
    log_info "Starting VerneMQ on node $node_index"
    ssh_vmq "$node_index" "sudo systemctl start vernemq"

    # Wait for node to respond to ping before applying settings
    local wait=0
    while (( wait < 60 )); do
        if ssh_vmq "$node_index" "sudo ${VMQ_ADMIN%vmq-admin}vernemq ping" 2>/dev/null | grep -q pong; then
            break
        fi
        sleep 5
        (( wait += 5 ))
    done

    # Re-apply runtime settings that don't persist through restart
    log_info "Re-applying runtime settings on node $node_index"
    ssh_vmq "$node_index" "$VMQ_ADMIN set allow_subscribe_during_netsplit=on" 2>/dev/null || true
    ssh_vmq "$node_index" "$VMQ_ADMIN set allow_publish_during_netsplit=on" 2>/dev/null || true
    ssh_vmq "$node_index" "$VMQ_ADMIN set allow_register_during_netsplit=on" 2>/dev/null || true
    ssh_vmq "$node_index" "$VMQ_ADMIN plugin enable --name vmq_acl" 2>/dev/null || true
}

check_balance_health() {
    local node_index="$1"
    local node
    node=$(_node_at VMQ_NODES "$node_index")
    ssh_vmq "$node_index" "curl -s -o /dev/null -w '%{http_code}' http://localhost:8888/api/balance-health 2>/dev/null" || echo "000"
}

# ---------------------------------------------------------------------------
# Results setup
# ---------------------------------------------------------------------------

init_scenario() {
    local scenario_name="$1"
    SCENARIO_TAG="${SCENARIO_TAG:-$scenario_name}"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}"
    mkdir -p "$out_dir"

    SCENARIO_START_EPOCH=$(date +%s)

    log_info "Scenario: $scenario_name"
    log_info "Results dir: $out_dir"
    log_info "VMQ nodes: $VMQ_NODES ($(vmq_node_count) nodes)"
    log_info "Bench nodes: $BENCH_NODES ($(bench_node_count) nodes)"
    log_info "DURATION: ${DURATION:-NOT SET}"
    log_info "LOAD_MULTIPLIER: ${LOAD_MULTIPLIER:-1}"

    # Warn if DURATION is not explicitly set (comparison runs should always set it)
    if [[ -z "${DURATION:-}" && "${BENCH_COMPARISON_MODE:-}" == "1" ]]; then
        log_error "FATAL: DURATION not set in comparison mode. Set --duration to ensure A/B consistency."
        exit 1
    fi

    {
        echo "scenario,$scenario_name"
        echo "start,$(_ts)"
        echo "start_epoch,$SCENARIO_START_EPOCH"
        echo "vmq_nodes,$VMQ_NODES"
        echo "bench_nodes,$BENCH_NODES"
        echo "vmq_node_count,$(vmq_node_count)"
        echo "bench_node_count,$(bench_node_count)"
        echo "duration,${DURATION:-default}"
        echo "load_multiplier,${LOAD_MULTIPLIER:-1}"
        echo "vmq_version,${VMQ_VERSION:-unknown}"
    } > "$out_dir/metadata.csv"

    # Ensure cluster is healthy before starting
    local total_nodes
    total_nodes=$(vmq_node_count)
    if (( total_nodes > 1 )); then
        assert_cluster_healthy "init_scenario" 120
    fi

    # Verify clean state (warn but don't fail — allows running on pre-warmed clusters)
    verify_clean_state "init_scenario" 500 || \
        log_error "WARNING: Cluster not in clean state. Results may be affected by residual load."

    # Record baseline metric snapshot for later delta validation
    collect_metrics "scenario_baseline"

    start_metrics_poller
}

finish_scenario() {
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}"
    SCENARIO_END_EPOCH=$(date +%s)
    echo "end,$(_ts)" >> "$out_dir/metadata.csv"
    echo "end_epoch,$SCENARIO_END_EPOCH" >> "$out_dir/metadata.csv"

    stop_metrics_poller

    # Clean shutdown: stop bench, drain connections, collect final state
    stop_all_emqtt_bench
    sleep 5

    # Collect final metrics for post-run analysis
    collect_metrics "scenario_final"

    # Report any cluster_bytes_dropped delta during this scenario
    local baseline_dir="${out_dir}/scenario_baseline"
    local final_dir="${out_dir}/scenario_final"
    if [[ -d "$baseline_dir" && -d "$final_dir" ]]; then
        local -a nodes
        read -ra nodes <<< "$VMQ_NODES"
        local total_dropped=0
        for i in "${!nodes[@]}"; do
            local before_file="${baseline_dir}/vmq_metrics_node${i}.txt"
            local after_file="${final_dir}/vmq_metrics_node${i}.txt"
            if [[ -f "$before_file" && -f "$after_file" ]]; then
                local d_before d_after delta
                d_before=$(grep 'cluster_bytes_dropped' "$before_file" | awk -F' = ' '{print $2}' | head -1 || echo 0)
                d_after=$(grep 'cluster_bytes_dropped' "$after_file" | awk -F' = ' '{print $2}' | head -1 || echo 0)
                delta=$(( ${d_after:-0} - ${d_before:-0} ))
                (( delta < 0 )) && delta=0
                total_dropped=$(( total_dropped + delta ))
                if (( delta > 0 )); then
                    log_error "Node $i: cluster_bytes_dropped +${delta} during scenario"
                fi
            fi
        done
        echo "cluster_bytes_dropped_total,$total_dropped" >> "$out_dir/metadata.csv"
        if (( total_dropped > 0 )); then
            log_error "TOTAL cluster_bytes_dropped during scenario: $total_dropped"
        else
            log_info "No cluster bytes dropped during scenario"
        fi
    fi

    # Optional per-scenario Prometheus export
    if [[ "${EXPORT_PROM:-0}" == "1" ]]; then
        local export_script="${SCRIPT_DIR}/../scripts/export_prometheus.sh"
        if [[ -x "$export_script" ]]; then
            bash "$export_script" \
                --prometheus-url "$PROMETHEUS_URL" \
                --results-dir "$out_dir" \
                --start-epoch "$SCENARIO_START_EPOCH" \
                --end-epoch "$SCENARIO_END_EPOCH" || true
        fi
    fi

    log_info "Scenario complete. Results in $out_dir"
}

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

# Distribute connections across bench nodes evenly.
# Usage: distribute_connections 100000 3  -> prints ~33334 33333 33333
distribute_connections() {
    local total="$1" num_bench="$2"
    local per=$(( total / num_bench ))
    local remainder=$(( total % num_bench ))
    for (( i=0; i<num_bench; i++ )); do
        if (( i < remainder )); then
            echo $(( per + 1 ))
        else
            echo "$per"
        fi
    done
}

# Build a comma-separated list of VMQ node hostnames for emqtt_bench -h
# Port should be passed separately via -p
vmq_host_list() {
    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    local result=""
    for n in "${nodes[@]}"; do
        if [[ -n "$result" ]]; then
            result="${result},${n}"
        else
            result="${n}"
        fi
    done
    echo "$result"
}

# Build comma-separated hosts targeting only specific node indices.
# Usage: vmq_host_subset 0 1  (targets nodes 0 and 1)
vmq_host_subset() {
    local result=""
    for idx in "$@"; do
        local node
        node=$(_node_at VMQ_NODES "$idx")
        if [[ -n "$result" ]]; then
            result="${result},${node}"
        else
            result="${node}"
        fi
    done
    echo "$result"
}

# ---------------------------------------------------------------------------
# Cluster-size helpers
# ---------------------------------------------------------------------------

vmq_node_count() {
    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    echo "${#nodes[@]}"
}

bench_node_count() {
    local -a nodes
    read -ra nodes <<< "$BENCH_NODES"
    echo "${#nodes[@]}"
}

require_min_vmq_nodes() {
    local min="$1" reason="${2:-}"
    local actual
    actual=$(vmq_node_count)
    if (( actual < min )); then
        log_info "SKIP: Requires at least $min VMQ nodes (have $actual)${reason:+: $reason}"
        exit 0
    fi
}

scale_load() {
    local base="$1" ref_nodes="$2"
    local actual
    actual=$(vmq_node_count)
    local multiplier="${LOAD_MULTIPLIER:-1}"
    # Use awk for decimal multiplier support (e.g. LOAD_MULTIPLIER=1.5)
    awk "BEGIN { printf \"%d\", $base * $actual * $multiplier / $ref_nodes }"
}

tail_node_indices() {
    local count="$1"
    local total
    total=$(vmq_node_count)
    local start=$(( total - count ))
    for (( i=start; i<total; i++ )); do
        echo "$i"
    done
}

head_node_indices() {
    local count="$1"
    for (( i=0; i<count; i++ )); do
        echo "$i"
    done
}

vmq_host_first_n() {
    local n="$1"
    local result=""
    for (( i=0; i<n; i++ )); do
        local node
        node=$(_node_at VMQ_NODES "$i")
        if [[ -n "$result" ]]; then
            result="${result},${node}"
        else
            result="${node}"
        fi
    done
    echo "$result"
}

require_feature() {
    local feature="$1"
    local version="${VMQ_VERSION:-integration}"
    case "$feature" in
        balance|rebalance|tiered_health|dead_node_cleanup|gossip_tuning)
            if [[ "$version" != "integration" ]]; then
                log_info "SKIP: Feature '$feature' requires integration branch (have $version)"
                exit 0
            fi
            ;;
        reg_trie_workers|connection_pool)
            if [[ "$version" == 1.* ]]; then
                log_info "SKIP: Feature '$feature' not available in version $version"
                exit 0
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Metrics poller management
# ---------------------------------------------------------------------------

METRICS_POLLER_PID=""
METRICS_POLL_INTERVAL="${METRICS_POLL_INTERVAL:-10}"

start_metrics_poller() {
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}"
    local poller_script="${SCRIPT_DIR}/../scripts/vmq_metrics_poller.sh"
    if [[ -x "$poller_script" ]]; then
        bash "$poller_script" \
            --nodes "$VMQ_NODES" \
            --interval "$METRICS_POLL_INTERVAL" \
            --output "$out_dir/vmq_metrics_timeseries.csv" \
            --ssh-opts "$SSH_OPTS" \
            --ssh-user "$SSH_USER" \
            --vmq-admin "$VMQ_ADMIN" &
        METRICS_POLLER_PID=$!
        log_info "Started metrics poller (PID: $METRICS_POLLER_PID, interval: ${METRICS_POLL_INTERVAL}s)"
    else
        log_info "Metrics poller not found at $poller_script, skipping"
    fi
}

stop_metrics_poller() {
    if [[ -n "$METRICS_POLLER_PID" ]] && kill -0 "$METRICS_POLLER_PID" 2>/dev/null; then
        kill "$METRICS_POLLER_PID" 2>/dev/null || true
        wait "$METRICS_POLLER_PID" 2>/dev/null || true
        log_info "Stopped metrics poller (PID: $METRICS_POLLER_PID)"
        METRICS_POLLER_PID=""
    fi
}
