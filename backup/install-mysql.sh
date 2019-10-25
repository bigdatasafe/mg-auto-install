#!/bin/bash

# set -x

function get_version(){
    curl -sSL https://mirrors.tuna.tsinghua.edu.cn/mysql/yum/mysql57-community-el7/ | \
      sed 's|</a>| |g' | \
      sed -e 's/<[^>]*>//g' | \
      grep 'mysql-community-server-' | \
      awk '{print $1}' | \
      sort -t '.' -k3n | \
      awk -F '-' '{print $4}'
}

function usage() {
  cat <<EOF
Usage: $0 command ...[parameters]....
    --help, -h             查看帮助信息
    --data-dir, -d         mysql 数据存储目录
    --bin-log, -l          true 启用二进制日志 默认不启用
    --version, -v          指定安装版本
    --root-pass, -p        mysql root 密码
    --get-version, -V      查看软件仓库版本

    $0 --active install --data-dir /home/hadoop/mysql --version 5.7.23 --root-pass 123abc@DEF --bin-log true

EOF
}

GETOPT_ARGS=`getopt -o hVd:v:p:a:l: -al help,get-version,data-dir:,version:,root-pass:,active:,bin-log: -- "$@"`
eval set -- "$GETOPT_ARGS"
while [ -n "$1" ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -V|--get-version)
            get_version
            exit 0
            ;;
        -d|--data-dir)
            data_dir=$2
            shift 2
            ;;
        -v|--version)
            version=$2
            shift 2
            ;;
        -p|--root-pass)
            root_pass=$2
            shift 2
            ;;
        -a|--active)
            active=$2
            shift 2
            ;;
        -l|--bin-log)
            bin_log=$2
            shift 2
            ;;
        --)
            shift
            ;;
        *)
            usage
            exit 1
            ;;
    esac
done

function install_mysql(){
    # 数据存储路径
    DATA=${data_dir:-/home/hadoop/mysql}

    # 软件版本
    mysql_version=${version:-5.7.23}

    # root 密码
    MYSQL_ROOT_PASS=${root_pass:-abc1@DEF}

    # 创建 Mysql 安装源
    cat > /etc/yum.repos.d/mysql-community.repo  <<'EOF'
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
    yum install -y mysql-community-server-${mysql_version}

    # 获取IP
    HOST_IF=$(ip route|grep default|cut -d' ' -f5)
    HOST_IP=$(ip a|grep "$HOST_IF$"|awk '{print $2}'|cut -d'/' -f1)
    ID=$(echo $HOST_IP|awk -F '.' '{print $NF}')

    # 创建配置文件
    temp_str=$(head /dev/urandom |cksum |md5sum |cut -c 1-4)
    mv /etc/my.cnf /etc/my.cnf.${temp_str}
    cat > /etc/my.cnf <<EOF
[mysqld]
server-id=$ID
datadir=$DATA
socket=$DATA/mysql.sock
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
pid-file=$DATA/mysqld.pid
# 启用/关闭binlog日志
# log-bin=$DATA/mysql-bin/binlog
# log_bin_trust_function_creators=1
# expire_logs_days=7

[mysqld_safe]
log-error=/var/log/mysqld.log
pid-file=/var/run/mysqld/mysqld.pid
socket=$DATA/mysql.sock

[mysqld.server]
character-set-server=utf8
socket=$DATA/mysql.sock

[mysqld.safe]
character-set-server=utf8
socket=$DATA/mysql.sock

[mysql]
# default-character-set=utf8
socket=$DATA/mysql.sock

[mysql.server]
# default-character-set=utf8
socket=$DATA/mysql.sock

[client]
default-character-set=utf8
socket=$DATA/mysql.sock
EOF

    # 创建数据目录, 设置权限
    mkdir -p $DATA
    chown -R mysql:mysql $DATA

    # 启动 MySql 服务,跟随系统启动
    systemctl start mysqld
    systemctl enable mysqld

    # 创建自动初始化脚本
    yum install -y expect
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
    chmod +x mysql_secure_installation.exp
    GET_PASS=$(grep "temporary password" /var/log/mysqld.log|awk '{ print $11}'| tail -n1)
    ./mysql_secure_installation.exp $GET_PASS $MYSQL_ROOT_PASS

    # 启用root远程登录
    mysql -uroot -p$MYSQL_ROOT_PASS --connect-expired-password -e "grant all on *.* to 'root'@'%' identified by '$MYSQL_ROOT_PASS' with grant option;"

    # 启用二进制日志
    if [[ "$bin_log" == 'true' ]]; then
        # 启用 bin-log
        sed -i '18,20 s/# //' /etc/my.cnf
        
        # 创建 bin-log 文件夹
        mkdir -p $DATA/mysql-bin
        chown -R mysql:mysql $DATA
        
        # 重启 mysqld 服务
        systemctl restart mysqld
    fi
}

if [ "$active" == 'install' ]; then
    install_mysql
fi
