#!/usr/bin/env bash
# generate_compose.sh - Generate docker-compose.yml for N VMQ nodes + optional monitoring.
#
# Usage:
#   ./generate_compose.sh --nodes 3                    # 3 VMQ nodes + bench
#   ./generate_compose.sh --nodes 5 --monitoring       # 5 VMQ nodes + bench + Prometheus/Grafana
#   ./generate_compose.sh --nodes 3 --output /tmp/dc.yml

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
NUM_NODES=3
MONITORING=0
OUTPUT="${SCRIPT_DIR}/docker-compose.yml"
VMQ_IMAGE="vmq-local-bench"
BENCH_IMAGE="emqtt-bench-local"
LB=0
AUTH=1
AUTH_USER=""
AUTH_PASS=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --nodes)      NUM_NODES="$2"; shift 2 ;;
        --monitoring) MONITORING=1; shift ;;
        --output)     OUTPUT="$2"; shift 2 ;;
        --vmq-image)  VMQ_IMAGE="$2"; shift 2 ;;
        --bench-image) BENCH_IMAGE="$2"; shift 2 ;;
        --lb)         LB=1; shift ;;
        --auth-user)  AUTH_USER="$2"; shift 2 ;;
        --auth-pass)  AUTH_PASS="$2"; shift 2 ;;
        --auth)       AUTH=1; shift ;;
        --no-auth)    AUTH=0; shift ;;
        -h|--help)
            echo "Usage: $(basename "$0") [--nodes N] [--monitoring] [--lb] [--output PATH]"
            exit 0 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if (( NUM_NODES < 1 )); then
    echo "ERROR: --nodes must be >= 1"
    exit 1
fi

# ---------------------------------------------------------------------------
# Read tunables from profile (single source of truth)
# ---------------------------------------------------------------------------
PROFILE_YAML="${SCRIPT_DIR}/../profiles/default.yaml"
BASE_ENV_BLOCK=""
INTEGRATION_ENV_BLOCK=""

