#!/bin/bash
set -Eeuo pipefail

# ============================================================
# 大数据集群一键部署脚本
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
SKIP_COMPONENTS=""

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

一键部署大数据集群 (Hadoop + Kafka + Flink + Spark)。

选项:
    -m, --mode MODE         安装模式: online(在线) | offline(离线)，默认: ${INSTALL_MODE}
    -s, --skip COMPONENTS   跳过指定组件 (逗号分隔: jdk,hadoop,kafka,flink,spark)
    --prepare-offline       仅下载所有安装包到离线目录 (不部署)
    -d, --dry-run           试运行模式
    -v, --verbose           启用详细输出
    -h, --help              显示此帮助信息

安装模式:
    online   从网络下载安装包后部署 (默认)
    offline  使用本地已下载的安装包部署，目录: ${OFFLINE_DIR}

示例:
    # 在线完整部署
    $(basename "$0")

    # 离线部署
    $(basename "$0") -m offline

    # 仅准备离线安装包 (在能访问外网的机器上执行)
    $(basename "$0") --prepare-offline

    # 离线部署，跳过已安装的组件
    $(basename "$0") -m offline -s jdk,hadoop
EOF
    exit "${1:-0}"
}

PREPARE_OFFLINE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)
            INSTALL_MODE="$2"
            [[ "$INSTALL_MODE" == "online" || "$INSTALL_MODE" == "offline" ]] || { log_error "无效的安装模式: $INSTALL_MODE"; exit 1; }
            shift 2 ;;
        -s|--skip) SKIP_COMPONENTS="$2"; shift 2 ;;
        --prepare-offline) PREPARE_OFFLINE=true; shift ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -v|--verbose) DEBUG=1; shift ;;
        -h|--help) usage 0 ;;
        *) log_error "未知选项: $1"; usage 1 ;;
    esac
done

should_skip() {
    local -r component="$1"
    [[ -n "$SKIP_COMPONENTS" ]] && echo "$SKIP_COMPONENTS" | grep -q "$component"
}

remote_exec() {
    local -r host="$1"; shift
    # 优先用 IP 连接 (解决 hosts 未配置时的连接问题)
    local connect_host
    connect_host=$(get_host_ip "$host") || connect_host="$host"
    ssh -i "$SSH_IDENTITY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" \
        -p "$SSH_PORT" "root@${connect_host}" "$@"
}

# ==================== 准备离线安装包 ====================
do_prepare_offline() {
    log_info "========================================"
    log_info "  准备离线安装包"
    log_info "========================================"
    log_info "目标目录: ${OFFLINE_DIR}"

    prepare_offline_packages

    log_info "========================================"
    log_info "  离线安装包准备完成"
    log_info "========================================"
    log_info "将 ${OFFLINE_DIR} 目录复制到目标服务器后，使用以下命令部署:"
    log_info "  ./deploy_all.sh -m offline"
}

# ==================== 统一下载所有安装包到本地 ====================
do_download_all_local() {
    log_info "========================================"
    log_info "  统一下载所有安装包到本地"
    log_info "========================================"
    log_info "下载目录: ${DOWNLOAD_DIR}"

    if [[ "$INSTALL_MODE" == "offline" ]]; then
        log_info "离线模式，跳过下载 (使用 ${OFFLINE_DIR})"
        return 0
    fi

    download_all_packages_to_local || {
        log_error "部分安装包下载失败"
        return 1
    }

    log_info "所有安装包已下载到: ${DOWNLOAD_DIR}"
}

