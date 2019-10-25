#!/bin/bash

# set -x

function usage() {
  cat <<EOF
Usage: $0 command ...[parameters]....
    --help, -h             查看帮助信息
    --data-dir, -d         数据备份存储目录
    --mode, -m             备份模式 [1|2] 必选
      备份模式: 1.周日做全量备份 周一到周六每天做上周日的增量备份
      备份模式: 2.周日做全量备份 周一到周六每天做上一天的增量备份

    --mail                 备份失败邮件告警 启用: --mail treu 默认禁用
    --mail-addr            邮件告警邮箱地址
      如果启用邮件告警: 请手动测试邮件告警脚本确定能正常发送邮件

    --remoute-bak          远程备份 启用: --remoute-bak true 默认禁用
    --remoute-server       远程服务器地址： root@192.168.0.71
    --remoute-dir          远程服务器路径： /home/data
      如果启用远程备份: 1.配置本机到远程服务器的秘钥登录 2.登录远程服务器创建备份路径

    Example:
        $0 --mode 1 --data-dir /home/backup

        $0 --mode 1 --mail true --mail-addr example@domain.com

        $0 --mode 1 --remoute-bak true --remoute-server root@192.168.0.71 --remoute-dir /home/backupmysql
EOF
}

GETOPT_ARGS=`getopt -o hd:m: -al help,data-dir:,mode:,mail:,mail-addr:,remoute-bak:,remoute-server:,remoute-dir: -- "$@"`
eval set -- "$GETOPT_ARGS"
while [ -n "$1" ]; do
    case "$1" in
        -h|--help)
            usage
            exit 0
            ;;
        -d|--data-dir)
            data_dir=$2
            shift 2
            ;;
        -m|--mode)
            mode=$2
            shift 2
            ;;
        --mail)
            mail=$2
            shift 2
            ;;
        --mail-addr)
            mail_addr=$2
            shift 2
            ;;
        --remoute-bak)
            remoute_bak=$2
            shift 2
            ;;
        --remoute-server)
            remoute_server=$2
            shift 2
            ;;
        --remoute-dir)
            remoute_dir=$2
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

function get_cfg(){
    # 本周期的第几天（0代表星期天）
    week_day=$(date +%w)

    # 备份数据存储路径
    data_dir=${data_dir:-/home/backup}

    # 备份失败是否发送邮件(启用: true)
    mail=${mail:-false}

    # 是否将备份发送到远程服务器(启用: true)
    remoute_bak=${remoute_bak:-false}

    # 如果没有指定备份模式
    if [ -z "$mode" ]; then
        echo "[Error] 未指定备份模式."
        exit 1
    fi

    # 邮件告警(告警信息)
    if [ "$mail" == 'true' ]; then
        # 备份失败告警收件人
        mail_addr=${mail_addr:-544025211@qq.com}

        # 获取当前服务器IP
        host_if=$(/usr/sbin/ip route|grep default|cut -d' ' -f5)
        host_ip=$(/usr/sbin/ip a|grep "$host_if$"|awk '{print $2}'|cut -d'/' -f1)

        # 告警邮件标题
        mail_title="MySQL备份-$host_ip"
    fi

    # 远程备份(远程备份信息)
    if [ "$remoute_bak" == "true" ]; then
        # 远程服务器路(需要配置秘钥登录从本机到 远程的)
        remoute_server="$remoute_server"

        if [ -z "$remoute_server" ]; then
            echo "[Error] 启用了远程备份. 未指定远程服务地址."
            exit 1
        fi

        # 远程服务器路径
        remoute_dir="${remoute_dir:-/home/backupmysql}"
    fi
}

# 获取全量备份时间(仅增量备份调用)
function get_last_weekend(){
    indate=${*:-$(date +%Y%m%d)}

    # 上周的今天日期
    statday=$(date -d "$indate -1 weeks" +%Y%m%d)

    # 上周的今天是周几
    whichday=$(date -d $statday +%w)

    # 获取上周末
    if [[ $whichday == 0 ]]; then
        startday=$(date -d "$statday" +%Y%m%d)
    else
        # 上周时间 + 7(一周7天) - 周几
        startday=$(date -d "$statday + $[7 - ${whichday}] days" +%Y%m%d)
    fi

    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 本次增量备份基于上次备份 ${startday}"
}

