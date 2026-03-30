#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Spark on YARN 部署脚本
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

部署 Spark on YARN 客户端和 History Server。

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
    local -r pkg_path="$(get_package_path "$SPARK_PACKAGE")"

    if [[ -f "$pkg_path" ]]; then
        log_info "Spark 安装包已存在: $pkg_path"
        return 0
    fi

    if [[ "$INSTALL_MODE" == "offline" ]]; then
        log_error "离线模式下安装包不存在: $pkg_path"
        log_info "请将 ${SPARK_PACKAGE} 放入 ${OFFLINE_DIR}/ 目录"
        return 1
    fi

    log_info "在线下载 Spark ${SPARK_VERSION}..."
    mkdir -p "$(dirname "$pkg_path")"
    run_cmd curl -L -o "$pkg_path" "$SPARK_DOWNLOAD_URL" || { log_error "Spark 下载失败"; return 1; }
}

# ==================== 生成 Spark 配置 ====================
generate_spark_configs() {
    log_info "生成 Spark 配置文件..."

    cat > "$TMPDIR/spark-defaults.conf" <<EOF
spark.master                     yarn
spark.submit.deployMode          client
spark.yarn.am.memory             1g
spark.driver.memory              1g
spark.executor.memory            2g
spark.executor.cores             2
spark.executor.instances          2
spark.eventLog.enabled           true
spark.eventLog.dir               hdfs://${MASTER_HOST}:${HDFS_NAMENODE_RPC_PORT}/spark/eventLog
spark.yarn.historyServer.address http://${MASTER_HOST}:${SPARK_HISTORY_PORT}
spark.history.ui.port            ${SPARK_HISTORY_PORT}
spark.serializer                 org.apache.spark.serializer.KryoSerializer
spark.sql.shuffle.partitions     6
spark.sql.adaptive.enabled       true
spark.dynamicAllocation.enabled  true
spark.dynamicAllocation.shuffleTracking.enabled true
spark.shuffle.service.enabled    true
EOF

    cat > "$TMPDIR/spark-env.sh" <<EOF
export JAVA_HOME=${JAVA_HOME_DIR}
export HADOOP_HOME=${HADOOP_HOME_DIR}
export HADOOP_CONF_DIR=\${HADOOP_HOME}/etc/hadoop
export YARN_CONF_DIR=\${HADOOP_HOME}/etc/hadoop
export SPARK_HOME=${SPARK_HOME_DIR}
export SPARK_LOG_DIR=${SPARK_LOG_DIR}
export SPARK_HISTORY_OPTS="-Dspark.history.fs.logDirectory=hdfs://${MASTER_HOST}:${HDFS_NAMENODE_RPC_PORT}/spark/eventLog"
EOF
}

# ==================== 安装 Spark ====================
install_spark_on_host() {
    local -r host="$1"
    local -r pkg_path="$(get_package_path "$SPARK_PACKAGE")"
    local remote_pkg="${DOWNLOAD_DIR}/${SPARK_PACKAGE}"

    log_info "=== 在 ${host} 上安装 Spark (模式: ${INSTALL_MODE}) ==="

    remote_exec "$host" "mkdir -p $INSTALL_DIR $DOWNLOAD_DIR $SPARK_LOG_DIR"

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
if [[ ! -d "${SPARK_HOME_DIR}" ]]; then
    tar -xzf "${DOWNLOAD_DIR}/${SPARK_PACKAGE}" -C "${INSTALL_DIR}"
    SPARK_DIR=\$(ls -d "${INSTALL_DIR}"/spark-* 2>/dev/null | head -1)
    ln -sf "\${SPARK_DIR}" "${SPARK_HOME_DIR}"
fi
echo "Spark 安装完成"
REMOTE_SCRIPT
}

