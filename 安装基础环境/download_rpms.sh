#!/bin/bash
set -Eeuo pipefail

# CentOS 7 离线包下载脚本
# 用于生成本地安装所需的RPM包

# 严格模式 + 错误捕获
trap 'echo "[错误] 脚本执行出错，行号: $LINENO" >&2' ERR

# 脚本目录
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DOWNLOAD_DIR="$SCRIPT_DIR/rpms_centos7"

# Docker Compose 版本
DOCKER_COMPOSE_VERSION="v2.29.1"

# 软件包列表
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

    # Docker相关
    "docker-ce"
    "docker-ce-cli"
    "containerd.io"
)

# 下载Docker Compose
download_docker_compose() {
    local target_file="$DOWNLOAD_DIR/docker-compose"

    echo ""
    echo "=== 下载Docker Compose ==="

    if [[ -f "$target_file" ]]; then
        echo "Docker Compose已存在，跳过下载"
        return 0
    fi

    # Docker Compose下载地址（国内镜像优先）
    local -a compose_urls=(
        "https://mirrors.aliyun.com/docker-toolbox/linux/compose/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64"
        "https://github.com/docker/compose/releases/download/${DOCKER_COMPOSE_VERSION}/docker-compose-linux-x86_64"
    )

    # 检查下载工具
    local download_cmd=""
    if command -v curl &>/dev/null; then
        download_cmd="curl"
    elif command -v wget &>/dev/null; then
        download_cmd="wget"
    else
        echo "[错误] 缺少下载工具: curl 或 wget"
        return 1
    fi

    # 尝试下载
    for url in "${compose_urls[@]}"; do
        echo "尝试下载: $url"

        if [[ "$download_cmd" == "curl" ]]; then
            if curl -L -o "$target_file" "$url" 2>/dev/null; then
                echo "  下载成功"
                chmod +x "$target_file"
                return 0
            fi
        else
            if wget -O "$target_file" "$url" 2>/dev/null; then
                echo "  下载成功"
                chmod +x "$target_file"
                return 0
            fi
        fi
        echo "  下载失败，尝试下一个地址"
    done

    echo "[错误] Docker Compose下载失败"
    return 1
}

# 添加Docker仓库
setup_docker_repo() {
    echo ""
    echo "=== 配置Docker仓库 ==="

    # 安装yum-utils
    if ! command -v yumdownloader &>/dev/null; then
        yum install -y yum-utils 2>/dev/null || true
    fi

    # 检查Docker仓库是否已配置
    if [[ -f /etc/yum.repos.d/docker-ce.repo ]]; then
        echo "Docker仓库已配置，跳过"
        return 0
    fi

    # 添加Docker阿里云仓库
    echo "添加Docker仓库: 阿里云镜像"
    yum-config-manager --add-repo https://mirrors.aliyun.com/docker-ce/linux/centos/docker-ce.repo 2>/dev/null || {
        echo "[警告] 添加Docker仓库失败，尝试使用官方仓库"
        yum-config-manager --add-repo https://download.docker.com/linux/centos/docker-ce.repo 2>/dev/null || true
    }

    echo "Docker仓库配置完成"
}

# 检查依赖
if ! command -v yumdownloader &>/dev/null; then
    echo "[错误] 缺少必要命令: yumdownloader" >&2
    echo "[提示] 请先安装: yum install -y yum-utils" >&2
    exit 1
fi

# 创建下载目录
mkdir -p "$DOWNLOAD_DIR"

echo "=== CentOS 7 离线包下载脚本 ==="
echo "下载目录: $DOWNLOAD_DIR"
echo ""

# 配置Docker仓库（用于下载Docker包）
setup_docker_repo

echo ""
echo "=== 下载RPM包 ==="

# 下载软件包
total=${#PACKAGES[@]}
current=0
failed=()

for pkg in "${PACKAGES[@]}"; do
    current=$((current + 1))
    echo "[$current/$total] 下载: $pkg"

    if yumdownloader --resolve --destdir="$DOWNLOAD_DIR" "$pkg" 2>/dev/null; then
        echo "  成功"
    else
        echo "  失败"
        failed+=("$pkg")
    fi
done

# 下载Docker Compose
download_docker_compose

echo ""
echo "=== 下载完成 ==="

# 生成包列表
ls -1 "$DOWNLOAD_DIR"/*.rpm > "$DOWNLOAD_DIR/package_list.txt" 2>/dev/null || true
rpm_count=$(ls -1 "$DOWNLOAD_DIR"/*.rpm 2>/dev/null | wc -l)

echo "共下载 ${rpm_count} 个RPM包"

# 检查Docker Compose
if [[ -f "$DOWNLOAD_DIR/docker-compose" ]]; then
    compose_version=$("$DOWNLOAD_DIR/docker-compose" --version 2>/dev/null || echo "未知版本")
    echo "Docker Compose: $compose_version"
fi

# 列出失败的包
if [[ ${#failed[@]} -gt 0 ]]; then
    echo ""
    echo "以下包下载失败:"
    for pkg in "${failed[@]}"; do
        echo "  - $pkg"
    done
fi

echo ""
echo "=== 目录结构 ==="
echo "rpms_centos7/"
echo "├── *.rpm ($rpm_count 个文件)"
if [[ -f "$DOWNLOAD_DIR/docker-compose" ]]; then
    echo "└── docker-compose"
fi

echo ""
echo "使用方法:"
echo "  将 rpms_centos7 目录拷贝到目标服务器"
echo "  运行: ./setup_centos7.sh -m offline -p /path/to/rpms_centos7"
