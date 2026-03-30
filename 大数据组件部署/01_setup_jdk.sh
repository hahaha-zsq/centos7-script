#!/bin/bash
set -Eeuo pipefail

# ============================================================
# JDK 安装脚本
# 支持在线下载和离线安装两种模式
# ============================================================

trap 'log_error "脚本执行出错，行号: $LINENO"' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# shellcheck source=env.sh
source "$SCRIPT_DIR/env.sh"

log_info() { printf "[%s] 信息: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_warn() { printf "[%s] 警告: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { printf "[%s] 错误: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_debug() { [[ "${DEBUG:-0}" == "1" ]] && printf "[%s] 调试: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

# ==================== 参数 ====================
DRY_RUN=false

usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

在所有集群节点上安装 JDK ${JAVA_VERSION}。

选项:
    -m, --mode MODE   安装模式: online(在线) | offline(离线)，默认: ${INSTALL_MODE}
    -d, --dry-run     试运行模式
    -v, --verbose     启用详细输出
    -h, --help        显示此帮助信息

离线模式:
    安装包目录: ${OFFLINE_DIR}
    需要的安装包: ${JAVA_PACKAGE}
EOF
    exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)
            INSTALL_MODE="$2"
            if [[ "$INSTALL_MODE" != "online" && "$INSTALL_MODE" != "offline" ]]; then
                log_error "无效的安装模式: $INSTALL_MODE (支持: online, offline)"
                exit 1
            fi
            shift 2
            ;;
        -d|--dry-run) DRY_RUN=true; shift ;;
        -v|--verbose) DEBUG=1; shift ;;
        -h|--help) usage 0 ;;
        *) log_error "未知选项: $1"; usage 1 ;;
    esac
done

# ==================== 临时目录 ====================
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
        -P "$SSH_PORT" "$src" "root@${host}:${dst}"
}

# ==================== 准备安装包 ====================
prepare_package() {
    local pkg_path
    pkg_path=$(get_package_path "$JAVA_PACKAGE")

    if [[ -f "$pkg_path" ]]; then
        log_info "JDK 安装包已存在: $pkg_path"
        return 0
    fi

    if [[ "$INSTALL_MODE" == "offline" ]]; then
        log_error "离线模式下安装包不存在: $pkg_path"
        log_info "请将 ${JAVA_PACKAGE} 放入 ${OFFLINE_DIR}/ 目录"
        log_info "或运行: curl -L -o ${pkg_path} ${JAVA_DOWNLOAD_URL}"
        return 1
    fi

    log_info "在线下载 JDK ${JAVA_VERSION}..."
    mkdir -p "$(dirname "$pkg_path")"
    run_cmd curl -L -o "$pkg_path" "$JAVA_DOWNLOAD_URL" || {
        log_error "JDK 下载失败"
        log_info "下载地址: $JAVA_DOWNLOAD_URL"
        return 1
    }
    log_info "JDK 下载完成: $pkg_path"
}

# ==================== 安装 JDK ====================
install_jdk_on_host() {
    local host="$1"
    local pkg_path
    pkg_path=$(get_package_path "$JAVA_PACKAGE")
    local remote_pkg="${DOWNLOAD_DIR}/${JAVA_PACKAGE}"

    log_info "=== 在 ${host} 上安装 JDK (模式: ${INSTALL_MODE}) ==="

    remote_exec "$host" "mkdir -p $INSTALL_DIR $DOWNLOAD_DIR"

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

INSTALL_DIR="$INSTALL_DIR"
JAVA_HOME_DIR="$JAVA_HOME_DIR"
JAVA_PKG="$DOWNLOAD_DIR/$JAVA_PACKAGE"

# 检查是否已安装
if [[ -d "\$JAVA_HOME_DIR" ]] && "\$JAVA_HOME_DIR/bin/java" -version &>/dev/null; then
    echo "JDK 已安装，跳过"
    "\$JAVA_HOME_DIR/bin/java" -version
    exit 0
fi

mkdir -p "\$INSTALL_DIR"

echo "解压 JDK..."
tar -xzf "\$JAVA_PKG" -C "\$INSTALL_DIR"

JAVA_DIR=\$(ls -d "\$INSTALL_DIR"/jdk-* 2>/dev/null | head -1)
if [[ -z "\$JAVA_DIR" ]]; then
    echo "错误: 解压后未找到 JDK 目录"
    exit 1
fi

ln -sf "\$JAVA_DIR" "\$JAVA_HOME_DIR"

# 配置环境变量
cat > /etc/profile.d/bigdata_jdk.sh <<ENVEOF
export JAVA_HOME=${JAVA_HOME_DIR}
export PATH=\${JAVA_HOME}/bin:\${PATH}
ENVEOF

    source /etc/profile.d/bigdata_jdk.sh
    echo "JDK 安装成功:"
    ${JAVA_HOME_DIR}/bin/java -version 2>&1
REMOTE_SCRIPT

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_info "${host} JDK 安装成功"
    else
        log_error "${host} JDK 安装失败"
        return 1
    fi
}

# ==================== 主函数 ====================
main() {
    log_info "========================================"
    log_info "  JDK ${JAVA_VERSION} 集群部署"
    log_info "========================================"
    log_info "安装模式: ${INSTALL_MODE}"
    [[ "$INSTALL_MODE" == "offline" ]] && log_info "离线目录: ${OFFLINE_DIR}"
    log_info "节点列表: ${ALL_HOSTS[*]}"

    prepare_package

    local success_count=0
    local fail_count=0

    for host in "${ALL_HOSTS[@]}"; do
        if install_jdk_on_host "$host"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
        fi
    done

    log_info "========================================"
    log_info "  JDK 安装汇总"
    log_info "========================================"
    log_info "成功: $success_count / ${#ALL_HOSTS[@]}"
    log_info "失败: $fail_count"

    [[ $fail_count -gt 0 ]] && return 1
    log_info "JDK 集群部署完成"
    return 0
}

main "$@"
