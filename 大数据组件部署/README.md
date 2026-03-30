# 大数据集群部署脚本

## 概述

大数据组件集群自动化部署脚本，支持 Hadoop (HDFS + YARN)、Kafka、Flink、Spark 的一键部署。采用防御性编程风格，具备完善的错误处理、日志记录和验证机制。

## 架构方案

```
┌─────────────────────────────────────────────────────────┐
│                    YARN (资源管理)                        │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐               │
│  │ Flink    │  │ Spark    │  │ MapReduce│               │
│  │ Session  │  │ App      │  │ Job      │               │
│  └──────────┘  └──────────┘  └──────────┘               │
├─────────────────────────────────────────────────────────┤
│  Kafka (消息队列)  ──────▶  Flink (实时处理)              │
│       │                         │                        │
│       ▼                         ▼                        │
│     HDFS (存储)  ◀──────── 处理结果落盘                   │
├─────────────────────────────────────────────────────────┤
│  ZooKeeper (协调服务)                                     │
└─────────────────────────────────────────────────────────┘
```

### 节点规划 (3节点)

| 节点 | 角色 | 组件 |
|------|------|------|
| node1 | Master | NameNode, ResourceManager, Flink JobManager, Spark HistoryServer, ZooKeeper, Kafka Broker |
| node2 | Worker | DataNode, NodeManager, Kafka Broker, Flink TaskManager, ZooKeeper, SecondaryNameNode |
| node3 | Worker | DataNode, NodeManager, Kafka Broker, Flink TaskManager, ZooKeeper |

> 3 节点集群 HDFS 副本数默认设为 2，Kafka 和 ZooKeeper 均为 3 节点部署以保证高可用。

## 软件版本

| 组件 | 版本 | 说明 |
|------|------|------|
| JDK | 17 | 运行时环境 |
| Hadoop | 3.3.6 | HDFS + YARN |
| Kafka | 3.6.2 | 消息队列 |
| ZooKeeper | 3.8.4 | 分布式协调 |
| Flink | 1.18.1 | 实时流处理 |
| Spark | 3.5.1 | 批处理 + SQL |

## 文件结构

```
大数据组件部署/
├── env.sh                  # 环境配置文件 (必须修改)
├── servers.txt             # 服务器列表模板
├── 01_setup_jdk.sh         # JDK 安装
├── 02_deploy_hadoop.sh     # Hadoop HDFS + YARN 部署
├── 03_deploy_kafka.sh      # Kafka + ZooKeeper 部署
├── 04_deploy_flink.sh      # Flink on YARN 部署
├── 05_deploy_spark.sh      # Spark on YARN 部署
├── check_health.sh         # 健康检查
├── deploy_all.sh           # 一键部署主脚本
└── README.md               # 本文档
```

## 前置条件

### 0. 执行方式

> **只需在一台机器上执行即可**，无需在每个节点重复运行。

脚本通过 SSH 远程操作所有节点，执行机器可以是：

| 场景 | 说明 |
|------|------|
| **Master 节点** | 最常见，Master 通常作为管理节点 |
| **跳板机/运维机** | 公司内部运维机，能 SSH 到所有服务器 |
| **本地笔记本** | 开发测试环境，笔记本能直连所有节点 |

```
控制机 (执行 ./deploy_all.sh)
  ├── SSH ──▶ node1  (远程安装所有组件)
  ├── SSH ──▶ node2  (远程安装所有组件)
  └── SSH ──▶ node3  (远程安装所有组件)
```

前提条件：执行机器能免密 SSH 到所有节点。

### 1. 操作系统

- CentOS 7 / CentOS Stream 8 / RHEL 7-8
- Ubuntu 20.04+ (需修改部分命令)

### 2. SSH 免密

所有节点之间需配置 SSH 免密登录，可使用上级目录的 `免密登录脚本/ssh_key_auth.sh`：

```bash
cd ../免密登录脚本
./ssh_key_auth.sh -f servers.txt -c
```

### 3. 安装模式

所有脚本支持两种安装模式：

| 模式 | 参数 | 说明 |
|------|------|------|
| **online** (默认) | `-m online` | 从网络下载安装包后部署 |
| **offline** | `-m offline` | 使用本地已下载的安装包部署 |

### 4. 网络要求

