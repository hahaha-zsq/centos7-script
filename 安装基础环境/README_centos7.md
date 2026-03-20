# CentOS 7 基础环境安装脚本

## 概述

本脚本用于批量安装CentOS 7服务器的基础环境，支持**线上安装**和**本地安装**两种模式，适用于生产环境部署和离线服务器环境。

## 功能特性

- 支持线上安装（从yum仓库）
- 支持本地安装（从离线RPM包）
- 支持国内镜像源（阿里云、清华、中科大）
- 幂等设计，已安装的软件包自动跳过
- 自动配置系统环境（时区、语言、ulimit、内核参数等）
- 试运行模式
- 详细日志输出
- 可批量下载RPM包用于离线部署

## 文件说明

| 文件 | 说明 |
|------|------|
| `setup_centos7.sh` | 主安装脚本 |
| `download_rpms.sh` | RPM包下载脚本（用于离线部署） |
| `rpms_centos7/` | 下载的RPM包目录（自动生成） |

## 环境要求

- CentOS 7.x
- root权限
- 线上模式需要网络连接

## 使用方法

### 方式一：线上安装

适用于可访问互联网的服务器：

```bash
# 赋予执行权限
chmod +x setup_centos7.sh

# 线上安装 (默认使用阿里云镜像)
./setup_centos7.sh -m online

# 使用清华镜像源
./setup_centos7.sh -m online -r tsinghua

# 使用中科大镜像源
./setup_centos7.sh -m online -r ustc

# 使用官方源
./setup_centos7.sh -m online -r default

# 试运行（不实际执行）
./setup_centos7.sh -m online -d

# 详细输出
./setup_centos7.sh -m online -v
```

### 方式二：本地安装

适用于无法访问互联网的服务器，需先在有网络的服务器上下载RPM包。

**步骤1：下载RPM包（在有网络的服务器上）**

```bash
# 安装yum-utils
yum install -y yum-utils

# 运行下载脚本
chmod +x download_rpms.sh
./download_rpms.sh
```

下载完成后会生成 `rpms_centos7/` 目录。

**步骤2：拷贝文件到目标服务器**

将以下文件/目录拷贝到目标服务器：
- `setup_centos7.sh`
- `rpms_centos7/` 目录

**步骤3：执行安装（在目标服务器上）**

```bash
chmod +x setup_centos7.sh

# 本地安装
./setup_centos7.sh -m offline -p ./rpms_centos7

# 试运行
./setup_centos7.sh -m offline -p ./rpms_centos7 -d
```

## 参数说明

| 参数 | 长参数 | 说明 | 必填 |
|------|--------|------|------|
| `-m` | `--mode` | 安装模式: `online` 或 `offline` | 是 |
| `-p` | `--pkg-dir` | RPM包目录路径（本地模式必填） | 本地模式是 |
| `-r` | `--repo` | YUM镜像源: `aliyun`/`tsinghua`/`ustc`/`default` | 否 |
| `-o` | `--output` | 日志输出目录 | 否 |
| `-d` | `--dry-run` | 试运行模式 | 否 |
| `-v` | `--verbose` | 启用详细输出 | 否 |
| `-h` | `--help` | 显示帮助信息 | 否 |

### 支持的镜像源

| 参数值 | 镜像源 | 说明 |
|--------|--------|------|
| `aliyun` | 阿里云 | 默认，国内速度快 |
| `tsinghua` | 清华大学 | TUNA镜像站 |
| `ustc` | 中科大 | USTC镜像站 |
| `default` | 官方源 | CentOS官方YUM源 |

## 安装的软件包

### 基础工具
| 包名 | 说明 |
|------|------|
| vim | 文本编辑器 |
| wget | 下载工具 |
| curl | HTTP客户端 |
| net-tools | 网络工具集 |
| lsof | 列出打开文件 |
| iotop | IO监控 |
| htop | 进程监控 |
| tree | 目录树查看 |
| zip/unzip | 压缩解压 |
| tar | 归档工具 |
| lrzsz | 文件传输 |

### 开发工具
| 包名 | 说明 |
|------|------|
| gcc/gcc-c++ | C/C++编译器 |
| make/cmake | 构建工具 |
| openssl-devel | OpenSSL开发库 |
| zlib-devel | 压缩库 |
| bzip2-devel | bzip2开发库 |
| readline-devel | 行编辑库 |
| sqlite-devel | SQLite开发库 |
| libffi-devel | FFI开发库 |

