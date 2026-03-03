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
EOF
if [[ -n "$AUTH_ENV_BLOCK" ]]; then
    echo "$AUTH_ENV_BLOCK" >> "$OUTPUT"
fi
cat >> "$OUTPUT" <<EOF
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
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
EOF
    if [[ -n "$AUTH_ENV_BLOCK" ]]; then
        echo "$AUTH_ENV_BLOCK" >> "$OUTPUT"
    fi
    cat >> "$OUTPUT" <<EOF
    ulimits:
      nofile:
        soft: 262144
        hard: 262144
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
        soft: 262144
        hard: 262144
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