# ==================== 自动配置 Hosts ====================
setup_hosts() {
    log_info "========================================"
    log_info "  配置 /etc/hosts"
    log_info "========================================"

    # 构建 hosts 内容
    local hosts_content=""
    for entry in "${SERVERS[@]}"; do
        local ip="${entry%% *}"
        local host="${entry##* }"
        hosts_content+="${ip} ${host}\n"
    done

    for host in "${ALL_HOSTS[@]}"; do
        local ip
        ip=$(get_host_ip "$host")
        log_info "配置 ${host} (${ip}) 的 /etc/hosts..."

        remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e

# 备份原始 hosts
cp /etc/hosts /etc/hosts.bak.\$(date +%Y%m%d%H%M%S) 2>/dev/null || true

# 清除已有的集群节点配置 (避免重复)
for entry in ${SERVERS[*]}; do
    host_name=\${entry##* }
    sed -i "/\b\${host_name}\b/d" /etc/hosts 2>/dev/null || true
done

# 追加集群节点映射
cat >> /etc/hosts <<'HOSTSEOF'
$(printf '%b' "$hosts_content")
HOSTSEOF

# 保留本机 localhost
grep -q "^127.0.0.1.*localhost" /etc/hosts || sed -i '1i 127.0.0.1   localhost' /etc/hosts
grep -q "^::1.*localhost" /etc/hosts || sed -i '2i ::1         localhost' /etc/hosts

echo "${host} hosts 配置完成"
cat /etc/hosts | grep -E "$(IFS='|'; echo "${ALL_HOSTS[*]}")" || true
REMOTE_SCRIPT
    done

    log_info "所有节点 hosts 配置完成"

    # 验证节点间 SSH 免密互通
    log_info "验证节点间 SSH 免密互通..."
    for src in "${ALL_HOSTS[@]}"; do
        for dst in "${ALL_HOSTS[@]}"; do
            [[ "$src" == "$dst" ]] && continue
            local src_ip
            src_ip=$(get_host_ip "$src") || src_ip="$src"
            if remote_exec "$src" "ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no root@${dst} 'echo ok'" &>/dev/null; then
                log_info "  ${src} -> ${dst}: 通"
            else
                log_warn "  ${src} -> ${dst}: 不通"
            fi
        done
    done
}

# ==================== 基础环境准备 ====================
prepare_environment() {
    log_info "========================================"
    log_info "  阶段 0: 基础环境准备"
    log_info "========================================"

    # 先配置 hosts
    setup_hosts

    for host in "${ALL_HOSTS[@]}"; do
        log_info "准备 ${host}..."

        remote_exec "$host" bash -s <<REMOTE_SCRIPT
set -e

if ! id "${DEPLOY_USER}" &>/dev/null; then
    groupadd -r ${DEPLOY_GROUP} 2>/dev/null || true
    useradd -r -g ${DEPLOY_GROUP} -m -s /bin/bash ${DEPLOY_USER}
    echo "${DEPLOY_USER}:hadoop123" | chpasswd
    echo "已创建用户: ${DEPLOY_USER}"
fi

mkdir -p ${DOWNLOAD_DIR} ${INSTALL_DIR} ${DATA_BASE_DIR} ${LOG_BASE_DIR}
chown -R ${DEPLOY_USER}:${DEPLOY_GROUP} ${DOWNLOAD_DIR} ${INSTALL_DIR} ${DATA_BASE_DIR} ${LOG_BASE_DIR}

# 离线模式下在远程创建离线目录
if [[ "${INSTALL_MODE}" == "offline" ]]; then
    mkdir -p ${DOWNLOAD_DIR}
fi

cat > /etc/sysctl.d/99-bigdata.conf <<'SYSEOF'
vm.swappiness = 10
net.core.somaxconn = 4096
net.ipv4.tcp_max_syn_backlog = 8192
SYSEOF
sysctl -p /etc/sysctl.d/99-bigdata.conf 2>/dev/null || true

cat > /etc/security/limits.d/99-bigdata.conf <<LIMEOF
${DEPLOY_USER} soft nofile 65535
${DEPLOY_USER} hard nofile 65535
${DEPLOY_USER} soft nproc 65535
${DEPLOY_USER} hard nproc 65535
LIMEOF

echo "${host} 基础环境准备完成"
REMOTE_SCRIPT
    done
}

# ==================== 智能传输安装包到远程节点 ====================
# 检查远程服务器是否已有安装包，只传输不存在的包
distribute_packages_smart() {
    log_info "========================================"
    log_info "  智能传输安装包到远程节点"
    log_info "========================================"

    local -a all_packages=(
        "$JAVA_PACKAGE"
        "$HADOOP_PACKAGE"
        "$ZOOKEEPER_PACKAGE"
        "$KAFKA_PACKAGE"
        "$FLINK_PACKAGE"
        "$SPARK_PACKAGE"
    )

    # 确定本地源目录
    local local_src_dir="$DOWNLOAD_DIR"
    if [[ "$INSTALL_MODE" == "offline" ]]; then
        local_src_dir="$OFFLINE_DIR"
    fi

    for host in "${ALL_HOSTS[@]}"; do
        log_info "检查并传输安装包到 ${host}..."
        remote_exec "$host" "mkdir -p $DOWNLOAD_DIR" || { log_warn "创建目录失败: ${host}"; continue; }

        local transfer_count=0
        local skip_count=0

        for pkg in "${all_packages[@]}"; do
            local src="${local_src_dir}/${pkg}"
            local remote_path="${DOWNLOAD_DIR}/${pkg}"

            # 检查本地源文件是否存在
            if [[ ! -f "$src" ]]; then
                log_warn "本地安装包不存在: ${src}"
                continue
            fi

            # 检查远程服务器是否已有该安装包
            local remote_exists=false
            if remote_exec "$host" "test -f '$remote_path'" >/dev/null 2>&1; then
                remote_exists=true
            fi

            if [[ "$remote_exists" == "true" ]]; then
                log_info "远程已存在，跳过: ${host}:${pkg}"
                skip_count=$((skip_count + 1))
                continue
            fi

            # 传输安装包
            log_info "传输: ${pkg} -> ${host}"
            if scp -i "$SSH_IDENTITY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" \
                -P "$SSH_PORT" "$src" "root@${host}:${remote_path}"; then
                transfer_count=$((transfer_count + 1))
            else
                log_warn "传输失败: ${pkg} -> ${host}"
            fi
        done

        log_info "${host}: 传输 ${transfer_count} 个, 跳过 ${skip_count} 个"
    done

    log_info "安装包传输完成"
}

# ==================== 部署各组件 ====================
run_script() {
    local -r script="$1"
    local -r name="$2"

    if should_skip "$name"; then
        log_info "跳过 ${name} 部署"
        return 0
    fi

    log_info "========================================"
    log_info "  执行: ${name} 部署"
    log_info "========================================"

    local args="-m ${INSTALL_MODE}"
    [[ "$DRY_RUN" == "true" ]] && args+=" -d"

    bash "${SCRIPT_DIR}/${script}" $args || {
        log_error "${name} 部署失败"
        return 1
    }
}

# ==================== 主函数 ====================
main() {
    # 仅准备离线包
    if [[ "$PREPARE_OFFLINE" == "true" ]]; then
        do_prepare_offline
        return $?
    fi

    local start_time
    start_time=$(date +%s)

    log_info "========================================"
    log_info "  大数据集群一键部署"
    log_info "========================================"
    log_info "安装模式: ${INSTALL_MODE}"
    [[ "$INSTALL_MODE" == "offline" ]] && log_info "离线目录: ${OFFLINE_DIR}"
    log_info "Master: ${MASTER_HOST}"
    log_info "Workers: ${WORKER_HOSTS[*]}"
    log_info "部署时间: $(date +'%Y-%m-%d %H:%M:%S')"

    [[ -n "$SKIP_COMPONENTS" ]] && log_info "跳过组件: ${SKIP_COMPONENTS}"

    # 阶段1: 统一下载所有安装包到本地
    do_download_all_local || exit 1

    # 阶段2: 基础环境准备
    prepare_environment

    # 阶段3: 智能传输安装包到远程节点 (检查远程是否存在，不存在才传输)
    distribute_packages_smart

    # 阶段4: 按顺序部署各组件
    run_script "01_setup_jdk.sh" "jdk" || exit 1
    run_script "02_deploy_hadoop.sh" "hadoop" || exit 1
    run_script "03_deploy_kafka.sh" "kafka" || exit 1
    run_script "04_deploy_flink.sh" "flink" || exit 1
    run_script "05_deploy_spark.sh" "spark" || exit 1

    # 健康检查
    log_info "========================================"
    log_info "  部署完成，执行健康检查"
    log_info "========================================"
    bash "${SCRIPT_DIR}/check_health.sh" || log_warn "部分健康检查未通过"

    local end_time
    end_time=$(date +%s)
    local duration=$((end_time - start_time))

    log_info "========================================"
    log_info "  部署完成"
    log_info "========================================"
    log_info "总耗时: $((duration / 60)) 分 $((duration % 60)) 秒"
    log_info ""
    log_info "Web UI 地址:"
    log_info "  HDFS NameNode:        http://${MASTER_HOST}:${HDFS_NAMENODE_PORT}"
    log_info "  YARN ResourceManager:  http://${MASTER_HOST}:${YARN_RESOURCEMANAGER_PORT}"
    log_info "  Spark History:        http://${MASTER_HOST}:${SPARK_HISTORY_PORT}"
}

main "$@"
