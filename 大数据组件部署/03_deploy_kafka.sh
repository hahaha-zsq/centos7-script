#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Kafka 集群部署脚本
# 支持在线下载和离线安装两种模式
# ============================================================

trap 'log_error "脚本执行出错，行号: $LINENO"' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/env.sh"

# Set alternative default ports to avoid common conflicts
# These can be overridden by env.sh or environment variables
: "${ZK_CLIENT_PORT:=2182}"  # Changed from default 2181
: "${ZK_PEER_PORT:=2889}"    # Changed from default 2888
: "${ZK_ELECTION_PORT:=3889}" # Changed from default 3888
: "${KAFKA_PORT:=9093}"      # Changed from default 9092

# Validate port numbers are in valid range
validate_port() {
    local port="$1"
    local name="$2"
    
    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        log_error "Invalid $name port: $port (must be between 1-65535)"
        return 1
    fi
    return 0
}

# Validate all ports
validate_port "$ZK_CLIENT_PORT" "ZooKeeper client" || exit 1
validate_port "$ZK_PEER_PORT" "ZooKeeper peer" || exit 1
validate_port "$ZK_ELECTION_PORT" "ZooKeeper election" || exit 1
validate_port "$KAFKA_PORT" "Kafka" || exit 1

# Check for port conflicts between ZooKeeper and Kafka ports
if [ "$ZK_CLIENT_PORT" -eq "$ZK_PEER_PORT" ] || [ "$ZK_CLIENT_PORT" -eq "$ZK_ELECTION_PORT" ] || [ "$ZK_CLIENT_PORT" -eq "$KAFKA_PORT" ] || \
   [ "$ZK_PEER_PORT" -eq "$ZK_ELECTION_PORT" ] || [ "$ZK_PEER_PORT" -eq "$KAFKA_PORT" ] || \
   [ "$ZK_ELECTION_PORT" -eq "$KAFKA_PORT" ]; then
    log_error "Port conflict detected: ZooKeeper client (${ZK_CLIENT_PORT}), peer (${ZK_PEER_PORT}), election (${ZK_ELECTION_PORT}), and Kafka (${KAFKA_PORT}) ports must be unique"
    exit 1
fi

log_info() { printf "[%s] 信息: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_warn() { printf "[%s] 警告: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { printf "[%s] 错误: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && printf "[%s] 调试: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

DRY_RUN=false

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

部署 Kafka 集群 (ZooKeeper 模式)。

选项:
    -m, --mode MODE   安装模式: online(在线) | offline(离线)，默认: ${INSTALL_MODE}
    -d, --dry-run     试运行模式
    -v, --verbose     启用详细输出
    -h, --help        显示此帮助信息
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)
            INSTALL_MODE="$2"
            [[ "$INSTALL_MODE" == "online" || "$INSTALL_MODE" == "offline" ]] || { log_error "无效的安装模式: $INSTALL_MODE"; exit 1; }
            shift 2 ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -v|--verbose) DEBUG=1; shift ;;
        -h|--help) usage 0 ;;
        *) log_error "未知选项: $1"; usage 1 ;;
    esac
done

TMPDIR=""
cleanup() { [[ -n "${TMPDIR:-}" && -d "${TMPDIR:-}" ]] && rm -rf -- "$TMPDIR"; }
trap cleanup EXIT
TMPDIR=$(mktemp -d) || { log_error "创建临时目录失败"; exit 1; }

run_cmd() { [[ "$DRY_RUN" == "true" ]] && { log_info "[试运行] $*"; return 0; }; "$@"; }
remote_exec() { local -r host="$1"; shift; ssh -i "$SSH_IDENTITY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" -p "$SSH_PORT" "root@${host}" "$@"; }
remote_copy() { local -r src="$1"; local -r host="$2"; local -r dst="$3"; scp -i "$SSH_IDENTITY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" -P "$SSH_PORT" -r "$src" "root@${host}:${dst}"; }

