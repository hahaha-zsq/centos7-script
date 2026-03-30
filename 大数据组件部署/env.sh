#!/bin/bash
# ============================================================
# 大数据集群环境配置文件
# 使用前请根据实际环境修改此文件
# ============================================================

# ==================== 集群节点配置 ====================
# 节点配置从 servers.txt 读取，格式: ip 主机名
# 第一行为主节点，其余为工作节点

SCRIPT_DIR_ENV="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SERVERS_FILE="${SCRIPT_DIR_ENV}/servers.txt"

if [[ ! -f "$SERVERS_FILE" ]]; then
    echo "ERROR: 服务器列表文件不存在: $SERVERS_FILE" >&2
    exit 1
fi

# 从 servers.txt 读取 IP-主机名映射
SERVERS=()
while IFS= read -r line; do
    line="${line%$'\r'}"
    [[ -z "$line" || "$line" =~ ^[[:space:]]*# ]] && continue
    read -r ip host <<< "$line"
    [[ -z "$ip" || -z "$host" ]] && continue
    SERVERS+=("${ip} ${host}")
done < "$SERVERS_FILE"

if [[ ${#SERVERS[@]} -eq 0 ]]; then
    echo "ERROR: servers.txt 中没有有效节点" >&2
    exit 1
fi

# 第一行为主节点
MASTER_HOST="${SERVERS[0]##* }"

# 其余为工作节点
WORKER_HOSTS=()
for ((i=1; i<${#SERVERS[@]}; i++)); do
    WORKER_HOSTS+=("${SERVERS[$i]##* }")
done

# 所有节点
ALL_HOSTS=()
for entry in "${SERVERS[@]}"; do
    ALL_HOSTS+=("${entry##* }")
done

# ZooKeeper: 所有节点部署 (最少3节点)
ZK_HOSTS=("${ALL_HOSTS[@]}")

# Kafka Broker: 所有节点部署
KAFKA_BROKERS=("${ALL_HOSTS[@]}")

# ==================== 用户配置 ====================
# 部署用户 (建议使用专用用户，非root)
DEPLOY_USER="hadoop"
DEPLOY_GROUP="hadoop"

# ==================== 安装模式配置 ====================
# 安装模式: online (在线下载) | offline (本地离线)
# 可通过脚本 -m 参数覆盖
INSTALL_MODE="online"

# 离线安装包目录 (本地模式必填)
# 目录结构:
#   ${OFFLINE_DIR}/jdk-17.0.12_linux-x64_bin.tar.gz
#   ${OFFLINE_DIR}/hadoop-3.3.6.tar.gz
#   ${OFFLINE_DIR}/kafka_2.13-3.6.2.tgz
#   ${OFFLINE_DIR}/apache-zookeeper-3.8.4-bin.tar.gz
#   ${OFFLINE_DIR}/flink-1.18.1-bin-scala_2.12.tgz
#   ${OFFLINE_DIR}/spark-3.5.1-bin-hadoop3.tgz
OFFLINE_DIR="/opt/offline_packages"

# ==================== 目录配置 ====================
# 安装包下载/缓存目录 (在线模式下用于缓存下载的包)
DOWNLOAD_DIR="/opt/software"

# 基础安装目录
INSTALL_DIR="/opt/bigdata"

# 各组件安装目录
JAVA_HOME_DIR="$INSTALL_DIR/jdk"
HADOOP_HOME_DIR="$INSTALL_DIR/hadoop"
KAFKA_HOME_DIR="$INSTALL_DIR/kafka"
FLINK_HOME_DIR="$INSTALL_DIR/flink"
SPARK_HOME_DIR="$INSTALL_DIR/spark"
ZOOKEEPER_HOME_DIR="$INSTALL_DIR/zookeeper"

# 数据目录
DATA_BASE_DIR="/data/bigdata"
HDFS_DATA_DIR="$DATA_BASE_DIR/hdfs"
HDFS_NAME_DIR="$DATA_BASE_DIR/hdfs/name"
HDFS_DATA_DATA_DIR="$DATA_BASE_DIR/hdfs/data"
YARN_LOG_DIR="$DATA_BASE_DIR/yarn/logs"
KAFKA_DATA_DIR="$DATA_BASE_DIR/kafka"
ZK_DATA_DIR="$DATA_BASE_DIR/zookeeper"

# 日志目录
LOG_BASE_DIR="/var/log/bigdata"
HADOOP_LOG_DIR="$LOG_BASE_DIR/hadoop"
KAFKA_LOG_DIR="$LOG_BASE_DIR/kafka"
FLINK_LOG_DIR="$LOG_BASE_DIR/flink"
SPARK_LOG_DIR="$LOG_BASE_DIR/spark"

# ==================== 软件版本 ====================
JAVA_VERSION="17"
JAVA_PACKAGE="jdk-17.0.12_linux-x64_bin.tar.gz"
JAVA_DOWNLOAD_URL="https://download.oracle.com/java/17/archive/jdk-17.0.12_linux-x64_bin.tar.gz"

HADOOP_VERSION="3.3.6"
HADOOP_PACKAGE="hadoop-${HADOOP_VERSION}.tar.gz"
HADOOP_DOWNLOAD_URL="https://archive.apache.org/dist/hadoop/common/hadoop-${HADOOP_VERSION}/${HADOOP_PACKAGE}"

KAFKA_VERSION="3.6.2"
KAFKA_PACKAGE="kafka_2.13-${KAFKA_VERSION}.tgz"
KAFKA_DOWNLOAD_URL="https://archive.apache.org/dist/kafka/${KAFKA_VERSION}/${KAFKA_PACKAGE}"

ZOOKEEPER_VERSION="3.8.4"
ZOOKEEPER_PACKAGE="apache-zookeeper-${ZOOKEEPER_VERSION}-bin.tar.gz"
ZOOKEEPER_DOWNLOAD_URL="https://archive.apache.org/dist/zookeeper/zookeeper-${ZOOKEEPER_VERSION}/${ZOOKEEPER_PACKAGE}"

FLINK_VERSION="1.18.1"
FLINK_PACKAGE="flink-${FLINK_VERSION}-bin-scala_2.12.tgz"
FLINK_DOWNLOAD_URL="https://archive.apache.org/dist/flink/flink-${FLINK_VERSION}/${FLINK_PACKAGE}"

SPARK_VERSION="3.5.1"
SPARK_PACKAGE="spark-${SPARK_VERSION}-bin-hadoop3.tgz"
SPARK_DOWNLOAD_URL="https://archive.apache.org/dist/spark/spark-${SPARK_VERSION}/${SPARK_PACKAGE}"

# ==================== 端口配置 ====================
# Hadoop
HDFS_NAMENODE_PORT=7779
HDFS_NAMENODE_RPC_PORT=7778
YARN_RESOURCEMANAGER_PORT=7777
YARN_RESOURCEMANAGER_SCHEDULER_PORT=7776
YARN_NODEMANAGER_PORT=7775

# Kafka
KAFKA_PORT=7774

# Zookeeper
ZK_CLIENT_PORT=7773
ZK_PEER_PORT=7772
ZK_ELECTION_PORT=7771

# Flink
FLINK_JOBMANAGER_PORT=7770

# Spark
SPARK_HISTORY_PORT=7769

# ==================== JVM 配置 ====================








# NameNode JVM 参数
# NameNode: 原 2g -> 建议 512m 或 1g (元数据少时 512m 足够)
NAMENODE_HEAP_SIZE="512m"
NAMENODE_OPTS="-Xmx${NAMENODE_HEAP_SIZE} -Xms${NAMENODE_HEAP_SIZE}"

# DataNode: 原 1g -> 建议 256m 或 512m (仅用于管理块信息，不存实际数据内容)
DATANODE_HEAP_SIZE="256m"
DATANODE_OPTS="-Xmx${DATANODE_HEAP_SIZE} -Xms${DATANODE_HEAP_SIZE}"

# ResourceManager: 原 2g -> 建议 512m 或 1g
RESOURCEMANAGER_HEAP_SIZE="512m"
RESOURCEMANAGER_OPTS="-Xmx${RESOURCEMANAGER_HEAP_SIZE} -Xms${RESOURCEMANAGER_HEAP_SIZE}"

# NodeManager: 原 1g -> 建议 256m 或 512m
NODEMANAGER_HEAP_SIZE="256m"
NODEMANAGER_OPTS="-Xmx${NODEMANAGER_HEAP_SIZE} -Xms${NODEMANAGER_HEAP_SIZE}"



# Flink JobManager JVM 参数
# Flink JobManager: 原 2g -> 建议 512m
FLINK_JM_HEAP_SIZE="512m"

# Flink TaskManager: 原 2g -> 建议 512m 或 1g (取决于您跑的任务大小)
FLINK_TM_HEAP_SIZE="512m"
FLINK_TM_PROCESS_SIZE="512m"


# ==================== Kafka 配置 ====================
KAFKA_LOG_RETENTION_HOURS=168
KAFKA_LOG_RETENTION_BYTES=10737418240
KAFKA_LOG_SEGMENT_BYTES=1073741824
KAFKA_NUM_PARTITIONS=3
KAFKA_DEFAULT_REPLICATION_FACTOR=2
KAFKA_MIN_INSYNC_REPLICAS=1

# ==================== HDFS 副本数 (3节点建议设为2) ====================
HDFS_REPLICATION_FACTOR=2

# ==================== YARN 资源配置 ====================
# 每个 NodeManager 可分配的总内存: 原 8192 (8GB) -> 建议 2048 (2GB) 或 3072 (3GB)
YARN_NODEMANAGER_RESOURCE_MEMORY_MB=1500

# 每个 NodeManager 可分配的 CPU 核数: 原 4 -> 建议 2 (根据实际 CPU 调整)
YARN_NODEMANAGER_RESOURCE_CPU_VCORES=1

# 单个任务最小申请内存: 原 512 -> 建议 256 (允许跑更小的任务)
YARN_SCHEDULER_MINIMUM_ALLOCATION_MB=256

# 单个任务最大申请内存: 不能超过 NodeManager 总内存
YARN_SCHEDULER_MAXIMUM_ALLOCATION_MB=2048

# CPU 最小/最大分配单元
YARN_SCHEDULER_MINIMUM_ALLOCATION_VCORES=1
YARN_SCHEDULER_MAXIMUM_ALLOCATION_VCORES=2

# ==================== SSH 配置 ====================
SSH_PORT=22
SSH_TIMEOUT=10
SSH_IDENTITY_FILE="${HOME}/.ssh/id_rsa"

# ==================== 工具函数 ====================

# 根据主机名获取 IP
get_host_ip() {
    local -r host="$1"
    for entry in "${SERVERS[@]}"; do
        if [[ "${entry##* }" == "$host" ]]; then
            echo "${entry%% *}"
            return 0
        fi
    done
    return 1
}
get_host_index() {
    local -r host="$1"
    for i in "${!ALL_HOSTS[@]}"; do
        if [[ "${ALL_HOSTS[$i]}" == "$host" ]]; then
            echo "$i"
            return 0
        fi
    done
    return 1
}

get_kafka_broker_id() {
    local -r host="$1"
    for i in "${!KAFKA_BROKERS[@]}"; do
        if [[ "${KAFKA_BROKERS[$i]}" == "$host" ]]; then
            echo "$((i + 1))"
            return 0
        fi
    done
    return 1
}

get_zk_id() {
    local -r host="$1"
    for i in "${!ZK_HOSTS[@]}"; do
        if [[ "${ZK_HOSTS[$i]}" == "$host" ]]; then
            echo "$((i + 1))"
            return 0
        fi
    done
    return 1
}

is_worker() {
    local -r host="$1"
    for w in "${WORKER_HOSTS[@]}"; do
        [[ "$w" == "$host" ]] && return 0
    done
    return 1
}

is_kafka_broker() {
    local -r host="$1"
    for b in "${KAFKA_BROKERS[@]}"; do
        [[ "$b" == "$host" ]] && return 0
    done
    return 1
}

is_zk_host() {
    local -r host="$1"
    for z in "${ZK_HOSTS[@]}"; do
        [[ "$z" == "$host" ]] && return 0
    done
    return 1
}

# ==================== 安装包路径解析 ====================
# 根据安装模式返回安装包的本地路径
# 用法: get_package_path <package_name>
# 返回: 安装包的完整路径, 如 /opt/software/hadoop-3.3.6.tar.gz
get_package_path() {
    local -r pkg_name="$1"

    if [[ "${INSTALL_MODE}" == "offline" ]]; then
        echo "${OFFLINE_DIR}/${pkg_name}"
    else
        echo "${DOWNLOAD_DIR}/${pkg_name}"
    fi
}

# 检查安装包是否存在
check_package_exists() {
    local -r pkg_name="$1"
    local -r pkg_path="$(get_package_path "$pkg_name")"

    if [[ -f "$pkg_path" ]]; then
        return 0
    fi
    return 1
}

# 下载安装包 (仅在线模式)
# 用法: download_package <package_name> <download_url>
download_package() {
    local -r pkg_name="$1"
    local -r download_url="$2"
    local -r pkg_path="$(get_package_path "$pkg_name")"

    # 如果已存在则跳过
    if [[ -f "$pkg_path" ]]; then
        return 0
    fi

    # 离线模式不下载
    if [[ "${INSTALL_MODE}" == "offline" ]]; then
        echo "ERROR: 离线模式下安装包不存在: ${pkg_path}" >&2
        echo "请将 ${pkg_name} 放入 ${OFFLINE_DIR}/ 目录" >&2
        return 1
    fi

    echo "下载 ${pkg_name}..." >&2
    mkdir -p "$(dirname "$pkg_path")"
    curl -L -o "$pkg_path" "$download_url" || {
        echo "ERROR: 下载失败 ${pkg_name}" >&2
        rm -f "$pkg_path"
        return 1
    }
}

# 打包所有安装包到离线目录 (用于提前准备离线包)
# 用法: prepare_offline_packages
prepare_offline_packages() {
    mkdir -p "${OFFLINE_DIR}"

    local -a packages=(
        "${JAVA_PACKAGE}|${JAVA_DOWNLOAD_URL}"
        "${HADOOP_PACKAGE}|${HADOOP_DOWNLOAD_URL}"
        "${KAFKA_PACKAGE}|${KAFKA_DOWNLOAD_URL}"
        "${ZOOKEEPER_PACKAGE}|${ZOOKEEPER_DOWNLOAD_URL}"
        "${FLINK_PACKAGE}|${FLINK_DOWNLOAD_URL}"
        "${SPARK_PACKAGE}|${SPARK_DOWNLOAD_URL}"
    )

    echo "准备离线安装包到: ${OFFLINE_DIR}"
    for entry in "${packages[@]}"; do
        local pkg_name="${entry%%|*}"
        local url="${entry##*|}"
        local pkg_path="${OFFLINE_DIR}/${pkg_name}"

        if [[ -f "$pkg_path" ]]; then
            echo "[跳过] ${pkg_name} 已存在"
        else
            echo "[下载] ${pkg_name}..."
            curl -L -o "$pkg_path" "$url" || echo "[失败] ${pkg_name}"
        fi
    done

    echo "离线包准备完成: ${OFFLINE_DIR}"
}

# ==================== 统一下载所有安装包到本地 ====================
# 用法: download_all_packages_to_local
download_all_packages_to_local() {
    mkdir -p "${DOWNLOAD_DIR}"

    local -a packages=(
        "${JAVA_PACKAGE}|${JAVA_DOWNLOAD_URL}"
        "${HADOOP_PACKAGE}|${HADOOP_DOWNLOAD_URL}"
        "${KAFKA_PACKAGE}|${KAFKA_DOWNLOAD_URL}"
        "${ZOOKEEPER_PACKAGE}|${ZOOKEEPER_DOWNLOAD_URL}"
        "${FLINK_PACKAGE}|${FLINK_DOWNLOAD_URL}"
        "${SPARK_PACKAGE}|${SPARK_DOWNLOAD_URL}"
    )

    local download_count=0
    local skip_count=0
    local fail_count=0

    for entry in "${packages[@]}"; do
        local pkg_name="${entry%%|*}"
        local url="${entry##*|}"
        local pkg_path="${DOWNLOAD_DIR}/${pkg_name}"

        if [[ -f "$pkg_path" ]]; then
            echo "[跳过] ${pkg_name} 已存在: ${pkg_path}"
            skip_count=$((skip_count + 1))
            continue
        fi

        echo "[下载] ${pkg_name}..."
        mkdir -p "$(dirname "$pkg_path")"
        if curl -L --fail --show-error -o "$pkg_path" "$url"; then
            echo "[完成] ${pkg_name}"
            download_count=$((download_count + 1))
        else
            echo "[失败] ${pkg_name}: ${url}"
            rm -f "$pkg_path"
            fail_count=$((fail_count + 1))
        fi
    done

    echo "========================================"
    echo "  下载汇总"
    echo "========================================"
    echo "新下载: ${download_count}"
    echo "已存在: ${skip_count}"
    echo "失败: ${fail_count}"
    echo "安装包目录: ${DOWNLOAD_DIR}"

    return $fail_count
}

# ==================== 获取所有需要的安装包列表 ====================
# 用法: get_all_packages_array
# 返回: 数组，每个元素为 "package_name|download_url"
get_all_packages_array() {
    echo "${JAVA_PACKAGE}|${JAVA_DOWNLOAD_URL}"
    echo "${HADOOP_PACKAGE}|${HADOOP_DOWNLOAD_URL}"
    echo "${KAFKA_PACKAGE}|${KAFKA_DOWNLOAD_URL}"
    echo "${ZOOKEEPER_PACKAGE}|${ZOOKEEPER_DOWNLOAD_URL}"
    echo "${FLINK_PACKAGE}|${FLINK_DOWNLOAD_URL}"
    echo "${SPARK_PACKAGE}|${SPARK_DOWNLOAD_URL}"
}
