#!/bin/bash

# 软件包路径
PACKAGE_DIR=/home/software

# 软件安装路径
SOFT_INSTALL_DIR=/home/hadoop

# 获取当前IP地址
host_if=$(/usr/sbin/ip route|grep default|cut -d' ' -f5)
host_ip=$(/usr/sbin/ip a|grep "$host_if$"|awk '{print $2}'|cut -d'/' -f1)
[ "$host_ip" ] || { echo -e "\n\t获取网卡 $NET 网卡IP地址失败...\n"; exit 1; }

# 创建相关目录
[ -d "$PACKAGE_DIR" ] || mkdir -p $PACKAGE_DIR
[ -d "$SOFT_INSTALL_DIR" ] || mkdir -p $SOFT_INSTALL_DIR

# 资源下载信息
SOFT_INFO(){
    # 软件版本信息
    JDK_VER=8u211
    ZOOKEEPER_VER=3.4.14
    HADOOP_VER=2.7.7
    HBASE_VER=1.2.12
    OPENTSDB_VER=2.4.0
    KAFKA_VER=2.12-2.2.0
    STORM_VER=1.2.2

    # 资源路径
    SERVER='soft.hc-yun.com'
    DOWNLOAD_SERVER_DIR="http://$SERVER/base/software"
}

#----------------------------------------------------------------------------------------------
# 初始化配置 |
#-------------
PREP(){
    # 优化ssh连接速度
    sed -i "s/#UseDNS yes/UseDNS no/" /etc/ssh/sshd_config
    sed -i "s/GSSAPIAuthentication .*/GSSAPIAuthentication no/" /etc/ssh/sshd_config
    systemctl restart sshd

    # 关闭防火墙,selinux
    systemctl stop firewalld
    systemctl disable firewalld
    setenforce 0
    sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config

    # 可打开文件限制 进程限制
    if [ ! "$(cat /etc/security/limits.conf | grep '# mango')" ]; then
        echo -e "\n# mango" >> /etc/security/limits.conf
        echo "* soft nofile 65535" >> /etc/security/limits.conf
        echo "* hard nofile 65535" >> /etc/security/limits.conf
        echo "* soft nproc 65535"  >> /etc/security/limits.conf
        echo "* hard nproc 65535"  >> /etc/security/limits.conf
        echo "* soft  memlock  unlimited"  >> /etc/security/limits.conf
        echo "* hard memlock  unlimited"  >> /etc/security/limits.conf
    fi

    # 配置yum源
    rm -f /etc/yum.repos.d/*.repo
    curl -so /etc/yum.repos.d/epel-7.repo http://mirrors.aliyun.com/repo/epel-7.repo
    curl -so /etc/yum.repos.d/Centos-7.repo http://mirrors.aliyun.com/repo/Centos-7.repo
    sed -i '/aliyuncs.com/d' /etc/yum.repos.d/Centos-7.repo /etc/yum.repos.d/epel-7.repo

    # 时间同步
    yum install -y ntpdate
    ntpdate ntp1.aliyun.com
    hwclock -w
    crontab -l > /tmp/crontab.tmp
    echo "*/20 * * * * /usr/sbin/ntpdate ntp1.aliyun.com > /dev/null 2>&1 && /usr/sbin/hwclock -w" >> /tmp/crontab.tmp
    cat /tmp/crontab.tmp | uniq > /tmp/crontab
    crontab /tmp/crontab
    rm -f /tmp/crontab.tmp /tmp/crontab

    # 安装 wget, net-tools
    yum install -y wget net-tools
}

#----------------------------------------------------------------------------------------------
# 安装 JDK |
#-----------
INSTALL_JDK(){
    # 安装JDK
    mkdir -p /usr/java/ $PACKAGE_DIR && cd $PACKAGE_DIR
    wget -c ${DOWNLOAD_SERVER_DIR}/jdk-${JDK_VER}-linux-x64.tar.gz
    tar zxf jdk-${JDK_VER}-linux-x64.tar.gz -C /usr/java/

    # 配置环境变量
    echo '#!/bin/bash' > /etc/profile.d/jdk.sh
    echo 'export JAVA_HOME=/usr/java/jdk1.8.0_211' >> /etc/profile.d/jdk.sh
    echo 'export JRE_HOME=${JAVA_HOME}/jre' >> /etc/profile.d/jdk.sh
    echo 'export CLASSPATH=.:$JAVA_HOME/lib/dt.jar:$JAVA_HOME/lib/tools.jar:$JRE_HOME/lib:$CLASSPATH' >> /etc/profile.d/jdk.sh
    echo 'export PATH=$JAVA_HOME/bin:$PATH' >> /etc/profile.d/jdk.sh

    # 读取环境变量
    chmod +x /etc/profile.d/jdk.sh
    source /etc/profile.d/jdk.sh
}