- **在线模式**: 所有节点可互相访问 + 能访问外网下载安装包
- **离线模式**: 所有节点可互相访问，无需外网

## 快速开始

### 步骤 1: 配置服务器列表

编辑 `servers.txt`，填入实际的 IP 和主机名：

```
# 格式: ip 主机名
# 第一行为主节点，其余为工作节点

# 主节点
192.168.1.10 node1

# 工作节点
192.168.1.11 node2
192.168.1.12 node3
```

### 步骤 2: 调整资源参数 (可选)

编辑 `env.sh`，根据服务器配置调整 JVM 内存和 YARN 资源：

```bash
NAMENODE_HEAP_SIZE="2g"
YARN_NODEMANAGER_RESOURCE_MEMORY_MB=8192
YARN_NODEMANAGER_RESOURCE_CPU_VCORES=4
```

### 步骤 3: 一键部署

脚本会自动完成以下操作：
1. **自动配置 `/etc/hosts`** — 将 `servers.txt` 中的 IP-主机名映射写入所有节点
2. **安装 JDK** → **Hadoop** → **Kafka** → **Flink** → **Spark**
3. **健康检查**

```bash
# 在线部署 (从网络下载)
./deploy_all.sh

# 离线部署 (使用本地安装包)
./deploy_all.sh -m offline

# 试运行
./deploy_all.sh -d
```

#### 重复运行说明

脚本具备**幂等性**，可安全重复运行：

| 检查项 | 行为 |
|--------|------|
| 已安装的组件 (JDK/Hadoop/Kafka...) | 自动跳过 |
| 已运行的服务 (HDFS/YARN/Kafka...) | 自动跳过启动 |
| HDFS 已格式化 | 跳过格式化，不会丢失数据 |
| Flink YARN Session 已存在 | 跳过创建 |
| 配置文件 `/etc/hosts` | 去重后重新写入 |

```bash
# 组件安装失败后修复问题，直接重新运行即可
./deploy_all.sh

# 只重新部署某个组件
./03_deploy_kafka.sh

# 跳过已成功的组件
./deploy_all.sh -s jdk,hadoop
```

> **注意**：配置文件 (`*.xml`, `*.yaml`, `*.properties`) 和环境变量文件 (`/etc/profile.d/bigdata_*.sh`) 每次运行会重新生成。如需自定义配置，建议修改脚本模板而非手动改文件。

#### 离线部署详细步骤

适用于目标服务器无法访问外网的场景：

```bash
# 第 1 步: 在能访问外网的机器上准备离线安装包
./deploy_all.sh --prepare-offline
# 安装包会下载到 /opt/offline_packages/ 目录

# 第 2 步: 将 /opt/offline_packages/ 目录复制到目标服务器

# 第 3 步: 在目标服务器上离线部署
./deploy_all.sh -m offline

# 离线部署也可跳过已安装的组件
./deploy_all.sh -m offline -s jdk,hadoop
```

离线模式需要的安装包：

```
/opt/offline_packages/
├── jdk-17.0.12_linux-x64_bin.tar.gz
├── hadoop-3.3.6.tar.gz
├── kafka_2.13-3.6.2.tgz
├── apache-zookeeper-3.8.4-bin.tar.gz
├── flink-1.18.1-bin-scala_2.12.tgz
└── spark-3.5.1-bin-hadoop3.tgz
```

### 步骤 4: 单独部署

每个组件脚本都支持 `-m` 参数：

```bash
# 在线模式 (默认)
./02_deploy_hadoop.sh

# 离线模式
./02_deploy_hadoop.sh -m offline
./03_deploy_kafka.sh -m offline
./04_deploy_flink.sh -m offline
./05_deploy_spark.sh -m offline
```

## 部署顺序