### 运维工具
| 包名 | 说明 |
|------|------|
| sysstat | 系统性能监控 |
| tcpdump | 网络抓包 |
| nmap | 网络扫描 |
| telnet/nc | 网络测试 |
| psmisc | 进程管理 |
| bash-completion | 命令补全 |
| epel-release | EPEL仓库 |

### SSH免密登录工具
| 包名 | 说明 |
|------|------|
| sshpass | 非交互式SSH密码输入 |
| openssh-clients | SSH客户端 (ssh, ssh-copy-id, scp, sftp) |
| openssh-server | SSH服务端 |

## 系统配置

脚本会自动配置以下系统参数：

### 时区和语言
- 时区：`Asia/Shanghai`
- 语言：`zh_CN.UTF-8`

### 安全配置
- 关闭SELinux
- 关闭防火墙

### 资源限制 (/etc/security/limits.conf)
```
* soft nofile 65535
* hard nofile 65535
* soft nproc 65535
* hard nproc 65535
```

### 内核参数 (/etc/sysctl.d/99-envsetup.conf)
```
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp_keepalive_time = 1200
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_max_tw_buckets = 5000
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 4096
vm.swappiness = 10
```

## 输出示例

```
[2026-03-20 10:00:00] 信息: CentOS 7 基础环境安装脚本
[2026-03-20 10:00:00] 信息: 脚本路径: /opt/scripts/setup_centos7.sh
[2026-03-20 10:00:00] 信息: === 开始安装基础环境 ===
[2026-03-20 10:00:00] 信息: 安装模式: online
[2026-03-20 10:00:00] 信息: 检查系统环境...
[2026-03-20 10:00:00] 信息: 系统版本: CentOS Linux release 7.9.2009 (Core)
[2026-03-20 10:00:00] 信息: 系统检查通过
[2026-03-20 10:00:01] 信息: 线上安装: vim
[2026-03-20 10:00:03] 信息: 安装成功: vim
[2026-03-20 10:00:03] 信息: 线上安装: wget
[2026-03-20 10:00:05] 信息: 安装成功: wget
...
[2026-03-20 10:05:00] 信息: === 安装汇总 ===
[2026-03-20 10:05:00] 信息: 软件包总数: 33
[2026-03-20 10:05:00] 信息: 成功安装: 33
[2026-03-20 10:05:00] 信息: 安装失败: 0
[2026-03-20 10:05:00] 信息: === 基础环境安装完成 ===
```

## 批量部署

### 使用SSH批量部署

```bash
# 服务器列表
SERVERS=("192.168.1.10" "192.168.1.11" "192.168.1.12")

for server in "${SERVERS[@]}"; do
    echo "部署到: $server"

    # 拷贝文件
    scp setup_centos7.sh rpms_centos7/ root@${server}:/opt/

    # 执行安装
    ssh root@${server} "cd /opt && chmod +x setup_centos7.sh && ./setup_centos7.sh -m offline -p ./rpms_centos7"
done
```

### 使用Ansible批量部署

```yaml
- name: 安装基础环境
  hosts: centos7_servers
  become: yes
  tasks:
    - name: 拷贝安装脚本
      copy:
        src: setup_centos7.sh
        dest: /opt/setup_centos7.sh
        mode: '0755'

    - name: 拷贝RPM包
      copy:
        src: rpms_centos7/
        dest: /opt/rpms_centos7/

    - name: 执行安装脚本
      command: /opt/setup_centos7.sh -m offline -p /opt/rpms_centos7
      args:
        creates: /var/log/env_setup/
```

## 故障排查

### 常见问题

| 问题 | 原因 | 解决方法 |
|------|------|----------|
| `请使用root用户运行` | 权限不足 | `sudo ./setup_centos7.sh` |
| `RPM包目录不存在` | 路径错误 | 检查 `-p` 参数 |
| `未找到RPM包` | 包名不匹配 | 重新下载RPM包 |
| `安装失败` | 依赖冲突 | 检查日志，手动解决依赖 |

### 查看日志

```bash
# 查看安装日志
ls /var/log/env_setup/

# 查看yum日志
tail -f /var/log/yum.log
```

## 安全注意事项

1. 线上安装请确保使用官方yum源
2. 本地RPM包需从可信来源获取
3. 安装后建议检查系统配置是否符合安全要求
4. 关闭SELinux和防火墙可能降低安全性，生产环境请按需配置

## 设计原则

本脚本遵循以下防御性编程原则：
- `set -Eeuo pipefail` 严格模式
- ERR trap 错误捕获
- EXIT trap 清理临时文件
- 幂等设计（已安装跳过）
- 结构化日志输出
- 输入验证和依赖检查
