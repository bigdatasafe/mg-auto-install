#!/bin/bash

# sshd 端口号
PORT=${SSH_PORT:-22}

# 默认网卡名
NET=${NET_NAME:-eth0}

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

# 获取网卡IP
LOCAL_IP=$(nmcli device show $NET | grep IP4.ADDRESS | awk '{print $NF}' | cut -d '/' -f1 | head -n1)
[ "$LOCAL_IP" ] || { echo -e "\n\t获取网卡 $NET 网卡IP地址失败...\n"; exit 1; }

# 配置 hosts 解析
if [ "$(echo ${SERVERS[@]} | grep $LOCAL_IP)" ]; then
    sed -i '3,$d' /etc/hosts
    echo -e "\n# hadoop" >> /etc/hosts
    let SER_LEN=${#SERVERS[@]}-1
    for ((i=0;i<=$SER_LEN;i++)); do
        echo "${SERVERS[i]}  ${HOSTS[i]}" >> /etc/hosts
    done
fi

# 更改主机名
for ((i=0;i<=$SER_LEN;i++)); do
    if [ "${SERVERS[i]}" == "$LOCAL_IP" ]; then
        hostnamectl set-hostname ${HOSTS[i]}
    fi
done

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
# 防火墙配置 |
#-------------
# 暂时未启用防火墙
CONF_FIREWALLD(){
    list="$1"
    for port in $list; do
        echo -e "$CGREEN -------------------- Allow Port $port -------------------- $CEND"
        firewall-cmd --zone=public --add-port=$port/tcp --permanent     # 永久生效允许 XXX 端口
        firewall-cmd --reload                                           # 重新载入防火墙配置
        firewall-cmd --zone=public --query-port=$port/tcp               # 查看 XXX 端口是否允许
        firewall-cmd --zone=public --list-ports
        sleep 3
    done
}

#----------------------------------------------------------------------------------------------
# 安装 JDK |
#-----------
INSTALL_JDK(){
    # 安装JDK
    mkdir -p /usr/java/ $PACKAGE_DIR && cd $PACKAGE_DIR
    tar zxf jdk-${JDK_VER}-linux-x64.tar.gz -C /usr/java/

    # 配置环境变量
    config=/etc/profile.d/jdk.sh
    echo '#!/bin/bash' > $config
    echo 'export JAVA_HOME=/usr/java/jdk1.8.0_211' >> $config
    echo 'export JRE_HOME=${JAVA_HOME}/jre' >> $config
    echo 'export CLASSPATH=.:$JAVA_HOME/lib/dt.jar:$JAVA_HOME/lib/tools.jar:$JRE_HOME/lib:$CLASSPATH' >> $config
    echo 'export PATH=$JAVA_HOME/bin:$PATH' >> $config

    # 读取环境变量
    chmod +x $config
    source $config
}

#----------------------------------------------------------------------------------------------
# zookeeper 安装配置 |
#---------------------
INSTALL_ZOOKEEPER(){
    mkdir -p $SOFT_INSTALL_DIR $PACKAGE_DIR && cd $PACKAGE_DIR
    tar zxf zookeeper-${ZOOKEEPER_VER}.tar.gz -C $SOFT_INSTALL_DIR
    mkdir -p ${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/{logs,data}
    config=${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/conf/zoo.cfg
    echo 'tickTime=2000' > $config
    echo 'initLimit=10' >> $config
    echo 'syncLimit=5' >> $config
    echo "dataDir=$SOFT_INSTALL_DIR/zookeeper-${ZOOKEEPER_VER}/data" >> $config
    echo "dataLogDir=$SOFT_INSTALL_DIR/zookeeper-${ZOOKEEPER_VER}/logs" >> $config
    echo 'clientPort=2181' >> $config
    echo 'autopurge.snapRetainCount=500' >> $config
    echo 'autopurge.purgeInterval=24' >> $config
    count=1
    for node in $ZOO_SERVER; do
        echo "server.$count=$node:2888:3888"  >> $config
        [ "$node" == "`hostname`" ] && echo "$count" > ${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/data/myid
        let count++
    done

    # 配置环境变量
    config=/etc/profile.d/zookeeper.sh
    echo '#!/bin/bash' > $config
    echo "export ZOOKEEPER_HOME=${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}" >> $config
    echo 'export PATH=$ZOOKEEPER_HOME/bin:$PATH' >> $config

    # 读取环境变量
    chmod +x $config
    source $config
}

#----------------------------------------------------------------------------------------------
#  zookeeper 启动脚本 |
#----------------------
ZOOKEEPER_SERVICE_SCRIPT(){
cat <<EOF   > ${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/bin/zk.sh
#!/bin/bash

echo "\$1"
user="root"
iparray=($ZOO_SERVER)

case "\$1" in
    start) cmd='zkServer.sh start' ;;
    status) cmd='zkServer.sh status' ;;
    stop) cmd='zkServer.sh stop' ;;
    *) { echo -e "\nUsage \$0 {start|stop|status}"; exit 1; }  ;;
esac

for ip in \${iparray[*]}; do
    echo "------> ssh to \$ip"
    ssh -p $PORT -T \$user@\$ip "\$cmd"
    echo "------> jps:"
    ssh -p $PORT -T \$user@\$ip 'jps'
    echo
done
EOF

    chmod +x ${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/bin/zk.sh
}

#----------------------------------------------------------------------------------------------
# hadoop 安装(单namenode) |
#--------------------------
INSTALL_HADOOP_NN1(){
    cd $PACKAGE_DIR
    tar zxf hadoop-${HADOOP_VER}.tar.gz -C ${SOFT_INSTALL_DIR}
    mkdir -p ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/{logs,tmp,name,data,journal}

    # 配置环境变量
    config=/etc/profile.d/hadoop.sh
    echo '#!/bin/bash' > $config
    echo "export HADOOP_HOME=$SOFT_INSTALL_DIR/hadoop-${HADOOP_VER}" >> $config
    echo 'export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin' >> $config

    # 读取环境变量
    chmod +x $config
    source $config

    # 创建 core-site.xml
    # ZOO_LIST="$(for i in $ZOO_SERVER; do echo $i:2181; done)"
    # ZOO_LIST="$(echo $ZOO_LIST | sed 's# #,#g')"
    cat <<EOF > ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/core-site.xml
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>

<configuration>
    <property>
        <name>fs.defaultFS</name>
        <value>hdfs://${NameNode}:9000</value>
    </property>
    <property>
        <name>io.file.buffer.size</name>
        <value>13107200</value>
    </property>
    <property>
        <name>hadoop.tmp.dir</name>
        <value>file:${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/tmp</value>
    </property>
</configuration>
EOF

    # 创建 hdfs-site.xml
    DATANODE="$(for i in $DataNode ; do echo $i:8485; done)"
    DATANODE="$(echo $DATANODE | sed 's# #;#g')"
    cat <<EOF > ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/hdfs-site.xml
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>

<configuration>
    <property>
        <name>dfs.namenode.secondary.http-address</name>
        <value>${NameNode}:50090</value>
    </property>
    <property>
        <name>dfs.replication</name>
        <value>2</value>
    </property>
    <property>
        <name>dfs.namenode.name.dir</name>
        <value>file:${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/name</value>
    </property>
    <property>
        <name>dfs.datanode.data.dir</name>
        <value>file:${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/data</value>
    </property>
</configuration>
EOF

    # 修改yarn-site.xml配置文件
    cat <<EOF > ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/yarn-site.xml
<?xml version="1.0"?>

<configuration>
    <property>
        <name>yarn.nodemanager.aux-services</name>
        <value>mapreduce_shuffle</value>
    </property>
    <property>
        <name>yarn.resourcemanager.address</name>
        <value>${NameNode}:8032</value>
    </property>
    <property>
        <name>yarn.resourcemanager.scheduler.address</name>
        <value>${NameNode}:8030</value>
    </property>
    <property>
        <name>yarn.resourcemanager.resource-tracker.address</name>
        <value>${NameNode}:8031</value>
    </property>
    <property>
        <name>yarn.resourcemanager.admin.address</name>
        <value>${NameNode}:8033</value>
    </property>
    <property>
        <name>yarn.resourcemanager.webapp.address</name>
        <value>${NameNode}:8088</value>
    </property>
</configuration>
EOF

    # 创建 mapred-site.xml
    cat <<EOF > ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/mapred-site.xml
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>

<configuration>
    <property>
        <name>mapreduce.framework.name</name>
        <value>yarn</value>
    </property>
    <property>
        <name>mapreduce.jobhistory.address</name>
        <value>${NameNode}:10020</value>
    </property>
    <property>
        <name>mapreduce.jobhistory.address</name>
        <value>${NameNode}:19888</value>
    </property>
</configuration>
EOF

    # 加入DataNode节点主机名
    rm -f ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/slaves
    for node in $DataNode; do
        echo "$node"  >> ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/slaves
    done

    # SSH端口
    echo "export HADOOP_SSH_OPTS=\"-p $PORT\"" >> ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/hadoop-env.sh

    # hadoop 集群内核优化
    cat > /etc/sysctl.conf  <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
vm.swappiness = 0
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rmem = 8192 262144 4096000
net.ipv4.tcp_wmem = 4096 262144 4096000
net.ipv4.tcp_max_orphans = 300000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 1
net.ipv4.ip_local_port_range = 1025 65535
net.ipv4.tcp_max_syn_backlog = 100000
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp.keepalive_time = 1200
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.netfilter.ip_conntrack_tcp_timeout_established = 1500
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.sysrq = 1
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.tcp_max_orphans = 3276800
fs.file-max = 800000
net.core.somaxconn=32768
net.core.rmem_default = 12697600
net.core.wmem_default = 12697600
net.core.rmem_max = 873800000
net.core.wmem_max = 655360000
EOF

    # 立即生效
    sysctl -p
}

#----------------------------------------------------------------------------------------------
# hadoop 集群初始化脚本(单namenode) |
#------------------------------------
INIT_HADOOP_NN1(){
    cat <<EEOF    > ${PACKAGE_DIR}/init-hadoop.sh
#!/bin/bash

source /etc/profile

# NameNode start zookeeper
ssh -p $PORT -T `hostname` <<EOF
    source /etc/profile.d/zookeeper.sh
    zk.sh start
EOF

sleep 5
# init hadoop
ssh -p $PORT -T $NameNode <<EOF
    source /etc/profile.d/hadoop.sh
    hdfs namenode -format -force
EOF

sleep 5
# start hadoop
ssh -p $PORT -T $NameNode <<EOF
    source /etc/profile.d/hadoop.sh
    ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/sbin/start-all.sh
EOF
EEOF
}

#----------------------------------------------------------------------------------------------
# hadoop 安装(双namenode) |
#--------------------------
INSTALL_HADOOP_NN2(){
    cd $PACKAGE_DIR
    tar zxf hadoop-${HADOOP_VER}.tar.gz -C ${SOFT_INSTALL_DIR}
    mkdir -p ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/{logs,tmp,name,data,journal}

    # 配置环境变量
    config=/etc/profile.d/hadoop.sh
    echo '#!/bin/bash' > $config
    echo "export HADOOP_HOME=$SOFT_INSTALL_DIR/hadoop-${HADOOP_VER}" >> $config
    echo 'export PATH=$PATH:$HADOOP_HOME/bin:$HADOOP_HOME/sbin' >> $config

    # 读取环境变量
    chmod +x $config
    source $config

    # 创建 core-site.xml
    ZOO_LIST="$(for i in $ZOO_SERVER; do echo $i:2181; done)"
    ZOO_LIST="$(echo $ZOO_LIST | sed 's# #,#g')"
    cat <<EOF > ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/core-site.xml
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
 <property>
     <name>fs.defaultFS</name>
     <value>hdfs://hadoopha</value>
 </property>
 <property>
     <name>hadoop.tmp.dir</name>
     <value>file:${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/tmp</value>
 </property>
 <property>
    <name>ha.zookeeper.quorum</name>
    <value>$ZOO_LIST</value>
 </property>
 <property>
    <name>ha.zookeeper.session-timeout.ms</name>
    <value>15000</value>
 </property>
</configuration>
EOF

    # 创建 hdfs-site.xml
    DATANODE="$(for i in $DataNode ; do echo $i:8485; done)"
    DATANODE="$(echo $DATANODE | sed 's# #;#g')"
    cat <<EOF > ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/hdfs-site.xml
<?xml version="1.0" encoding="UTF-8"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
 <property>
     <name>dfs.namenode.name.dir</name>
     <value>file:${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/name</value>
 </property>
 <property>
     <name>dfs.datanode.data.dir</name>
     <value>file:${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/data</value>
 </property>
 <property>
     <name>dfs.replication</name>
     <value>3</value>
 </property>
 <!--HA配置 -->
 <property>
     <name>dfs.nameservices</name>
     <value>hadoopha</value>
 </property>
 <property>
     <name>dfs.ha.namenodes.hadoopha</name>
     <value>nn1,nn2</value>
 </property>
 <!--namenode1 RPC端口 -->
 <property>
     <name>dfs.namenode.rpc-address.hadoopha.nn1</name>
     <value>${HDP_NN1}:9000</value>
 </property>
 <!--namenode1 HTTP端口 -->
 <property>
     <name>dfs.namenode.http-address.hadoopha.nn1</name>
     <value>${HDP_NN1}:50070</value>
 </property>
 <!--namenode2 RPC端口 -->
 <property>
     <name>dfs.namenode.rpc-address.hadoopha.nn2</name>
     <value>${HDP_NN2}:9000</value>
 </property>
  <!--namenode2 HTTP端口 -->
 <property>
     <name>dfs.namenode.http-address.hadoopha.nn2</name>
     <value>${HDP_NN2}:50070</value>
 </property>
  <!--HA故障切换 -->
 <property>
     <name>dfs.ha.automatic-failover.enabled</name>
     <value>true</value>
 </property>
 <!-- journalnode 配置 -->
 <property>
     <name>dfs.namenode.shared.edits.dir</name>
     <value>qjournal://${DATANODE}/hadoopha</value>
 </property>
 <property>
     <name>dfs.client.failover.proxy.provider.hadoopha</name>
     <value>org.apache.hadoop.hdfs.server.namenode.ha.ConfiguredFailoverProxyProvider</value>
 </property>
 <property>
     <name>dfs.ha.fencing.methods</name>
     <value>shell(/bin/true)</value>
  </property>
   <!--SSH私钥 -->
  <property>
      <name>dfs.ha.fencing.ssh.private-key-files</name>
      <value>/root/.ssh/id_rsa</value>
  </property>
 <!--SSH超时时间 -->
  <property>
      <name>dfs.ha.fencing.ssh.connect-timeout</name>
      <value>30000</value>
  </property>
  <!--Journal Node文件存储地址 -->
  <property>
      <name>dfs.journalnode.edits.dir</name>
      <value>${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/journal</value>
  </property>
</configuration>
EOF

    # 修改yarn-site.xml配置文件
    cat <<EOF > ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/yarn-site.xml
<?xml version="1.0"?>
<configuration>
    <!-- 开启RM高可用 -->
    <property>
         <name>yarn.resourcemanager.ha.enabled</name>
         <value>true</value>
    </property>
    <!-- 指定RM的cluster id -->
    <property>
         <name>yarn.resourcemanager.cluster-id</name>
         <value>yrc</value>
    </property>
    <!-- 指定RM的名字 -->
    <property>
         <name>yarn.resourcemanager.ha.rm-ids</name>
         <value>rm1,rm2</value>
    </property>
    <!-- 分别指定RM的地址 -->
    <property>
         <name>yarn.resourcemanager.hostname.rm1</name>
         <value>${HDP_RM1}</value>
    </property>
    <property>
         <name>yarn.resourcemanager.hostname.rm2</name>
         <value>${HDP_RM2}</value>
    </property>
    <!-- 指定zk集群地址 -->
    <property>
         <name>yarn.resourcemanager.zk-address</name>
         <value>${ZOO_LIST}</value>
    </property>
    <property>
         <name>yarn.nodemanager.aux-services</name>
         <value>mapreduce_shuffle</value>
    </property>
</configuration>
EOF

    # 创建 mapred-site.xml
    cat <<EOF > ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/mapred-site.xml
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>
<configuration>
   <property>
          <name>mapreduce.framework.name</name>
          <value>yarn</value>
   </property>
   <property>
         <name>mapreduce.map.memory.mb</name>
         <value>2048</value>
   </property>
   <property>
          <name>mapreduce.reduce.memory.mb</name>
          <value>2048</value>
   </property>
</configuration>
EOF

    # 加入DataNode节点主机名
    rm -f ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/slaves
    for node in $DataNode; do
        echo "$node"  >> ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/slaves
    done

    # SSH端口
    echo "export HADOOP_SSH_OPTS=\"-p $PORT\"" >> ${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/etc/hadoop/hadoop-env.sh

    # hadoop 集群内核优化
    cat > /etc/sysctl.conf  <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
vm.swappiness = 0
net.ipv4.neigh.default.gc_stale_time = 120
net.ipv4.conf.all.rp_filter = 0
net.ipv4.conf.default.rp_filter = 0
net.ipv4.conf.default.arp_announce = 2
net.ipv4.conf.lo.arp_announce = 2
net.ipv4.conf.all.arp_announce = 2
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 1024
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_rmem = 8192 262144 4096000
net.ipv4.tcp_wmem = 4096 262144 4096000
net.ipv4.tcp_max_orphans = 300000
net.ipv4.tcp_tw_reuse = 1
net.ipv4.tcp_tw_recycle = 1
net.ipv4.ip_local_port_range = 1025 65535
net.ipv4.tcp_max_syn_backlog = 100000
net.ipv4.tcp_fin_timeout = 30
net.ipv4.tcp.keepalive_time = 1200
net.ipv4.tcp_max_tw_buckets = 5000
net.ipv4.netfilter.ip_conntrack_tcp_timeout_established = 1500
kernel.msgmnb = 65536
kernel.msgmax = 65536
kernel.sysrq = 1
net.ipv4.icmp_echo_ignore_all = 0
net.ipv4.tcp_max_orphans = 3276800
fs.file-max = 800000
net.core.somaxconn=32768
net.core.rmem_default = 12697600
net.core.wmem_default = 12697600
net.core.rmem_max = 873800000
net.core.wmem_max = 655360000
EOF

    # 立即生效
    sysctl -p
}

#----------------------------------------------------------------------------------------------
#  hadoop 初始化脚本(双namenode) |
#---------------------------------
INIT_HADOOP_NN2(){
    cat <<EEOF    > ${PACKAGE_DIR}/init-hadoop.sh
#!/bin/bash

source /etc/profile

# NameNode start zookeeper
ssh -p $PORT -T `hostname` <<EOF
    source /etc/profile.d/zookeeper.sh
    zk.sh start
EOF

sleep 5
# start zkfc
ssh -p $PORT -T `hostname` <<EOF
    source /etc/profile.d/hadoop.sh
    hdfs zkfc -formatZK -force
EOF

sleep 5
# datanode 启动  journalnode
for node in $DataNode;do
    ssh -p $PORT -T \$node <<EOF
      source /etc/profile.d/hadoop.sh
      hadoop-daemon.sh  start journalnode
EOF
done

sleep 5
# NodeName Master 初始化
ssh -p $PORT -T $HDP_NN1 <<EOF
    source /etc/profile.d/hadoop.sh
    hdfs namenode -format -force
EOF

sleep 5
# start datanode
for node in $DataNode;do
    ssh -p $PORT -T \$node <<EOF
      source /etc/profile.d/hadoop.sh
      hadoop-daemon.sh start datanode
EOF
done

sleep 5
# start namenode1 master
ssh -p $PORT -T $HDP_NN1 <<EOF
    source /etc/profile.d/hadoop.sh
    hadoop-daemon.sh start namenode
EOF

sleep 5
# start namenode2 master
ssh -p $PORT -T $HDP_NN2 <<EOF
    source /etc/profile.d/hadoop.sh
    hdfs namenode -bootstrapStandby -force
    hadoop-daemon.sh start namenode
EOF

sleep 5
# NameNode start zkfc
for node in $NameNode;do
    ssh -p $PORT -T \$node <<EOF
      source /etc/profile.d/hadoop.sh
      hadoop-daemon.sh start zkfc
EOF
done
EEOF
}

#----------------------------------------------------------------------------------------------
# hbase 安装(hdp单namenode) |
#----------------------------
INSTALL_HBASE_NN1(){
    # 下载解压
    mkdir -p $PACKAGE_DIR && cd $PACKAGE_DIR
    tar zxf hbase-${HBASE_VER}-bin.tar.gz -C ${SOFT_INSTALL_DIR}/

    # 配置 hbase
    sed -i 's/# export HBASE_MANAGES_ZK=true/export HBASE_MANAGES_ZK=false/' ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/hbase-env.sh
    ZOOK_SERVER_LIST="$(echo $ZOO_SERVER | sed 's/ /,/g')"
    cat <<EOF    > ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/hbase-site.xml
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>

<configuration>
<property>
    <name>hbase.rootdir</name>
    <value>hdfs://${NameNode}:9000/hbase</value>
</property>
<property>
    <name>hbase.cluster.distributed</name>
    <value>true</value>
</property>
<property>
    <name>hbase.zookeeper.quorum</name>
    <value>${ZOOK_SERVER_LIST}</value>
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
</configuration>
EOF

    mkdir -p ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/{data,logs,tmp}
    rm -f ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/regionservers
    for node in $HBASE_SLAVE; do echo "$node" >> ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/regionservers ;done

    # 添加环境变量
    config=/etc/profile.d/hbase.sh
    echo '#!/bin/bash' > $config
    echo "export HBASE_HOME=${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}" >> $config
    echo 'export PATH=$HBASE_HOME/bin:$PATH' >> $config

    # SSH端口
    echo "export HBASE_SSH_OPTS=\"-p $PORT\"" >> ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/hbase-env.sh

    # 读取环境变量
    chmod +x $config
    source $config
}

#----------------------------------------------------------------------------------------------
# hbase 安装(hdp双namenode) |
#----------------------------
INSTALL_HBASE_NN2(){
    # 下载解压
    mkdir -p $PACKAGE_DIR && cd $PACKAGE_DIR
    tar zxf hbase-${HBASE_VER}-bin.tar.gz -C ${SOFT_INSTALL_DIR}/

    # 配置 hbase
    sed -i 's/# export HBASE_MANAGES_ZK=true/export HBASE_MANAGES_ZK=false/' ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/hbase-env.sh
    ZOOK_SERVER_LIST="$(echo $ZOO_SERVER | sed 's/ /,/g')"
    cat <<EOF    > ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/hbase-site.xml
<?xml version="1.0"?>
<?xml-stylesheet type="text/xsl" href="configuration.xsl"?>

<configuration>
<property>
    <name>hbase.rootdir</name>
    <!-- hadoopha 是namenode HA配置的 dfs.nameservices名称 -->
    <value>hdfs://hadoopha/hbase</value>
</property>
<property>
    <name>hbase.cluster.distributed</name>
    <value>true</value>
</property>
<property>
    <name>hbase.zookeeper.quorum</name>
    <value>${ZOOK_SERVER_LIST}</value>
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
    <value>${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/tmp</value>
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
</configuration>
EOF

    mkdir -p ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/{data,logs,tmp}
    rm -f ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/regionservers
    for node in $HBASE_SLAVE; do echo "$node" >> ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/regionservers ;done

    # 添加环境变量
    config=/etc/profile.d/hbase.sh
    echo '#!/bin/bash' > $config
    echo "export HBASE_HOME=${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}" >> $config
    echo 'export PATH=$HBASE_HOME/bin:$PATH' >> $config

    # SSH端口
    echo "export HBASE_SSH_OPTS=\"-p $PORT\"" >> ${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/conf/hbase-env.sh

    # 读取环境变量
    chmod +x $config
    source $config
}

#----------------------------------------------------------------------------------------------
# opentsdb 安装配置 |
#--------------------
INSTALL_TSDB(){
    cd $PACKAGE_DIR
    yum install -y opentsdb-${OPENTSDB_VER}.noarch.rpm
    ZOOK_SERVER_LIST="$(echo $ZOO_SERVER | sed 's/ /,/g')"
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
    echo "tsd.storage.hbase.zk_quorum = ${ZOOK_SERVER_LIST}" >> $confile
    echo 'tsd.query.timeout = 0' >> $confile
    echo 'tsd.query.filter.expansion_limit = 65535' >> $confile
    echo 'tsd.network.keep_alive = true' >> $confile
    echo 'tsd.network.backlog = 3072' >> $confile
    echo 'tsd.storage.fix_duplicates=true' >> $confile

    mkdir -p ${SOFT_INSTALL_DIR}/opentsdb/{data,logs,tmp}
}

#----------------------------------------------------------------------------------------------
# opentsdb 初始化脚本 |
#----------------------
INIT_OPENTSDB(){
    cat <<EEOF   > ${PACKAGE_DIR}/init-opentsdb.sh
#!/bin/bash

source /etc/profile

# start hbase
${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/bin/start-hbase.sh

# copy 创建 opentsdb 表文件到当前节点
sleep 15
scp -P $PORT $(echo $TSDB_SERVER | awk '{print $1}'):/usr/share/opentsdb/tools/create_table.sh /tmp/create_table.sh
sed -i 's#\$TSDB_TTL#2147483647#' /tmp/create_table.sh

# 导入 opentsdb 表
env COMPRESSION=none HBASE_HOME=${SOFT_INSTALL_DIR}/hbase-${HBASE_VER} /tmp/create_table.sh

sleep 25
# 启动 opentsdb
for node in $TSDB_SERVER; do
    ssh -p $PORT -T \$node "tsdb tsd --config=/etc/opentsdb/opentsdb.conf > /dev/null 2>&1 &"
done

# 启动 kafka
for node in $KAFKA_SERVER; do
    ssh -p $PORT -T \$node kafka-server-start.sh -daemon ${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/config/server.properties
done

# 启动 apache-storm
${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/start-all.sh
EEOF
}

#----------------------------------------------------------------------------------------------
# kafka 安装配置 |
#-----------------
INSTALL_KAFKA(){
    # 下载解压
    mkdir -p $PACKAGE_DIR && cd $PACKAGE_DIR
    tar zxf kafka_${KAFKA_VER}.tgz -C ${SOFT_INSTALL_DIR}

    # 配置kafka
    mkdir -p ${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/{data,logs,tmp}
    ID=$(echo $LOCAL_IP | awk -F '.' '{print $NF}')
    ZOO_LIST="$(for i in $ZOO_SERVER; do echo $i:2181; done)"
    ZOO_LIST="$(echo $ZOO_LIST | sed 's# #,#g')"
    config=${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/config/server.properties
    echo "broker.id=$ID" > $config
    echo "listeners=PLAINTEXT://${LOCAL_IP}:9092" >> $config
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
    echo "zookeeper.connect=$ZOO_LIST" >> $config
    echo 'zookeeper.connection.timeout.ms=60000' >> $config
    echo 'group.initial.rebalance.delay.ms=0' >> $config

    # 配置环境变量
    config=/etc/profile.d/kafka.sh
    echo '#!/bin/bash' > $config
    echo "export KAFKA_HOME=${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}" >> $config
    echo 'export PATH=$KAFKA_HOME/bin:$PATH' >> $config

    # 读取环境变量
    chmod +x $config
    source $config
}

#----------------------------------------------------------------------------------------------
# storm 安装 配置 |
#------------------
INSTALL_STORM(){
    # 下载解压
    cd $PACKAGE_DIR
    tar zxf apache-storm-${STORM_VER}.tar.gz -C ${SOFT_INSTALL_DIR}

    config=${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/conf/storm.yaml
    echo 'storm.zookeeper.servers:' > $config
    for node in $ZOO_SERVER; do echo "  - \"$node\"" >> $config ; done
    echo "storm.local.dir: \"${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/data\"" >> $config
    echo "nimbus.seeds: [\"$STORM_MASTER\"]" >> $config
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
    rm -f ${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/supervisor-hosts
    for node in $STORM_SLAVE; do echo "$node" >> ${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/supervisor-hosts; done

    # 服务启动脚本
    cat <<EOF  > ${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/start-all.sh
#!/bin/bash

source /etc/profile
bin=${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin
supervisors=\$bin/supervisor-hosts

storm nimbus >/dev/null 2>&1 &
storm ui >/dev/null 2>&1 &

cat \$supervisors | while read supervisor
  do
    echo "---> \$supervisor"
    ssh -p $PORT -T \$supervisor \$bin/start-supervisor.sh &
done
EOF

    cat <<'EOF'  >${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/start-supervisor.sh
#!/bin/bash
source /etc/profile

storm supervisor >/dev/null 2>&1 &
EOF

    # 服务关闭脚本
    cat <<EOF  >${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/stop-all.sh
#!/bin/bash

source /etc/profile
bin=${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin
supervisors=\$bin/supervisor-hosts

kill -9 \$(ps -ef | grep -v grep | grep daemon.nimbus | awk '{print \$2}')
kill -9 \$(ps -ef | grep -v grep | grep ui.core | awk '{print \$2}')

cat \$supervisors | while read supervisor
  do
    echo "---> \$supervisor"
    ssh -p $PORT -T \$supervisor \$bin/stop-supervisor.sh &
done
EOF

    cat <<EOF  >${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/stop-supervisor.sh
#!/bin/bash
source /etc/profile

kill -9 \$(ps -ef | grep -v grep | grep daemon.supervisor| awk '{print \$2}')
EOF

    chmod +x ${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/*.sh

    # 配置环境变量
    config=/etc/profile.d/storm.sh
    echo '#!/bin/bash' > $config
    echo "export STORM_HOME=${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}" >> $config
    echo 'export PATH=$STORM_HOME/bin:$PATH' >> $config

    # 读取环境变量
    chmod +x $config
    source $config
}

#----------------------------------------------------------------------------------------------
# Preprocess 安装 |
#------------------
INSTALL_PREPROCESS(){
    # 解压jar包
    uncompress_file(){
        mkdir $package
        cp $jar_file $package
        cd $package
        file_path=$(jar tvf $jar_file | egrep "$conf_file" | awk '{print $NF}')
        jar -xvf $jar_file $file_path
    }

    # 获取参数
    get_var(){
        SERVICE=$1
        SERVICE_PORT=$2
        hostaddr=
        for node in $SERVICE; do
            cat /etc/hosts | grep -v '^#' | grep $node >& /dev/null
            if test $? -eq 0; then
                hostaddr="$(cat /etc/hosts | grep -v '^#' | grep $node | awk '{print $1}'):$SERVICE_PORT $hostaddr"
            else
                echo "在hosts文件中未找到 $node 对应的 ip 地址..."
                exit 1
            fi
        done
    }

    # 将文件替换到压缩包内
    replace_file(){
        jar -uvf $jar_file $file_path
        rm -rf $(echo $file_path | awk -F '/' '{print $NR}')
    }

    package=preprocess
    package_ver=$PREPROCESS_VER
    jar_file="${package}-${package_ver}.jar"
    conf_file="hazelcast-default.xml|kafka-test.properties|mongodb-test.properties|opentsdb-test.conf"

    # 解压包
    cd $PACKAGE_DIR
    uncompress_file

    # 配置缓存分组参数
    sed -i "s#mango-prod#$HAZECAST_GROUP#" ./hazelcast-default.xml

    # 配置 kafka 参数
    get_var "$KAFKA_SERVER" "9092"
    KAFKA_LIST=$(echo $hostaddr |sed 's# #,#g')
    sed -i "s#bootstrap.servers.*#bootstrap.servers = $KAFKA_LIST#" ./kafka-test.properties

    # 配置 mongodb 参数
    get_var "$MONGODB_SERVER" "27017"
    MANGO_LIST=$(echo $hostaddr |sed 's# #,#g')
    sed -i "s#serverAddresses.*#serverAddresses = $MANGO_LIST#" ./mongodb-test.properties

    # 配置 zookeeper 参数
    get_var "$ZOO_SERVER" "2181"
    ZOOK_LIST=$(echo $hostaddr |sed 's# #,#g')
    sed -i "s#tsd.storage.hbase.zk_quorum.*#tsd.storage.hbase.zk_quorum = $ZOOK_LIST#" ./opentsdb-test.conf

    # 替换文件
    replace_file

    # 移动到软件安装目录
    cd ..
    mv $package $SOFT_INSTALL_DIR
    cd $SOFT_INSTALL_DIR/$package

    # 添加启动命令到初始化脚本
    echo -e "\n#start Preprocess" >> ${PACKAGE_DIR}/init-opentsdb.sh
    echo "CMD=\"${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/storm\"" >> ${PACKAGE_DIR}/init-opentsdb.sh
    echo "OPTION=\"jar $SOFT_INSTALL_DIR/$package/$jar_file com.haocang.data.preprocess.PreprocessTopologyV2 test > /dev/null 2>&1 &\"" >> ${PACKAGE_DIR}/init-opentsdb.sh
    echo "ssh -p $PORT -T `hostname` \"\$CMD \$OPTION\"" >> ${PACKAGE_DIR}/init-opentsdb.sh
}

#----------------------------------------------------------------------------------------------
# fastdfs 安装 |
#---------------
INSTALL_FASTDFS(){
    # 安装编译环境
    yum install -y unzip make cmake gcc gcc-c++ perl wget

    # 下载解压软件
    mkdir -p $PACKAGE_DIR && cd $PACKAGE_DIR
    tar -xvf libfastcommon-${LIBFASTCOMMON_VER}.tar.gz -C $SOURCE_DIR
    tar -xvf fastdfs-${FASTDFS_VER}.tar.gz -C $SOURCE_DIR

    # 编译安装 libfastcommon
    cd $SOURCE_DIR/libfastcommon-${LIBFASTCOMMON_VER}
    ./make.sh && ./make.sh install

    #编译安装 fastdfs
    cd $SOURCE_DIR/fastdfs-${FASTDFS_VER}
    ./make.sh && ./make.sh install
    /usr/bin/cp $SOURCE_DIR/fastdfs-${FASTDFS_VER}/conf/http.conf  /etc/fdfs/
    /usr/bin/cp $SOURCE_DIR/fastdfs-${FASTDFS_VER}/conf/mime.types /etc/fdfs/
}

#----------------------------------------------------------------------------------------------
# fastdfs tracker 配置 |
#-----------------------
CONFIG_TRACKER(){
    mkdir -p $TRACKER_DIR
    /usr/bin/cp -a /etc/fdfs/tracker.conf.sample /etc/fdfs/tracker.conf
    sed -i "s#store_group=.*#store_group=group1#" /etc/fdfs/tracker.conf
    sed -i "s#base_path=.*#base_path=$TRACKER_DIR#" /etc/fdfs/tracker.conf

    # 创建服务管理脚本
    cat > /usr/lib/systemd/system/fdfs_trackerd.service <<EOF
[Unit]
Description=The FastDFS File server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=$TRACKER_DIR/data/fdfs_trackerd.pid
ExecStart=/usr/bin/fdfs_trackerd /etc/fdfs/tracker.conf start
ExecReload=/usr/bin/fdfs_trackerd /etc/fdfs/tracker.conf restart
ExecStop=/usr/bin/fdfs_trackerd /etc/fdfs/tracker.conf stop

[Install]
WantedBy=multi-user.target
EOF

    # 启动 fdfs_trackerd 服务, 跟随系统启动
    systemctl daemon-reload
    systemctl enable fdfs_trackerd.service
    systemctl start fdfs_trackerd.service
    systemctl status fdfs_trackerd.service
}

#----------------------------------------------------------------------------------------------
# fastdfs storage 配置 |
#-----------------------
CONFIG_STORAGE(){
    mkdir -p $STORAGE_DIR
    /usr/bin/cp -a /etc/fdfs/storage.conf.sample /etc/fdfs/storage.conf
    sed -i "s#base_path=.*#base_path=$STORAGE_DIR#" /etc/fdfs/storage.conf
    sed -i "s#store_path0=.*#store_path0=$STORAGE_DIR#" /etc/fdfs/storage.conf
    sed -i "/tracker_server=/d" /etc/fdfs/storage.conf
    for node in $TRACKER_SERVER; do
        sed -i "113a tracker_server=${node}:22122" /etc/fdfs/storage.conf
    done

    # 创建服务管理脚本
    cat > /usr/lib/systemd/system/fdfs_storaged.service <<EOF
[Unit]
Description=The FastDFS File server
After=network.target remote-fs.target nss-lookup.target

[Service]
Type=forking
PIDFile=$STORAGE_DIR/data/fdfs_storaged.pid
ExecStart=/usr/bin/fdfs_storaged /etc/fdfs/storage.conf start
ExecReload=/usr/bin/fdfs_storaged /etc/fdfs/storage.conf restart
ExecStop=/usr/bin/fdfs_storaged /etc/fdfs/storage.conf stop

[Install]
WantedBy=multi-user.target
EOF

    # 启动 fdfs_storaged 服务, 跟随系统启动
    systemctl daemon-reload
    systemctl enable fdfs_storaged.service
    systemctl start fdfs_storaged.service
    systemctl status fdfs_storaged.service
}

#----------------------------------------------------------------------------------------------
# fastdfs client 配置 |
#----------------------
CONFIG_CLIENT(){
    mkdir -p $STORAGE_DIR
    /usr/bin/cp -a /etc/fdfs/client.conf.sample /etc/fdfs/client.conf
    sed -i "s#base_path=.*#base_path=$STORAGE_DIR#" /etc/fdfs/client.conf
    sed -i "/tracker_server=/d" /etc/fdfs/client.conf
        for node in $TRACKER_SERVER; do
        sed -i "13a tracker_server=${node}:22122" /etc/fdfs/client.conf
    done
}

#----------------------------------------------------------------------------------------------
# storage nginx 安装 |
#---------------------
INSTALL_FASTDFS_NGINX(){
    # 安装依赖环境
    yum install -y pcre pcre-devel zlib zlib-devel openssl openssl-devel

    # 下载解压软件
    cd $PACKAGE_DIR
    tar -zxf nginx-${NGINX_VER}.tar.gz -C $SOURCE_DIR
    tar -zxf fastdfs-nginx-module-${FASTDFS_NGINX_MODULE_VER}.tar.gz -C $SOURCE_DIR

    # 编译安装
    cd $SOURCE_DIR/nginx-${NGINX_VER}
    export C_INCLUDE_PATH=/usr/include/fastcommon
    ./configure --prefix=/usr/local/nginx --add-module=$SOURCE_DIR/fastdfs-nginx-module-${FASTDFS_NGINX_MODULE_VER}/src
    make && make install

    # 配置
    /usr/bin/cp $SOURCE_DIR/fastdfs-nginx-module-${FASTDFS_NGINX_MODULE_VER}/src/mod_fastdfs.conf /etc/fdfs/
    sed -i "/tracker_server=/d" /etc/fdfs/mod_fastdfs.conf
    sed -i "s#base_path=.*#base_path=$STORAGE_DIR#" /etc/fdfs/mod_fastdfs.conf
    sed -i "s#store_path0=.*#store_path0=$STORAGE_DIR#" /etc/fdfs/mod_fastdfs.conf
    sed -i "s#url_have_group_name = .*#url_have_group_name = true#" /etc/fdfs/mod_fastdfs.conf

    sed -i "s#group_count =.*#group_count = 1#" /etc/fdfs/mod_fastdfs.conf
    for node in $TRACKER_SERVER; do
        sed -i "39a tracker_server=${node}:22122" /etc/fdfs/mod_fastdfs.conf
    done

    # nginx
    cat <<'EOF'  > /usr/local/nginx/conf/nginx.conf
worker_processes  4;

events {
    worker_connections  65535;
    use epoll;
}

http {
    include            mime.types;
    default_type       application/octet-stream;
    sendfile           on;
    keepalive_timeout  65;
    server {
        listen       8888;
        server_name  localhost;

        location / {
            root   html;
            index  index.html index.htm;
        }

        location ~ /group1/M00 {
            ngx_fastdfs_module;
        }

        error_page   500 502 503 504  /50x.html;
        location = /50x.html {
            root   html;
        }
    }

    include /usr/local/nginx/conf.d/*.conf;
}
EOF

    echo -e "\n[group1]\ngroup_name=group1\nstorage_server_port=23000\nstore_path_count=1\nstore_path0=$STORAGE_DIR" >>/etc/fdfs/mod_fastdfs.conf

    # nginx proxy 8888
    confile='/usr/local/nginx/conf.d/dfs_proxy.conf'
    mkdir -p /usr/local/nginx/conf.d
    echo 'upstream fdfs_group1 {' > $confile
    for node in $STORAGE_SERVER;do
        echo -e "    server ${node}:8888 weight=2 max_fails=2 fail_timeout=30s;" >> $confile
    done
    echo '}' >> $confile
    echo 'server {' >> $confile
    echo "    listen       80;" >> $confile
    echo "    server_name  localhost;" >> $confile
    echo '' >> $confile
    echo 'location / {' >> $confile
    echo '    proxy_pass http://fdfs_group1;' >> $confile
    echo '}' >> $confile
    echo '' >> $confile
    echo '    location ~ /group1/M00 {' >> $confile
    echo '        proxy_pass http://fdfs_group1;' >> $confile
    echo '    }' >> $confile
    echo "    error_log    $NGINX_LOGS/error_dfs_proxy.log;" >> $confile
    echo "    access_log   $NGINX_LOGS/access_dfs_proxy.log;" >> $confile
    echo '}' >> $confile
    echo "<h1>$HOSTNAME $(hostname -I)</h1>" > /usr/local/nginx/html/index.html

    # 配置环境变量
    config=/etc/profile.d/nginx.sh
    echo '#!/bin/bash' > $config
    echo "export NGINX_HOME=/usr/local/nginx" >> $config
    echo 'export PATH=$NGINX_HOME/sbin:$PATH' >> $config

    # 读取环境变量
    chmod +x $config
    source $config

    # 启动nginx服务,跟随系统启动
    /usr/local/nginx/sbin/nginx
    echo -e "\n# start nginx\n/usr/local/nginx/sbin/nginx" >> /etc/rc.local
    chmod +x /etc/rc.d/rc.local
}

#----------------------------------------------------------------------------------------------
# keepalived 安装配置(代理fastdfs资源高可用) |
#---------------------------------------------
INSTALL_KEEPALIVED(){
    # install keepelived
    yum install -y keepalived

    # 配置keepalived
    if [ "`hostname`" == "$KEEP_MASTER" ]; then
        ROLE='MASTER'
        PRIORITY=100
        WEIGHT='-40'
    else
        ROLE='BACKUP'
        PRIORITY=90
        WEIGHT='2'
    fi
    ID="$(echo $LOCAL_IP | awk -F '.' '{print $NF}')"
    cat > /etc/keepalived/keepalived.conf <<EOF
! Configuration File for keepalived

global_defs {
   router_id $ID
   script_user root
   enable_script_security
}

vrrp_script nginx {
    script "/etc/keepalived/check_nginx.sh"
    interval 2
    weight $WEIGHT
}

vrrp_instance VI_1 {
    state $ROLE
    interface $NET
    virtual_router_id 110
    priority $PRIORITY
    advert_int 1
    authentication {
        auth_type PASS
        auth_pass zxdr5few
    }

    virtual_ipaddress {
        $KEEP_VIP
    }

    track_script {
        nginx
    }
}
EOF

    # 创建检测脚本
    cat > /etc/keepalived/check_nginx.sh   <<'EOF'
#!/bin/sh
A=`ps -C nginx --no-header |wc -l`
if [ $A -eq 0 ]
then
    exit 1
fi
EOF
    chmod +x /etc/keepalived/check_nginx.sh

    # 服务管理
    systemctl restart keepalived
    systemctl enable keepalived
    systemctl status keepalived
}


#----------------------------------------------------------------------------------------------
# 集群服务管理脚本 |
#-------------------
SERVER_MANAGE_SCRIPT(){
    cat <<EEOF    > /usr/local/bin/mango
#!/bin/bash

ARG=\$1

START(){
    echo "----> start zookeeper"
    ssh -p $PORT -T `hostname` "${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/bin/zk.sh start"

    sleep 5
    echo "----> start hadoop"
    ssh -p $PORT -T `hostname` "${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/sbin/start-all.sh"

    sleep 5
    echo "----> start hbase"
    ssh -p $PORT -T ${HBASE_MASTER} "${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/bin/start-hbase.sh"

    sleep 5
    echo "----> start kafka"
    for node in $KAFKA_SERVER; do
        echo "--> \$node"
        ssh -p $PORT -T \$node kafka-server-start.sh -daemon $SOFT_INSTALL_DIR/kafka_${KAFKA_VER}/config/server.properties
    done

    sleep 10
    echo "----> start storm"
    ssh -p $PORT -T ${STORM_MASTER} "${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/start-all.sh"

    sleep 15
    echo "----> start opentsdb"
    for node in $TSDB_SERVER; do
        echo "--> \$node"
        ssh -p $PORT -T \$node "tsdb tsd --config=/etc/opentsdb/opentsdb.conf > /dev/null 2>&1 &"
    done

    echo "----> start preprocess"
    CMD="${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/storm"
    OPTION="jar $SOFT_INSTALL_DIR/$package/$jar_file com.haocang.data.preprocess.PreprocessTopologyV2 test > /dev/null 2>&1 &"
    ssh -p $PORT -T `hostname` "\$CMD \$OPTION"
}

STOP(){
    echo "----> stop preprocess"
    jps | grep Preprocess | grep -v gerp | awk '{print \$1}' >& /dev/null
    if test \$? -eq 0; then
        jps | grep Preprocess | grep -v gerp | awk '{print \$1}' | xargs kill -9
        echo "---->stop Preprocess..."
    else
        echo "---->Preprocess is not running..."
    fi

    echo "----> stop opentsdb"
    for node in $TSDB_SERVER; do
        echo "--> \$node"
        ssh -p $PORT -T \$node "jps | grep TSDMain | awk '{print \\\$1}' | xargs kill > /dev/null 2>&1"
    done

    echo "----> stop storm"
    ssh -p $PORT -T ${STORM_MASTER} "${SOFT_INSTALL_DIR}/apache-storm-${STORM_VER}/bin/stop-all.sh"

    sleep 5
    echo "----> stop hbase"
    ssh -p $PORT -T ${HBASE_MASTER} "${SOFT_INSTALL_DIR}/hbase-${HBASE_VER}/bin/stop-hbase.sh"

    sleep 5
    echo "----> stop hadoop"
    # ssh -p $PORT -T ${STORM_MASTER} "${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/sbin/stop-all.sh"
    ssh -p $PORT -T ${STORM_MASTER} "${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/sbin/stop-dfs.sh"
    ssh -p $PORT -T ${STORM_MASTER} "${SOFT_INSTALL_DIR}/hadoop-${HADOOP_VER}/sbin/stop-yarn.sh"

    sleep 5
    echo "----> stop kafka"
    for node in $KAFKA_SERVER; do
        echo "--> \$node"
        ssh -p $PORT -T \$node "${SOFT_INSTALL_DIR}/kafka_${KAFKA_VER}/bin/kafka-server-stop.sh"
    done

    sleep 5
    echo "----> stop zookeeper"
    ssh -p $PORT -T `hostname` "${SOFT_INSTALL_DIR}/zookeeper-${ZOOKEEPER_VER}/bin/zk.sh stop"
}

INFO(){
    echo -e "\n\tUSAGE: \$0 {start|stop}\n"
}

case "\$ARG" in
    start) START ;;
    stop) STOP ;;
    *) INFO ;;
esac
EEOF

    chmod +x /usr/local/bin/mango
}

#----------------------------------------------------------------------------------------------
# mysql安装 |
#------------
INSTALL_MYSQL(){
    # 创建 Mysql 安装源
    cat <<EOF   > /etc/yum.repos.d/mysql-community.repo 
[mysql-connectors-community]
name=MySQL Connectors Community
baseurl=https://mirrors.tuna.tsinghua.edu.cn/mysql/yum/mysql-connectors-community-el7/
enabled=1
gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql

[mysql-tools-community]
name=MySQL Tools Community
baseurl=https://mirrors.tuna.tsinghua.edu.cn/mysql/yum/mysql-tools-community-el7/
enabled=1
gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql

# Enable to use MySQL 5.5
[mysql55-community]
name=MySQL 5.5 Community Server
baseurl=http://repo.mysql.com/yum/mysql-5.5-community/el/7/$basearch/
enabled=0
gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql

# Enable to use MySQL 5.6
[mysql56-community]
name=MySQL 5.6 Community Server
baseurl=https://mirrors.tuna.tsinghua.edu.cn/mysql/yum/mysql56-community-el7/
enabled=1
gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql

[mysql57-community]
name=MySQL 5.7 Community Server
baseurl=https://mirrors.tuna.tsinghua.edu.cn/mysql/yum/mysql57-community-el7/
enabled=1
gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql

[mysql80-community]
name=MySQL 8.0 Community Server
baseurl=https://mirrors.tuna.tsinghua.edu.cn/mysql/yum/mysql80-community-el7/
enabled=0
gpgcheck=0
gpgkey=file:///etc/pki/rpm-gpg/RPM-GPG-KEY-mysql
EOF

    # 安装 MySql-5.7
    yum install -y mysql-community-server

    # 启动 MySql 服务,跟随系统启动
    systemctl start mysqld
    systemctl enable mysqld

    # 创建自动初始化脚本
    yum install -y expect
    mkdir -p $PACKAGE_DIR && cd $PACKAGE_DIR
    cat > mysql_secure_installation.exp  <<'EOF'
#!/usr/bin/expect
set timeout 10
set oldpass [lindex $argv 0]
set newpass [lindex $argv 1]
spawn bash -c "mysql_secure_installation"
expect "Enter password for user root: "
    send "$oldpass\n"
expect "New password: "
    send "$newpass\n"
expect "Re-enter new password: "
    send "$newpass\n"
expect "Change the password for root ? ((Press y|Y for Yes, any other key for No) : "
    send "Y\n"
expect "New password: "
    send "$newpass\n"
expect "Re-enter new password: "
    send "$newpass\n"
expect "Do you wish to continue with the password provided?(Press y|Y for Yes, any other key for No) : "
    send "Y\n"
expect "Remove anonymous users? (Press y|Y for Yes, any other key for No) : "
    send "Y\n"
expect "Disallow root login remotely? (Press y|Y for Yes, any other key for No) : "
    send "Y\n"
expect "Remove test database and access to it? (Press y|Y for Yes, any other key for No) : "
    send "Y\n"
expect "Reload privilege tables now? (Press y|Y for Yes, any other key for No) : "
    send "Y\n"
    send "\n"
    send "exit"
    send "\n"
expect eof
EOF

    # 自动初始化MySql,更改密码
    NEW_PASS=${MYSQL_ROOT_PASS:-zaq1@WSX}
    OLD_PASS=$(grep "temporary password" /var/log/mysqld.log|awk '{ print $11}'| tail -n1)
    chmod +x mysql_secure_installation.exp
    ./mysql_secure_installation.exp $OLD_PASS $NEW_PASS

    # 启用root远程登录
    mysql -uroot -p$NEW_PASS --connect-expired-password -e "grant all on *.* to 'root'@'%' identified by  '$NEW_PASS' with grant option;"

    # 更改数据存储路径
    systemctl stop mysqld
    mv /etc/my.cnf /etc/my.cnf.default
    mkdir -p $DATA
    mv /var/lib/mysql $DATA/mysql

    # 以本机IP最后一段为MySqlID
    ID=$(echo $LOCAL_IP | awk -F '.' '{print $NF}')

    # 创建配置文件
    cat <<EOF > /etc/my.cnf
[mysqld]
server-id=$ID
datadir=$DATA/mysql
socket=$DATA/mysql/mysql.sock
character-set-server=utf8
symbolic-links=0
max_connections=50000
wait_timeout=30000
interactive_timeout=30000
lower_case_table_names=1
sql_mode=STRICT_TRANS_TABLES,NO_ZERO_IN_DATE,NO_ZERO_DATE,ERROR_FOR_DIVISION_BY_ZERO,NO_AUTO_CREATE_USER,NO_ENGINE_SUBSTITUTION
default-storage-engine=INNODB
symbolic-links=0
log-error=/var/log/mysqld.log
explicit_defaults_for_timestamp=true
pid-file=$DATA/mysql/mysqld.pid
# 启用/关闭binlog日志
# log-bin=$DATA/mysql/mysql-bin/binlog
# log_bin_trust_function_creators=1
# 此参数表示binlog日志保留的时间，默认单位是天。
# expire_logs_days=7

[mysqld_safe]
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid
socket=$DATA/mysql/mysql.sock

[mysqld.server]
character-set-server=utf8
socket=$DATA/mysql/mysql.sock

[mysqld.safe]
character-set-server=utf8
socket=$DATA/mysql/mysql.sock

[mysql]
# default-character-set=utf8
socket=$DATA/mysql/mysql.sock

[mysql.server]
# default-character-set=utf8
socket=$DATA/mysql/mysql.sock

[client]
default-character-set=utf8
socket=$DATA/mysql/mysql.sock
EOF

    # 创建二进制日志目录,更改数据目录权限,重启MySql服务
    mkdir -p $DATA/mysql/mysql-bin
    chown mysql:mysql -R $DATA/mysql
    systemctl restart mysqld

    # 配置防火墙
    CONF_FIREWALLD "3306"
}

#----------------------------------------------------------------------------------------------
# mysql 主从 init |
#------------------
INIT_MYSQL_CLUSTER(){
    # 变量
    NEW_PASS=${MYSQL_ROOT_PASS:-zaq1@WSX}                                     # MYSQL_ROOT_PASS
    MYSQL_SLAVE=$(echo $MYSQL_SERVER | awk '{print $2}')                      # MYSQL_SERVER 变量第二个字段备节点
    MYSQL_MASTER=$(echo $MYSQL_SERVER | awk '{print $1}')                     # MYSQL_SERVER 变量第一个字段主节点
    MYSQL_SLAVE_IP=$(cat /etc/hosts | grep $MYSQL_SLAVE | awk '{print $1}')   # 备节点IP
    MYSQL_MASTER_IP=$(cat /etc/hosts | grep $MYSQL_MASTER | awk '{print $1}') # 主节点IP
    SYNC_USER_PASS=$(mkpasswd -l 20 -C 6 -c 6 -d 4 -s 4 | tr -d \"\')         # 同步账户密码 随机数长度20 大写字母6 小写字母6 数字4 特殊字符4(排除特殊字符["''])

    # mysql主从初始化脚本
    cat > ${PACKAGE_DIR}/init-mysql-cluster.sh  <<EOFF
#!/bin/bash

# 备份用户名
sync_user=sync

# 备份用户密码(如果没有配置则使用默认值)
sync_user_pass='${SYNC_USER_PASS:-Qs4sObZrcajMi8m#}'

# mysql 登陆参数
mysql_cmd='mysql -uroot -p$NEW_PASS'

# 开启主节点二进制日志
ssh -p $PORT -T $MYSQL_MASTER <<EOF
    sed -i 's/# log-bin/log-bin/' /etc/my.cnf
    sed -i 's/# log_bin/log_bin/' /etc/my.cnf
    sed -i 's/# expire_logs/expire_logs/' /etc/my.cnf

    # 判断是否存在
    cat /etc/my.cnf | grep mysqldump >& /dev/null
    if test \\\$? -ne 0; then
        echo "" >> /etc/my.cnf
        echo "[mysqldump]" >> /etc/my.cnf
        echo "user = \$sync_user" >> /etc/my.cnf
        echo "password = '\$sync_user_pass'" >> /etc/my.cnf
    else
        sed -i "/\[mysqldump\]/d" /etc/my.cnf
        sed -i "/user =/d" /etc/my.cnf
        sed -i "/password =/d" /etc/my.cnf
        echo "[mysqldump]" >> /etc/my.cnf
        echo "user = \$sync_user" >> /etc/my.cnf
        echo "password = '\$sync_user_pass'" >> /etc/my.cnf
    fi

    systemctl restart mysqld
EOF

# 主节点创建备份用户(仅允许备节点登录)
ssh -p $PORT -T $MYSQL_MASTER <<EOF
    echo "grant replication slave on *.* to '\$sync_user'@'$MYSQL_SLAVE_IP' identified by '\$sync_user_pass';" | \$mysql_cmd
    echo "flush privileges;" | \$mysql_cmd
exit
EOF

# 获取主节点二进制日志文件名及位置
log_pos=\$(ssh -p $PORT -T $MYSQL_MASTER "echo 'SHOW MASTER STATUS;' | \$mysql_cmd" | tail -n1 | awk '{print \$2}')
log_file=\$(ssh -p $PORT -T $MYSQL_MASTER "echo 'SHOW MASTER STATUS;' | \$mysql_cmd" | tail -n1 | awk '{print \$1}')

# 备节点只允许具有SUPER权限的用户进行更新(root,sync)
ssh -p $PORT -T $MYSQL_SLAVE <<EOF
    sed -i '/\[mysqld\]/a\read-only' /etc/my.cnf
    systemctl restart mysqld 
EOF

# 从连接主参数
ssh -p $PORT -T $MYSQL_SLAVE <<EOF
    echo 'stop slave;' | \$mysql_cmd
    echo "change master to master_host='$MYSQL_MASTER_IP', \
          master_port=3306, master_user='\$sync_user', \
          master_password='\$sync_user_pass', \
          master_log_file='\$log_file', \
          master_log_pos=\$log_pos;" | \$mysql_cmd
    echo 'start slave;' | \$mysql_cmd
    echo 'show slave status\G;' | \$mysql_cmd
EOF
EOFF
}

#----------------------------------------------------------------------------------------------
# mangodb安装 |
#--------------
INSTALL_MONGODB(){
    # 创建安装源
    cat <<EOF > /etc/yum.repos.d/mongodb-org.repo
[mongodb-org]
[mongodb-org]
name=MongoDB Repository
baseurl=http://mirrors.aliyun.com/mongodb/yum/redhat/7Server/mongodb-org/3.6/x86_64/
gpgcheck=0
enabled=1
EOF

    # 更新yum缓存,安装mongodb
    yum -y makecache fast
    yum install -y mongodb-org

    # 更改监听IP, 更改数据存储路径
    mkdir -p $SOFT_INSTALL_DIR/mongo
    sed -i "s/bindIp: 127.0.0.1/bindIp: 0.0.0.0/g" /etc/mongod.conf
    sed -i "s#dbPath:.*#dbPath: $DATA/mongo#" /etc/mongod.conf
    chown mongod.mongod -R $DATA/mongo
    
    # 启动服务&&跟随系统启动
    systemctl start mongod
    systemctl enable mongod
    systemctl restart mongod

    # 配置防火墙
    CONF_FIREWALLD "27017"
}

#----------------------------------------------------------------------------------------------
# emqtt安装 |
#------------
INSTALL_EMQTT(){
    yum install -y unzip
    cd $PACKAGE_DIR
    [ -d "/usr/local/emqttd" ] && rm -rf /usr/local/emqttd
    unzip emqttd-${EMQTTD_VER}.zip -d /usr/local
    sed -i "s#node.name = emq@.*#node.name = emq@$LOCAL_IP#" /usr/local/emqttd/etc/emq.conf

    # 防火墙
    CONF_FIREWALLD "4369 8080 8083 8084 18083 6369 4369"

    # 创建服务管理脚本
    cat > /usr/lib/systemd/system/emqtt.service  <<EOF
[Unit]
Description=emqx enterprise
After=network.target

[Service]
Type=forking
Environment=HOME=/root
ExecStart=/bin/sh /usr/local/emqttd/bin/emqttd start
LimitNOFILE=1048576
ExecStop=/bin/sh /usr/local/emqttd/bin/emqttd stop

[Install]
WantedBy=multi-user.target
EOF

    # 启动服务,跟随系统启动
    systemctl daemon-reload
    systemctl restart emqtt
    systemctl enable emqtt
}

#----------------------------------------------------------------------------------------------
# nodejs安装 |
#-------------
INSTALL_NODE(){
    cd $PACKAGE_DIR
    tar xzf node-${NODEJS_VER}.tar.gz
    mv node-${NODEJS_VER} /usr/local/nodejs
    ln -s /usr/local/nodejs/bin/npm /usr/local/bin/
    ln -s /usr/local/nodejs/bin/node /usr/local/bin/
}

#----------------------------------------------------------------------------------------------
# redis安装 |
#------------
INSTALL_REDIS(){
    # 安装 gcc
    yum install -y gcc

    # 下载,编译安装 redis
    cd $PACKAGE_DIR
    tar xzf redis-${REDIS_VER}.tar.gz -C $SOURCE_DIR
    cd $SOURCE_DIR/redis-${REDIS_VER}
    make MALLOC=libc && cd src
    make install PREFIX=/usr/local/redis

    # 优化参数
    if [ ! "$(cat /etc/sysctl.conf | grep '# redis')" ]; then
        echo -e "\n# redis" >> /etc/sysctl.conf
        echo 'vm.overcommit_memory = 1' >> /etc/sysctl.conf
        echo 'net.core.somaxconn= 1024' >> /etc/sysctl.conf
        sysctl -p
        
        echo -e "\n# redis\necho never > /sys/kernel/mm/transparent_hugepage/enabled" >> /etc/rc.d/rc.local
        chmod +x  /etc/rc.d/rc.local
        echo never > /sys/kernel/mm/transparent_hugepage/enabled
    fi

    # 配置redis
    mkdir -p /usr/local/redis/etc
    /usr/bin/cp ../redis.conf /usr/local/redis/etc
    sed -i "s/bind 127.0.0.1/bind $LOCAL_IP/" /usr/local/redis/etc/redis.conf
    sed -i 's#^dir.*#dir /var/lib/redis#' /usr/local/redis/etc/redis.conf

    # 创建服务用户
    groupadd -g 995 redis
    useradd -r -g redis -u 997 -s /sbin/nologin redis

    # 创建数据目录
    mkdir /var/lib/redis
    chown -Rf redis:redis /var/lib/redis

    # 创建服务关闭脚本
    cat > /usr/local/redis/bin/redis-shutdown  <<'EOF'
#!/bin/bash
#
# Wrapper to close properly redis and sentinel
test x"$REDIS_DEBUG" != x && set -x

REDIS_CLI=/usr/local/redis/bin/redis-cli

# Retrieve service name
SERVICE_NAME="$1"
if [ -z "$SERVICE_NAME" ]; then
   SERVICE_NAME=redis
fi

# Get the proper config file based on service name
CONFIG_FILE="/usr/local/redis/etc/$SERVICE_NAME.conf"

# Use awk to retrieve host, port from config file
HOST=`awk '/^[[:blank:]]*bind/ { print $2 }' $CONFIG_FILE | tail -n1`
PORT=`awk '/^[[:blank:]]*port/ { print $2 }' $CONFIG_FILE | tail -n1`
PASS=`awk '/^[[:blank:]]*requirepass/ { print $2 }' $CONFIG_FILE | tail -n1`
SOCK=`awk '/^[[:blank:]]*unixsocket\s/ { print $2 }' $CONFIG_FILE | tail -n1`

# Just in case, use default host, port
HOST=${HOST:-127.0.0.1}
if [ "$SERVICE_NAME" = redis ]; then
    PORT=${PORT:-6379}
else
    PORT=${PORT:-26739}
fi

# Setup additional parameters
# e.g password-protected redis instances
[ -z "$PASS"  ] || ADDITIONAL_PARAMS="-a $PASS"

# shutdown the service properly
if [ -e "$SOCK" ] ; then
	$REDIS_CLI -s $SOCK $ADDITIONAL_PARAMS shutdown
else
	$REDIS_CLI -h $HOST -p $PORT $ADDITIONAL_PARAMS shutdown
fi
EOF

    chmod +x /usr/local/redis/bin/redis-shutdown
 
    cat > /usr/lib/systemd/system/redis.service <<'EOF'
[Unit]
Description=Redis persistent key-value database
After=network.target
After=network-online.target
Wants=network-online.target

[Service]
ExecStart=/usr/local/redis/bin/redis-server /usr/local/redis/etc/redis.conf --supervised systemd
ExecStop=/usr/local/redis/bin/redis-shutdown
Type=notify
User=redis
Group=redis
RuntimeDirectory=redis
RuntimeDirectoryMode=0755

[Install]
WantedBy=multi-user.target
EOF

    # 配置防火墙
    CONF_FIREWALLD "6379"

    # 启动服务,跟随系统启动
    systemctl start redis
    systemctl enable redis
}

#----------------------------------------------------------------------------------------------
# Tomcat 安装 |
#--------------
INSTALL_TOMCAT(){
    source /etc/profile

    # 下载解压tomcat
    mkdir -p $PACKAGE_DIR && cd $PACKAGE_DIR
    wget -c https://mirrors.tuna.tsinghua.edu.cn/apache/tomcat/tomcat-9/v9.0.20/bin/apache-tomcat-9.0.20.tar.gz
    tar xzf apache-tomcat-9.0.20.tar.gz
    mv apache-tomcat-9.0.20 /usr/local/tomcat9

    # 创建服务用户
    groupadd -g 53 tomcat
    useradd -r -g tomcat -u 53 -s /sbin/nologin tomcat

    # 创建服务管理脚本
    cat >/usr/lib/systemd/system/tomcat.service  <<EOF
[Unit]
Description=tomcat9
After=network.target
# Wants=jms.service   # 依赖的服务

[Service]
Type=forking
# PIDFile=/usr/local/tomcat9/tomcat.pid
ExecStart=/usr/local/tomcat9/bin/startup.sh
Environment="JAVA_HOME=$JAVA_HOME" "JRE_HOME=$JRE_HOME"
ExecStop=/usr/local/tomcat9/bin/shutdown.sh
# User=tomcat

[Install]
WantedBy=multi-user.target
EOF

    # 配置日志
    cat > /etc/logrotate.d/tomcat <<EOF
/usr/local/tomcat9/logs/catalina.out
{
    copytruncate
    daily
    rotate 7
    missingok
    notifempty
    compress
    create 0644 root root
}
EOF

    # 配置防火墙
    CONF_FIREWALLD "8080"

    # 启动服务,跟随系统启动
    systemctl start tomcat
    systemctl enable tomcat
}

#----------------------------------------------------------------------------------------------
# Hazecast 安装 |
#----------------
INSTALL_HAZECAST(){
    source /etc/profile

    # 解压
    cd $PACKAGE_DIR
    tar xf hazelcast-${HAZELCAST_VER}.tar.gz
    
    # 设置分组名     
    sed -i "s#mango-dev#$HAZECAST_GROUP#" hazelcast/bin/hazelcast.xml
    
    # 配置管理地址
    sed -i 's#<management-center.*#<\!-- & -->#' hazelcast/bin/hazelcast.xml
    sed -i '/<management-center.*/a\    <management-center enabled="true">http://localhost:9099/hazelcast-mancenter</management-center>' hazelcast/bin/hazelcast.xml
    chmod +x hazelcast/bin/*.sh
    
    # 复制3份
    [ -d "/usr/local/hazelcast" ] && rm -rf /usr/local/hazelcast
    mkdir /usr/local/hazelcast
    cp -a hazelcast /usr/local/hazelcast/haze1
    cp -a hazelcast /usr/local/hazelcast/haze2
    mv hazelcast /usr/local/hazelcast/haze3

    # 创建服务启动/关闭脚本
    cat > /usr/local/hazelcast/service.sh <<'EOF'
#!/bin/bash

ARG=$1

BASE_DIR=$(cd "`dirname $0`"; pwd)
cd $BASE_DIR

for i in 1 2 3; do
    cd  haze${i}/bin
    sh ${ARG}.sh
    cd ../../
done
EOF

    chmod +x /usr/local/hazelcast/service.sh

    # 创建服务管理脚本
    cat > /usr/lib/systemd/system/haze.service <<EOF
[Unit]
Description=hazelcast
After=network.target
# Wants=jms.service   # 依赖的服务

[Service]
Type=forking
# PIDFile=/usr/local/tomcat9/tomcat.pid
ExecStart=/usr/local/hazelcast/service.sh start
Environment="JAVA_HOME=$JAVA_HOME" "JRE_HOME=$JRE_HOME"
ExecStop=/usr/local/hazelcast/service.sh stop

[Install]
WantedBy=multi-user.target
EOF

    # 配置防火墙
    CONF_FIREWALLD "5701 5702 5703"


    # 启动服务,跟随系统启动
    systemctl daemon-reload
    systemctl enable haze
    systemctl restart haze
}

#----------------------------------------------------------------------------------------------
# nginx 安装 |
#-------------
INSTALL_NGINX(){
    # 安装依赖环境
    yum install -y pcre pcre-devel zlib zlib-devel openssl openssl-devel gcc

    # 解压软件
    cd $PACKAGE_DIR
    tar -zxf nginx-${NGINX_VER}.tar.gz -C $SOURCE_DIR

    # 编译安装
    cd $SOURCE_DIR/nginx-${NGINX_VER}
    ./configure --prefix=/usr/local/nginx
    make && make install

    # nginx 配置文件
    cat > /usr/local/nginx/conf/nginx.conf  <<'EOF'
user  root;
worker_processes  1;

#error_log  logs/error.log;
#error_log  logs/error.log  notice;
#error_log  logs/error.log  info;

#pid        logs/nginx.pid;


events {
    worker_connections  1024;
}


http {
    include       mime.types;
    default_type  application/octet-stream;

#    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
#                      '$status $body_bytes_sent "$http_referer" '
#                      '"$http_user_agent" "$http_x_forwarded_for"';
#
#    #access_log  logs/access.log  main;

   log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for" $request_time';

    log_format log_json '{ "@timestamp": "$time_local", '
    '"remote_addr": "$remote_addr", '
    '"referer": "$http_referer", '
    '"request": "$request", '
    '"status": $status, '
    '"bytes": $body_bytes_sent, '
    '"agent": "$http_user_agent", '
    '"x_forwarded": "$http_x_forwarded_for", '
    '"up_addr": "$upstream_addr",'
    '"up_host": "$upstream_http_host",'
    '"up_resp_time": "$upstream_response_time",'
    '"request_time": "$request_time"'
    ' }';

    access_log  /var/log/nginx/access.log log_json;

    sendfile        on;
    tcp_nopush     on;
    tcp_nodelay    on;
    #keepalive_timeout  0;
    keepalive_timeout  65;

    # gzip  on;
    underscores_in_headers on;
    client_max_body_size 50m;

    server {
        listen       801;
        server_name  localhost;

        #charset koi8-r;

        #access_log  logs/host.access.log  main;
        location /share {
            alias /home/mango/web/share;
            index index.html index.htm;
        }
        # web
        location / {
            root   /home/mango/web/dist;
            index  index.html index.htm;
        }
        #uaa api auth message base patrol equipment loong
        location /auth {
            proxy_pass http://localhost:8080;
	    proxy_set_header Host $host;
            # proxy_pass http://gateway:8080;
        }
        location /uaa {
            proxy_pass http://localhost:8080;
	    proxy_set_header Host $host;
	    proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
	    # proxy_pass http://gateway:8080;
        }
        location /api {
            proxy_pass http://localhost:8080;
	    proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
            # proxy_pass http://gateway:8080;
        }
        location /inventory {
            proxy_pass http://localhost:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
            # proxy_pass http://gateway:8080;
        }
        location /message {
            proxy_pass http://localhost:8080;
	    proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
            # proxy_pass http://gateway:8080;
        }
        location /base {
            proxy_pass http://localhost:8080;
	    proxy_set_header Host $host;
	    proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
            # proxy_pass http://gateway:8080;
        }
        location /patrol {
            proxy_pass http://localhost:8080;
	    proxy_set_header Host $host;
	    proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
            # proxy_pass http://gateway:8080;
        }
        location /equipment {
            proxy_pass http://localhost:8080;
	    proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
            # proxy_pass http://gateway:8080;
        }
        location /loong {
            proxy_pass http://localhost:8080;
	    proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
            # proxy_pass http://gateway:8080;
        }
	location /box {
	    proxy_pass http://localhost:8080;
	    proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
            # proxy_pass http://gateway:8080;
	}

        location /zuul {
            proxy_pass http://localhost:8080;
            proxy_set_header Host $host;
            proxy_set_header X-Real-IP $remote_addr;
            proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
            proxy_set_header X-NginX-Proxy true;
            # proxy_pass http://gateway:8080;
        }

    }

    server {
        listen       901;
        server_name  localhost;

        # 前端页面
        location / {
            root   /home/mango/backstage-web/dist;
            index  index.html index.htm;
        }

        # 后端api
        location /backstage {
            proxy_pass http://localhost:8087;
            proxy_set_header Host $host;
        }

        error_page 500 502 503 504 /50x.html;
        location = /50x.html {
            root    html;
        }
    }
}
EOF

    # 创建日志目录
    mkdir /var/log/nginx

    # 配置防火墙
    CONF_FIREWALLD "801 901"


    # 启动服务,跟随系统启动
    /usr/local/nginx/sbin/nginx
    echo -e "\n# start nginx\n/usr/local/nginx/sbin/nginx" >> /etc/rc.local
    chmod +x /etc/rc.d/rc.local
}

#----------------------------------------------------------------------------------------------
# 主节点安装完成后的提示信息 |
#-----------------------------
INIT_INFO(){
cat <<EOF

----------------------------------------- 初始化命令 -----------------------------------------

 1.初始化 hadoop
    # 脚本功能启动zookeeper 初始化 hadoop 集群
    source /etc/profile
    sh ${PACKAGE_DIR}/init-hadoop.sh

        打开浏览器确认初始化成功后请删除初始化脚本

 2.初始化 opentsdb
    # 脚本功能启动 hbase, opentsdb, kafka, storm, Perprocess
    source /etc/profile
    sh ${PACKAGE_DIR}/init-opentsdb.sh

        打开浏览器确认初始化成功后请删除初始化脚本


 3.测试fastdfs
    a.查看集群状态
    fdfs_monitor /etc/fdfs/client.conf | egrep 'ip_addr|tracker'

    b.上传测试
    fdfs_test /etc/fdfs/client.conf upload /usr/local/src/fastdfs-5.11/conf/anti-steal.jpg

    c.服务管理
    systemctl status fdfs_trackerd
    systemctl status fdfs_storaged


 4.服务管理
    mango stop     # 关闭服务
    mango start    # 启动服务


EOF
}


#----------------------------------------------------------------------------------------------
# 初始化
if [ "$(echo ${SERVERS[@]} | grep $LOCAL_IP)" ]; then
    PREP
fi

# 安装 JDK
jdk_list="$NameNode $DataNode $HBASE_MASTER $HBASE_SLAVE $TSDB_SERVER $KAFKA_SERVER $STORM_MASTER $STORM_SLAVE $CAIJI_SERVER $GATEWAY_SERVER $CALC_SERVER"
if [ "$(echo $jdk_list | grep `hostname`)" ]; then
    INSTALL_JDK
fi

# 安装 zookeeper
if [ "$(echo $ZOO_SERVER | grep `hostname`)" ]; then
    INSTALL_ZOOKEEPER
fi

# 安装 hadoop(判断 NameNode 参数个数安装 单/双 namenode节点版)
if [ "$(echo $NameNode $DataNode | grep `hostname`)" ]; then
    NameNodeLen=($NameNode)
    if [ ${#NameNodeLen[@]} -eq 1 ]; then
        INSTALL_HADOOP_NN1
    elif [ ${#NameNodeLen[@]} -eq 2 ]; then
        INSTALL_HADOOP_NN2
    else
        echo "Hadoop NameNode 参数错误 ..."
    fi
fi

# 安装 hbase(根据不同 单/双 namenode节点版 安装相应版本hbase)
if [ "$(echo $HBASE_MASTER $HBASE_SLAVE | grep `hostname`)" ]; then
    NameNodeLen=($NameNode)
    if [ ${#NameNodeLen[@]} -eq 1 ]; then
        INSTALL_HBASE_NN1
    elif [ ${#NameNodeLen[@]} -eq 2 ]; then
        INSTALL_HBASE_NN2
    else
        echo "Hadoop NameNode 参数错误 ..."
    fi
fi

# 安装 opentsdb
if [ "$(echo $TSDB_SERVER | grep `hostname`)" ]; then
    INSTALL_TSDB
fi

# 安装 kafka
if [ "$(echo $KAFKA_SERVER | grep `hostname`)" ]; then
    INSTALL_KAFKA
fi

# 安装 storm
if [ "$(echo $STORM_MASTER $STORM_SLAVE | grep `hostname`)" ]; then
    INSTALL_STORM
fi

# 安装 fastdfs
if [ "$(echo $TRACKER_SERVER $STORAGE_SERVER | grep `hostname`)" ]; then
    # 安装fastdfs
    INSTALL_FASTDFS

    # 配置客户端
    CONFIG_CLIENT
fi

# 配置 tracker
if [ "$(echo $TRACKER_SERVER | grep `hostname`)" ]; then
    CONFIG_TRACKER
fi

# 配置sotrage
if [ "$(echo $STORAGE_SERVER | grep `hostname`)" ]; then
    CONFIG_STORAGE

    # 安装 nginx
    INSTALL_FASTDFS_NGINX

    # 安装 keepalived
    INSTALL_KEEPALIVED
fi

# mysql 安装
if [ "$(echo $MYSQL_SERVER | grep `hostname`)" ]; then
    INSTALL_MYSQL
fi

# Mangodb 安装
if [ "$(echo $MONGODB_SERVER | grep `hostname`)" ]; then
    INSTALL_MONGODB
fi

# NodeJS 安装
if [ "$(echo $NODEJS_SERVER | grep `hostname`)" ]; then
    INSTALL_NODE
fi

# 网关节点安装缓存
if [ "$(echo $GATEWAY_SERVER | grep `hostname`)" ]; then
    INSTALL_HAZECAST
fi

# 采集 emqtt
if [ "$(echo $CAIJI_SERVER | grep `hostname`)" ]; then
    INSTALL_EMQTT
fi

# web server安装
if [ "$(echo $WEB_SERVER | grep `hostname`)" ]; then
    INSTALL_TOMCAT
    INSTALL_NGINX
fi

# NameNode 节点执行
if [ "$(echo $NameNode | grep `hostname`)" ]; then
    # 秘钥登录
    SERVER_LIST="${SERVERS[@]}"
    cd $PACKAGE_DIR
    ./ssh-key-copy.sh "$SERVER_LIST" $SSH_USER $SSH_PASS $PORT

    # zookeeper 服务管理脚本
    ZOOKEEPER_SERVICE_SCRIPT

    # hadoop 初始化脚本
    NameNodeLen=($NameNode)
    if [ ${#NameNodeLen[@]} -eq 1 ]; then
        INIT_HADOOP_NN1
    elif [ ${#NameNodeLen[@]} -eq 2 ]; then
        INIT_HADOOP_NN2
    else
        echo "Hadoop NameNode 参数错误 ..."
    fi

    # 服务管理脚本(mango stop/start)
    SERVER_MANAGE_SCRIPT

    # opentsdb 初始化脚本
    INIT_OPENTSDB
fi

# 输出初始化信息
if [ "$(echo $NameNode | awk '{print $1}')" == `hostname` ]; then
    # 安装预处理 
    INSTALL_PREPROCESS

    # 输出初始化信息
    INIT_INFO

    # 如果 MYSQL_SERVER 配置了两个字段,创建初始化脚本
    MYSQL_SERVER_LEN=($MYSQL_SERVER)
    if [ ${#MYSQL_SERVER_LEN[@]} -eq 2 ]; then
        INIT_MYSQL_CLUSTER
        echo ' 5.初始化mysql主从'
        echo "    sh $PACKAGE_DIR/init-mysql-cluster.sh"
    fi
    echo
    echo '-----------------------------------------------------------------------------------------------'
fi