distribute_spark_configs() {
    local -r host="$1"
    local conf_dir="${SPARK_HOME_DIR}/conf"

    for config_file in spark-defaults.conf spark-env.sh; do
        remote_copy "$TMPDIR/$config_file" "$host" "$conf_dir/"
    done

    remote_exec "$host" "chmod +x ${conf_dir}/spark-env.sh"

    remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e
export JAVA_HOME=${JAVA_HOME_DIR}
export HADOOP_HOME=${HADOOP_HOME_DIR}

su - ${DEPLOY_USER} -c "
    \${HADOOP_HOME}/bin/hdfs dfs -mkdir -p /spark/eventLog
    \${HADOOP_HOME}/bin/hdfs dfs -mkdir -p /spark/jars
    \${HADOOP_HOME}/bin/hdfs dfs -chmod -R 777 /spark
"

su - ${DEPLOY_USER} -c "
    \${HADOOP_HOME}/bin/hdfs dfs -put ${SPARK_HOME_DIR}/jars/* /spark/jars/ 2>/dev/null || true
"

chown -R ${DEPLOY_USER}:${DEPLOY_GROUP} "${SPARK_HOME_DIR}" "${SPARK_LOG_DIR}" 2>/dev/null || true
REMOTE_SCRIPT
}

setup_spark_env() {
    local -r host="$1"
    remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e
cat > /etc/profile.d/bigdata_spark.sh <<ENVEOF
export SPARK_HOME=${SPARK_HOME_DIR}
export PATH=\${SPARK_HOME}/bin:\${SPARK_HOME}/sbin:\$PATH
ENVEOF
REMOTE_SCRIPT
}

start_history_server() {
    log_info "=== 启动 Spark History Server ==="

    remote_exec "$MASTER_HOST" bash -s <<REMOTE_SCRIPT
set -e
export JAVA_HOME=${JAVA_HOME_DIR}
export HADOOP_HOME=${HADOOP_HOME_DIR}
export SPARK_HOME=${SPARK_HOME_DIR}

# 检查是否已运行
if curl -s -o /dev/null -w '%{http_code}' http://localhost:${SPARK_HISTORY_PORT} 2>/dev/null | grep -q "200"; then
    echo "Spark History Server 已运行，跳过启动"
    exit 0
fi

HISTORY_PID=\$(jps 2>/dev/null | grep -i "HistoryServer" | awk '{print \$1}') || true
if [[ -n "\$HISTORY_PID" ]]; then
    echo "Spark History Server 进程已存在 (pid=\${HISTORY_PID})，跳过启动"
    exit 0
fi

su - ${DEPLOY_USER} -c '
    export JAVA_HOME=${JAVA_HOME_DIR}
    export HADOOP_HOME=${HADOOP_HOME_DIR}
    \${SPARK_HOME}/sbin/start-history-server.sh
'
echo "Spark History Server 启动完成"
REMOTE_SCRIPT

    sleep 3
}

verify_deployment() {
    log_info "=== 验证 Spark 部署 ==="

    remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '
        export JAVA_HOME=${JAVA_HOME_DIR}
        export HADOOP_HOME=${HADOOP_HOME_DIR}
        ${SPARK_HOME_DIR}/bin/spark-submit --version 2>&1 | head -3
    '" 2>/dev/null && log_info "Spark 客户端正常" || log_warn "Spark 客户端异常"

    if remote_exec "$MASTER_HOST" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${SPARK_HISTORY_PORT}" 2>/dev/null | grep -q "200"; then
        log_info "Spark History Server 运行正常"
    else
        log_warn "Spark History Server 状态异常"
    fi

    log_info "Spark History Server: http://${MASTER_HOST}:${SPARK_HISTORY_PORT}"
}

main() {
    log_info "========================================"
    log_info "  Spark on YARN 部署"
    log_info "========================================"
    log_info "安装模式: ${INSTALL_MODE}"
    [[ "$INSTALL_MODE" == "offline" ]] && log_info "离线目录: ${OFFLINE_DIR}"
    log_info "Spark 版本: ${SPARK_VERSION}"

    prepare_package
    generate_spark_configs

    install_spark_on_host "$MASTER_HOST"
    distribute_spark_configs "$MASTER_HOST"
    setup_spark_env "$MASTER_HOST"

    for host in "${WORKER_HOSTS[@]}"; do
        install_spark_on_host "$host"
        distribute_spark_configs "$host"
        setup_spark_env "$host"
    done

    start_history_server
    verify_deployment

    log_info "========================================"
    log_info "  Spark on YARN 部署完成"
    log_info "========================================"
}

main "$@"
