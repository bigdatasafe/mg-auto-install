#### MySQL

> mysql-5.7 安装(yum方式)

````shell
curl -sSL http://kaifa.hc-yun.com:30050/mango/mango-auto-install/raw/master/backup/install-mysql.sh -o install-mysql.sh
chmod +x install-mysql.sh
./install-mysql.sh --get-version         # 查看存储库中的软件版本

# example
./install-mysql.sh --active install --data-dir /home/hadoop/mysql --version 5.7.23 --root-pass 123abc@DEF

  --help       # 查看帮助信息
  --data-dir   # mysql 数据存储目录默认为 /home/hadoop/mysql
  --version    # 指定安装版本
  --root-pass  # root 密码
  --bin-log    # 是否启用二进制日志(二进制日志只保留7天) 默认不启用
````

> 使用 xtrabackup 备份 MySQL

 - 安装 percona-xtrabackup

````shell
wget https://www.percona.com/downloads/Percona-XtraBackup-2.4/Percona-XtraBackup-2.4.15/binary/redhat/7/x86_64/percona-xtrabackup-24-2.4.15-1.el7.x86_64.rpm
yum localinstall percona-xtrabackup-24-2.4.15-1.el7.x86_64.rpm
````

 - 下载备份脚本

````shell
curl -sSL http://kaifa.hc-yun.com:30050/mango/mango-auto-install/raw/master/backup/innobackup.sh -o innobackup.sh    # 备份脚本
curl -sSL http://kaifa.hc-yun.com:30050/mango/mango-auto-install/raw/master/backup/send_mail.py -o send_mail.py      # 邮件告警
chmod +x innobackup.sh send_mail.py

````

 - 备份脚本使用说明
 

````shell

 ./innobackup.sh --mode 1                       # 默认备份到本地 /home/backup
    --help                                      # 查看帮助信息
    --mode  {1|2}                               # 指定备份模式(周日做全量备份, 周一到周六每天做上周日的增量备份/每天做上一天的增量备份)
    --data-dir /home/backup                     # 指定本地备份路径 /home/backup
    --mail true --mail-addr example@domain.com  # 启用邮件告警(备份失败发送邮件通知[可在备份时关闭mysql服务测试])
    --remoute-bak true --remoute-server root@192.168.0.71 --remoute-dir /home/backupmysql  # 启用远程备份指定 服务器(需要免密码 密钥登陆) 指定路径(需要登陆远程服务器创建)

````

 - 测试邮件发送


````shell
# 替换 example@qq.com 为你的邮箱
./send_mail.py example@qq.com 'title标题' '测试邮件正文'
````

 - 加入定时任务

````shell
mkdir /script
mv innobackup.sh send_mail.py  /script
chmod +x /script/send_mail.py /script/innobackup.sh
crontab -l > /tmp/crontab.tmp
echo "10 1 * * * /script/innobackup.sh --mode 1 --remoute-bak true --remoute-server root@192.168.0.71 --remoute-dir /home/backupmysql" >> /tmp/crontab.tmp
cat /tmp/crontab.tmp | uniq > /tmp/crontab
crontab /tmp/crontab
rm -f /tmp/crontab.tmp /tmp/crontab
````

 - 注意事项
 
````shell
1. 修改 innobackup.sh 187,255 行 参数--password=的值为 mysql root用户密码
2. 启用远程备份需要配置从本机到远程服务器的免密码登陆(密钥登陆)
3. 本地备份默认只保留 7 天 远程服务器默认保留 28 天 (不小于这个时间)
4. 启用邮件告警请先执行 [测试邮件发送] 确认成功
5. 配置完成后手动执行一次确定备份正常再配置定时任务
6. 查看历史定时任务备份输出信息 cat /var/spool/mail/root (执行过定时备份任务且启用邮件告警才有)
````

