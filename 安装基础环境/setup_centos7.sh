#!/bin/bash
set -Eeuo pipefail

# CentOS 7 基础环境安装脚本
# 支持线上安装和本地安装两种模式

# 严格模式 + 错误捕获
trap 'log_error "脚本执行出错，行号: $LINENO"' ERR

# ==================== 日志函数 ====================
log_info() {
    printf "[%s] 信息: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

log_warn() {
    printf "[%s] 警告: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

log_error() {
    printf "[%s] 错误: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
}

log_debug() {
    if [[ "${DEBUG:-0}" == "1" ]]; then
        printf "[%s] 调试: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2
    fi
}

# ==================== 使用说明 ====================
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

CentOS 7 基础环境安装脚本，支持线上和本地两种安装模式。

选项:
    -m, --mode MODE      安装模式: online(线上) | offline(本地)，必填
    -p, --pkg-dir DIR    本地安装模式的RPM包目录 (本地模式必填)
    -r, --repo REPO      YUM镜像源: aliyun(阿里云) | tsinghua(清华) | ustc(中科大) | default(官方)
    -o, --output DIR     日志输出目录 (默认: /var/log/env_setup)
    -d, --dry-run        试运行模式，不实际执行
    -v, --verbose        启用详细输出
    -h, --help           显示此帮助信息

安装内容:
    - 基础工具: vim, wget, curl, net-tools, lsof, htop 等
    - 开发工具: gcc, make, cmake 等
    - SSH工具: sshpass, openssh-clients, openssh-server
    - Docker: docker-ce, docker-ce-cli, containerd.io
    - Docker Compose: 最新稳定版

示例:
    # 线上安装 (使用阿里云镜像)
    $(basename "$0") -m online -r aliyun

    # 本地安装 (指定RPM包目录)
    $(basename "$0") -m offline -p /opt/rpms

    # 试运行
    $(basename "$0") -m online -d
EOF
    exit "${1:-0}"
}

# ==================== 默认值 ====================
INSTALL_MODE=""
PKG_DIR=""
OUTPUT_DIR="/var/log/env_setup"
DRY_RUN=false
REPO_MIRROR="aliyun"  # 默认使用阿里云镜像

# 脚本目录
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"

# ==================== 镜像源配置 ====================
# 镜像源URL定义
declare -A MIRROR_BASE=(
    ["aliyun"]="https://mirrors.aliyun.com"
    ["tsinghua"]="https://mirrors.tuna.tsinghua.edu.cn"
    ["ustc"]="https://mirrors.ustc.edu.cn"
    ["default"]=""
)

# 镜像源名称
declare -A MIRROR_NAME=(
    ["aliyun"]="阿里云"
    ["tsinghua"]="清华大学"
    ["ustc"]="中国科学技术大学"
    ["default"]="官方源"
)

# 安装的软件包列表 (基础环境)
PACKAGES=(
    # 文本编辑和下载工具
    "vim"
    "wget"
    "curl"

    # 网络工具
    "net-tools"
    "lsof"
    "telnet"
    "nc"
    "tcpdump"
    "nmap"

    # 系统监控
    "iotop"
    "htop"
    "sysstat"
    "psmisc"

    # 文件处理
    "tree"
    "zip"
    "unzip"
    "tar"
    "lrzsz"

    # 开发工具
    "gcc"
    "gcc-c++"
    "make"
    "cmake"
    "openssl-devel"
    "zlib-devel"
    "bzip2-devel"
    "readline-devel"
    "sqlite-devel"
    "libffi-devel"

    # 其他
    "epel-release"
    "bash-completion"

    # SSH免密登录工具
    "sshpass"
    "openssh-clients"
    "openssh-server"
)

# ==================== 参数解析 ====================
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--mode)
            INSTALL_MODE="$2"
            shift 2
            ;;
        -p|--pkg-dir)
            PKG_DIR="$2"
            shift 2
            ;;
        -r|--repo)
            REPO_MIRROR="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -d|--dry-run)
            DRY_RUN=true
            shift
            ;;
        -v|--verbose)
            DEBUG=1
            shift
            ;;
        -h|--help)
            usage 0
            ;;
        --)
            shift
            break
            ;;
        *)
            log_error "未知选项: $1"
            usage 1
            ;;
    esac
