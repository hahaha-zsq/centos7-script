#!/bin/bash
set -Eeuo pipefail

# ============================================================
# Hadoop HDFS + YARN 集群部署脚本
# 支持在线下载和离线安装两种模式
# ============================================================

trap 'log_error "脚本执行出错，行号: $LINENO"' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/env.sh"

log_info() { printf "[%s] 信息: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_warn() { printf "[%s] 警告: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { printf "[%s] 错误: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && printf "[%s] 调试: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# ==================== 参数 ====================
DRY_RUN=false
SKIP_FORMAT=false

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

部署 Hadoop HDFS + YARN 集群。

选项:
    -m, --mode MODE    安装模式: online(在线) | offline(离线)，默认: ${INSTALL_MODE}
    --skip-format      跳过 HDFS 格式化 (已有数据时使用)
    -d, --dry-run      试运行模式
    -v, --verbose      启用详细输出
    -h, --help         显示此帮助信息
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)
            INSTALL_MODE="$2"
            [[ "$INSTALL_MODE" == "online" || "$INSTALL_MODE" == "offline" ]] || { log_error "无效的安装模式: $INSTALL_MODE"; exit 1; }
            shift 2 ;;
        --skip-format) SKIP_FORMAT=true; shift ;;
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

run_cmd() {
    [[ "$DRY_RUN" == "true" ]] && { log_info "[试运行] $*"; return 0; }
    "$@"
}

remote_exec() {
    local -r host="$1"; shift
    ssh -i "$SSH_IDENTITY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" \
        -p "$SSH_PORT" "root@${host}" "$@"
}

remote_copy() {
    local -r src="$1"; local -r host="$2"; local -r dst="$3"
    scp -i "$SSH_IDENTITY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" \
        -P "$SSH_PORT" -r "$src" "root@${host}:${dst}"
}

# ==================== 准备安装包 ====================
prepare_package() {
    local -r pkg_path="$(get_package_path "$HADOOP_PACKAGE")"

    if [[ -f "$pkg_path" ]]; then
        log_info "Hadoop 安装包已存在: $pkg_path"
        return 0
    fi

    if [[ "$INSTALL_MODE" == "offline" ]]; then
        log_error "离线模式下安装包不存在: $pkg_path"
        log_info "请将 ${HADOOP_PACKAGE} 放入 ${OFFLINE_DIR}/ 目录"
        return 1
    fi

    log_info "在线下载 Hadoop ${HADOOP_VERSION}..."
    mkdir -p "$(dirname "$pkg_path")"
    run_cmd curl -L -o "$pkg_path" "$HADOOP_DOWNLOAD_URL" || {
        log_error "Hadoop 下载失败: $HADOOP_DOWNLOAD_URL"
        return 1
    }
}