# 全量备份
function full_backup(){
    if [ "$1" == "rebackup" ]; then
        # 周一到周六每天做 上周末的增量备份
        if [[ $mode == 1 ]]; then
            # 未检测到上周末全量备份 创建今天的全量备份到 上周末的全量备份文件夹.
            # 本次全量备份文件夹
            get_last_weekend
            full_date="full_${startday}"
        # 周一做周末增量备份 周二做周一增量备份 周三做周二增量备份 依次类推
        elif [[ $mode == 2 ]]; then
            # 未检测到上次备份(本次做完全备份)
            # 本次全量备份文件夹
            full_date="inc_$(date '+%Y%m%d')"
        fi
    else
        # 正常全量备份文件夹 full_20190929
        full_date="full_$(date '+%Y%m%d')"
    fi

    # 全量备份路径
    full_backup_dir="${data_dir}/${full_date}"

    # 全量备份日志
    full_backup_log="${full_backup_dir}/backup.log"

    # 如果存在则移动(防止第一次全量备份失败 后续无法继续备份)
    if [[ -d "${full_backup_dir}" ]]; then
        temp_dir="$(mktemp --tmpdir=${data_dir} -d ${full_date}_XXX)"
        mv ${full_backup_dir} $temp_dir
    fi

    # 创建备份目录
    mkdir -p ${full_backup_dir}

    # 全量备份
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 开始全量备份."
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 开始全量备份." > ${full_backup_log}
    innobackupex \
      --defaults-file=/etc/my.cnf \
      --user=root \
      --password='123abc@DEF' \
      --no-timestamp ${full_backup_dir} &>> ${full_backup_log}

    # 验证备份结果(失败发送邮件)
    tail -n 1 ${full_backup_log} | grep 'completed OK!' &> /dev/null
    if [[ $? -eq 0 ]];then
        touch ${full_backup_dir}/backup_ok
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 全量备份成功."
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 全量备份成功." >> ${full_backup_log}
    else
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 全量备份失败."
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 全量备份失败." >> ${full_backup_log}
        if [[ "$mail" == 'true' ]]; then
            /usr/bin/python /script/send_mail.py $mail_addr $mail_title "$(cat ${full_backup_log})"
        fi
        exit 1
    fi

    if [ "$remoute_bak" == "true" ]; then
        # 打包备份
        cd ${data_dir}
        tar -czf ${full_date}.tar.gz ${full_date}

        # 发送到远程服务器
        rsync -azp ${full_date}.tar.gz ${remoute_server}:${remoute_dir}/${full_date}.tar.gz
        rm -f ${full_date}.tar.gz
    fi
}

