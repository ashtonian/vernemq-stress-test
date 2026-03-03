#!/usr/bin/env bash
# common.sh - Shared helper functions for VerneMQ benchmark scenarios.
# Source this file from each scenario script.

set -euo pipefail

# ---------------------------------------------------------------------------
# Auto-source bench.env if SSH_KEY is not already set
# ---------------------------------------------------------------------------

if [[ -z "${SSH_KEY:-}" ]]; then
    _common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${_common_dir}/../bench.env" ]]; then
        # shellcheck disable=SC1091
        source "${_common_dir}/../bench.env"
    fi
    unset _common_dir
fi

# ---------------------------------------------------------------------------
# Configuration defaults (override via environment)
# ---------------------------------------------------------------------------

# Space-separated lists of node IPs/hostnames read from Ansible inventory.
BENCH_NODES="${BENCH_NODES:-}"
VMQ_NODES="${VMQ_NODES:-}"
RESULTS_DIR="${RESULTS_DIR:-./results}"
SCENARIO_TAG="${SCENARIO_TAG:-default}"
SSH_USER="${SSH_USER:-ec2-user}"
SSH_KEY="${SSH_KEY:-}"
MONITOR_HOST="${MONITOR_HOST:-}"
LB_HOST="${LB_HOST:-}"
BENCH_USE_LB="${BENCH_USE_LB:-0}"
BENCH_MQTT_USERNAME="${BENCH_MQTT_USERNAME:-}"
BENCH_MQTT_PASSWORD="${BENCH_MQTT_PASSWORD:-}"
SSH_OPTS="${SSH_OPTS:--o StrictHostKeyChecking=no -o ConnectTimeout=10 -o ControlMaster=auto -o ControlPath=/tmp/vmq-bench-%r@%h:%p -o ControlPersist=120${SSH_KEY:+ -i $SSH_KEY}}"

# If MONITOR_HOST is set and nodes are on private subnets, add ProxyJump
# Set SSH_USE_PROXY=0 to disable ProxyJump (e.g. when nodes are directly reachable)
if [[ -n "$MONITOR_HOST" && "${SSH_USE_PROXY:-1}" == "1" ]]; then
    SSH_OPTS="${SSH_OPTS} -o ProxyJump=${SSH_USER}@${MONITOR_HOST}"
fi

PROMETHEUS_URL="${PROMETHEUS_URL:-http://${MONITOR_HOST:-localhost}:9090}"
VMQ_ADMIN="${VMQ_ADMIN:-sudo /usr/sbin/vmq-admin}"

# ---------------------------------------------------------------------------
# Version profile system
# ---------------------------------------------------------------------------

PROFILES_DIR="${PROFILES_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/profiles}"

load_profile() {
    local version="${VMQ_VERSION:-integration}"
    local profile_file=""

    # Exact match: "integration" -> integration.sh
    if [[ -f "${PROFILES_DIR}/${version}.sh" ]]; then
        profile_file="${PROFILES_DIR}/${version}.sh"
    else
        # Strip leading 'v' for version matching
        local ver="${version#v}"

        # Try major.minor match: "2.1.2" -> v2.1.sh
        local major_minor="${ver%.*}"
        if [[ "$major_minor" != "$ver" && -f "${PROFILES_DIR}/v${major_minor}.sh" ]]; then
            profile_file="${PROFILES_DIR}/v${major_minor}.sh"
        else
            # Try major.x match: "1.13.0" -> v1.x.sh
            local major="${ver%%.*}"
            if [[ -f "${PROFILES_DIR}/v${major}.x.sh" ]]; then
                profile_file="${PROFILES_DIR}/v${major}.x.sh"
            fi
        fi
    fi

    if [[ -z "$profile_file" ]]; then
        echo "[WARN] No profile found for version '${version}', falling back to integration" >&2
        profile_file="${PROFILES_DIR}/integration.sh"
    fi

    if [[ ! -f "$profile_file" ]]; then
        echo "[ERROR] Profile file not found: ${profile_file}" >&2
        return 1
    fi

    # shellcheck disable=SC1090
    source "$profile_file"
}

has_feature() {
    local feat="$1"
    [[ " ${PROFILE_FEATURES:-} " == *" $feat "* ]]
}

