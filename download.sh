#!/bin/bash

# 获取当前路径
BASE_DIR=$(cd "$(dirname $0)"; pwd)
cd $BASE_DIR

# 循环执行直到成功
function repeat() {
    while true; do
        $@ && return
    done
}

# 读取配置文件
if [ -f './conf.cfg' ]; then
    source ./conf.cfg
else
    echo -e "\n----------------------- Please Crate conf.cfg -----------------------\n"
    curl http://soft.hc-yun.com/base/conf.cfg
    echo -e "\n\n\n"
    exit 1
fi

# 检测 HOSTS,SERVERS 数组个数
if [ "${#HOSTS[@]}" != "${#SERVERS[@]}" ]; then
    echo -e "\n\tHOSTS与SERVERS 数组个数不匹配...\n"
    exit 1
fi

# 检测服务器是否在线
for host in ${SERVERS[@]}; do
    ping -i 0.2 -c 3 -W 1 $host >& /dev/null
    if test $? -ne 0; then
        echo "[ERROR]: Can't connect $host"
        exit 1
    fi
done

clear
let SER_LEN=${#SERVERS[@]}-1
# 打印配置信息
cat <<EOF

----------------------------------------- Install Info -----------------------------------------

IP/主机对应关系
---------------

$(for ((i=0;i<=$SER_LEN;i++)); do echo -e "    ${SERVERS[i]} <---> ${HOSTS[i]}"; done)

hadoop 服务
-----------

      zookeeper:
          zookeeper: $ZOO_SERVER

      hadoop:
           namenode: $NameNode
           datanode: $DataNode

      hbase:
             master: $HBASE_MASTER
              slave: $HBASE_SLAVE

      opentsdb:
           opentsdb: $TSDB_SERVER

      kafka:
              kafka: $KAFKA_SERVER

      apache-storm:
             master: $STORM_MASTER
              slave: $STORM_SLAVE

      fastdfs:
            storage: $STORAGE_SERVER
            tracker: $TRACKER_SERVER

            storage:
                  nginx: $STORAGE_SERVER
              keeplived: $STORAGE_SERVER
            keep_master: $KEEP_MASTER
               keep_vip: $KEEP_VIP

其他服务
--------

              mysql: $MYSQL_SERVER

            mongodb: $MONGODB_SERVER

             nodejs: $NODEJS_SERVER (ht-3d-editor)
            
            gateway: $GATEWAY_SERVER (网关/注册中心)

              emqtt: $CAIJI_SERVER

       nginx/Tomcat: $WEB_SERVER (资源代理)

  calcroot/calctask: $CALC_SERVER (计算节点)

------------------------------------------------------------------------------------------------

EOF

read -p '确认以上信息请输入[Y]：' ARG
[ "$ARG" != 'Y' ] && { echo -e '\n\t取消...\n'; exit 1; }

# 判断内\外网
ping -c2 192.168.2.7 >/dev/null
if [ $? -eq 0 ];then
    SERVER='192.168.2.7'
else
    SERVER='soft.hc-yun.com'
fi

# 软件下载链接(软件版本信息在conf.cfg配置文件中)
DOWNLOAD_SERVER_DIR="http://$SERVER/base/software"

# 需要下载的软件列表
PACKAGE_LIST=(
  jdk-${JDK_VER}-linux-x64.tar.gz
  zookeeper-${ZOOKEEPER_VER}.tar.gz
  hadoop-${HADOOP_VER}.tar.gz
  hbase-${HBASE_VER}-bin.tar.gz
  opentsdb-${OPENTSDB_VER}.noarch.rpm
  kafka_${KAFKA_VER}.tgz
  apache-storm-${STORM_VER}.tar.gz
  fastdfs-${FASTDFS_VER}.tar.gz
  libfastcommon-${LIBFASTCOMMON_VER}.tar.gz
  nginx-${NGINX_VER}.tar.gz
  fastdfs-nginx-module-${FASTDFS_NGINX_MODULE_VER}.tar.gz
  emqttd-${EMQTTD_VER}.zip
  node-${NODEJS_VER}.tar.gz
  redis-${REDIS_VER}.tar.gz
  hazelcast-${HAZELCAST_VER}.tar.gz
  preprocess-${PREPROCESS_VER}.jar
)

# 配置YUM源
rm -f /etc/yum.repos.d/*.repo
curl -so /etc/yum.repos.d/epel-7.repo http://mirrors.aliyun.com/repo/epel-7.repo
curl -so /etc/yum.repos.d/Centos-7.repo http://mirrors.aliyun.com/repo/Centos-7.repo
sed -i '/aliyuncs.com/d' /etc/yum.repos.d/Centos-7.repo /etc/yum.repos.d/epel-7.repo

# 秘钥登录所有节点
SERVER_LIST="${SERVERS[@]}"
PORT=${SSH_PORT:-22}
./ssh-key-copy.sh "$SERVER_LIST" $SSH_USER $SSH_PASS $SSH_PORT

# 安装 wget
[ -f '/usr/bin/wget' ] || yum  install -y wget
mkdir -p $PACKAGE_DIR && cd $PACKAGE_DIR

# 创建软件包目录
for node in ${SERVERS[@]}; do
    ssh -p $PORT -T $node "mkdir -p $PACKAGE_DIR"
done

# 获取本机 eth0网卡IP
LOCAL_IP=$(nmcli device show eth0 | grep IP4.ADDRESS | awk '{print $NF}' | cut -d '/' -f1)

# 下载,发送软件到所有节点
for package in ${PACKAGE_LIST[@]}; do
    # 下载软件
    repeat wget -c $DOWNLOAD_SERVER_DIR/$package
    # 将软件发送到其他节点
    for node in ${SERVERS[@]}; do
        [ "$LOCAL_IP" == "$node" ] && continue
        scp -P $PORT -q $package ${node}:${PACKAGE_DIR} &
    done
done

cd ${BASE_DIR}
# 复制安装脚本到软件安装目录
for node in ${SERVERS[@]}; do
    scp -P $PORT -q info.sh conf.cfg install.sh ssh-key-copy.sh $node:${PACKAGE_DIR} &
done

clear
cat <<EOF

----------------------------------- 所有节点执行 -----------------------------------

    cd $PACKAGE_DIR && ./install.sh

------------------------------------------------------------------------------------

EOF

# 原软件下载地址
# sed -i "s#kaifa.hc-yun.com:30027#soft.hc-yun.com#" download.sh install.sh install-other.sh