done

# ==================== 参数验证 ====================
[[ -n "$INSTALL_MODE" ]] || { log_error "缺少必要参数: -m/--mode"; usage 1; }

if [[ "$INSTALL_MODE" != "online" && "$INSTALL_MODE" != "offline" ]]; then
    log_error "无效的安装模式: $INSTALL_MODE (支持: online, offline)"
    exit 1
fi

# 验证镜像源选项
if [[ "$INSTALL_MODE" == "online" ]]; then
    if [[ -z "${MIRROR_BASE[$REPO_MIRROR]+x}" ]]; then
        log_error "无效的镜像源: $REPO_MIRROR (支持: aliyun, tsinghua, ustc, default)"
        exit 1
    fi
fi

if [[ "$INSTALL_MODE" == "offline" ]]; then
    [[ -n "$PKG_DIR" ]] || { log_error "本地模式缺少必要参数: -p/--pkg-dir"; usage 1; }
    [[ -d "$PKG_DIR" ]] || { log_error "RPM包目录不存在: $PKG_DIR"; exit 1; }
fi

# ==================== 临时目录 ====================
TMPDIR=""
cleanup() {
    if [[ -n "${TMPDIR:-}" && -d "${TMPDIR:-}" ]]; then
        rm -rf -- "$TMPDIR"
        log_debug "已清理临时目录: $TMPDIR"
    fi
}
trap cleanup EXIT

TMPDIR=$(mktemp -d) || { log_error "创建临时目录失败"; exit 1; }
log_debug "临时目录: $TMPDIR"

# ==================== 试运行封装 ====================
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[试运行] 将执行: $*"
        return 0
    fi
    "$@"
}

# ==================== 依赖检查 ====================
check_dependencies() {
    local -a missing_deps=()
    local -a required=("yum" "rpm")

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "缺少必要命令: ${missing_deps[*]}"
        return 1
    fi
}

# ==================== 系统检查 ====================
check_system() {
    log_info "检查系统环境..."

    # 检查是否为root用户
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用root用户或sudo运行此脚本"
        return 1
    fi

    # 检查系统版本
    if [[ ! -f /etc/centos-release ]]; then
        log_warn "未检测到CentOS系统，可能不兼容"
    else
        local os_version
        os_version=$(cat /etc/centos-release)
        log_info "系统版本: $os_version"
    fi

    log_info "系统检查通过"
}

# ==================== 线上安装 ====================
online_install() {
    local -r pkg="$1"

    log_info "线上安装: $pkg"

    # 先检查是否已安装
    if rpm -q "$pkg" &>/dev/null; then
        log_info "已安装，跳过: $pkg"
        return 0
    fi

    run_cmd yum install -y "$pkg" || {
        log_error "安装失败: $pkg"
        return 1
    }

    log_info "安装成功: $pkg"
    return 0
}

# ==================== 本地安装 ====================
offline_install() {
    local -r pkg="$1"

    log_info "本地安装: $pkg"

    # 先检查是否已安装
    if rpm -q "$pkg" &>/dev/null; then
        log_info "已安装，跳过: $pkg"
        return 0
    fi

    # 查找本地RPM包
    local rpm_file
    rpm_file=$(find "$PKG_DIR" -name "${pkg}*.rpm" -type f | head -1)

    if [[ -z "$rpm_file" ]]; then
        log_error "未找到RPM包: $pkg (目录: $PKG_DIR)"
        return 1
    fi

    log_debug "找到RPM包: $rpm_file"

    run_cmd rpm -ivh --nodeps "$rpm_file" || {
        log_error "安装失败: $pkg ($rpm_file)"
        return 1
    }

    log_info "安装成功: $pkg"
    return 0
}