# ==================== 准备安装包 ====================
prepare_packages() {
    for entry in "${ZOOKEEPER_PACKAGE}|${ZOOKEEPER_DOWNLOAD_URL}" "${KAFKA_PACKAGE}|${KAFKA_DOWNLOAD_URL}"; do
        local pkg_name="${entry%%|*}"
        local url="${entry##*|}"
        local pkg_path
        pkg_path=$(get_package_path "$pkg_name")

        if [[ -f "$pkg_path" ]]; then
            log_info "安装包已存在: $pkg_name"
            continue
        fi

        if [[ "$INSTALL_MODE" == "offline" ]]; then
            log_error "离线模式下安装包不存在: $pkg_path"
            log_info "请将 ${pkg_name} 放入 ${OFFLINE_DIR}/ 目录"
            return 1
        fi

        log_info "在线下载 ${pkg_name}..."
        mkdir -p "$(dirname "$pkg_path")"
        run_cmd curl -L -o "$pkg_path" "$url" || { log_error "下载失败: ${pkg_name}"; return 1; }
    done
}

# ==================== ZooKeeper 配置 ====================
generate_zk_configs() {
    log_info "生成 ZooKeeper 配置..."

    local zk_connect=""
    for h in "${ZK_HOSTS[@]}"; do
        [[ -n "$zk_connect" ]] && zk_connect+=","
        zk_connect+="${h}:${ZK_CLIENT_PORT}"
    done
    echo "$zk_connect" > "$TMPDIR/zk_connect"

    cat > "$TMPDIR/zoo.cfg" <<EOF
tickTime=2000
initLimit=10
syncLimit=5
dataDir=${ZK_DATA_DIR}/data
dataLogDir=${ZK_DATA_DIR}/log
clientPort=${ZK_CLIENT_PORT}
maxClientCnxns=60
autopurge.snapRetainCount=3
autopurge.purgeInterval=1
EOF

    for i in "${!ZK_HOSTS[@]}"; do
        echo "server.$((i + 1))=${ZK_HOSTS[$i]}:${ZK_PEER_PORT}:${ZK_ELECTION_PORT}" >> "$TMPDIR/zoo.cfg"
    done
}

install_zk_on_host() {
    local -r host="$1"
    local -r pkg_path="$(get_package_path "$ZOOKEEPER_PACKAGE")"
    local zk_id
    zk_id=$(get_zk_id "$host")
    local remote_pkg="${DOWNLOAD_DIR}/${ZOOKEEPER_PACKAGE}"

    log_info "=== 在 ${host} 上安装 ZooKeeper (myid=${zk_id}) ==="

    remote_exec "$host" "mkdir -p $INSTALL_DIR $DOWNLOAD_DIR $ZK_DATA_DIR/data $ZK_DATA_DIR/log $LOG_BASE_DIR/zookeeper"

    # 检查远程服务器是否已有安装包，没有才传输
    local remote_exists=false
    if remote_exec "$host" "test -f '$remote_pkg'" >/dev/null 2>&1; then
        remote_exists=true
    fi

    if [[ "$remote_exists" == "true" ]]; then
        log_info "远程已有安装包，跳过传输: ${host}:${remote_pkg}"
    else
        log_info "传输安装包到 ${host}..."
        remote_copy "$pkg_path" "$host" "$DOWNLOAD_DIR/"
    fi

    remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e
if [[ ! -d "${ZOOKEEPER_HOME_DIR}" ]]; then
    tar -xzf "${DOWNLOAD_DIR}/${ZOOKEEPER_PACKAGE}" -C "${INSTALL_DIR}"
    ZK_DIR=\$(ls -d "${INSTALL_DIR}"/apache-zookeeper-* 2>/dev/null | head -1)
    ln -sf "\${ZK_DIR}" "${ZOOKEEPER_HOME_DIR}"
fi
echo "${zk_id}" > "${ZK_DATA_DIR}/data/myid"
cp "${DOWNLOAD_DIR}/zoo.cfg" "${ZOOKEEPER_HOME_DIR}/conf/zoo.cfg"
chown -R ${DEPLOY_USER}:${DEPLOY_GROUP} "${ZK_DATA_DIR}" "${ZOOKEEPER_HOME_DIR}" 2>/dev/null || true
echo "ZooKeeper 安装完成, myid=${zk_id}"
REMOTE_SCRIPT
}