check_scenario_compat() {
    local num="$1"
    local compat="${SCENARIO_COMPAT[$num]:-full}"
    if [[ "$compat" == "skip" ]]; then
        log_info "SKIP: Scenario $num not compatible with profile '${PROFILE_NAME:-unknown}'"
        exit 0
    fi
}

set_vmq_config() {
    local setting="$1" value="$2" target="${3:-all}"

    _set_vmq_config_node() {
        local node_idx="$1"
        if ! ssh_vmq "$node_idx" "$VMQ_ADMIN set ${setting}=${value}" 2>/dev/null; then
            log_info "WARNING: Failed to set ${setting}=${value} on node $node_idx (not available, using default)"
            local results_csv="${RESULTS_DIR}/${SCENARIO_TAG:-default}/degraded_config.csv"
            mkdir -p "$(dirname "$results_csv")"
            echo "$(_ts),${setting},${value},node${node_idx},failed" >> "$results_csv"
        fi
    }

    if [[ "$target" == "all" ]]; then
        local -a nodes
        read -ra nodes <<< "$VMQ_NODES"
        for i in "${!nodes[@]}"; do
            _set_vmq_config_node "$i"
        done
    else
        _set_vmq_config_node "$target"
    fi
}

# Load profile automatically when common.sh is sourced
load_profile

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

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

    # Inject auth credentials if configured.
    # NOTE: credentials are passed as CLI arguments and will be visible in the
    # process table (ps aux).  emqtt_bench does not support env-var or
    # file-based auth, so there is no alternative.  Use dedicated bench
    # credentials with minimal privileges and rotate after runs.
    local auth_args=""
    if [[ -n "$BENCH_MQTT_USERNAME" && -n "$BENCH_MQTT_PASSWORD" ]]; then
        auth_args="-u $BENCH_MQTT_USERNAME -P $BENCH_MQTT_PASSWORD"
    fi

    log_info "Starting emqtt_bench on bench node $bench_node ($node): $args${auth_args:+ [auth]}"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${SSH_USER}@${node}" \
        "nohup emqtt_bench $args $auth_args > /tmp/emqtt_bench_\$\$.log 2>&1 & echo \$!"
}