# ==================== 生成 Hadoop 配置文件 ====================
generate_hadoop_configs() {
    log_info "生成 Hadoop 配置文件..."

    # workers 文件: 包含所有节点 (Master 也运行 DataNode + NodeManager)
    cat > "$TMPDIR/workers" <<EOF
$(printf '%s\n' "${ALL_HOSTS[@]}")
EOF

    cat > "$TMPDIR/core-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://${MASTER_HOST}:${HDFS_NAMENODE_RPC_PORT}</value>
    </property>
    <property>
        <name>hadoop.tmp.dir</name>
        <value>${DATA_BASE_DIR}/tmp</value>
    </property>
    <property>
        <name>io.file.buffer.size</name>
        <value>131072</value>
    </property>
</configuration>
EOF

    cat > "$TMPDIR/hdfs-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>dfs.replication</name>
        <value>${HDFS_REPLICATION_FACTOR}</value>
    </property>
    <property>
        <name>dfs.namenode.name.dir</name>
        <value>file://${HDFS_NAME_DIR}</value>
    </property>
    <property>
        <name>dfs.datanode.data.dir</name>
        <value>file://${HDFS_DATA_DATA_DIR}</value>
    </property>
    <property>
        <name>dfs.namenode.http-address</name>
        <value>${MASTER_HOST}:${HDFS_NAMENODE_PORT}</value>
    </property>
    <property>
        <name>dfs.namenode.secondary.http-address</name>
        <value>${WORKER_HOSTS[-1]}:9868</value>
    </property>
    <property>
        <name>dfs.permissions</name>
        <value>false</value>
    </property>
</configuration>
EOF

    cat > "$TMPDIR/yarn-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>yarn.resourcemanager.hostname</name>
        <value>${MASTER_HOST}</value>
    </property>
    <property>
        <name>yarn.resourcemanager.webapp.address</name>
        <value>${MASTER_HOST}:${YARN_RESOURCEMANAGER_PORT}</value>
    </property>
    <property>
        <name>yarn.nodemanager.resource.memory-mb</name>
        <value>${YARN_NODEMANAGER_RESOURCE_MEMORY_MB}</value>
    </property>
    <property>
        <name>yarn.nodemanager.resource.cpu-vcores</name>
        <value>${YARN_NODEMANAGER_RESOURCE_CPU_VCORES}</value>
    </property>
    <property>
        <name>yarn.scheduler.minimum-allocation-mb</name>
        <value>${YARN_SCHEDULER_MINIMUM_ALLOCATION_MB}</value>
    </property>
    <property>
        <name>yarn.scheduler.maximum-allocation-mb</name>
        <value>${YARN_SCHEDULER_MAXIMUM_ALLOCATION_MB}</value>
    </property>
    <property>
        <name>yarn.scheduler.minimum-allocation-vcores</name>
        <value>${YARN_SCHEDULER_MINIMUM_ALLOCATION_VCORES}</value>
    </property>
    <property>
        <name>yarn.scheduler.maximum-allocation-vcores</name>
        <value>${YARN_SCHEDULER_MAXIMUM_ALLOCATION_VCORES}</value>
    </property>
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>
    <property>
        <name>yarn.nodemanager.env-whitelist</name>
        <value>JAVA_HOME,HADOOP_COMMON_HOME,HADOOP_HDFS_HOME,HADOOP_CONF_DIR,CLASSPATH_PREPEND_DISTCACHE,HADOOP_YARN_HOME,HADOOP_MAPRED_HOME</value>
    </property>
    <property>
        <name>yarn.log-aggregation-enable</name>
        <value>true</value>
    </property>
    <property>
        <name>yarn.log.server.url</name>
        <value>http://${MASTER_HOST}:19888/jobhistory/logs</value>
    </property>
    <property>
        <name>yarn.nodemanager.remote-app-log-dir</name>
        <value>/logs</value>
    </property>
</configuration>
EOF

    cat > "$TMPDIR/mapred-site.xml" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
    <property>
        <name>mapreduce.framework.name</name>
        <value>yarn</value>
    </property>
    <property>
        <name>mapreduce.jobhistory.address</name>
        <value>${MASTER_HOST}:10020</value>
    </property>
    <property>
        <name>mapreduce.jobhistory.webapp.address</name>
        <value>${MASTER_HOST}:19888</value>
    </property>
    <property>
        <name>yarn.app.mapreduce.am.env</name>
        <value>HADOOP_MAPRED_HOME=\${HADOOP_HOME}</value>
    </property>
    <property>
        <name>mapreduce.map.env</name>
        <value>HADOOP_MAPRED_HOME=\${HADOOP_HOME}</value>
    </property>
    <property>
        <name>mapreduce.reduce.env</name>
        <value>HADOOP_MAPRED_HOME=\${HADOOP_HOME}</value>
    </property>
</configuration>
EOF

    cat > "$TMPDIR/hadoop-env.sh" <<EOF
export JAVA_HOME=${JAVA_HOME_DIR}
export HADOOP_HOME=${HADOOP_HOME_DIR}
export HADOOP_CONF_DIR=\${HADOOP_HOME}/etc/hadoop
export HADOOP_LOG_DIR=${HADOOP_LOG_DIR}
export HDFS_NAMENODE_USER=${DEPLOY_USER}
export HDFS_DATANODE_USER=${DEPLOY_USER}
export HDFS_SECONDARYNAMENODE_USER=${DEPLOY_USER}
export YARN_RESOURCEMANAGER_USER=${DEPLOY_USER}
export YARN_NODEMANAGER_USER=${DEPLOY_USER}
export HADOOP_SSH_OPTS="-o StrictHostKeyChecking=no -o ConnectTimeout=${SSH_TIMEOUT}"
export HADOOP_NAMENODE_OPTS="${NAMENODE_OPTS} \${HADOOP_NAMENODE_OPTS}"
export HADOOP_DATANODE_OPTS="${DATANODE_OPTS} \${HADOOP_DATANODE_OPTS}"
export HADOOP_RESOURCEMANAGER_OPTS="${RESOURCEMANAGER_OPTS} \${HADOOP_RESOURCEMANAGER_OPTS}"
export HADOOP_NODEMANAGER_OPTS="${NODEMANAGER_OPTS} \${HADOOP_NODEMANAGER_OPTS}"
EOF

    log_info "配置文件生成完成"
}

