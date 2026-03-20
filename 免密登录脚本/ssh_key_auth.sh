#!/bin/bash
set -Eeuo pipefail

# SSH免密认证部署脚本
# 在多台服务器之间建立免密SSH认证

# 严格模式 + 错误捕获
trap 'log_error "脚本执行出错，行号: $LINENO"' ERR

# 日志函数
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

# 检查依赖
check_dependencies() {
    local -a missing_deps=()
    local -a required=("ssh-keygen" "ssh-copy-id" "ssh" "sshpass")

    for cmd in "${required[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            missing_deps+=("$cmd")
        fi
    done

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "缺少必要命令: ${missing_deps[*]}"
        log_info "请使用以下命令安装: brew install ${missing_deps[*]}"
        return 1
    fi
}

# 使用说明
usage() {
    cat <<EOF
用法: $(basename "$0") [选项]

在多台服务器之间建立免密SSH认证。

选项:
    -f, --file 文件          服务器列表文件 (格式: 每行 ip 用户名 密码)
    -k, --key 路径           SSH私钥路径 (默认: ~/.ssh/id_rsa)
    -p, --port 端口          SSH端口 (默认: 22)
    -t, --timeout 秒数       连接超时时间 (默认: 10)
    -o, --output 目录        密钥/日志输出目录 (默认: 当前目录)
    -c, --cross              交叉认证模式（服务器之间互相免密）
    --force                  强制重新生成密钥
    -v, --verbose            启用详细输出
    -d, --dry-run            试运行模式，不实际执行
    -h, --help               显示此帮助信息

服务器列表文件格式 (每行一台服务器):
    ip 用户名 密码

示例:
    # 单向认证（控制机到各服务器）
    $(basename "$0") -f servers.txt

    # 交叉认证（服务器之间互相免密）
    $(basename "$0") -f servers.txt -c

    # 强制重新生成密钥
    $(basename "$0") -f servers.txt --force
EOF
    exit "${1:-0}"
}

# 默认值
SERVER_FILE=""
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
SSH_PORT=22
SSH_TIMEOUT=10
OUTPUT_DIR=""
VERBOSE=false
DRY_RUN=false
CROSS_MODE=false
FORCE_MODE=false

# 脚本目录
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_NAME="$(basename -- "${BASH_SOURCE[0]}")"

# 解析参数
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--file)
            SERVER_FILE="$2"
            shift 2
            ;;
        -k|--key)
            SSH_KEY_PATH="$2"
            shift 2
            ;;
        -p|--port)
            SSH_PORT="$2"
            shift 2
            ;;
        -t|--timeout)
            SSH_TIMEOUT="$2"
            shift 2
            ;;
        -o|--output)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        -c|--cross)
            CROSS_MODE=true
            shift
            ;;
        --force)
            FORCE_MODE=true
            shift
            ;;
        -v|--verbose)
            VERBOSE=true
            DEBUG=1
            shift
            ;;
        -d|--dry-run)
            DRY_RUN=true
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

# 验证必要参数
[[ -n "$SERVER_FILE" ]] || { log_error "缺少必要参数: -f/--file"; usage 1; }
[[ -f "$SERVER_FILE" ]] || { log_error "服务器文件不存在: $SERVER_FILE"; exit 1; }

# 设置输出目录
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$SCRIPT_DIR/ssh_auth_output"
fi

# 临时目录
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

# 试运行模式
run_cmd() {
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[试运行] 将执行: $*"
        return 0
    fi
    "$@"
}