#----------------------------------------------------------------------------------------------
# zookeeper 单节点 |
#------------------
INSTALL_ZOOKEEPER(){
    # 下载解压软件
    cd $PACKAGE_DIR
    wget -c ${DOWNLOAD_SERVER_DIR}/zookeeper-${ZOOKEEPER_VER}.tar.gz
    tar zxf zookeeper-${ZOOKEEPER_VER}.tar.gz -C $SOFT_INSTALL_DIR

    # 创建配置文件
    zk_config=${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/conf/zoo.cfg
    myid_count=1
    echo 'tickTime=2000' > $zk_config
    echo 'initLimit=10' >> $zk_config
    echo 'syncLimit=5' >> $zk_config
    echo 'clientPort=2181' >> $zk_config
    echo 'autopurge.snapRetainCount=500' >> $zk_config
    echo 'autopurge.purgeInterval=24' >> $zk_config
    echo "server.$myid_count=$host_ip:2888:3888"  >> $zk_config
    echo "dataDir=${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/data" >> $zk_config
    echo "dataLogDir=${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/logs" >> $zk_config
    echo "$myid_count" > ${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/data/myid

    # 配置环境变量
    echo '#!/bin/bash' > /etc/profile.d/zookeeper.sh
    echo "export ZOOKEEPER_HOME=${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}" >> /etc/profile.d/zookeeper.sh
    echo 'export PATH=$ZOOKEEPER_HOME/bin:$PATH' >> /etc/profile.d/zookeeper.sh

    # 读取环境变量
    chmod +x /etc/profile.d/zookeeper.sh
    source /etc/profile.d/zookeeper.sh


    # 创建数据目录
    mkdir -p ${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/{logs,data}

    # 创建服务管理脚本
    cat > /usr/lib/systemd/system/zookeeper.service  <<EOF
[Unit]
Description=zookeeper
After=network.target

[Service]
TimeoutSec=10
Type=forking
ExecStart=${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/bin/zkServer.sh start
Environment="JAVA_HOME=$JAVA_HOME" "JRE_HOME=$JRE_HOME"
ExecStop=${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/bin/zkServer.sh stop

[Install]
WantedBy=multi-user.target
EOF

    # 跟随系统启动
    systemctl daemon-reload
    systemctl enable zookeeper
}


#----------------------------------------------------------------------------------------------
# hbase 单节点 |
#---------------
INSTALL_HBASE(){
    # 下载解压软件
    cd $PACKAGE_DIR
    wget -c ${DOWNLOAD_SERVER_DIR}/hbase-${HBASE_VER}-bin.tar.gz
    tar zxf hbase-${HBASE_VER}-bin.tar.gz -C  ${SOFT_INSTALL_DIR}
    
    # 创建配置文件
    cat > ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/hbase-site.xml  <<EOF
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>

<configuration>
<property>
    <name>hbase.rootdir</name>
    <value>file://${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/data</value>
</property>
<property>
    <name>hbase.client.scanner.timeout.period</name>
    <value>180000</value>
</property>
<property>
    <name>zookeeper.session.timeout</name>
    <value>120000</value>
</property>
<property>
    <name>hbase.rpc.timeout</name>
    <value>300000</value>
</property>
<property>
    <name>hbase.hregion.majorcompaction</name>
    <value>0</value>
</property>
<property>
    <name>hbase.regionserver.thread.compaction.large</name>
    <value>5</value>
</property>
<property>
    <name>hbase.regionserver.thread.compaction.small</name>
    <value>5</value>
</property>
<property>
    <name>hbase.regionserver.thread.compaction.throttle</name>
    <value>10737418240</value>
</property>
<property>
    <name>hbase.regionserver.regionSplitLimit</name>
    <value>150</value>
</property>
<property>
    <name>hfile.block.cache.size</name>
    <value>0</value>
</property>
<property>
    <name>hbase.cluster.distributed</name>   
    <value>true</value>
</property>
<property>
    <name>hbase.zookeeper.quorum</name>
    <value>$host_ip</value>
</property>
<property>
    <name>hbase.zookeeper.property.clientPort</name>
    <value>2181</value>
</property>
<property>
    <name>hbase.zookeeper.property.dataDir</name>
    <value>${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/data</value>
</property>
<property>
    <name>hbase.tmp.dir</name>
    <value>${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/tmp</value>
</property>
</configuration>
EOF

    # 禁用自带zookeeper
    sed -i 's/# export HBASE_MANAGES_ZK=true/export HBASE_MANAGES_ZK=false/' ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/hbase-env.sh

    # 创建数据,日志目录
    mkdir -p ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/{data,logs,tmp}
    echo "localhost" > ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/regionservers

    # 添加环境变量
    echo '#!/bin/bash' > /etc/profile.d/hbase.sh
    echo "export HBASE_HOME=${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}" >> /etc/profile.d/hbase.sh
    echo 'export PATH=$HBASE_HOME/bin:$PATH' >> /etc/profile.d/hbase.sh
    
    # 读取环境变量
    chmod +x /etc/profile.d/hbase.sh
    source /etc/profile.d/hbase.sh

    # 服务管理
    cat > /usr/lib/systemd/system/hbase.service  <<EOF
[Unit]
Description=hbase
After=network.target
Wants=zookeeper.service

[Service]
TimeoutSec=10
Type=forking
ExecStart=${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/bin/start-hbase.sh
Environment="JAVA_HOME=$JAVA_HOME" "JRE_HOME=$JRE_HOME"
ExecStop=${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/bin/stop-hbase.sh

[Install]
WantedBy=multi-user.target
EOF

    # 跟随系统启动
    systemctl daemon-reload
    systemctl enable hbase
}

#----------------------------------------------------------------------------------------------
# oentsdb 单节点 |
#-----------------
INSTALL_TSDB(){
    # 下载解压软件
    cd $PACKAGE_DIR
    wget -c ${DOWNLOAD_SERVER_DIR}/opentsdb-${OPENTSDB_VER}.noarch.rpm
    yum install -y opentsdb-${OPENTSDB_VER}.noarch.rpm
    
    # 创建配置文件
    confile=/etc/opentsdb/opentsdb.conf
    echo 'tsd.core.preload_uid_cache = true' > $confile
    echo 'tsd.core.auto_create_metrics = true' >> $confile
    echo 'tsd.storage.enable_appends = true' >> $confile
    echo 'tsd.core.enable_ui = true' >> $confile
    echo 'tsd.core.enable_api = true' >> $confile
    echo 'tsd.network.port = 14242' >> $confile
    echo 'tsd.http.staticroot = /usr/share/opentsdb/static' >> $confile
    echo "tsd.http.cachedir = ${SOFT_INSTALL_DIR}/opentsdb/tmp" >> $confile
    echo 'tsd.http.request.enable_chunked = true' >> $confile
    echo 'tsd.http.request.max_chunk = 65535' >> $confile
    echo "tsd.storage.hbase.zk_quorum = ${host_ipIP}:2181" >> $confile
    echo 'tsd.query.timeout = 0' >> $confile
    echo 'tsd.query.filter.expansion_limit = 65535' >> $confile
    echo 'tsd.network.keep_alive = true' >> $confile
    echo 'tsd.network.backlog = 3072' >> $confile
    echo 'tsd.storage.fix_duplicates=true' >> $confile
    
    # 创建数据,日志目录
    mkdir -p ${SOFT_INSTALL_DIR}/opentsdb/{data,logs,tmp}

    # 创建服务启动/关闭脚本
    cat > /etc/opentsdb/opentsdb.sh  <<EOF
#!/bin/bash

ARG=\$1
source /etc/profile
start(){
    /usr/bin/tsdb tsd --config /etc/opentsdb/opentsdb.conf > /dev/null 2>&1 &
}

stop(){
    jps | grep TSDMain | awk '{print \$1}' | xargs kill > /dev/null 2>&1
}

case "\$ARG" in
    stop)   stop
    ;;
    start)   start
    ;;
    *)   echo "\$0 {start|stop}"
    ;;
esac
EOF

    chmod +x /etc/opentsdb/opentsdb.sh
    # 创建服务管理脚本
    cat > /usr/lib/systemd/system/opentsdb.service  <<EOF
[Unit]
Description=OpenTSDB
After=network-online.target
Wants=hbase.service

[Service]
TimeoutSec=10
Type=forking
Environment=JAVA_HOME=$JAVA_HOME
Environment='JVMARGS=-Xmx6000m -DLOG_FILE=/var/log/opentsdb/%p_%i.log -DQUERY_LOG=/var/log/opentsdb/%p_%i_queries.log -XX:+ExitOnOutOfMemoryError -enableassertions -enablesystemassertions'
ExecStart=/etc/opentsdb/opentsdb.sh start
ExecStop=/etc/opentsdb/opentsdb.sh stop

[Install]
WantedBy=multi-user.target
EOF

    # 跟随系统启动
    systemctl daemon-reload
    systemctl enable opentsdb
}

#----------------------------------------------------------------------------------------------
# kafka 单节点 |
#---------------
INSTALL_KAFKA(){
    # 下载解压软件
    cd $PACKAGE_DIR
    wget -c ${DOWNLOAD_SERVER_DIR}/kafka_${KAFKA_VER}.tgz
    tar zxf kafka_${KAFKA_VER}.tgz -C ${SOFT_INSTALL_DIR}

    # 创建配置文件
    BROKER_ID=$(echo $host_ip | awk -F '.' '{print $NF}')
    config=${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/config/server.properties
    echo "broker.id=$BROKER_ID" > $config
    echo "listeners=PLAINTEXT://${host_ip}:9092" >> $config
    echo 'num.network.threads=3' >> $config
    echo 'num.io.threads=8' >> $config
    echo '#auto.create.topics.enable =true' >> $config
    echo 'socket.send.buffer.bytes=102400' >> $config
    echo 'socket.receive.buffer.bytes=102400' >> $config
    echo 'socket.request.max.bytes=104857600' >> $config
    echo "log.dirs=${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/logs" >> $config
    echo 'num.partitions=1' >> $config
    echo 'num.recovery.threads.per.data.dir=1' >> $config
    echo 'offsets.topic.replication.factor=1' >> $config
    echo 'transaction.state.log.replication.factor=1' >> $config
    echo 'transaction.state.log.min.isr=1' >> $config
    echo 'log.retention.hours=168' >> $config
    echo 'log.segment.bytes=1073741824' >> $config
    echo 'log.retention.check.interval.ms=300000' >> $config
    echo "zookeeper.connect=${host_ip}:2181" >> $config
    echo 'zookeeper.connection.timeout.ms=60000' >> $config
    echo 'group.initial.rebalance.delay.ms=0' >> $config
    
    # 配置环境变量
    echo '#!/bin/bash' > /etc/profile.d/kafka.sh
    echo "export KAFKA_HOME=${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}" >> /etc/profile.d/kafka.sh
    echo 'export PATH=$KAFKA_HOME/bin:$PATH' >> /etc/profile.d/kafka.sh

    # 读取环境变量
    chmod +x /etc/profile.d/kafka.sh
    source /etc/profile.d/kafka.sh

    # 创建服务管理脚本
    cat > /usr/lib/systemd/system/kafka.service  <<EOF
[Unit]
Description=kafka
After=network.target

[Service]
TimeoutSec=10
Type=forking
Environment="JAVA_HOME=$JAVA_HOME" "JRE_HOME=$JRE_HOME"
ExecStart=${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/bin/kafka-server-start.sh -daemon ${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/config/server.properties
ExecStop=${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/bin/kafka-server-stop.sh

[Install]
WantedBy=multi-user.target
EOF

    # 跟随系统启动
    systemctl daemon-reload
    systemctl enable kafka
}

#----------------------------------------------------------------------------------------------
# storm 单节点 |
#---------------
INSTALL_STORM(){
    # 下载解压
    cd $PACKAGE_DIR
    wget -c ${DOWNLOAD_SERVER_DIR}/apache-storm-${STORM_VER}.tar.gz
    tar zxf apache-storm-${STORM_VER}.tar.gz -C ${SOFT_INSTALL_DIR}

    # 创建配置文件
    config=${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/conf/storm.yaml
    echo 'storm.zookeeper.servers:' > $config
    echo "  - \"$host_ip\"" >> $config
    echo "storm.local.dir: \"${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/data\"" >> $config
    echo "nimbus.seeds: [\"localhost\"]" >> $config
    echo 'nimbus.childopts: "-Xmx1024m"' >> $config
    echo 'supervisor.childopts: "-Xmx1024m"' >> $config
    echo 'worker.childopts: "-Xmx%HEAP-MEM%m -Xms%HEAP-MEM%m -XX:+UseG1GC -Xloggc:artifacts/gc.log"' >> $config
    echo 'topology.worker.max.heap.size.mb: 2048' >> $config
    echo 'worker.heap.memory.mb: 2048' >> $config
    echo 'topology.message.timeout.secs: 180' >> $config
    echo 'supervisor.worker.timeout.secs: 60' >> $config
    echo 'supervisor.slots.ports:' >> $config
    echo '  - 6700' >> $config
    echo '  - 6701' >> $config
    echo '  - 6702' >> $config
    echo '  - 6703' >> $config
    
    # 创建服务启动脚本
    cat <<EOF  > ${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/storm-all.sh
#!/bin/bash

ARG=\$1

source /etc/profile
BASE_DIR=\$(cd \$(dirname \$0); pwd)

start(){
    cd \$BASE_DIR
    storm nimbus >/dev/null 2>&1 &
    storm ui >/dev/null 2>&1 &
    storm supervisor >/dev/null 2>&1 &
}

stop(){
    kill -9 \$(ps -ef | grep -v grep | grep daemon.nimbus | awk '{print \$2}')
    kill -9 \$(ps -ef | grep -v grep | grep ui.core | awk '{print \$2}')
    kill -9 \$(ps -ef | grep -v grep | grep daemon.supervisor| awk '{print \$2}')
}

case "\$ARG" in
    stop)   stop
    ;;
    start)   start
    ;;
    restart)   stop && start
    ;;
    *)   echo "\$0 {start|stop|restart}"
    ;;
esac
EOF

    # 添加可执行权限
    chmod +x ${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/storm-all.sh
    
    # 配置环境变量
    config=/etc/profile.d/storm.sh
    echo '#!/bin/bash' > $config
    echo "export STORM_HOME=${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}" >> $config
    echo 'export PATH=$STORM_HOME/bin:$PATH' >> $config

    # 读取环境变量
    chmod +x $config
    source $config

    # 创建服务管理脚本
cat > /usr/lib/systemd/system/storm.service  <<EOF
[Unit]
Description=apache-storm
After=network.target
Wants=zookeeper.service

[Service]
TimeoutSec=10
Type=forking
Environment="JAVA_HOME=$JAVA_HOME" "JRE_HOME=$JRE_HOME"
ExecStart=${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/storm-all.sh start

[Install]
WantedBy=multi-user.target
EOF

    # 跟随系统启动
    systemctl daemon-reload
    systemctl enable storm
}

SERVICE_MANGE_SCRIPT(){
    # 服务管理脚本
    cat  > /root/service.sh   <<EOF
#!/bin/bash

ARG=\$1

start(){
    echo "----> start zookeeper"
    ${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/bin/zkServer.sh start

    echo "----> start hbase"
    ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/bin/start-hbase.sh
    
    echo "----> start opentsdb"
    /usr/bin/tsdb tsd --config /etc/opentsdb/opentsdb.conf > /dev/null 2>&1 &

    echo "----> start kafka"
    ${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/bin/kafka-server-start.sh -daemon ${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/config/server.properties

    echo "----> start apache-storm"
    ${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/storm-all.sh start
}

stop(){
    echo "----> stop opentsdb"
    jps | grep TSDMain | awk '{print \$1}' | xargs kill > /dev/null 2>&1

    echo "----> stop apache-storm"
    ${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/storm-all.sh stop

    echo "----> stop hbase"
    ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/bin/stop-hbase.sh
    
    echo "----> stop kafka"
    ${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/bin/kafka-server-stop.sh

    echo "----> stop zookeeper"
    ${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/bin/zkServer.sh stop
}

case "\$ARG" in
    stop)   stop
    ;;
    start)   start
    ;;
    *)   echo "\$0 {start|stop}"
    ;;
esac
EOF

    chmod +x /root/service.sh
}

# 说明信息
INFO(){

cat <<EOF

#----------------------------------------------------------------------------------------------

    # 请手动执行以下命令初始化 opentsdb
    
    # 启动 hbase(启动后浏览器打开验证)
    systemctl start zookeeper
    systemctl start hbase
    
    # 导入数据库文件
    cp /usr/share/opentsdb/tools/create_table.sh /tmp/create_table.sh
    sed -i 's#\$TSDB_TTL#2147483647#' /tmp/create_table.sh
    env COMPRESSION=none HBASE_HOME=${SOFT_INSTALL_DIR}/hbase-${HBASE_VER} /tmp/create_table.sh
    
    # 启动其他服务
    systemctl start opentsdb
    systemctl start kafka
    systemctl start storm
    
#----------------------------------------------------------------------------------------------

EOF
}

function main(){
    SOFT_INFO
    PREP
    INSTALL_JDK
    INSTALL_ZOOKEEPER
    INSTALL_HBASE
    INSTALL_TSDB
    INSTALL_KAFKA
    INSTALL_STORM
    SERVICE_MANGE_SCRIPT
    INFO
}

main