# ==================== 安装 Hadoop 到节点 ====================
install_hadoop_on_host() {
    local -r host="$1"
    local -r pkg_path="$(get_package_path "$HADOOP_PACKAGE")"
    local remote_pkg="${DOWNLOAD_DIR}/${HADOOP_PACKAGE}"

    log_info "=== 在 ${host} 上安装 Hadoop (模式: ${INSTALL_MODE}) ==="

    remote_exec "$host" "mkdir -p $INSTALL_DIR $DOWNLOAD_DIR $HDFS_DATA_DIR $HDFS_NAME_DIR $HDFS_DATA_DATA_DIR $YARN_LOG_DIR $HADOOP_LOG_DIR $DATA_BASE_DIR/tmp"

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

if [[ -d "${HADOOP_HOME_DIR}" ]] && "${HADOOP_HOME_DIR}/bin/hadoop" version &>/dev/null 2>&1; then
    echo "Hadoop 已安装，跳过解压"
else
    echo "解压 Hadoop..."
    tar -xzf "${DOWNLOAD_DIR}/${HADOOP_PACKAGE}" -C "${INSTALL_DIR}"
    HADOOP_DIR=\$(ls -d "${INSTALL_DIR}"/hadoop-* 2>/dev/null | head -1)
    ln -sf "\${HADOOP_DIR}" "${HADOOP_HOME_DIR}"
fi

mkdir -p "${HDFS_NAME_DIR}" "${HDFS_DATA_DATA_DIR}" "${YARN_LOG_DIR}" "${HADOOP_LOG_DIR}" "${DATA_BASE_DIR}/tmp"
chown -R ${DEPLOY_USER}:${DEPLOY_GROUP} "${DATA_BASE_DIR}" "${HADOOP_LOG_DIR}" 2>/dev/null || true

echo "Hadoop 安装完成"
REMOTE_SCRIPT
}

distribute_configs() {
    local -r host="$1"
    log_info "分发配置到 ${host}..."

    local conf_dir="${HADOOP_HOME_DIR}/etc/hadoop"
    remote_exec "$host" "mkdir -p $conf_dir"

    for config_file in core-site.xml hdfs-site.xml yarn-site.xml mapred-site.xml hadoop-env.sh workers; do
        remote_copy "$TMPDIR/$config_file" "$host" "$conf_dir/"
    done

    remote_exec "$host" "chmod +x $conf_dir/hadoop-env.sh"
    remote_exec "$host" "chown -R ${DEPLOY_USER}:${DEPLOY_GROUP} ${HADOOP_HOME_DIR} ${DATA_BASE_DIR} ${HADOOP_LOG_DIR} 2>/dev/null || true"
}

setup_env_on_host() {
    local -r host="$1"
    log_info "配置 ${host} 环境变量..."

    remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e
cat > /etc/profile.d/bigdata_hadoop.sh <<ENVEOF
export HADOOP_HOME=${HADOOP_HOME_DIR}
export HADOOP_CONF_DIR=\${HADOOP_HOME}/etc/hadoop
export PATH=\${HADOOP_HOME}/bin:\${HADOOP_HOME}/sbin:\$PATH
ENVEOF
REMOTE_SCRIPT
}