# ==================== 配置YUM镜像源 ====================
setup_yum_mirror() {
    # 仅在线上安装模式下配置镜像源
    if [[ "$INSTALL_MODE" != "online" ]]; then
        log_debug "本地模式，跳过镜像源配置"
        return 0
    fi

    # 如果是官方源，则不修改
    if [[ "$REPO_MIRROR" == "default" ]]; then
        log_info "使用官方YUM源，无需修改"
        return 0
    fi

    local mirror_base="${MIRROR_BASE[$REPO_MIRROR]:-}"
    local mirror_name="${MIRROR_NAME[$REPO_MIRROR]:-未知}"

    log_info "配置YUM镜像源: $mirror_name"

    # 备份原始repo文件
    local backup_dir="/etc/yum.repos.d/backup_$(date +%Y%m%d%H%M%S)"
    if [[ ! -d "$backup_dir" ]]; then
        run_cmd mkdir -p "$backup_dir"
        run_cmd cp /etc/yum.repos.d/*.repo "$backup_dir/" 2>/dev/null || true
        log_info "已备份原始repo文件到: $backup_dir"
    fi

    # 禁用原有repo文件
    for repo_file in /etc/yum.repos.d/*.repo; do
        if [[ -f "$repo_file" ]] && [[ "$(basename "$repo_file")" != "CentOS-Mirror.repo" ]]; then
            run_cmd mv "$repo_file" "${repo_file}.disabled" 2>/dev/null || true
        fi
    done

    # 生成新的repo配置
    local repo_file="/etc/yum.repos.d/CentOS-Mirror.repo"

    if [[ "$REPO_MIRROR" == "aliyun" ]]; then
        run_cmd bash -c "cat > $repo_file" <<'EOF'
# CentOS 7 - 阿里云镜像源
[base]
name=CentOS-$releasever - Base - Aliyun
baseurl=https://mirrors.aliyun.com/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-$releasever - Updates - Aliyun
baseurl=https://mirrors.aliyun.com/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-$releasever - Extras - Aliyun
baseurl=https://mirrors.aliyun.com/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[centosplus]
name=CentOS-$releasever - Plus - Aliyun
baseurl=https://mirrors.aliyun.com/centos/$releasever/centosplus/$basearch/
gpgcheck=1
gpgkey=https://mirrors.aliyun.com/centos/RPM-GPG-KEY-CentOS-7
enabled=0
EOF
    elif [[ "$REPO_MIRROR" == "tsinghua" ]]; then
        run_cmd bash -c "cat > $repo_file" <<'EOF'
# CentOS 7 - 清华大学镜像源
[base]
name=CentOS-$releasever - Base - TUNA
baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=https://mirrors.tuna.tsinghua.edu.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-$releasever - Updates - TUNA
baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=https://mirrors.tuna.tsinghua.edu.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-$releasever - Extras - TUNA
baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=https://mirrors.tuna.tsinghua.edu.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[centosplus]
name=CentOS-$releasever - Plus - TUNA
baseurl=https://mirrors.tuna.tsinghua.edu.cn/centos/$releasever/centosplus/$basearch/
gpgcheck=1
gpgkey=https://mirrors.tuna.tsinghua.edu.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=0
EOF
    elif [[ "$REPO_MIRROR" == "ustc" ]]; then
        run_cmd bash -c "cat > $repo_file" <<'EOF'
# CentOS 7 - 中科大镜像源
[base]
name=CentOS-$releasever - Base - USTC
baseurl=https://mirrors.ustc.edu.cn/centos/$releasever/os/$basearch/
gpgcheck=1
gpgkey=https://mirrors.ustc.edu.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[updates]
name=CentOS-$releasever - Updates - USTC
baseurl=https://mirrors.ustc.edu.cn/centos/$releasever/updates/$basearch/
gpgcheck=1
gpgkey=https://mirrors.ustc.edu.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[extras]
name=CentOS-$releasever - Extras - USTC
baseurl=https://mirrors.ustc.edu.cn/centos/$releasever/extras/$basearch/
gpgcheck=1
gpgkey=https://mirrors.ustc.edu.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=1

[centosplus]
name=CentOS-$releasever - Plus - USTC
baseurl=https://mirrors.ustc.edu.cn/centos/$releasever/centosplus/$basearch/
gpgcheck=1
gpgkey=https://mirrors.ustc.edu.cn/centos/RPM-GPG-KEY-CentOS-7
enabled=0
EOF
    fi

    # 配置EPEL镜像源
    log_info "配置EPEL镜像源"
    if [[ "$REPO_MIRROR" == "aliyun" ]]; then
        run_cmd bash -c "cat > /etc/yum.repos.d/epel-Mirror.repo" <<'EOF'
[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch - Aliyun
baseurl=https://mirrors.aliyun.com/epel/7/$basearch
failovermethod=priority
enabled=1
gpgcheck=0
EOF
    elif [[ "$REPO_MIRROR" == "tsinghua" ]]; then
        run_cmd bash -c "cat > /etc/yum.repos.d/epel-Mirror.repo" <<'EOF'
[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch - TUNA
baseurl=https://mirrors.tuna.tsinghua.edu.cn/epel/7/$basearch
failovermethod=priority
enabled=1
gpgcheck=0
EOF
    elif [[ "$REPO_MIRROR" == "ustc" ]]; then
        run_cmd bash -c "cat > /etc/yum.repos.d/epel-Mirror.repo" <<'EOF'
[epel]
name=Extra Packages for Enterprise Linux 7 - $basearch - USTC
baseurl=https://mirrors.ustc.edu.cn/epel/7/$basearch
failovermethod=priority
enabled=1
gpgcheck=0
EOF
    fi

    # 清除缓存并生成新缓存
    log_info "清除YUM缓存并生成新缓存"
    run_cmd yum clean all || true
    run_cmd yum makecache || true

    log_info "YUM镜像源配置完成: $mirror_name"
}

# ==================== 配置系统环境 ====================
setup_environment() {
    log_info "配置系统环境..."

    # 设置时区
    if [[ ! -f /etc/localtime ]] || ! readlink /etc/localtime | grep -q "Asia/Shanghai"; then
        log_info "设置时区为 Asia/Shanghai"
        run_cmd ln -sf /usr/share/zoneinfo/Asia/Shanghai /etc/localtime
    fi

    # 配置系统语言
    if [[ ! -f /etc/locale.conf ]] || ! grep -q "zh_CN.UTF-8" /etc/locale.conf; then
        log_info "配置系统语言"
        run_cmd bash -c 'echo "LANG=zh_CN.UTF-8" > /etc/locale.conf'
    fi

    # 加载locale
    run_cmd localedef -c -f UTF-8 -i zh_CN zh_CN.UTF-8 2>/dev/null || true

    # 关闭SELinux
    if command -v getenforce &>/dev/null && [[ $(getenforce) != "Disabled" ]]; then
        log_info "关闭SELinux"
        run_cmd setenforce 0 || true
        run_cmd sed -i 's/^SELINUX=enforcing/SELINUX=disabled/' /etc/selinux/config || true
    fi

    # 关闭防火墙 (可选，按需启用)
    if systemctl is-active firewalld &>/dev/null; then
        log_info "关闭防火墙"
        run_cmd systemctl stop firewalld || true
        run_cmd systemctl disable firewalld || true
    fi

    # 配置ulimit
    log_info "配置系统资源限制"
    local limits_conf="/etc/security/limits.conf"
    if ! grep -q "# EnvSetup" "$limits_conf" 2>/dev/null; then
        run_cmd bash -c "cat >> $limits_conf" <<'EOF'

# EnvSetup
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
EOF
    fi

    # 配置内核参数
    log_info "配置内核参数"
    local sysctl_conf="/etc/sysctl.d/99-envsetup.conf"
    if [[ ! -f "$sysctl_conf" ]]; then
        run_cmd bash -c "cat > $sysctl_conf" <<'EOF'
# EnvSetup kernel parameters
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
vm.swappiness = 10
EOF
        run_cmd sysctl -p "$sysctl_conf" || true
    fi

    log_info "系统环境配置完成"
}

# ==================== Docker镜像加速地址 ====================
DOCKER_MIRRORS=(
    "https://docker.1ms.run"
    "https://docker.1panel.live"
    "https://docker.ketches.cn"
)

# ==================== 安装Docker ====================
install_docker() {
    log_info "=== 安装Docker ==="

    # 检查是否已安装Docker
    if command -v docker &>/dev/null; then
        local docker_version
        docker_version=$(docker --version 2>/dev/null || echo "未知")
        log_info "Docker已安装，跳过: $docker_version"
        return 0
    fi

    log_info "开始安装Docker..."

    if [[ "$INSTALL_MODE" == "online" ]]; then
        # 线上安装：使用官方安装脚本或yum
        log_info "使用yum安装Docker"

        # 添加Docker官方仓库
        if [[ ! -f /etc/yum.repos.d/docker-ce.repo ]]; then
            run_cmd yum install -y yum-utils || true

            # 根据镜像源选择Docker仓库
            local docker_repo_url
            case "$REPO_MIRROR" in
                aliyun)
                    docker_repo_url="https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo"
                    ;;
                tsinghua)
                    docker_repo_url="https://mirrors.tuna.tsinghua.edu.cn/docker-ce/linux/centos/docker-ce.repo"
                    ;;
                ustc)
                    docker_repo_url="https://mirrors.ustc.edu.cn/docker-ce/linux/centos/docker-ce.repo"
                    ;;
                *)
                    docker_repo_url="https://download.docker.com/linux/centos/docker-ce.repo"
                    ;;
            esac

            log_info "添加Docker仓库: $docker_repo_url"
            run_cmd yum-config-manager --add-repo "$docker_repo_url" || true
        fi

        # 安装Docker
        run_cmd yum install -y docker-ce docker-ce-cli containerd.io || {
            log_error "Docker安装失败"
            return 1
        }
    else
        # 本地安装：从本地包安装
        log_info "使用本地包安装Docker"

        local docker_packages=("docker-ce" "docker-ce-cli" "containerd.io")
        for pkg in "${docker_packages[@]}"; do
            local rpm_file
            rpm_file=$(find "$PKG_DIR" -name "${pkg}*.rpm" -type f 2>/dev/null | head -1)

            if [[ -n "$rpm_file" ]]; then
                log_info "安装: $pkg"
                run_cmd rpm -ivh --nodeps "$rpm_file" || {
                    log_warn "安装失败: $pkg"
                }
            else
                log_warn "未找到RPM包: $pkg"
            fi
        done
    fi

    # 启动Docker服务
    log_info "启动Docker服务"
    run_cmd systemctl start docker || true
    run_cmd systemctl enable docker || true

    # 配置Docker镜像加速
    setup_docker_mirrors

    log_info "Docker安装完成"
}

# ==================== 配置Docker镜像加速 ====================
setup_docker_mirrors() {
    log_info "配置Docker镜像加速"

    local daemon_json="/etc/docker/daemon.json"

    # 备份现有配置
    if [[ -f "$daemon_json" ]]; then
        run_cmd cp "$daemon_json" "${daemon_json}.bak.$(date +%Y%m%d%H%M%S)" || true
    fi

    # 创建daemon.json配置
    run_cmd mkdir -p /etc/docker

    # 构建镜像列表
    local mirrors_json="["
    local first=true
    for mirror in "${DOCKER_MIRRORS[@]}"; do
        if [[ "$first" == "true" ]]; then
            mirrors_json+="\"$mirror\""
            first=false
        else
            mirrors_json+=", \"$mirror\""
        fi
    done
    mirrors_json+="]"

    # 写入配置
    run_cmd bash -c "cat > $daemon_json" <<EOF
{
    "registry-mirrors": $mirrors_json,
    "log-driver": "json-file",
    "log-opts": {
        "max-size": "100m",
        "max-file": "3"
    },
    "storage-driver": "overlay2"
}
EOF

    log_info "Docker镜像加速配置完成"
    for mirror in "${DOCKER_MIRRORS[@]}"; do
        log_info "  - $mirror"
    done

    # 重启Docker使配置生效
    run_cmd systemctl daemon-reload || true
    run_cmd systemctl restart docker || true
}

# ==================== 安装Docker Compose ====================
install_docker_compose() {
    log_info "=== 安装Docker Compose ==="

    # 检查是否已安装
    if command -v docker-compose &>/dev/null || docker compose version &>/dev/null 2>&1; then
        local compose_version
        compose_version=$(docker-compose --version 2>/dev/null || docker compose version 2>/dev/null || echo "未知")
        log_info "Docker Compose已安装，跳过: $compose_version"
        return 0
    fi

    log_info "开始安装Docker Compose..."

    local compose_version="v2.29.1"
    local compose_url="https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-x86_64"

    # 根据镜像源选择下载地址
    case "$REPO_MIRROR" in
        aliyun)
            compose_url="https://mirrors.aliyun.com/docker-toolbox/linux/compose/${compose_version}/docker-compose-linux-x86_64"
            ;;
        tsinghua)
            compose_url="https://mirrors.tuna.tsinghua.edu.cn/docker-compose/linux/$(uname -s)-$(uname -m)/${compose_version}/docker-compose-linux-x86_64"
            ;;
    esac

    if [[ "$INSTALL_MODE" == "online" ]]; then
        # 线上安装
        log_info "下载Docker Compose: $compose_url"

        # 尝试下载
        run_cmd curl -L "$compose_url" -o /usr/local/bin/docker-compose || {
            # 备用地址
            log_warn "主下载地址失败，尝试备用地址..."
            run_cmd curl -L "https://github.com/docker/compose/releases/download/${compose_version}/docker-compose-linux-x86_64" \
                -o /usr/local/bin/docker-compose || {
                log_error "Docker Compose下载失败"
                return 1
            }
        }
    else
        # 本地安装
        local local_compose="$PKG_DIR/docker-compose"
        if [[ -f "$local_compose" ]]; then
            log_info "使用本地Docker Compose: $local_compose"
            run_cmd cp "$local_compose" /usr/local/bin/docker-compose || {
                log_error "复制Docker Compose失败"
                return 1
            }
        else
            log_error "本地未找到Docker Compose: $local_compose"
            return 1
        fi
    fi

    # 设置执行权限
    run_cmd chmod +x /usr/local/bin/docker-compose || true

    # 创建软链接
    if [[ ! -L /usr/bin/docker-compose ]]; then
        run_cmd ln -sf /usr/local/bin/docker-compose /usr/bin/docker-compose || true
    fi

    # 验证安装
    if docker-compose --version &>/dev/null; then
        local installed_version
        installed_version=$(docker-compose --version)
        log_info "Docker Compose安装成功: $installed_version"
    else
        log_warn "Docker Compose安装后验证失败，但文件已复制"
    fi

    return 0
}

# ==================== 下载RPM包 ====================
download_rpms() {
    local -r download_dir="$1"

    log_info "下载RPM包到: $download_dir"

    mkdir -p "$download_dir" || { log_error "创建下载目录失败"; return 1; }

    for pkg in "${PACKAGES[@]}"; do
        log_info "下载: $pkg"
        run_cmd yumdownloader --resolve --destdir="$download_dir" "$pkg" || {
            log_warn "下载失败: $pkg"
        }
    done

    log_info "RPM包下载完成"
}

# ==================== 生成本地安装包 ====================
generate_offline_packages() {
    local -r output_dir="$SCRIPT_DIR/rpms_centos7"

    log_info "=== 生成本地安装包 ==="
    log_info "输出目录: $output_dir"

    if [[ -d "$output_dir" ]] && [[ -n "$(ls -A "$output_dir" 2>/dev/null)" ]]; then
        log_warn "目录已存在且不为空: $output_dir"
        log_info "如需重新下载，请先删除该目录"
        return 0
    fi

    download_rpms "$output_dir"

    # 生成包列表
    local pkg_list="$output_dir/package_list.txt"
    ls -1 "$output_dir"/*.rpm > "$pkg_list" 2>/dev/null || true

    log_info "本地安装包生成完成"
    log_info "共 $(wc -l < "$pkg_list") 个RPM包"
    log_info "使用方法: $(basename "$0") -m offline -p $output_dir"
}

# ==================== 主安装流程 ====================
main_install() {
    log_info "=== 开始安装基础环境 ==="
    log_info "安装模式: $INSTALL_MODE"
    log_info "日志目录: $OUTPUT_DIR"

    # 检查依赖
    check_dependencies

    # 检查系统
    check_system

    # 配置YUM镜像源 (线上模式)
    if [[ "$INSTALL_MODE" == "online" ]]; then
        setup_yum_mirror
    fi

    # 创建日志目录
    mkdir -p "$OUTPUT_DIR" || { log_error "创建日志目录失败"; exit 1; }

    # 记录安装结果
    local success_count=0
    local fail_count=0
    local skipped_count=0
    local failed_packages=()

    # 安装软件包
    for pkg in "${PACKAGES[@]}"; do
        if [[ "$INSTALL_MODE" == "online" ]]; then
            if online_install "$pkg"; then
                success_count=$((success_count + 1))
            else
                fail_count=$((fail_count + 1))
                failed_packages+=("$pkg")
            fi
        else
            if offline_install "$pkg"; then
                success_count=$((success_count + 1))
            else
                fail_count=$((fail_count + 1))
                failed_packages+=("$pkg")
            fi
        fi
    done

    # 配置系统环境
    setup_environment

    # 安装Docker
    install_docker

    # 安装Docker Compose
    install_docker_compose

    # 汇总结果
    log_info "=== 安装汇总 ==="
    log_info "软件包总数: ${#PACKAGES[@]}"
    log_info "成功安装: $success_count"
    log_info "安装失败: $fail_count"

    if [[ ${#failed_packages[@]} -gt 0 ]]; then
        log_warn "失败的软件包:"
        for pkg in "${failed_packages[@]}"; do
            log_warn "  - $pkg"
        done
    fi

    if [[ $fail_count -gt 0 ]]; then
        log_error "部分软件包安装失败，请检查日志"
        return 1
    fi

    log_info "=== 基础环境安装完成 ==="
    return 0
}

# ==================== 主函数 ====================
main() {
    log_info "CentOS 7 基础环境安装脚本"
    log_info "脚本路径: $SCRIPT_DIR/$(basename "$0")"

    # 安全获取镜像源名称
    local mirror_display="${MIRROR_NAME[$REPO_MIRROR]:-未知}"
    log_info "镜像源: $mirror_display"

    # 如果指定了生成离线包，则执行下载
    if [[ "${GENERATE_OFFLINE:-}" == "1" ]]; then
        generate_offline_packages
        return $?
    fi

    main_install
}

# 执行主函数
main "$@"