if [[ -f "$PROFILE_YAML" ]]; then
    # Map profile YAML keys → VMQ_ env var names
    # Uses simple grep/sed — no python/yq dependency
    read_tunable() {
        local key="$1" envvar="$2" target="${3:-base}"
        local val
        val=$(grep -E "^\s+${key}:" "$PROFILE_YAML" | head -1 | sed 's/.*: *//; s/"//g; s/ *$//')
        if [[ -n "$val" ]]; then
            # Allow env override
            val="${!envvar:-$val}"
            if [[ "$target" == "integration" ]]; then
                INTEGRATION_ENV_BLOCK="${INTEGRATION_ENV_BLOCK}      ${envvar}: \"${val}\"
"
            else
                BASE_ENV_BLOCK="${BASE_ENV_BLOCK}      ${envvar}: \"${val}\"
"
            fi
        fi
    }

    # --- Base tunables (all versions) ---

    # Erlang VM
    read_tunable erlang_async_threads             VMQ_ERLANG_ASYNC_THREADS
    read_tunable erlang_max_ports                 VMQ_ERLANG_MAX_PORTS
    read_tunable erlang_max_processes             VMQ_ERLANG_MAX_PROCESSES
    read_tunable erlang_distribution_buffer_size  VMQ_ERLANG_DISTRIBUTION_BUFFER_SIZE

    # Listeners
    read_tunable mqtt_listener_max_connections    VMQ_MQTT_LISTENER_MAX_CONNECTIONS
    read_tunable mqtt_listener_nr_of_acceptors    VMQ_MQTT_LISTENER_NR_OF_ACCEPTORS
    read_tunable listener_max_connections         VMQ_LISTENER_MAX_CONNECTIONS
    read_tunable listener_nr_of_acceptors         VMQ_LISTENER_NR_OF_ACCEPTORS
    read_tunable tcp_listen_options               VMQ_TCP_LISTEN_OPTIONS
    read_tunable listener_tcp_allowed_protocol_versions  VMQ_LISTENER_TCP_ALLOWED_PROTOCOL_VERSIONS
    read_tunable listener_tcp_proxy_protocol      VMQ_LISTENER_TCP_PROXY_PROTOCOL
    read_tunable listener_ws_allowed_protocol_versions   VMQ_LISTENER_WS_ALLOWED_PROTOCOL_VERSIONS
    read_tunable listener_ws_proxy_protocol       VMQ_LISTENER_WS_PROXY_PROTOCOL

    # Queue / message settings
    read_tunable max_inflight_messages            VMQ_MAX_INFLIGHT_MESSAGES
    read_tunable max_online_messages              VMQ_MAX_ONLINE_MESSAGES
    read_tunable max_offline_messages             VMQ_MAX_OFFLINE_MESSAGES
    read_tunable queue_deliver_mode               VMQ_QUEUE_DELIVER_MODE
    read_tunable queue_type                       VMQ_QUEUE_TYPE
    read_tunable max_message_rate                 VMQ_MAX_MESSAGE_RATE
    read_tunable max_message_size                 VMQ_MAX_MESSAGE_SIZE
    read_tunable upgrade_outgoing_qos             VMQ_UPGRADE_OUTGOING_QOS

    # MQTT protocol
    read_tunable mqtt_connect_timeout             VMQ_MQTT_CONNECT_TIMEOUT
    read_tunable disconnect_on_unauthorized_publish_v3  VMQ_DISCONNECT_ON_UNAUTH_PUB_V3
    read_tunable persistent_client_expiration     VMQ_PERSISTENT_CLIENT_EXPIRATION

    # Session / registration
    read_tunable coordinate_registrations         VMQ_COORDINATE_REGISTRATIONS
    read_tunable shared_subscription_policy       VMQ_SHARED_SUBSCRIPTION_POLICY

    # Netsplit behavior
    read_tunable allow_register_during_netsplit    VMQ_ALLOW_REGISTER_DURING_NETSPLIT
    read_tunable allow_publish_during_netsplit     VMQ_ALLOW_PUBLISH_DURING_NETSPLIT
    read_tunable allow_subscribe_during_netsplit   VMQ_ALLOW_SUBSCRIBE_DURING_NETSPLIT
    read_tunable allow_unsubscribe_during_netsplit VMQ_ALLOW_UNSUBSCRIBE_DURING_NETSPLIT

    # Storage
    read_tunable leveldb_maximum_memory_percent   VMQ_LEVELDB_MAX_MEM_PCT

    # --- 2.x+ tunables ---
    read_tunable outgoing_clustering_buffer_size  VMQ_OUTGOING_CLUSTERING_BUFFER_SIZE

    # --- Integration-only tunables ---
    if [[ "${VMQ_VERSION_FAMILY:-2.x}" == "integration" ]]; then
        # Cluster health
        read_tunable cluster_ready_quorum         VMQ_CLUSTER_READY_QUORUM          integration
        read_tunable cluster_ready_rpc_timeout    VMQ_CLUSTER_READY_RPC_TIMEOUT     integration
        read_tunable dead_node_cleanup_timeout    VMQ_DEAD_NODE_CLEANUP_TIMEOUT     integration

        # Registry
        read_tunable reg_trie_workers             VMQ_REG_TRIE_WORKERS              integration
        read_tunable reg_sync_shards              VMQ_REG_SYNC_SHARDS               integration

        # Clustering connections
        read_tunable outgoing_clustering_connection_count       VMQ_OUTGOING_CLUSTERING_CONNECTION_COUNT    integration
        read_tunable outgoing_clustering_reconnect_base_delay   VMQ_OUTGOING_CLUSTERING_RECONNECT_BASE_DELAY integration
        read_tunable outgoing_clustering_reconnect_max_delay    VMQ_OUTGOING_CLUSTERING_RECONNECT_MAX_DELAY  integration
        read_tunable outgoing_clustering_buffer_drop_policy     VMQ_OUTGOING_CLUSTERING_BUFFER_DROP_POLICY   integration

        # Balance
        read_tunable balance_enabled              VMQ_BALANCE_ENABLED               integration
        read_tunable balance_reject_enabled       VMQ_BALANCE_REJECT_ENABLED        integration
        read_tunable balance_threshold            VMQ_BALANCE_THRESHOLD             integration
        read_tunable balance_hysteresis           VMQ_BALANCE_HYSTERESIS            integration
        read_tunable balance_min_connections      VMQ_BALANCE_MIN_CONNECTIONS       integration
        read_tunable balance_check_interval       VMQ_BALANCE_CHECK_INTERVAL        integration

        # Rebalance
        read_tunable rebalance_enabled            VMQ_REBALANCE_ENABLED             integration
        read_tunable rebalance_threshold          VMQ_REBALANCE_THRESHOLD           integration
        read_tunable rebalance_batch_size         VMQ_REBALANCE_BATCH_SIZE          integration
        read_tunable rebalance_cooldown           VMQ_REBALANCE_COOLDOWN            integration
        read_tunable rebalance_on_node_join       VMQ_REBALANCE_ON_NODE_JOIN        integration
        read_tunable rebalance_stable_interval    VMQ_REBALANCE_STABLE_INTERVAL     integration
        read_tunable rebalance_auto_interval      VMQ_REBALANCE_AUTO_INTERVAL       integration

        # Gossip
        read_tunable gossip_interval              VMQ_SWC_GOSSIP_INTERVAL           integration
        read_tunable fast_gossip_interval         VMQ_SWC_FAST_GOSSIP_INTERVAL      integration
        read_tunable fast_gossip_duration         VMQ_SWC_FAST_GOSSIP_DURATION      integration
    fi