function incremental_backup(){
    # 增量备份路径
    inc_date="inc_$(date '+%Y%m%d')"
    inc_backup_dir="${data_dir}/${inc_date}"

    # 增量备份日志
    inc_backup_log="${inc_backup_dir}/backup.log"

    # 如果当前目录存在备份
    if [[ -f "${inc_backup_dir}/xtrabackup_logfile" ]]; then
        temp_dir="$(mktemp --tmpdir=${data_dir} -d  ${inc_date}_XXX)"
        mv ${inc_backup_dir} $temp_dir
    fi

    # 创建备份目录
    mkdir -p ${inc_backup_dir}

    # 检查上次备份是否正常
    if [[ -f "${incremental_basedir}/backup_ok" ]];then
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 上次备份状态正常."
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 上次备份状态正常." >> ${inc_backup_log}
    else
        echo "[Warning] $(date '+%Y-%m-%d %H:%M:%S') 上次备份不存在 准备进行全量备份."
        rm -rf ${inc_backup_dir}
        full_backup rebackup
        if [[ $mode == 1 ]]; then
            echo "[Warning] $(date '+%Y-%m-%d %H:%M:%S') 本次未建增量备份(上周末创建的全量备份不存在 已重新创建全量备份)"
        elif [[ $mode == 2 ]]; then
            echo "[Warning] $(date '+%Y-%m-%d %H:%M:%S') 本次创建了全量备份(上次备份失败或不存在)"
        fi
        exit 0
    fi

    # 增量备份
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 开始增量备份."
    echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 开始增量备份." >> ${inc_backup_log}
    /usr/bin/innobackupex \
      --defaults-file=/etc/my.cnf \
      --user=root \
      --password='123abc@DEF' \
      --incremental \
      --incremental-basedir=${incremental_basedir} \
      --no-timestamp ${inc_backup_dir} &>> ${inc_backup_log}

    # 验证备份结果(失败发送邮件)
    tail -n 1 ${inc_backup_log} | grep 'completed OK!' &> /dev/null
    if [[ $? -eq 0 ]];then
        touch ${inc_backup_dir}/backup_ok
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 增量备份成功."
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 增量备份成功." >> ${inc_backup_log}
    else
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 增量备份失败."
        echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 增量备份失败." >> ${inc_backup_log}
        if [[ "$mail" == 'true' ]]; then
            /usr/bin/python /script/send_mail.py $mail_addr $mail_title "$(cat ${inc_backup_log})"
        fi
        exit 1
    fi

    if [ "$remoute_bak" == 'true' ]; then
        # 打包备份
        cd ${data_dir}
        tar -czf ${inc_date}.tar.gz ${inc_date}

        # rsync
        rsync -azp ${inc_date}.tar.gz ${remoute_server}:${remoute_dir}/${inc_date}.tar.gz
        rm -f ${inc_date}.tar.gz
    fi
}

# 清理备份
function clean_backup(){
    # 本地保留 1 周
    find $data_dir -mtime +7 -type d | xargs rm -rf

    if [ "$remoute_bak" == "true" ]; then
        # 远程服务器保留 4 周
        ssh -T ${remoute_server} 'find /home/backupmysql -mtime +28 -type f | xargs rm -rf'
    fi
}

# 备份模式: 1.上周末全量备份 本周一到周六每天做上周末的增量备份
function mode_1(){
  case $week_day in
    0)
      echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 全量备份."
      full_backup
      sleep 5
      echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 清理历史备份."
      clean_backup
      ;;
    [1-6])
      echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 增量备份."

      # 获取上周末增量备份目录
      get_last_weekend

      # 每次增量备份基于 上周末全量备份
      incremental_basedir=${data_dir}/full_${startday}

      # 开始增量备份
      incremental_backup
      ;;
  esac
}

# 备份模式: 2.上周末全量备份 本周一到周六每天做上一天的增量备份
function mode_2(){
  case $week_day in
    # 如果是周末
    0)
      echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 全量备份."
      full_backup
      sleep 3
      echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 清理历史备份."
      clean_backup
      ;;
    # 如果是周一
    1)
      echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 增量备份."

      # 获取上周末增量备份目录
      get_last_weekend

      # 本次增量备份基于 上周末全量备份
      incremental_basedir=${data_dir}/full_${startday}

      # 开始增量备份
      incremental_backup
      ;;
    # 如果是周二,三,四,五,六
    [2-6])
      echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 增量备份."

      # 本次增量备份基于 上次增量备份目录
      echo "[INFO] $(date '+%Y-%m-%d %H:%M:%S') 本次增量备份基于上次备份 inc_$(date -d "-1 day" '+%Y%m%d')."
      incremental_basedir=${data_dir}/inc_$(date -d "-1 day" '+%Y%m%d')

      # 开始增量备份
      incremental_backup
      ;;
  esac
}

if [[ "$mode" == '1' ]]; then
    get_cfg
    mode_1
elif [[ "$mode" == '2' ]]; then
    get_cfg
    mode_2
fi