# ==================== 配置 Hadoop 用户 SSH 免密 ====================
setup_hadoop_ssh() {
    log_info "=== 配置 ${DEPLOY_USER} 用户 SSH 免密登录 ==="

    local hadoop_home
    hadoop_home=$(remote_exec "$MASTER_HOST" "eval echo ~${DEPLOY_USER}" 2>/dev/null)

    # 在 master 上生成 hadoop 用户的密钥
    log_info "在 ${MASTER_HOST} 上生成 ${DEPLOY_USER} SSH 密钥..."
    remote_exec "$MASTER_HOST" bash -s <<REMOTE_SCRIPT
set -e
mkdir -p "${hadoop_home}/.ssh"
chmod 700 "${hadoop_home}/.ssh"
if [[ ! -f "${hadoop_home}/.ssh/id_rsa" ]]; then
    su - ${DEPLOY_USER} -c 'ssh-keygen -t rsa -b 2048 -N "" -f ~/.ssh/id_rsa -q'
fi
chown -R ${DEPLOY_USER}:${DEPLOY_GROUP} "${hadoop_home}/.ssh"
REMOTE_SCRIPT

    # 收集 master 的公钥
    local master_pubkey
    master_pubkey=$(remote_exec "$MASTER_HOST" "cat ${hadoop_home}/.ssh/id_rsa.pub" 2>/dev/null | tr -d '\r')

    if [[ -z "$master_pubkey" ]]; then
        log_warn "无法获取 master SSH 公钥，跳过 SSH 配置"
        return 0
    fi

    # 将公钥写入所有节点（包括 master 自身）
    for host in "${ALL_HOSTS[@]}"; do
        log_info "分发 ${DEPLOY_USER} SSH 公钥到 ${host}..."
        remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e
HOST_HOME=\$(eval echo ~${DEPLOY_USER})
mkdir -p "\${HOST_HOME}/.ssh"
chmod 700 "\${HOST_HOME}/.ssh"

# 追加公钥（幂等）
grep -qxF '${master_pubkey}' "\${HOST_HOME}/.ssh/authorized_keys" 2>/dev/null || echo '${master_pubkey}' >> "\${HOST_HOME}/.ssh/authorized_keys"

chmod 600 "\${HOST_HOME}/.ssh/authorized_keys"
chown -R ${DEPLOY_USER}:${DEPLOY_GROUP} "\${HOST_HOME}/.ssh"
REMOTE_SCRIPT
    done

    # 验证 SSH 连通性
    log_info "验证 ${DEPLOY_USER} 用户 SSH 连通性..."
    for host in "${ALL_HOSTS[@]}"; do
        if remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c 'ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no ${host} echo ok'" 2>/dev/null | grep -q "ok"; then
            log_info "${MASTER_HOST} -> ${host}: SSH 连通"
        else
            log_warn "${MASTER_HOST} -> ${host}: SSH 连接失败"
        fi
    done

    log_info "${DEPLOY_USER} 用户 SSH 免密登录配置完成"
}

# ==================== 格式化 HDFS ====================
format_hamaster() {
    if [[ "$SKIP_FORMAT" == "true" ]]; then
        log_info "跳过 HDFS 格式化"
        return 0
    fi

    log_info "=== 格式化 HDFS NameNode ==="

    remote_exec "$MASTER_HOST" bash -s <<REMOTE_SCRIPT
set -e
export JAVA_HOME=${JAVA_HOME_DIR}
export HADOOP_HOME=${HADOOP_HOME_DIR}
export HADOOP_LOG_DIR=${HADOOP_LOG_DIR}

mkdir -p "${HADOOP_LOG_DIR}"
chown ${DEPLOY_USER}:${DEPLOY_GROUP} "${HADOOP_LOG_DIR}"

if [[ -d "${HDFS_NAME_DIR}/current" ]]; then
    echo "HDFS 已格式化，跳过"
    exit 0
fi

# 双重检查: 检查 NameNode 是否已在运行
HADOOP_PID_DIR="\${HADOOP_HOME}/pids"
if [[ -f "\${HADOOP_PID_DIR}/hadoop-\${USER}-namenode.pid" ]]; then
    NN_PID=\$(cat "\${HADOOP_PID_DIR}/hadoop-\${USER}-namenode.pid" 2>/dev/null)
    if kill -0 "\$NN_PID" 2>/dev/null; then
        echo "NameNode 进程正在运行，HDFS 应已格式化，跳过"
        exit 0
    fi
fi

echo "正在格式化 NameNode..."
su - ${DEPLOY_USER} -c "export HADOOP_LOG_DIR=${HADOOP_LOG_DIR}; \${HADOOP_HOME}/bin/hdfs namenode -format -force -nonInteractive"
echo "HDFS 格式化完成"
REMOTE_SCRIPT
}

