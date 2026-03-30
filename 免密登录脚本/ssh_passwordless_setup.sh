#!/bin/bash

# 配置部分
SSH_KEY_PATH="$HOME/.ssh/id_rsa"
SSH_KEY_COMMENT="mianmi"

echo "========================================"
echo "SSH 免密登录配置脚本 (增强版)"
echo "========================================"

# 1. 检查 ssh-copy-id 是否存在
if ! command -v ssh-copy-id &> /dev/null; then
    echo "错误: 未找到 ssh-copy-id 命令，请安装 openssh-clients"
    exit 1
fi

# 2. 密钥生成逻辑优化
if [ -f "$SSH_KEY_PATH" ]; then
    echo "SSH 密钥已存在: $SSH_KEY_PATH"
    echo "使用现有密钥..."
else
    # 确保 .ssh 目录权限正确
    mkdir -p "$(dirname "$SSH_KEY_PATH")"
    chmod 700 "$(dirname "$SSH_KEY_PATH")"

    echo "正在生成新的 SSH 密钥..."
    ssh-keygen -t rsa -b 4096 -C "$SSH_KEY_COMMENT" -f "$SSH_KEY_PATH" -N ""

    if [ $? -ne 0 ]; then
        echo "密钥生成失败!"
        exit 1
    fi
fi

# 显示本地密钥信息
echo ""
echo "========================================"
echo "本地密钥信息:"
echo "  私钥: $SSH_KEY_PATH"
echo "  公钥: ${SSH_KEY_PATH}.pub"
ls -la "$SSH_KEY_PATH" "${SSH_KEY_PATH}.pub"
echo "========================================"

# 3. 输入服务器信息 (优化交互)
echo ""
echo "========================================"
echo "请输入目标服务器信息"
echo "格式: user@ip user2@ip2 (用空格分隔)"
echo "示例: root@10.16.192.158 root@10.16.192.159"
echo "========================================"
read -p "输入服务器列表: " -r server_input

if [ -z "$server_input" ]; then
    echo "未输入任何服务器!"
    exit 1
fi

# 将输入转换为数组
servers=($server_input)

echo ""
echo "========================================"
echo "开始分发密钥..."
echo "注意: 每个服务器可能需要单独输入密码"
echo "========================================"

success_count=0
fail_count=0

for server in "${servers[@]}"; do
    echo ""
    echo ">>> 正在配置: $server"

    # -o StrictHostKeyChecking=no 避免首次连接询问 yes/no
    # -o ConnectTimeout=10 避免网络不通时卡死太久
    ssh-copy-id -i "${SSH_KEY_PATH}.pub" -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$server"

    if [ $? -eq 0 ]; then
        echo "  ✓ $server 配置成功"
        
        # 调试：验证密钥是否正确分发
        echo "  [调试] 验证密钥分发..."
        LOCAL_PUB_KEY=$(cat "${SSH_KEY_PATH}.pub")
        echo "  公钥内容: $LOCAL_PUB_KEY"
        remote_key=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$server" "cat ~/.ssh/authorized_keys 2>/dev/null | grep -F '$LOCAL_PUB_KEY' && echo '已找到' || echo '未找到'" 2>&1)
        echo "  远程验证结果: $remote_key"
        
        # 自动修复权限和SSH配置
        echo "  [调试] 检查并修复SSH配置..."
        ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$server" "
            chmod 700 ~/.ssh
            chmod 600 ~/.ssh/authorized_keys
            chmod 644 ~/.ssh/authorized_keys 2>/dev/null || true
            chmod 600 ~/.ssh/id_rsa 2>/dev/null || true
        " 2>/dev/null
        echo "  权限已修复"
        
        # 检查SSH配置
        echo "  [调试] 检查SSH服务配置..."
        ssh_config=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$server" "grep -E 'PubkeyAuthentication|PasswordAuthentication' /etc/ssh/sshd_config 2>/dev/null" 2>&1)
        echo "  SSH配置: $ssh_config"
        
        # 如果 PubkeyAuthentication no，自动修复
        if echo "$ssh_config" | grep -q "PubkeyAuthentication no"; then
            echo "  [修复] 启用 PubkeyAuthentication..."
            ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 "$server" "
                sed -i 's/^PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
                sed -i 's/^#*PubkeyAuthentication no/PubkeyAuthentication yes/' /etc/ssh/sshd_config
                systemctl restart sshd 2>/dev/null || service sshd restart 2>/dev/null || true
            " 2>/dev/null
            echo "  SSH服务已重启"
        fi
        
        ((success_count++))
    else
        echo "  ✗ $server 配置失败 (请检查密码、网络或SSH服务)"
        ((fail_count++))
    fi
done

echo ""
echo "========================================"
echo "配置完成!"
echo "成功: $success_count | 失败: $fail_count"
echo "========================================"

# 5. 测试免密登录
echo ""
echo "========================================"
echo "测试免密登录..."
echo "========================================"

for server in "${servers[@]}"; do
    echo ""
    echo "测试: ssh $server 'hostname'"
    result=$(ssh -o StrictHostKeyChecking=no -o ConnectTimeout=10 -o BatchMode=yes "$server" "hostname" 2>&1)
    if [ $? -eq 0 ]; then
        echo "  ✓ 成功! 主机名: $result"
    else
        echo "  ✗ 失败: $result"
    fi
done

echo ""
echo "========================================"
echo "如果测试失败，请手动执行以下命令修复:"
echo ""
echo "# 在目标服务器上执行:"
echo "ssh $server 'sed -i \"s/#PubkeyAuthentication.*/PubkeyAuthentication yes/\" /etc/ssh/sshd_config'"
echo "ssh $server 'sed -i \"s/PubkeyAuthentication no/PubkeyAuthentication yes/\" /etc/ssh/sshd_config'"
echo "ssh $server 'systemctl restart sshd'"
echo "========================================"