```
阶段 0: 基础环境准备 (创建用户、目录、内核参数)
    │
    ▼
阶段 1: JDK 17 安装 (所有节点)
    │
    ▼
阶段 2: Hadoop 部署 (HDFS + YARN)
    │  ├── 生成配置文件
    │  ├── 分发到所有节点
    │  ├── 格式化 NameNode
    │  └── 启动集群
    │
    ▼
阶段 3: Kafka 部署 (ZooKeeper + Kafka)
    │  ├── 安装 ZooKeeper 集群
    │  ├── 启动 ZooKeeper
    │  ├── 安装 Kafka Broker
    │  └── 启动 Kafka
    │
    ▼
阶段 4: Flink 部署 (on YARN)
    │  ├── 安装 Flink 客户端
    │  ├── 配置高可用 (ZooKeeper)
    │  └── 启动 YARN Session Cluster
    │
    ▼
阶段 5: Spark 部署 (on YARN)
    │  ├── 安装 Spark 客户端
    │  ├── 配置 History Server
    │  └── 启动 History Server
    │
    ▼
阶段 6: 健康检查
```

## 健康检查

```bash
./check_health.sh

# 详细输出
./check_health.sh -v
```

检查项包括：
- JDK 安装状态
- HDFS NameNode / DataNode 状态
- YARN ResourceManager / NodeManager 状态
- ZooKeeper 集群状态
- Kafka Broker 状态
- Flink YARN Session 状态
- Spark History Server 状态
- 关键端口监听状态

## Web UI 地址

部署完成后可访问以下管理界面：

| 组件 | 地址 | 说明 |
|------|------|------|
| HDFS NameNode | http://master:9870 | 文件系统管理 |
| YARN ResourceManager | http://master:8088 | 任务调度管理 |
| Spark History | http://master:18080 | Spark 任务历史 |
| Flink | 通过 YARN UI 访问 | Flink Web Dashboard |

## 端口说明及修改方法

以下是各组件使用的端口列表。如果端口被其他应用占用，可以通过修改 `env.sh` 文件中的相应变量来更改端口。

### 端口列表

| 组件 | 端口 | 用途 | 说明 |
|------|------|------|------|
| **Hadoop HDFS** | | | |
| NameNode HTTP | 9870 | Web UI | 访问 HDFS 名称节点管理界面 |
| NameNode RPC | 9000 | 服务通信 | HDFS 客户端与 NameNode 通信 |
| **Hadoop YARN** | | | |
| ResourceManager | 8088 | Web UI | 访问 YARN 资源管理器界面 |
| ResourceManager Scheduler | 8030 | 内部通信 | ResourceManager 内部调度通信 |
| NodeManager | 8042 | 服务通信 | NodeManager 与 ResourceManager 通信 |
| **Kafka** | | | |
| Kafka Broker | 9092/9093 | 客户端连接 | 生产者和消费者连接 Kafka |
| ZooKeeper Client | 2181/2182 | 客户端连接 | Kafka/ZooKeeper 客户端连接 |
| ZooKeeper Peer | 2888/2889 | 集群通信 | ZooKeeper 节点间同步通信 |
| ZooKeeper Election | 3888/3889 | 选举通信 | ZooKeeper 节点选举过程通信 |
| **Flink** | | | |
| JobManager | 8081 | REST API | Flink JobManager REST 接口 |
| **Spark** | | | |
| History Server | 18080 | Web UI | Spark 作业历史查询界面 |

### 修改端口的方法

1. **通过 env.sh 文件修改（推荐）**
   编辑 `env.sh` 文件中的端口配置变量（位于文件第131-151行）：
   ```bash
   # ==================== 端口配置 ====================
   # Hadoop
   HDFS_NAMENODE_PORT=9870
   HDFS_NAMENODE_RPC_PORT=9000
   YARN_RESOURCEMANAGER_PORT=8088
   YARN_RESOURCEMANAGER_SCHEDULER_PORT=8030
   YARN_NODEMANAGER_PORT=8042
   
   # Kafka
   KAFKA_PORT=9092
   
   # Zookeeper
   ZK_CLIENT_PORT=2181
   ZK_PEER_PORT=2888
   ZK_ELECTION_PORT=3888
   
   # Flink
   FLINK_JOBMANAGER_PORT=8081
   
   # Spark
   SPARK_HISTORY_PORT=18080
   ```
   修改对应的端口值后重新运行部署脚本。

2. **通过脚本参数临时覆盖（仅针对 Kafka/ZooKeeper）**
   在 `03_deploy_kafka.sh` 脚本中，可以通过环境变量临时覆盖端口：
   ```bash
   # 临时修改 ZooKeeper 端口
   ZK_CLIENT_PORT=2183 ZK_PEER_PORT=2890 ZK_ELECTION_PORT=3890 ./03_deploy_kafka.sh
   
   # 临时修改 Kafka 端口
   KAFKA_PORT=9094 ./03_deploy_kafka.sh
   ```

