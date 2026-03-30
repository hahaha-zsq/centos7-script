#!/bin/bash
set -Eeuo pipefail

# ============================================================
# 集群健康检查脚本
# 检查所有大数据组件的运行状态
# ============================================================

trap 'log_error "脚本执行出错，行号: $LINENO"' ERR

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
source "$SCRIPT_DIR/env.sh"

log_info() { printf "[%s] 信息: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_warn() { printf "[%s] 警告: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }
log_error() { printf "[%s] 错误: %s\n" "$(date +'%Y-%m-%d %H:%M:%S')" "$*" >&2; }

VERBOSE=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -v|--verbose) VERBOSE=true; shift ;;
        -h|--help) echo "用法: $(basename "$0") [-v]"; exit 0 ;;
        *) shift ;;
    esac
done

remote_exec() {
    local -r host="$1"; shift
    ssh -i "$SSH_IDENTITY_FILE" -o StrictHostKeyChecking=no -o ConnectTimeout=5 \
        -p "$SSH_PORT" "root@${host}" "$@" 2>/dev/null
}

# 状态计数
TOTAL_CHECKS=0
PASSED_CHECKS=0
FAILED_CHECKS=0

check() {
    local -r name="$1"
    local -r result="$2"
    TOTAL_CHECKS=$((TOTAL_CHECKS + 1))

    if [[ "$result" == "0" ]]; then
        printf "  %-30s [✓] 正常\n" "$name"
        PASSED_CHECKS=$((PASSED_CHECKS + 1))
    else
        printf "  %-30s [✗] 异常\n" "$name"
        FAILED_CHECKS=$((FAILED_CHECKS + 1))
    fi
}

# ==================== 检查 JDK ====================
check_jdk() {
    log_info "检查 JDK..."
    for host in "${ALL_HOSTS[@]}"; do
        local result=1
        if remote_exec "$host" "source /etc/profile.d/bigdata_jdk.sh 2>/dev/null; java -version" &>/dev/null; then
            result=0
        fi
        check "JDK @ ${host}" "$result"
    done
}