fi

# ---------------------------------------------------------------------------
# Generate docker-compose.yml
# ---------------------------------------------------------------------------

cat > "$OUTPUT" <<'HEADER'
# Auto-generated — regenerate with: ./generate_compose.sh
services:
HEADER

# VMQ node 1 (seed node)
MQTT_PORT=1883
HTTP_PORT=8888

AUTH_ENV_BLOCK=""
if (( AUTH )) && [[ -n "$AUTH_USER" && -n "$AUTH_PASS" ]]; then
    AUTH_ENV_BLOCK="      VMQ_AUTH_ENABLED: \"true\"
      VMQ_AUTH_USERNAME: \"${AUTH_USER}\"
      VMQ_AUTH_PASSWORD: \"${AUTH_PASS}\""
fi

cat >> "$OUTPUT" <<EOF
  vmq1:
    build:
      context: ../..
      dockerfile: bench/local/Dockerfile
    image: ${VMQ_IMAGE}
    hostname: vmq1.local
    container_name: vmq1
    ports:
      - "${MQTT_PORT}:1883"
      - "${HTTP_PORT}:8888"
    environment:
      VMQ_NODENAME: "VerneMQ@vmq1.local"
      VMQ_COOKIE: "vmqlocalbench"
      VMQ_VERSION_FAMILY: "${VMQ_VERSION_FAMILY:-2.x}"
EOF
if [[ -n "$AUTH_ENV_BLOCK" ]]; then
    echo "$AUTH_ENV_BLOCK" >> "$OUTPUT"
fi
if [[ -n "$BASE_ENV_BLOCK" ]]; then
    printf '%s' "$BASE_ENV_BLOCK" >> "$OUTPUT"
fi
if [[ -n "$INTEGRATION_ENV_BLOCK" ]]; then
    printf '%s' "$INTEGRATION_ENV_BLOCK" >> "$OUTPUT"
fi
cat >> "$OUTPUT" <<EOF
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    sysctls:
      net.core.somaxconn: 65535
      net.ipv4.tcp_max_syn_backlog: 65535
      net.ipv4.ip_local_port_range: "1024 65535"
      net.ipv4.tcp_tw_reuse: 1
      net.ipv4.tcp_fin_timeout: 15
    volumes:
      - vmq1_data:/opt/vernemq/data
      - vmq1_log:/opt/vernemq/log
    networks:
      vmq_cluster:
        aliases:
          - vmq1.local
    healthcheck:
      test: ["CMD", "/opt/vernemq/bin/vernemq", "ping"]
      interval: 5s
      retries: 12
      start_period: 30s
      timeout: 5s

EOF

# VMQ nodes 2..N
for (( i=2; i<=NUM_NODES; i++ )); do
    MQTT_PORT=$(( 1882 + i ))
    HTTP_PORT=$(( 8887 + i ))
    cat >> "$OUTPUT" <<EOF
  vmq${i}:
    build:
      context: ../..
      dockerfile: bench/local/Dockerfile
    image: ${VMQ_IMAGE}
    hostname: vmq${i}.local
    container_name: vmq${i}
    ports:
      - "${MQTT_PORT}:1883"
      - "${HTTP_PORT}:8888"
    environment:
      VMQ_NODENAME: "VerneMQ@vmq${i}.local"
      VMQ_DISCOVERY_NODE: "VerneMQ@vmq1.local"
      VMQ_COOKIE: "vmqlocalbench"
      VMQ_VERSION_FAMILY: "${VMQ_VERSION_FAMILY:-2.x}"
EOF
    if [[ -n "$AUTH_ENV_BLOCK" ]]; then
        echo "$AUTH_ENV_BLOCK" >> "$OUTPUT"
    fi
    if [[ -n "$BASE_ENV_BLOCK" ]]; then
        printf '%s' "$BASE_ENV_BLOCK" >> "$OUTPUT"
    fi
    if [[ -n "$INTEGRATION_ENV_BLOCK" ]]; then
        printf '%s' "$INTEGRATION_ENV_BLOCK" >> "$OUTPUT"
    fi
    cat >> "$OUTPUT" <<EOF
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    sysctls:
      net.core.somaxconn: 65535
      net.ipv4.tcp_max_syn_backlog: 65535
      net.ipv4.ip_local_port_range: "1024 65535"
      net.ipv4.tcp_tw_reuse: 1
      net.ipv4.tcp_fin_timeout: 15
    volumes:
      - vmq${i}_data:/opt/vernemq/data
      - vmq${i}_log:/opt/vernemq/log
    networks:
      vmq_cluster:
        aliases:
          - vmq${i}.local
    depends_on:
      vmq1:
        condition: service_healthy
    healthcheck:
      test: ["CMD", "/opt/vernemq/bin/vernemq", "ping"]
      interval: 5s
      retries: 12
      start_period: 30s
      timeout: 5s