stop_emqtt_bench_pid() {
    local bench_node="$1" pid="$2"
    local node
    node=$(_node_at BENCH_NODES "$bench_node")
    log_info "Stopping emqtt_bench PID $pid on bench node $bench_node ($node)"
    # shellcheck disable=SC2086
    ssh ${SSH_OPTS} "${SSH_USER}@${node}" "kill $pid 2>/dev/null; sleep 2; kill -9 $pid 2>/dev/null" || true
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

# Get a metric value by raw name (without counter./gauge. prefix)
get_vmq_metric_raw() {
    local node_index="$1" metric_name="$2"
    ssh_vmq "$node_index" "$VMQ_ADMIN metrics show" 2>/dev/null \
        | grep "${metric_name} " | awk -F' = ' '{print $2}' | head -1 || echo "0"
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

collect_all_metrics() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    log_info "Collecting all metrics snapshot: $tag"

    # 1. Per-node VerneMQ metrics (existing approach)
    local -a nodes
    read -ra nodes <<< "$VMQ_NODES"
    for i in "${!nodes[@]}"; do
        ssh_vmq "$i" "$VMQ_ADMIN metrics show" \
            > "$out_dir/vmq_metrics_node${i}.txt" 2>/dev/null || true
    done

    # 2. Prometheus instant queries
    if [[ -n "$PROMETHEUS_URL" ]]; then
        # Check Prometheus reachability first
        if ! curl -sf --max-time 3 "${PROMETHEUS_URL}/-/healthy" >/dev/null 2>&1; then
            log_info "WARNING: Prometheus unreachable at ${PROMETHEUS_URL}, skipping Prometheus metrics"
            local epoch
            epoch=$(date +%s)
            echo "epoch,$epoch" > "$out_dir/prom_instant.csv"
            for name in publish_received_rate publish_sent_rate latency_p50 latency_p95 latency_p99 active_connections process_memory_bytes process_cpu_rate cluster_bytes_dropped cluster_readiness; do
                echo "${name},N/A" >> "$out_dir/prom_instant.csv"
            done
        else
            local epoch
            epoch=$(date +%s)
            echo "epoch,$epoch" > "$out_dir/prom_instant.csv"

            local -A prom_queries=(
                ["publish_received_rate"]='sum(rate(mqtt_publish_received_total[1m]))'
                ["publish_sent_rate"]='sum(rate(mqtt_publish_sent_total[1m]))'
                ["latency_p50"]='histogram_quantile(0.50, sum(rate(mqtt_publish_latency_seconds_bucket[1m])) by (le))'
                ["latency_p95"]='histogram_quantile(0.95, sum(rate(mqtt_publish_latency_seconds_bucket[1m])) by (le))'
                ["latency_p99"]='histogram_quantile(0.99, sum(rate(mqtt_publish_latency_seconds_bucket[1m])) by (le))'
                ["active_connections"]='sum(mqtt_socket_open) - sum(mqtt_socket_close)'
                ["process_memory_bytes"]='sum(process_resident_memory_bytes)'
                ["process_cpu_rate"]='sum(rate(process_cpu_seconds_total[1m]))'
                ["cluster_bytes_dropped"]='sum(vmq_cluster_bytes_dropped_total)'
                ["cluster_readiness"]='min(vmq_cluster_readiness)'
            )

            for name in "${!prom_queries[@]}"; do
                local query="${prom_queries[$name]}"
                local value
                value=$(curl -sf --max-time 10 \
                    "${PROMETHEUS_URL}/api/v1/query" \
                    --data-urlencode "query=${query}" 2>/dev/null \
                    | python3 -c "
import sys, json
try:
    data = json.load(sys.stdin)
    results = data.get('data', {}).get('result', [])
    if results:
        print(results[0].get('value', [None, '0'])[1])
    else:
        print('0')
except Exception: print('0')" 2>/dev/null) || value="N/A"
                echo "${name},${value}" >> "$out_dir/prom_instant.csv"
            done
        fi
    fi

    log_info "All metrics saved to $out_dir"
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
    set_vmq_config "allow_subscribe_during_netsplit" "on" "$node_index"
    set_vmq_config "allow_publish_during_netsplit" "on" "$node_index"
    set_vmq_config "allow_register_during_netsplit" "on" "$node_index"
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
    log_info "Profile: ${PROFILE_NAME:-unknown} (${PROFILE_DESCRIPTION:-})"
    log_info "Results dir: $out_dir"
    log_info "VMQ nodes: $VMQ_NODES ($(vmq_node_count) nodes)"
    log_info "Bench nodes: $BENCH_NODES ($(bench_node_count) nodes)"
    log_info "DURATION: ${DURATION:-NOT SET}"
    log_info "LOAD_MULTIPLIER: ${LOAD_MULTIPLIER:-1}"
    log_info "LB mode: ${SCENARIO_LB_MODE:-direct_only}$(should_use_lb && echo ' (ACTIVE via '"$LB_HOST"')' || echo '')"
    if [[ -n "$BENCH_MQTT_USERNAME" ]]; then
        log_info "Auth: enabled (user: $BENCH_MQTT_USERNAME)"
    fi

    # Warn if bench nodes may be undersized for the current scale.
    # Estimate worst-case: 100k base conns (scenario 01 phase 3) is the heaviest
    # standard load point.  Add pub connections too (50k base).
    local _est_conns _est_pubs
    _est_conns=$(scale_load 100000 8)
    _est_pubs=$(scale_load 50000 8)
    check_bench_capacity $(( _est_conns + _est_pubs ))

    # Warn if DURATION is not explicitly set (comparison runs should always set it)
    if [[ -z "${DURATION:-}" && "${BENCH_COMPARISON_MODE:-}" == "1" ]]; then
        log_error "FATAL: DURATION not set in comparison mode. Set --duration to ensure A/B consistency."
        exit 1
    fi

    {
        echo "scenario,$scenario_name"
        echo "start,$(_ts)"
        echo "start_epoch,$SCENARIO_START_EPOCH"
        echo "vmq_nodes,\"$VMQ_NODES\""
        echo "bench_nodes,\"$BENCH_NODES\""
        echo "vmq_node_count,$(vmq_node_count)"
        echo "bench_node_count,$(bench_node_count)"
        echo "duration,${DURATION:-default}"
        echo "load_multiplier,${LOAD_MULTIPLIER:-1}"
        echo "vmq_version,${VMQ_VERSION:-unknown}"
        echo "profile,${PROFILE_NAME:-unknown}"
        echo "profile_features,${PROFILE_FEATURES:-}"
        echo "profile_pool_sizes,${PROFILE_POOL_SIZES[*]:-}"
        echo "profile_worker_counts,${PROFILE_WORKER_COUNTS[*]:-}"
        echo "lb_mode,${SCENARIO_LB_MODE:-direct_only}"
        echo "lb_active,$(should_use_lb && echo true || echo false)"
        echo "lb_host,${LB_HOST:-}"
        echo "auth_enabled,$( [[ -n "$BENCH_MQTT_USERNAME" ]] && echo true || echo false)"
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
    collect_all_metrics "scenario_baseline"

    # Check if Prometheus data was collected
    local baseline_prom="${RESULTS_DIR}/${SCENARIO_TAG}/scenario_baseline/prom_instant.csv"
    if [[ -f "$baseline_prom" ]] && grep -q "N/A" "$baseline_prom" 2>/dev/null; then
        log_info "WARNING: Prometheus metrics unavailable. Scenarios will run with reduced metrics."
    fi

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
    collect_all_metrics "scenario_final"

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

    # Per-scenario Prometheus range data export
    local _common_dir
    _common_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local export_script="${_common_dir}/../scripts/export_prometheus.sh"
    if [[ -x "$export_script" ]]; then
        bash "$export_script" \
            --prometheus-url "$PROMETHEUS_URL" \
            --results-dir "$out_dir" \
            --start-epoch "$SCENARIO_START_EPOCH" \
            --end-epoch "$SCENARIO_END_EPOCH" || true
    fi

    # Collect application logs for diagnostics
    collect_logs "$out_dir"

    log_info "Scenario complete. Results in $out_dir"
}

# ---------------------------------------------------------------------------
# Log collection
# ---------------------------------------------------------------------------

collect_logs() {
    local out_dir="$1"
    local vmq_log_dir="${out_dir}/vmq_logs"
    local bench_log_dir="${out_dir}/bench_logs"
    mkdir -p "$vmq_log_dir" "$bench_log_dir"

    log_info "Collecting application logs..."

    # Collect VerneMQ logs (console.log, error.log, crash.log)
    local -a vmq_nodes_arr
    read -ra vmq_nodes_arr <<< "$VMQ_NODES"
    for i in "${!vmq_nodes_arr[@]}"; do
        local node_log_dir="${vmq_log_dir}/node${i}"
        mkdir -p "$node_log_dir"
        # Try common log locations
        for logfile in console.log error.log crash.log; do
            for logpath in /var/log/vernemq /opt/vernemq/log; do
                ssh_vmq "$i" "cat ${logpath}/${logfile}" > "${node_log_dir}/${logfile}" 2>/dev/null && break
            done
        done
        # Tail last 200 lines of console.log for quick review
        ssh_vmq "$i" "tail -200 /var/log/vernemq/console.log 2>/dev/null || tail -200 /opt/vernemq/log/console.log 2>/dev/null" \
            > "${node_log_dir}/console_tail.log" 2>/dev/null || true
    done

    # Collect emqtt_bench logs from bench nodes
    local -a bench_nodes_arr
    read -ra bench_nodes_arr <<< "$BENCH_NODES"
    for i in "${!bench_nodes_arr[@]}"; do
        local node_bench_dir="${bench_log_dir}/bench${i}"
        mkdir -p "$node_bench_dir"
        # Concatenate all emqtt_bench logs
        ssh_bench "$i" "cat /tmp/emqtt_bench_*.log 2>/dev/null" \
            > "${node_bench_dir}/emqtt_bench.log" 2>/dev/null || true
        # Also grab last 100 lines for quick review
        ssh_bench "$i" "tail -100 /tmp/emqtt_bench_*.log 2>/dev/null" \
            > "${node_bench_dir}/emqtt_bench_tail.log" 2>/dev/null || true
    done

    # Remove empty log files
    find "$vmq_log_dir" "$bench_log_dir" -type f -empty -delete 2>/dev/null || true
    # Remove empty directories
    find "$vmq_log_dir" "$bench_log_dir" -type d -empty -delete 2>/dev/null || true

    local log_count
    log_count=$(find "$out_dir/vmq_logs" "$out_dir/bench_logs" -type f 2>/dev/null | wc -l | tr -d ' ')
    log_info "Collected ${log_count} log file(s)"
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

require_min_bench_nodes() {
    local min="$1" reason="${2:-}"
    local actual
    actual=$(bench_node_count)
    if (( actual < min )); then
        log_info "SKIP: Requires at least $min bench nodes (have $actual)${reason:+: $reason}"
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

# ---------------------------------------------------------------------------
# Bench node capacity check
# ---------------------------------------------------------------------------

# Max connections a single bench node can reliably sustain.
# emqtt-bench uses one Erlang process per connection (~2-4 KB).  CPU is the
# real bottleneck: a c6i.2xlarge (8 vCPU) tops out around 120-150k active
# connections with pub/sub traffic.  A c6i.4xlarge (16 vCPU) handles ~250-300k.
BENCH_CONN_WARN_THRESHOLD="${BENCH_CONN_WARN_THRESHOLD:-150000}"

check_bench_capacity() {
    local total_conns="$1"
    local num_bench
    num_bench=$(bench_node_count)
    if (( num_bench == 0 )); then
        log_error "WARNING: No bench nodes defined. Cannot check capacity."
        return
    fi
    local per_bench=$(( total_conns / num_bench ))

    if (( per_bench > BENCH_CONN_WARN_THRESHOLD )); then
        log_error "WARNING: Estimated ${per_bench} connections per bench node (${total_conns} total / ${num_bench} bench nodes)."
        log_error "  This exceeds the recommended limit of ${BENCH_CONN_WARN_THRESHOLD} per node."
        log_error "  The bench node may become a bottleneck. Consider:"
        log_error "    - Increasing bench_node_count (recommended: 1 bench per 3-4 VMQ nodes)"
        log_error "    - Using a larger instance (c6i.4xlarge for ~250k, c6i.8xlarge for ~500k)"
        log_error "    - Reducing LOAD_MULTIPLIER"
    fi
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

# ---------------------------------------------------------------------------
# Load balancer support
# ---------------------------------------------------------------------------

SCENARIO_LB_MODE="${SCENARIO_LB_MODE:-direct_only}"

should_use_lb() {
    # Returns 0 (true) if LB should be used, 1 (false) otherwise
    if [[ "$SCENARIO_LB_MODE" == "direct_only" ]]; then
        return 1
    fi
    if [[ "$SCENARIO_LB_MODE" == "supported" && -n "$LB_HOST" && "$BENCH_USE_LB" == "1" ]]; then
        return 0
    fi
    return 1
}

resolve_bench_hosts() {
    # Returns LB host if LB is active, otherwise direct VMQ host list
    if should_use_lb; then
        echo "$LB_HOST"
    else
        vmq_host_list
    fi
}

require_feature() {
    local feature="$1"
    if ! has_feature "$feature"; then
        log_info "SKIP: Feature '$feature' not available in profile '${PROFILE_NAME:-unknown}'"
        exit 0
    fi
}

# ---------------------------------------------------------------------------
# Metrics poller management
# ---------------------------------------------------------------------------

METRICS_POLLER_PID=""
METRICS_POLL_INTERVAL="${METRICS_POLL_INTERVAL:-10}"

start_metrics_poller() {
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}"
    local poller_script
    poller_script="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/scripts/vmq_metrics_poller.sh"
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

# ---------------------------------------------------------------------------
# Transport backend (override SSH functions when running in Docker)
# ---------------------------------------------------------------------------

if [[ "${BENCH_TRANSPORT:-ssh}" == "docker" ]]; then
    _transport_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [[ -f "${_transport_dir}/transport_docker.sh" ]]; then
        # shellcheck disable=SC1091
        source "${_transport_dir}/transport_docker.sh"
    else
        echo "[ERROR] BENCH_TRANSPORT=docker but transport_docker.sh not found" >&2
        exit 1
    fi
    unset _transport_dir
fi