# ==================== 检查 HDFS ====================
check_hdfs() {
    log_info "检查 HDFS..."

    # NameNode 状态
    local nn_result=1
    if remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '${HADOOP_HOME_DIR}/bin/hdfs dfsadmin -report'" &>/dev/null; then
        nn_result=0
    fi
    check "HDFS NameNode" "$nn_result"

    # DataNode 数量
    local dn_report
    dn_report=$(remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '${HADOOP_HOME_DIR}/bin/hdfs dfsadmin -report'" 2>/dev/null) || true
    local live_dns
    live_dns=$(echo "$dn_report" | grep -c "Name:" 2>/dev/null || echo "0")
    local dn_result=1
    if [[ "$live_dns" -gt 0 ]]; then
        dn_result=0
    fi
    check "HDFS DataNodes (${live_dns} 节点在线)" "$dn_result"

    # HDFS 读写测试
    local rw_result=1
    if remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '
        echo test | ${HADOOP_HOME_DIR}/bin/hdfs dfs -put - /healthcheck_test
        ${HADOOP_HOME_DIR}/bin/hdfs dfs -cat /healthcheck_test
        ${HADOOP_HOME_DIR}/bin/hdfs dfs -rm /healthcheck_test
    '" &>/dev/null; then
        rw_result=0
    fi
    check "HDFS 读写测试" "$rw_result"
}

# ==================== 检查 YARN ====================
check_yarn() {
    log_info "检查 YARN..."

    # ResourceManager
    local rm_result=1
    if remote_exec "$MASTER_HOST" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${YARN_RESOURCEMANAGER_PORT}" 2>/dev/null | grep -q "200"; then
        rm_result=0
    fi
    check "YARN ResourceManager" "$rm_result"

    # NodeManager
    for host in "${WORKER_HOSTS[@]}"; do
        local nm_result=1
        if remote_exec "$host" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${YARN_NODEMANAGER_PORT}" 2>/dev/null | grep -q "200"; then
            nm_result=0
        fi
        check "YARN NodeManager @ ${host}" "$nm_result"
    done
}

# ==================== 检查 ZooKeeper ====================
check_zookeeper() {
    log_info "检查 ZooKeeper..."
    for host in "${ZK_HOSTS[@]}"; do
        local zk_result=1
        if remote_exec "$host" "echo ruok | nc localhost ${ZK_CLIENT_PORT}" 2>/dev/null | grep -q "imok"; then
            zk_result=0
        fi
        check "ZooKeeper @ ${host}" "$zk_result"
    done
}

# ==================== 检查 Kafka ====================
check_kafka() {
    log_info "检查 Kafka..."
    for host in "${KAFKA_BROKERS[@]}"; do
        local kafka_result=1
        # 检查进程
        if remote_exec "$host" "jps 2>/dev/null | grep -i kafka" &>/dev/null; then
            kafka_result=0
        fi
        check "Kafka Broker @ ${host}" "$kafka_result"
    done

    # 集群连接测试
    local first_broker="${KAFKA_BROKERS[0]}"
    local cluster_result=1
    if remote_exec "$first_broker" "su - ${DEPLOY_USER} -c '${KAFKA_HOME_DIR}/bin/kafka-topics.sh --list --bootstrap-server ${first_broker}:${KAFKA_PORT}'" &>/dev/null; then
        cluster_result=0
    fi
    check "Kafka 集群连接" "$cluster_result"
}

# ==================== 检查 Flink ====================
check_flink() {
    log_info "检查 Flink..."

    local flink_result=1
    local flink_app
    flink_app=$(remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '
        export JAVA_HOME=${JAVA_HOME_DIR}
        export HADOOP_HOME=${HADOOP_HOME_DIR}
        yarn application -list 2>/dev/null | grep -i flink
    '" 2>/dev/null) || true

    if [[ -n "$flink_app" ]]; then
        flink_result=0
    fi
    check "Flink YARN Session" "$flink_result"
}

# ==================== 检查 Spark ====================
check_spark() {
    log_info "检查 Spark..."

    # History Server
    local hs_result=1
    if remote_exec "$MASTER_HOST" "curl -s -o /dev/null -w '%{http_code}' http://localhost:${SPARK_HISTORY_PORT}" 2>/dev/null | grep -q "200"; then
        hs_result=0
    fi
    check "Spark History Server" "$hs_result"

    # spark-submit 测试
    local submit_result=1
    if remote_exec "$MASTER_HOST" "su - ${DEPLOY_USER} -c '
        export JAVA_HOME=${JAVA_HOME_DIR}
        export HADOOP_HOME=${HADOOP_HOME_DIR}
        ${SPARK_HOME_DIR}/bin/spark-submit --version
    '" &>/dev/null; then
        submit_result=0
    fi
    check "Spark 客户端" "$submit_result"
}

# ==================== 检查端口监听 ====================
check_ports() {
    log_info "检查端口监听..."

    local -A port_checks=(
        ["${MASTER_HOST}:${HDFS_NAMENODE_RPC_PORT}"]="HDFS RPC"
        ["${MASTER_HOST}:${YARN_RESOURCEMANAGER_PORT}"]="YARN Web"
        ["${MASTER_HOST}:${FLINK_JOBMANAGER_PORT}"]="Flink Web"
        ["${MASTER_HOST}:${SPARK_HISTORY_PORT}"]="Spark History"
    )

    for key in "${!port_checks[@]}"; do
        local host="${key%%:*}"
        local port="${key##*:}"
        local name="${port_checks[$key]}"

        local port_result=1
        if remote_exec "$host" "ss -tlnp | grep -q ':${port}'" &>/dev/null; then
            port_result=0
        fi
        check "${name} (${host}:${port})" "$port_result"
    done
}

# ==================== 主函数 ====================
main() {
    log_info "========================================"
    log_info "  大数据集群健康检查"
    log_info "========================================"

    check_jdk
    check_hdfs
    check_yarn
    check_zookeeper
    check_kafka
    check_flink
    check_spark
    check_ports

    log_info "========================================"
    log_info "  检查汇总"
    log_info "========================================"
    log_info "总检查项: $TOTAL_CHECKS"
    log_info "通过: $PASSED_CHECKS"
    log_info "失败: $FAILED_CHECKS"

    if [[ $FAILED_CHECKS -gt 0 ]]; then
        log_warn "存在 ${FAILED_CHECKS} 项异常，请检查"
        return 1
    fi

    log_info "所有检查项通过"
    return 0
}

main "$@"