# ==================== Kafka 配置 ====================
generate_kafka_configs() {
    log_info "生成 Kafka 配置..."
    local zk_connect
    zk_connect=$(cat "$TMPDIR/zk_connect")

    for i in "${!KAFKA_BROKERS[@]}"; do
        local host="${KAFKA_BROKERS[$i]}"
        local broker_id=$((i + 1))

        cat > "$TMPDIR/server-${broker_id}.properties" <<EOF
broker.id=${broker_id}
listeners=PLAINTEXT://${host}:${KAFKA_PORT}
advertised.listeners=PLAINTEXT://${host}:${KAFKA_PORT}
num.network.threads=3
num.io.threads=8
socket.send.buffer.bytes=102400
socket.receive.buffer.bytes=102400
socket.request.max.bytes=104857600
log.dirs=${KAFKA_DATA_DIR}/logs-${broker_id}
num.partitions=${KAFKA_NUM_PARTITIONS}
num.recovery.threads.per.data.dir=1
offsets.topic.replication.factor=${KAFKA_DEFAULT_REPLICATION_FACTOR}
transaction.state.log.replication.factor=${KAFKA_DEFAULT_REPLICATION_FACTOR}
transaction.state.log.min.isr=${KAFKA_MIN_INSYNC_REPLICAS}
log.retention.hours=${KAFKA_LOG_RETENTION_HOURS}
log.retention.bytes=${KAFKA_LOG_RETENTION_BYTES}
log.segment.bytes=${KAFKA_LOG_SEGMENT_BYTES}
log.retention.check.interval.ms=300000
zookeeper.connect=${zk_connect}
zookeeper.connection.timeout.ms=18000
group.initial.rebalance.delay.ms=0
EOF
    done
}

install_kafka_on_host() {
    local -r host="$1"
    local -r pkg_path="$(get_package_path "$KAFKA_PACKAGE")"
    local broker_id
    broker_id=$(get_kafka_broker_id "$host")
    local remote_pkg="${DOWNLOAD_DIR}/${KAFKA_PACKAGE}"

    log_info "=== 在 ${host} 上安装 Kafka (broker.id=${broker_id}) ==="

    remote_exec "$host" "mkdir -p $INSTALL_DIR $DOWNLOAD_DIR ${KAFKA_DATA_DIR}/logs-${broker_id} $KAFKA_LOG_DIR"

    # 检查远程服务器是否已有安装包，没有才传输
    local remote_exists=false
    if remote_exec "$host" "test -f '$remote_pkg'" >/dev/null 2>&1; then
        remote_exists=true
    fi

    if [[ "$remote_exists" == "true" ]]; then
        log_info "远程已有安装包，跳过传输: ${host}:${remote_pkg}"
    else
        log_info "传输安装包到 ${host}..."
        remote_copy "$pkg_path" "$host" "$DOWNLOAD_DIR/"
    fi

    # 传输配置文件
    remote_copy "$TMPDIR/server-${broker_id}.properties" "$host" "$DOWNLOAD_DIR/"

    remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e
if [[ ! -d "${KAFKA_HOME_DIR}" ]]; then
    tar -xzf "${DOWNLOAD_DIR}/${KAFKA_PACKAGE}" -C "${INSTALL_DIR}"
    KAFKA_DIR=\$(ls -d "${INSTALL_DIR}"/kafka_* 2>/dev/null | head -1)
    ln -sf "\${KAFKA_DIR}" "${KAFKA_HOME_DIR}"
fi
cp "${DOWNLOAD_DIR}/server-${broker_id}.properties" "${KAFKA_HOME_DIR}/config/server.properties"
chown -R ${DEPLOY_USER}:${DEPLOY_GROUP} "${KAFKA_DATA_DIR}" "${KAFKA_HOME_DIR}" "${KAFKA_LOG_DIR}" 2>/dev/null || true
echo "Kafka 安装完成"
REMOTE_SCRIPT
}

setup_kafka_env() {
    local -r host="$1"
    remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e
cat > /etc/profile.d/bigdata_kafka.sh <<ENVEOF
export KAFKA_HOME=${KAFKA_HOME_DIR}
export PATH=\${KAFKA_HOME}/bin:\$PATH
ENVEOF
REMOTE_SCRIPT
}

