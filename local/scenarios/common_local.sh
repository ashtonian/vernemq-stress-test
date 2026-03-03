#!/usr/bin/env bash
# common_local.sh - Shared helpers for Docker-based local VerneMQ benchmarks.
# Mirrors bench/scenarios/common.sh but uses docker exec instead of SSH.

set -euo pipefail

# ---------------------------------------------------------------------------
# Configuration defaults
# ---------------------------------------------------------------------------

RESULTS_DIR="${RESULTS_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/results}"
SCENARIO_TAG="${SCENARIO_TAG:-default}"
VMQ_ADMIN="${VMQ_ADMIN:-/opt/vernemq/bin/vmq-admin}"

# Local scale factor: 8x reduction for laptop vs c6i.2xlarge
LOCAL_SCALE="${LOCAL_SCALE:-0.125}"

# Docker container names
VMQ_CONTAINERS="${VMQ_CONTAINERS:-vmq1 vmq2 vmq3}"
BENCH_CONTAINER="${BENCH_CONTAINER:-bench}"

# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

_vmq_containers_array() {
    echo $VMQ_CONTAINERS
}

_vmq_container_at() {
    local idx="$1"
    local -a containers
    read -ra containers <<< "$VMQ_CONTAINERS"
    if (( idx < 0 || idx >= ${#containers[@]} )); then
        echo "ERROR: container index $idx out of range (${#containers[@]} containers)" >&2
        return 1
    fi
    echo "${containers[$idx]}"
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
    mkdir -p "${RESULTS_DIR}/${SCENARIO_TAG}"
    echo "$ts,$phase,$description" >> "${RESULTS_DIR}/${SCENARIO_TAG}/phases.csv"
}

log_info() {
    echo "[INFO $(_ts)] $*"
}

log_error() {
    echo "[ERROR $(_ts)] $*" >&2
}

# ---------------------------------------------------------------------------
# Docker exec wrappers
# ---------------------------------------------------------------------------

exec_vmq() {
    local idx="$1"; shift
    local container
    container=$(_vmq_container_at "$idx")
    docker exec "$container" "$@"
}

exec_bench() {
    docker exec "$BENCH_CONTAINER" "$@"
}

# ---------------------------------------------------------------------------
# emqtt_bench management
# ---------------------------------------------------------------------------

start_emqtt_bench() {
    local args="$*"
    log_info "Starting emqtt_bench: $args"
    # Run detached in the bench container
    docker exec -d "$BENCH_CONTAINER" sh -c "emqtt_bench $args > /tmp/emqtt_bench_$$.log 2>&1"
}

stop_all_emqtt_bench() {
    log_info "Stopping all emqtt_bench processes"
    docker exec "$BENCH_CONTAINER" pkill -f emqtt_bench 2>/dev/null || true
    sleep 1
}

# ---------------------------------------------------------------------------
# VerneMQ metrics
# ---------------------------------------------------------------------------

get_vmq_metric() {
    local node_index="$1" metric_name="$2"
    exec_vmq "$node_index" "$VMQ_ADMIN" metrics show 2>/dev/null \
        | grep "^counter\.${metric_name}\|^gauge\.${metric_name}" \
        | awk -F' = ' '{print $2}' | head -1 || echo "0"
}

get_vmq_metric_sum() {
    local metric_name="$1"
    local -a containers
    read -ra containers <<< "$VMQ_CONTAINERS"
    local total=0
    for i in "${!containers[@]}"; do
        local val
        val=$(get_vmq_metric "$i" "$metric_name") || val=0
        total=$(( total + val ))
    done
    echo "$total"
}

# ---------------------------------------------------------------------------
# Cluster health
# ---------------------------------------------------------------------------

assert_cluster_healthy() {
    local label="${1:-pre-phase}"
    local expected_nodes
    expected_nodes=$(vmq_node_count)
    local max_wait="${2:-60}"

    log_info "Asserting cluster health ($label)..."

    wait_cluster_ready "$expected_nodes" "$max_wait"

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

wait_connections_drained() {
    local target="${1:-0}"
    local max_wait="${2:-120}"
    local interval=5
    local elapsed=0

    log_info "Waiting for connections to drain to $target (timeout: ${max_wait}s)..."

    while (( elapsed < max_wait )); do
        local open closed active
        open=$(get_vmq_metric_sum "socket_open") || open=0
        closed=$(get_vmq_metric_sum "socket_close") || closed=0
        active=$(( open - closed ))
        (( active < 0 )) && active=0

        if (( active <= target )); then
            log_info "Connections drained: $active active (target: $target)"
            return 0
        fi
        log_info "Draining connections: $active active, waiting..."
        sleep "$interval"
        (( elapsed += interval ))
    done

    log_error "Connections not drained within ${max_wait}s"
    return 1
}

wait_subscriptions_converged() {
    local max_wait="${1:-120}"
    local stable_for="${2:-10}"
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

verify_clean_state() {
    local label="${1:-pre-phase}"
    local max_conns="${2:-100}"

    log_info "Verifying clean state ($label)..."

    local open closed active
    open=$(get_vmq_metric_sum "socket_open") || open=0
    closed=$(get_vmq_metric_sum "socket_close") || closed=0
    active=$(( open - closed ))
    (( active < 0 )) && active=0

    if (( active > max_conns )); then
        log_error "DIRTY STATE ($label): $active active connections (threshold: $max_conns)"
        return 1
    fi

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

phase_cleanup() {
    local label="${1:-between-phases}"
    local drain_timeout="${2:-60}"

    log_info "Phase cleanup ($label)..."
    stop_all_emqtt_bench
    sleep 5

    wait_connections_drained 100 "$drain_timeout" || \
        log_error "WARNING: connections did not fully drain, continuing..."

    sleep 3
    log_info "Phase cleanup complete ($label)"
}

# ---------------------------------------------------------------------------
# Metrics collection
# ---------------------------------------------------------------------------

collect_metrics() {
    local tag="$1"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}/${tag}"
    mkdir -p "$out_dir"

    log_info "Collecting metrics snapshot: $tag"

    local -a containers
    read -ra containers <<< "$VMQ_CONTAINERS"
    for i in "${!containers[@]}"; do
        exec_vmq "$i" "$VMQ_ADMIN" metrics show \
            > "$out_dir/vmq_metrics_node${i}.txt" 2>/dev/null || true
    done

    log_info "Metrics saved to $out_dir"
}

# ---------------------------------------------------------------------------
# Cluster operations
# ---------------------------------------------------------------------------

wait_cluster_ready() {
    local expected_nodes="$1"
    local max_wait="${2:-120}"
    local interval=5
    local elapsed=0

    log_info "Waiting for cluster to have $expected_nodes running nodes (timeout: ${max_wait}s)"

    while (( elapsed < max_wait )); do
        local running
        running=$(exec_vmq 0 "$VMQ_ADMIN" cluster show 2>/dev/null \
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

# ---------------------------------------------------------------------------
# Utility
# ---------------------------------------------------------------------------

vmq_node_count() {
    local -a containers
    read -ra containers <<< "$VMQ_CONTAINERS"
    echo "${#containers[@]}"
}

vmq_host_list() {
    local -a containers
    read -ra containers <<< "$VMQ_CONTAINERS"
    local result=""
    for c in "${containers[@]}"; do
        if [[ -n "$result" ]]; then
            result="${result},${c}"
        else
            result="${c}"
        fi
    done
    echo "$result"
}

vmq_host_subset() {
    local result=""
    for idx in "$@"; do
        local container
        container=$(_vmq_container_at "$idx")
        if [[ -n "$result" ]]; then
            result="${result},${container}"
        else
            result="${container}"
        fi
    done
    echo "$result"
}

vmq_host_first_n() {
    local n="$1"
    local result=""
    for (( i=0; i<n; i++ )); do
        local container
        container=$(_vmq_container_at "$i")
        if [[ -n "$result" ]]; then
            result="${result},${container}"
        else
            result="${container}"
        fi
    done
    echo "$result"
}

# Scale load for local Docker environment
# base: original load for ref_nodes nodes on c6i.2xlarge
# ref_nodes: original cluster size the load was designed for
# Result: base * actual_nodes * LOCAL_SCALE / ref_nodes
scale_load_local() {
    local base="$1" ref_nodes="$2"
    local actual
    actual=$(vmq_node_count)
    awk "BEGIN { v = int($base * $actual * $LOCAL_SCALE / $ref_nodes); if (v < 1) v = 1; printf \"%d\", v }"
}

distribute_connections() {
    local total="$1" num="$2"
    local per=$(( total / num ))
    local remainder=$(( total % num ))
    for (( i=0; i<num; i++ )); do
        if (( i < remainder )); then
            echo $(( per + 1 ))
        else
            echo "$per"
        fi
    done
}

# ---------------------------------------------------------------------------
# Scenario lifecycle
# ---------------------------------------------------------------------------

init_scenario() {
    local scenario_name="$1"
    SCENARIO_TAG="${SCENARIO_TAG:-$scenario_name}"
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}"
    mkdir -p "$out_dir"

    SCENARIO_START_EPOCH=$(date +%s)

    log_info "Scenario: $scenario_name"
    log_info "Results dir: $out_dir"
    log_info "VMQ containers: $VMQ_CONTAINERS ($(vmq_node_count) nodes)"
    log_info "LOCAL_SCALE: $LOCAL_SCALE"

    {
        echo "scenario,$scenario_name"
        echo "start,$(_ts)"
        echo "start_epoch,$SCENARIO_START_EPOCH"
        echo "vmq_containers,$VMQ_CONTAINERS"
        echo "vmq_node_count,$(vmq_node_count)"
        echo "local_scale,$LOCAL_SCALE"
    } > "$out_dir/metadata.csv"

    local total_nodes
    total_nodes=$(vmq_node_count)
    if (( total_nodes > 1 )); then
        assert_cluster_healthy "init_scenario" 120
    fi

    verify_clean_state "init_scenario" 500 || \
        log_error "WARNING: Cluster not in clean state. Results may be affected."

    collect_metrics "scenario_baseline"
}

finish_scenario() {
    local out_dir="${RESULTS_DIR}/${SCENARIO_TAG}"
    SCENARIO_END_EPOCH=$(date +%s)
    echo "end,$(_ts)" >> "$out_dir/metadata.csv"
    echo "end_epoch,$SCENARIO_END_EPOCH" >> "$out_dir/metadata.csv"

    stop_all_emqtt_bench
    sleep 5

    collect_metrics "scenario_final"

    # Report cluster_bytes_dropped delta
    local baseline_dir="${out_dir}/scenario_baseline"
    local final_dir="${out_dir}/scenario_final"
    if [[ -d "$baseline_dir" && -d "$final_dir" ]]; then
        local -a containers
        read -ra containers <<< "$VMQ_CONTAINERS"
        local total_dropped=0
        for i in "${!containers[@]}"; do
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

    log_info "Scenario complete. Results in $out_dir"
}