3. **注意事项**
   - 修改端口后需要重新运行相应组件的部署脚本
   - 确保修改后的端口在所有节点之间保持一致
   - 修改端口后需要更新防火墙规则以允许新端口的通信
   - 对于生产环境，建议在 `env.sh` 文件中统一管理端口配置

> **提示**：脚本已经内置了端口冲突检测机制（特别是在 Kafka 部署脚本中），如果端口被占用会在部署过程中报错并给出提示。

## 常用命令

```bash
# HDFS
hdfs dfs -ls /                        # 列出根目录
hdfs dfs -mkdir -p /data              # 创建目录
hdfs dfs -put localfile /data/        # 上传文件
hdfs dfsadmin -report                 # 集群状态

# YARN
yarn application -list                # 列出应用
yarn application -kill <app_id>       # 杀死应用
yarn node -list                       # 列出节点

# Kafka
kafka-topics.sh --list --bootstrap-server node2:9092
kafka-topics.sh --create --topic test --partitions 3 --replication-factor 2 --bootstrap-server node2:9092
kafka-console-producer.sh --topic test --bootstrap-server node2:9092
kafka-console-consumer.sh --topic test --from-beginning --bootstrap-server node2:9092

# Flink (YARN Session)
flink list                            # 列出作业
flink run -c MainClass app.jar        # 提交作业

# Spark
spark-submit --master yarn --deploy-mode client ...
spark-sql --master yarn               # Spark SQL Shell
```

## 数据目录结构

```
/data/bigdata/
├── hdfs/
│   ├── name/           # NameNode 元数据
│   └── data/           # DataNode 数据块
├── kafka/
│   └── logs-*/         # Kafka 消息日志
└── zookeeper/
    ├── data/           # ZK 快照
    └── log/            # ZK 事务日志

/var/log/bigdata/
├── hadoop/             # Hadoop 日志
├── kafka/              # Kafka 日志
├── flink/              # Flink 日志
└── spark/              # Spark 日志

/opt/bigdata/
├── jdk/                # JDK 安装
├── hadoop/             # Hadoop 安装
├── kafka/              # Kafka 安装
├── flink/              # Flink 安装
├── spark/              # Spark 安装
└── zookeeper/          # ZooKeeper 安装
```

## 故障排查

### HDFS 启动失败

```bash
# 检查 NameNode 日志
cat /var/log/bigdata/hadoop/hadoop-*-namenode-*.log

# 重新格式化 (会丢失数据)
hdfs namenode -format -force -nonInteractive
```

### YARN 容器内存不足

修改 `env.sh` 中的内存配置，确保：
- `YARN_NODEMANAGER_RESOURCE_MEMORY_MB` <= 节点可用内存
- `YARN_SCHEDULER_MAXIMUM_ALLOCATION_MB` <= `YARN_NODEMANAGER_RESOURCE_MEMORY_MB`

### Kafka 无法连接

```bash
# 检查 ZooKeeper
echo ruok | nc node1 2181

# 检查 Kafka 日志
tail -f /var/log/bigdata/kafka/kafka-server.log
```

### Flink 任务提交失败

```bash
# 检查 YARN 资源
yarn node -list

# 检查 Flink 是否有 Hadoop 依赖
ls ${FLINK_HOME}/lib/flink-shaded-hadoop*
```

## 安全注意事项

1. **密码安全**：生产环境建议使用密钥认证替代密码
2. **目录权限**：确保 `DEPLOY_USER` 对所有数据目录有读写权限
3. **防火墙**：按需开放端口，不要完全关闭
4. **SELinux**：如启用需配置相应策略

## 扩展指南

### 添加 Worker 节点

1. 在 `servers.txt` 中添加新节点（IP + 主机名）
2. 配置新节点的 SSH 免密
3. 运行 `deploy_all.sh` (已有组件会自动跳过)

```
192.168.1.10 node1
192.168.1.11 node2
192.168.1.12 node3
192.168.1.13 node4   # 新增
```

### 调整资源分配

修改 `env.sh` 中的 JVM 和 YARN 资源参数后，重新运行对应组件的部署脚本。

## 许可

内部使用。