# ==================== 启动 Hadoop ====================
start_hadoop() {
    log_info "=== 启动 Hadoop 集群 ==="

    # 检查 HDFS 是否已运行
    local hdfs_running
    hdfs_running=$(remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '${HADOOP_HOME_DIR}/bin/hdfs dfsadmin -report'" 2>/dev/null) || true
    if echo "$hdfs_running" | grep -q "Live datanodes"; then
        log_info "HDFS 已在运行，跳过启动"
    else
        log_info "启动 HDFS..."
        remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '${HADOOP_HOME_DIR}/sbin/start-dfs.sh'" || { log_error "HDFS 启动失败"; return 1; }
    fi
    sleep 5

    # 检查 YARN 是否已运行
    local yarn_running
    yarn_running=$(remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '${HADOOP_HOME_DIR}/bin/yarn node -list'" 2>/dev/null) || true
    if echo "$yarn_running" | grep -q "RUNNING\|NodeManager"; then
        log_info "YARN 已在运行，跳过启动"
    else
        log_info "启动 YARN..."
        remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '${HADOOP_HOME_DIR}/sbin/start-yarn.sh'" || { log_error "YARN 启动失败"; return 1; }
    fi

    # MapReduce HistoryServer
    local mr_running
    mr_running=$(remote_exec "$MASTER_HOST" "jps 2>/dev/null | grep -i JobHistoryServer" || true)
    if [[ -n "$mr_running" ]]; then
        log_info "MapReduce HistoryServer 已在运行，跳过启动"
    else
        log_info "启动 MapReduce HistoryServer..."
        remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '${HADOOP_HOME_DIR}/bin/mapred --daemon start historyserver'" || true
    fi
    sleep 3
}

# ==================== 验证 ====================
verify_deployment() {
    log_info "=== 验证 Hadoop 部署 ==="

    local hdfs_status
    hdfs_status=$(remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '${HADOOP_HOME_DIR}/bin/hdfs dfsadmin -report'" 2>/dev/null) || true
    if echo "$hdfs_status" | grep -q "Live datanodes"; then
        log_info "HDFS 运行正常，活跃 DataNode: $(echo "$hdfs_status" | grep "Live datanodes" | awk '{print $3}')"
    else
        log_warn "HDFS 状态检查异常"
    fi

    log_info "HDFS NameNode:      http://${MASTER_HOST}:${HDFS_NAMENODE_PORT}"
    log_info "YARN ResourceManager: http://${MASTER_HOST}:${YARN_RESOURCEMANAGER_PORT}"
}

# ==================== 主函数 ====================
main() {
    log_info "========================================"
    log_info "  Hadoop HDFS + YARN 集群部署"
    log_info "========================================"
    log_info "安装模式: ${INSTALL_MODE}"
    [[ "$INSTALL_MODE" == "offline" ]] && log_info "离线目录: ${OFFLINE_DIR}"
    log_info "Master: ${MASTER_HOST}"
    log_info "Workers: ${WORKER_HOSTS[*]}"

    prepare_package
    generate_hadoop_configs

    for host in "${ALL_HOSTS[@]}"; do
        install_hadoop_on_host "$host"
        distribute_configs "$host"
        setup_env_on_host "$host"
    done

    format_hamaster
    setup_hadoop_ssh
    start_hadoop
    verify_deployment

    log_info "========================================"
    log_info "  Hadoop 集群部署完成"
    log_info "========================================"
}

main "$@"