# ==================== 启动服务 ====================
start_zookeeper() {
    log_info "=== 启动 ZooKeeper 集群 ==="
    for host in "${ZK_HOSTS[@]}"; do
        # 检查是否已运行
        local zk_running
        zk_running=$(remote_exec "$host" "su - ${DEPLOY_USER} -c '${ZOOKEEPER_HOME_DIR}/bin/zkServer.sh status'" 2>/dev/null) || true
        if echo "$zk_running" | grep -q "Mode"; then
            log_info "ZooKeeper 已运行 on ${host}，跳过启动"
            continue
        fi

        log_info "启动 ZooKeeper on ${host}..."
        remote_exec "$host" "su - ${DEPLOY_USER} -c '${ZOOKEEPER_HOME_DIR}/bin/zkServer.sh start'" || { log_error "ZooKeeper 启动失败: ${host}"; return 1; }
    done
    sleep 5
    for host in "${ZK_HOSTS[@]}"; do
        local status
        status=$(remote_exec "$host" "su - ${DEPLOY_USER} -c '${ZOOKEEPER_HOME_DIR}/bin/zkServer.sh status'" 2>/dev/null) || true
        echo "$status" | grep -q "Mode" && log_info "ZooKeeper ${host}: $(echo "$status" | grep "Mode" | awk '{print $2}')"
    done
}

start_kafka() {
    log_info "=== 启动 Kafka 集群 ==="
    for host in "${KAFKA_BROKERS[@]}"; do
        local broker_id
        broker_id=$(get_kafka_broker_id "$host")

        # 检查 Kafka 进程是否已运行
        local kafka_pid
        kafka_pid=$(remote_exec "$host" "pgrep -f 'kafka\.Kafka' 2>/dev/null || pgrep -f 'kafka-server-start' 2>/dev/null" || true)
        if [[ -n "$kafka_pid" ]]; then
            log_info "Kafka 已运行 on ${host} (pid=${kafka_pid})，跳过启动"
            continue
        fi

        log_info "启动 Kafka Broker on ${host} (id=${broker_id})..."
        remote_exec "$host" "su - ${DEPLOY_USER} -c 'nohup ${KAFKA_HOME_DIR}/bin/kafka-server-start.sh ${KAFKA_HOME_DIR}/config/server.properties > ${KAFKA_LOG_DIR}/kafka-server.log 2>&1 &'" || { log_error "Kafka 启动失败: ${host}"; return 1; }
        sleep 3
    done
    sleep 5
}

# ==================== 验证 ====================
verify_deployment() {
    log_info "=== 验证 Kafka 部署 ==="
    local first_broker="${KAFKA_BROKERS[0]}"
    remote_exec "$first_broker" "su - ${DEPLOY_USER} -c '${KAFKA_HOME_DIR}/bin/kafka-topics.sh --list --bootstrap-server ${first_broker}:${KAFKA_PORT}'" 2>/dev/null && log_info "Kafka 集群连接正常" || log_warn "Kafka 集群连接异常"
    log_info "ZooKeeper: $(cat "$TMPDIR/zk_connect")"
}

# ==================== 主函数 ====================
main() {
    log_info "========================================"
    log_info "  Kafka 集群部署"
    log_info "========================================"
    log_info "安装模式: ${INSTALL_MODE}"
    [[ "$INSTALL_MODE" == "offline" ]] && log_info "离线目录: ${OFFLINE_DIR}"
    log_info "ZooKeeper 节点: ${ZK_HOSTS[*]}"
    log_info "Kafka Brokers: ${KAFKA_BROKERS[*]}"

    prepare_packages
    generate_zk_configs

    for host in "${ZK_HOSTS[@]}"; do install_zk_on_host "$host"; done
    start_zookeeper

    generate_kafka_configs
    for host in "${KAFKA_BROKERS[@]}"; do
        install_kafka_on_host "$host"
        setup_kafka_env "$host"
    done
    start_kafka
    verify_deployment

    log_info "========================================"
    log_info "  Kafka 集群部署完成"
    log_info "========================================"
}

main "$@"