EOF
done

# Bench container — depends on all VMQ nodes being healthy
BENCH_DEPENDS=""
for (( i=1; i<=NUM_NODES; i++ )); do
    BENCH_DEPENDS="${BENCH_DEPENDS}      vmq${i}:
        condition: service_healthy
"
done

cat >> "$OUTPUT" <<EOF
  bench:
    build:
      context: .
      dockerfile: Dockerfile.bench
    image: ${BENCH_IMAGE}
    hostname: bench
    container_name: bench
    ulimits:
      nofile:
        soft: 1048576
        hard: 1048576
    sysctls:
      net.core.somaxconn: 65535
      net.ipv4.tcp_max_syn_backlog: 65535
      net.ipv4.ip_local_port_range: "1024 65535"
      net.ipv4.tcp_tw_reuse: 1
      net.ipv4.tcp_fin_timeout: 15
    volumes:
      - ./results:/results
    networks:
      - vmq_cluster
    depends_on:
${BENCH_DEPENDS}    command: ["tail", "-f", "/dev/null"]

EOF

# Optional HAProxy load balancer
if (( LB )); then
    # Generate HAProxy config
    mkdir -p "${SCRIPT_DIR}/haproxy"
    {
        cat <<'HAPROXY_HEADER'
global
    log stdout format raw local0
    maxconn 100000

defaults
    mode tcp
    timeout connect 5s
    timeout client  300s
    timeout server  300s

frontend mqtt_in
    bind *:1883
    default_backend vmq_nodes

backend vmq_nodes
    balance roundrobin
HAPROXY_HEADER
        for (( i=1; i<=NUM_NODES; i++ )); do
            echo "    server vmq${i} vmq${i}.local:1883 check"
        done
    } > "${SCRIPT_DIR}/haproxy/haproxy.cfg"

    cat >> "$OUTPUT" <<'EOF'
  haproxy:
    image: haproxy:2.9-alpine
    hostname: haproxy
    container_name: haproxy
    ports:
      - "11883:1883"
    volumes:
      - ./haproxy/haproxy.cfg:/usr/local/etc/haproxy/haproxy.cfg:ro
    networks:
      vmq_cluster:
        aliases:
          - lb.local
    depends_on:
      vmq1:
        condition: service_healthy

EOF
fi

# Optional monitoring services
if (( MONITORING )); then
    # Generate Prometheus config
    mkdir -p "${SCRIPT_DIR}/monitoring"
    {
        cat <<'PROM_HEADER'
global:
  scrape_interval: 5s
  evaluation_interval: 5s

scrape_configs:
  - job_name: 'vernemq'
    metrics_path: '/metrics'
    static_configs:
      - targets:
PROM_HEADER
        for (( i=1; i<=NUM_NODES; i++ )); do
            echo "          - 'vmq${i}:8888'"
        done
    } > "${SCRIPT_DIR}/monitoring/prometheus.yml"

    cat >> "$OUTPUT" <<'EOF'
  prometheus:
    image: prom/prometheus:v3.2.1
    hostname: prometheus
    container_name: prometheus
    ports:
      - "9090:9090"
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus_data:/prometheus
    networks:
      - vmq_cluster
    command:
      - '--config.file=/etc/prometheus/prometheus.yml'
      - '--storage.tsdb.path=/prometheus'
      - '--storage.tsdb.retention.time=7d'

  grafana:
    image: grafana/grafana:11.5.2
    hostname: grafana
    container_name: grafana
    ports:
      - "3000:3000"
    environment:
      GF_SECURITY_ADMIN_PASSWORD: "benchadmin"
      GF_USERS_ALLOW_SIGN_UP: "false"
    volumes:
      - grafana_data:/var/lib/grafana
    networks:
      - vmq_cluster
    depends_on:
      - prometheus

EOF
fi

# Volumes section
{
    echo "volumes:"
    for (( i=1; i<=NUM_NODES; i++ )); do
        echo "  vmq${i}_data:"
        echo "  vmq${i}_log:"
    done
    if (( MONITORING )); then
        echo "  prometheus_data:"
        echo "  grafana_data:"
    fi
} >> "$OUTPUT"

# Networks section
cat >> "$OUTPUT" <<'EOF'

networks:
  vmq_cluster:
    driver: bridge
EOF

if (( MONITORING )); then
    echo "Generated ${OUTPUT} with ${NUM_NODES} VMQ nodes + monitoring"
else
    echo "Generated ${OUTPUT} with ${NUM_NODES} VMQ nodes"
fi
