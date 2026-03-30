#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Flink on YARN 部署脚本
# 支持在线下载和离线安装两种模式
# ============================================================

trap 'log_error "脚本执行出错，行号: $LINENO"' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/env.sh"

log_info() { printf "[%s] 信息: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_warn() { printf "[%s] 警告: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { printf "[%s] 错误: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && printf "[%s] 调试: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

DRY_RUN=false

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

部署 Flink on YARN Session Cluster。

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
prepare_package() {
    local -r pkg_path="$(get_package_path "$FLINK_PACKAGE")"

    if [[ -f "$pkg_path" ]]; then
        log_info "Flink 安装包已存在: $pkg_path"
        return 0
    fi

    if [[ "$INSTALL_MODE" == "offline" ]]; then
        log_error "离线模式下安装包不存在: $pkg_path"
        log_info "请将 ${FLINK_PACKAGE} 放入 ${OFFLINE_DIR}/ 目录"
        return 1
    fi

    log_info "在线下载 Flink ${FLINK_VERSION}..."
    mkdir -p "$(dirname "$pkg_path")"
    run_cmd curl -L -o "$pkg_path" "$FLINK_DOWNLOAD_URL" || { log_error "Flink 下载失败"; return 1; }
}

# ==================== 生成 Flink 配置 ====================
generate_flink_configs() {
    log_info "生成 Flink 配置文件..."

    cat > "$TMPDIR/flink-conf.yaml" <<EOF
jobmanager.rpc.address: ${MASTER_HOST}
jobmanager.rpc.port: 6123
jobmanager.memory.process.size: ${FLINK_JM_HEAP_SIZE}
taskmanager.memory.process.size: ${FLINK_TM_PROCESS_SIZE}
taskmanager.numberOfTaskSlots: 2
parallelism.default: 2
highAvailability: zookeeper
highAvailability.zookeeper.quorum: $(IFS=,; echo "${ZK_HOSTS[*]}"):${ZK_CLIENT_PORT}
highAvailability.zookeeper.path.root: /flink
highAvailability.storageDir: hdfs://${MASTER_HOST}:${HDFS_NAMENODE_RPC_PORT}/flink/ha/
state.backend: hashmap
state.checkpoints.dir: hdfs://${MASTER_HOST}:${HDFS_NAMENODE_RPC_PORT}/flink/checkpoints
state.savepoints.dir: hdfs://${MASTER_HOST}:${HDFS_NAMENODE_RPC_PORT}/flink/savepoints
execution.checkpointing.interval: 60000
execution.checkpointing.mode: EXACTLY_ONCE
classloader.resolve-order: child-first
rest.port: ${FLINK_JOBMANAGER_PORT}
rest.address: ${MASTER_HOST}
env.java.opts: "-Dlog4j2.formatMsgNoLookups=true"
metrics.reporters: prom
metrics.reporter.prom.factory.class: org.apache.flink.metrics.prometheus.PrometheusReporterFactory
metrics.reporter.prom.port: 9250
EOF

    cat > "$TMPDIR/masters" <<EOF
${MASTER_HOST}:${FLINK_JOBMANAGER_PORT}
EOF
    cat > "$TMPDIR/workers" <<EOF
$(printf '%s\n' "${WORKER_HOSTS[@]}")
EOF
}

# ==================== 安装 Flink ====================
install_flink_on_master() {
    local -r pkg_path="$(get_package_path "$FLINK_PACKAGE")"
    local remote_pkg="${DOWNLOAD_DIR}/${FLINK_PACKAGE}"

    log_info "=== 在 ${MASTER_HOST} 上安装 Flink (模式: ${INSTALL_MODE}) ==="

    remote_exec "$MASTER_HOST" "mkdir -p $INSTALL_DIR $DOWNLOAD_DIR $FLINK_LOG_DIR"

    # 检查远程服务器是否已有安装包，没有才传输
    local remote_exists=false
    if remote_exec "$MASTER_HOST" "test -f '$remote_pkg'" >/dev/null 2>&1; then
        remote_exists=true
    fi

    if [[ "$remote_exists" == "true" ]]; then
        log_info "远程已有安装包，跳过传输: ${MASTER_HOST}:${remote_pkg}"
    else
        log_info "传输安装包到 ${MASTER_HOST}..."
        remote_copy "$pkg_path" "$MASTER_HOST" "$DOWNLOAD_DIR/"
    fi

    remote_exec "$MASTER_HOST" bash -s <<REMOTE_SCRIPT
set -e
if [[ ! -d "${FLINK_HOME_DIR}" ]]; then
    tar -xzf "${DOWNLOAD_DIR}/${FLINK_PACKAGE}" -C "${INSTALL_DIR}"
    FLINK_DIR=\$(ls -d "${INSTALL_DIR}"/flink-* 2>/dev/null | head -1)
    ln -sf "\${FLINK_DIR}" "${FLINK_HOME_DIR}"
fi
echo "Flink 安装完成"
REMOTE_SCRIPT
}

distribute_flink_configs() {
    log_info "分发 Flink 配置..."
    local conf_dir="${FLINK_HOME_DIR}/conf"
    for config_file in flink-conf.yaml masters workers; do
        remote_copy "$TMPDIR/$config_file" "$MASTER_HOST" "$conf_dir/"
    done

    remote_exec "$MASTER_HOST" bash -s <<REMOTE_SCRIPT
set -e
chown -R ${DEPLOY_USER}:${DEPLOY_GROUP} "${FLINK_HOME_DIR}" "${FLINK_LOG_DIR}" 2>/dev/null || true
REMOTE_SCRIPT
}

setup_flink_env() {
    local -r host="$1"
    remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e
cat > /etc/profile.d/bigdata_flink.sh <<ENVEOF
export FLINK_HOME=${FLINK_HOME_DIR}
export PATH=\${FLINK_HOME}/bin:\$PATH
ENVEOF
REMOTE_SCRIPT
}

start_flink_session() {
    log_info "=== 启动 Flink Session Cluster on YARN ==="

    remote_exec "$MASTER_HOST" bash -s <<REMOTE_SCRIPT
set -e
export JAVA_HOME=${JAVA_HOME_DIR}
export HADOOP_HOME=${HADOOP_HOME_DIR}
export HADOOP_CONF_DIR=\${HADOOP_HOME}/etc/hadoop
export FLINK_HOME=${FLINK_HOME_DIR}

EXISTING_APP=\$(yarn application -list 2>/dev/null | grep "Flink session" | head -1) || true
if [[ -n "\$EXISTING_APP" ]]; then
    echo "Flink YARN Session 已存在，跳过启动"
    exit 0
fi

echo "启动 Flink YARN Session Cluster..."
su - ${DEPLOY_USER} -c '
    export JAVA_HOME=${JAVA_HOME_DIR}
    export HADOOP_HOME=${HADOOP_HOME_DIR}
    export HADOOP_CONF_DIR=\${HADOOP_HOME}/etc/hadoop
    export FLINK_HOME=${FLINK_HOME_DIR}
    \${FLINK_HOME}/bin/yarn-session.sh -jm ${FLINK_JM_HEAP_SIZE} -tm ${FLINK_TM_HEAP_SIZE} -s 2 -nm "flink-session-cluster" -d
'
echo "Flink YARN Session 启动命令已提交"
REMOTE_SCRIPT

    sleep 10
}

verify_deployment() {
    log_info "=== 验证 Flink 部署 ==="
    local yarn_apps
    yarn_apps=$(remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c 'export JAVA_HOME=${JAVA_HOME_DIR}; export HADOOP_HOME=${HADOOP_HOME_DIR}; yarn application -list 2>/dev/null'" 2>/dev/null) || true
    echo "$yarn_apps" | grep -qi "flink" && log_info "Flink YARN Session 运行正常" || log_warn "未检测到运行中的 Flink YARN Session"
    log_info "YARN UI: http://${MASTER_HOST}:${YARN_RESOURCEMANAGER_PORT}"
}

main() {
    log_info "========================================"
    log_info "  Flink on YARN 部署"
    log_info "========================================"
    log_info "安装模式: ${INSTALL_MODE}"
    [[ "$INSTALL_MODE" == "offline" ]] && log_info "离线目录: ${OFFLINE_DIR}"
    log_info "Flink 版本: ${FLINK_VERSION}"

    prepare_package
    generate_flink_configs
    install_flink_on_master
    distribute_flink_configs
    setup_flink_env "$MASTER_HOST"
    start_flink_session
    verify_deployment

    log_info "========================================"
    log_info "  Flink on YARN 部署完成"
    log_info "========================================"
}

main "$@"