# 验证服务器列表文件格式
validate_server_file() {
    local line_num=0

    while IFS= read -r line; do
        line_num=$((line_num + 1))
        # 移除Windows换行符
        line="${line%$'\r'}"
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        # 解析字段
        read -r ip user password <<< "$line"

        if [[ -z "$ip" || -z "$user" || -z "$password" ]]; then
            log_error "第 $line_num 行格式错误: 期望 'ip 用户名 密码' (当前: ip='$ip' user='$user')"
            return 1
        fi

        # 验证IP格式
        if ! [[ "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            log_warn "第 $line_num 行: IP地址格式可能无效: $ip"
        fi
    done < "$SERVER_FILE"

    log_info "服务器文件验证通过"
}

# 生成SSH密钥
generate_ssh_key() {
    local key_dir
    key_dir=$(dirname "$SSH_KEY_PATH")

    if [[ ! -d "$key_dir" ]]; then
        run_cmd mkdir -p "$key_dir" || { log_error "创建.ssh目录失败"; return 1; }
    fi

    # 强制模式：删除旧密钥
    if [[ "$FORCE_MODE" == "true" && -f "$SSH_KEY_PATH" ]]; then
        log_info "强制模式：删除旧密钥 $SSH_KEY_PATH"
        run_cmd rm -f "$SSH_KEY_PATH" "$SSH_KEY_PATH.pub"
    fi

    if [[ ! -f "$SSH_KEY_PATH" ]]; then
        log_info "正在生成SSH密钥: $SSH_KEY_PATH"
        run_cmd ssh-keygen -t rsa -b 4096 -f "$SSH_KEY_PATH" -N "" -C "ssh_auth_setup"
    else
        log_info "SSH密钥已存在: $SSH_KEY_PATH"
    fi
}

# 为单台服务器设置认证
setup_server_auth() {
    local -r ip="$1"
    local -r user="$2"
    local -r password="$3"
    local log_file="$TMPDIR/${ip}.log"

    log_info "正在为 ${user}@${ip} 配置认证"

    # 非强制模式：检查是否已认证
    if [[ "$FORCE_MODE" != "true" ]]; then
        if ssh -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" -o BatchMode=yes \
               -i "$SSH_KEY_PATH" -p "$SSH_PORT" "${user}@${ip}" "exit 0" 2>/dev/null; then
            log_info "已认证，跳过: ${user}@${ip}"
            return 0
        fi
    fi

    # 试运行模式
    if [[ "$DRY_RUN" == "true" ]]; then
        log_info "[试运行] 将复制SSH密钥到 ${user}@${ip}"
        return 0
    fi

    # 使用sshpass提供密码
    SSHPASS="$password" sshpass -e ssh-copy-id \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -i "$SSH_KEY_PATH.pub" \
        -p "$SSH_PORT" \
        "${user}@${ip}" > "$log_file" 2>&1 || {
            log_error "为 ${user}@${ip} 配置认证失败"
            cat "$log_file" >&2
            return 1
        }

    log_info "已成功为 ${user}@${ip} 配置认证"
    return 0
}

# 验证认证
verify_auth() {
    local -r ip="$1"
    local -r user="$2"

    log_info "正在验证 ${user}@${ip} 的认证"

    # 使用临时文件捕获错误信息
    local tmp_err
    tmp_err=$(mktemp)

    local result
    result=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout="$SSH_TIMEOUT" \
           -o BatchMode=yes \
           -i "$SSH_KEY_PATH" -p "$SSH_PORT" \
           "${user}@${ip}" "echo 'SSH_AUTH_SUCCESS'" 2>"$tmp_err") || true

    if [[ "$result" == "SSH_AUTH_SUCCESS" ]]; then
        log_info "验证通过: ${user}@${ip}"
        rm -f "$tmp_err"
        return 0
    else
        log_warn "验证失败: ${user}@${ip}"
        # 输出SSH错误信息帮助调试
        if [[ -s "$tmp_err" ]]; then
            log_debug "SSH错误信息:"
            while IFS= read -r err_line; do
                log_debug "  $err_line"
            done < "$tmp_err"
        fi
        rm -f "$tmp_err"
        return 1
    fi
}

# 检查服务器上的密钥配置
check_server_key() {
    local -r ip="$1"
    local -r user="$2"
    local -r password="$3"

    log_info "检查 ${user}@${ip} 上的密钥配置"

    # 获取本地公钥内容
    local local_pubkey
    local_pubkey=$(cat "$SSH_KEY_PATH.pub" 2>/dev/null)

    if [[ -z "$local_pubkey" ]]; then
        log_warn "无法读取本地公钥: $SSH_KEY_PATH.pub"
        return 1
    fi

    # 检查远程服务器上的authorized_keys
    local remote_keys
    remote_keys=$(SSHPASS="$password" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -p "$SSH_PORT" \
        "${user}@${ip}" "cat ~/.ssh/authorized_keys 2>/dev/null || echo 'FILE_NOT_FOUND'" 2>/dev/null) || true

    if [[ "$remote_keys" == "FILE_NOT_FOUND" ]]; then
        log_warn "远程服务器上不存在 ~/.ssh/authorized_keys"
        return 1
    fi

    # 检查公钥是否在authorized_keys中
    local pubkey_fingerprint
    pubkey_fingerprint=$(echo "$local_pubkey" | awk '{print $2}')

    if echo "$remote_keys" | grep -q "$pubkey_fingerprint"; then
        log_info "公钥已存在于远程服务器的 authorized_keys 中"
        return 0
    else
        log_warn "公钥未找到于远程服务器的 authorized_keys 中"
        log_debug "本地公钥指纹: ${pubkey_fingerprint:0:20}..."
        return 1
    fi
}

# 自动修复SSH认证问题
fix_ssh_auth() {
    local -r ip="$1"
    local -r user="$2"
    local -r password="$3"

    log_info "正在自动修复 ${user}@${ip} 的SSH认证问题..."

    local local_pubkey
    local_pubkey=$(cat "$SSH_KEY_PATH.pub" 2>/dev/null)

    if [[ -z "$local_pubkey" ]]; then
        log_error "无法读取本地公钥: $SSH_KEY_PATH.pub"
        return 1
    fi

    # 在远程服务器上执行修复命令
    SSHPASS="$password" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -p "$SSH_PORT" \
        "${user}@${ip}" bash -s <<REMOTE_SCRIPT
set -e

echo "开始修复SSH认证..."

# 1. 创建.ssh目录并设置权限
mkdir -p ~/.ssh
chmod 700 ~/.ssh
echo "[1/5] .ssh目录权限已设置为700"

# 2. 创建或更新authorized_keys
if [[ ! -f ~/.ssh/authorized_keys ]]; then
    touch ~/.ssh/authorized_keys
    echo "[2/5] authorized_keys 文件已创建"
else
    echo "[2/5] authorized_keys 文件已存在"
fi

# 3. 设置authorized_keys权限
chmod 600 ~/.ssh/authorized_keys
echo "[3/5] authorized_keys 权限已设置为600"

# 4. 添加公钥（如果不存在）
PUBKEY="$local_pubkey"
PUBKEY_FINGERPRINT=\$(echo "\$PUBKEY" | awk '{print \$2}')

if ! grep -qF "\$PUBKEY_FINGERPRINT" ~/.ssh/authorized_keys 2>/dev/null; then
    echo "\$PUBKEY" >> ~/.ssh/authorized_keys
    echo "[4/5] 公钥已添加到authorized_keys"
else
    echo "[4/5] 公钥已存在于authorized_keys中"
fi

# 5. 检查SSH配置
if grep -q "^PubkeyAuthentication no" /etc/ssh/sshd_config 2>/dev/null; then
    sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
    systemctl restart sshd 2>/dev/null || service sshd restart 2>/dev/null || true
    echo "[5/5] PubkeyAuthentication已启用并重启sshd"
else
    echo "[5/5] SSH配置正常"
fi

# 修复SELinux上下文（如果启用）
if command -v restorecon &>/dev/null; then
    restorecon -R -v ~/.ssh/ 2>/dev/null || true
    echo "[附加] SELinux上下文已修复"
fi

echo "SSH认证修复完成"
REMOTE_SCRIPT

    local exit_code=$?
    if [[ $exit_code -eq 0 ]]; then
        log_info "${user}@${ip} SSH认证修复成功"
        return 0
    else
        log_error "${user}@${ip} SSH认证修复失败"
        return 1
    fi
}

# 在服务器上生成密钥并获取公钥
get_server_public_key() {
    local -r ip="$1"
    local -r user="$2"
    local -r password="$3"

    log_debug "获取 ${user}@${ip} 的公钥"

    # 在远程服务器上生成密钥（如果不存在或强制模式）
    SSHPASS="$password" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -p "$SSH_PORT" \
        "${user}@${ip}" "
            if [[ ! -f ~/.ssh/id_rsa ]] || [[ '$FORCE_MODE' == 'true' ]]; then
                mkdir -p ~/.ssh && chmod 700 ~/.ssh
                rm -f ~/.ssh/id_rsa ~/.ssh/id_rsa.pub
                ssh-keygen -t rsa -b 4096 -f ~/.ssh/id_rsa -N '' -C '${user}@${ip}' >/dev/null 2>&1
            fi
            cat ~/.ssh/id_rsa.pub
        " 2>/dev/null
}

# 将公钥复制到目标服务器
copy_key_to_server() {
    local -r target_ip="$1"
    local -r target_user="$2"
    local -r target_password="$3"
    local -r pubkey="$4"

    log_debug "复制公钥到 ${target_user}@${target_ip}"

    SSHPASS="$target_password" sshpass -e ssh \
        -o StrictHostKeyChecking=no \
        -o ConnectTimeout="$SSH_TIMEOUT" \
        -p "$SSH_PORT" \
        "${target_user}@${target_ip}" "
            mkdir -p ~/.ssh && chmod 700 ~/.ssh
            if ! grep -qF '$pubkey' ~/.ssh/authorized_keys 2>/dev/null; then
                echo '$pubkey' >> ~/.ssh/authorized_keys
                chmod 600 ~/.ssh/authorized_keys
                echo 'KEY_ADDED'
            else
                echo 'KEY_EXISTS'
            fi
        " 2>/dev/null
}

# 交叉认证：服务器之间互相免密
setup_cross_auth() {
    if [[ "$CROSS_MODE" != "true" ]]; then
        return 0
    fi

    log_info "=== 开始交叉认证（服务器之间互相免密）==="

    # 读取所有服务器信息到数组
    declare -a SERVER_IPS=()
    declare -a SERVER_USERS=()
    declare -a SERVER_PASSWORDS=()

    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        read -r ip user password <<< "$line"
        SERVER_IPS+=("$ip")
        SERVER_USERS+=("$user")
        SERVER_PASSWORDS+=("$password")
    done < "$SERVER_FILE"

    local total=${#SERVER_IPS[@]}

    # 为每对服务器建立双向认证
    for ((i=0; i<total; i++)); do
        for ((j=0; j<total; j++)); do
            # 跳过自己到自己
            if [[ $i -eq $j ]]; then
                continue
            fi

            local src_ip="${SERVER_IPS[$i]}"
            local src_user="${SERVER_USERS[$i]}"
            local src_pass="${SERVER_PASSWORDS[$i]}"
            local dst_ip="${SERVER_IPS[$j]}"
            local dst_user="${SERVER_USERS[$j]}"
            local dst_pass="${SERVER_PASSWORDS[$j]}"

            log_info "配置 ${src_user}@${src_ip} -> ${dst_user}@${dst_ip} 免密"

            # 获取源服务器的公钥
            local pubkey
            pubkey=$(get_server_public_key "$src_ip" "$src_user" "$src_pass")

            if [[ -z "$pubkey" ]]; then
                log_warn "无法获取 ${src_user}@${src_ip} 的公钥，跳过"
                continue
            fi

            # 将公钥复制到目标服务器
            local result
            result=$(copy_key_to_server "$dst_ip" "$dst_user" "$dst_pass" "$pubkey")

            if [[ "$result" == "KEY_ADDED" ]]; then
                log_info "已添加: ${src_user}@${src_ip} -> ${dst_user}@${dst_ip}"
            elif [[ "$result" == "KEY_EXISTS" ]]; then
                log_info "已存在: ${src_user}@${src_ip} -> ${dst_user}@${dst_ip}"
            else
                log_warn "失败: ${src_user}@${src_ip} -> ${dst_user}@${dst_ip}"
            fi
        done
    done

    log_info "=== 交叉认证完成 ==="
}

# 验证交叉认证
verify_cross_auth() {
    if [[ "$CROSS_MODE" != "true" ]]; then
        return 0
    fi

    log_info "=== 验证交叉认证 ==="

    # 读取所有服务器信息到数组
    declare -a SERVER_IPS=()
    declare -a SERVER_USERS=()
    declare -a SERVER_PASSWORDS=()

    while IFS= read -r line; do
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        read -r ip user password <<< "$line"
        SERVER_IPS+=("$ip")
        SERVER_USERS+=("$user")
        SERVER_PASSWORDS+=("$password")
    done < "$SERVER_FILE"

    local total=${#SERVER_IPS[@]}
    local success=0
    local fail=0

    # 验证每对服务器的双向认证
    for ((i=0; i<total; i++)); do
        for ((j=0; j<total; j++)); do
            if [[ $i -eq $j ]]; then
                continue
            fi

            local src_ip="${SERVER_IPS[$i]}"
            local src_user="${SERVER_USERS[$i]}"
            local src_pass="${SERVER_PASSWORDS[$i]}"
            local dst_ip="${SERVER_IPS[$j]}"
            local dst_user="${SERVER_USERS[$j]}"

            log_info "验证 ${src_user}@${src_ip} -> ${dst_user}@${dst_ip}"

            # 从源服务器SSH到目标服务器测试
            local result=""
            result=$(SSHPASS="$src_pass" sshpass -e ssh \
                -o StrictHostKeyChecking=no \
                -o ConnectTimeout="$SSH_TIMEOUT" \
                -o BatchMode=yes \
                -p "$SSH_PORT" \
                "${src_user}@${src_ip}" \
                "ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 -o BatchMode=yes ${dst_user}@${dst_ip} 'echo OK'" 2>/dev/null) || true

            if [[ "$result" == "OK" ]]; then
                log_info "验证通过: ${src_user}@${src_ip} -> ${dst_user}@${dst_ip}"
                success=$((success + 1))
            else
                log_warn "验证失败: ${src_user}@${src_ip} -> ${dst_user}@${dst_ip}"
                fail=$((fail + 1))
            fi
        done
    done

    log_info "交叉认证验证结果: 成功 $success, 失败 $fail"
}

# 主函数
main() {
    log_info "开始SSH免密认证部署"
    log_info "脚本路径: $SCRIPT_DIR/$SCRIPT_NAME"
    log_info "服务器文件: $SERVER_FILE"
    log_info "SSH密钥: $SSH_KEY_PATH"
    log_info "SSH端口: $SSH_PORT"
    log_info "交叉认证: $([ "$CROSS_MODE" = "true" ] && echo "启用" || echo "禁用")"
    log_info "强制模式: $([ "$FORCE_MODE" = "true" ] && echo "启用" || echo "禁用")"

    # 检查依赖
    check_dependencies

    # 验证服务器文件
    validate_server_file

    # 创建输出目录
    mkdir -p "$OUTPUT_DIR" || { log_error "创建输出目录失败"; exit 1; }

    # 生成SSH密钥
    generate_ssh_key

    # 记录成功/失败数量
    local success_count=0
    local fail_count=0
    local failed_servers=()

    # 处理每台服务器（单向认证：控制机到服务器）
    log_info "=== 阶段1：控制机到服务器认证 ==="
    while IFS= read -r line; do
        # 移除Windows换行符
        line="${line%$'\r'}"
        # 跳过空行和注释
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        read -r ip user password <<< "$line"

        if setup_server_auth "$ip" "$user" "$password"; then
            success_count=$((success_count + 1))
        else
            fail_count=$((fail_count + 1))
            failed_servers+=("${user}@${ip}")
        fi
    done < "$SERVER_FILE"

    # 验证单向认证
    log_info "=== 阶段2：验证控制机认证 ==="
    local verify_fail_count=0
    local fixed_count=0

    while IFS= read -r line; do
        # 移除Windows换行符
        line="${line%$'\r'}"
        [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue

        read -r ip user password <<< "$line"

        if ! verify_auth "$ip" "$user"; then
            verify_fail_count=$((verify_fail_count + 1))
            
            # 尝试自动修复
            log_info "检测到认证失败，尝试自动修复..."
            if fix_ssh_auth "$ip" "$user" "$password"; then
                # 修复后重新验证
                log_info "修复完成，重新验证..."
                if verify_auth "$ip" "$user"; then
                    log_info "修复成功！${user}@${ip} 现在可以免密登录"
                    fixed_count=$((fixed_count + 1))
                    verify_fail_count=$((verify_fail_count - 1))
                else
                    log_warn "修复后仍然验证失败，请手动检查"
                fi
            fi
        fi
    done < "$SERVER_FILE"

    # 交叉认证（服务器之间互相免密）
    if [[ "$CROSS_MODE" == "true" ]]; then
        setup_cross_auth
        verify_cross_auth
    fi

    # 汇总结果
    log_info "=== 部署汇总 ==="
    log_info "处理服务器总数: $((success_count + fail_count))"
    log_info "成功: $success_count"
    log_info "失败: $fail_count"

    if [[ ${#failed_servers[@]} -gt 0 ]]; then
        log_warn "失败的服务器:"
        for server in "${failed_servers[@]}"; do
            log_warn "  - $server"
        done
    fi

    if [[ $fixed_count -gt 0 ]]; then
        log_info "自动修复成功: $fixed_count 台服务器"
    fi

    if [[ $verify_fail_count -gt 0 ]]; then
        log_warn "=== 验证失败诊断 ==="
        log_warn "$verify_fail_count 台服务器验证失败，请手动检查以下可能原因："
        log_warn "  1. 服务器SSH配置不允许公钥认证 (PubkeyAuthentication)"
        log_warn "  2. authorized_keys 文件权限问题 (应为 600)"
        log_warn "  3. .ssh 目录权限问题 (应为 700)"
        log_warn "  4. SELinux 阻止了SSH访问"
        log_warn ""
        log_warn "建议手动检查："
        log_warn "  ssh -v -i $SSH_KEY_PATH root@<服务器IP>"
    fi

    log_info "SSH免密认证部署完成"
    return 0
}

# 执行主函数
main "$@"
