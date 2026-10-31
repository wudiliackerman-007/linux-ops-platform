# 03 On-call 手册

> 告警响了先别慌，照这个顺序做：**确认影响面 → 止血 → 定位根因 → 复盘**。
> 这份手册的目标是让你在凌晨三点也能按步骤走，而不是靠"感觉"。

## 0. 一分钟判断法

```bash
curl -s http://127.0.0.1:9090/api/v1/alerts | jq '.data.alerts[] | {name:.labels.alertname, sev:.labels.severity, since:.activeAt, state:.state}'
curl -s http://127.0.0.1:9093/api/v2/alerts | jq '.[] | .labels.alertname' | sort | uniq -c
sudo /opt/ops-platform/bin/healthcheck.sh          # 20+ 项一把梭，先看哪块红
```

三个问题依次回答：

1. **用户还能用吗？** —— `curl -sk https://<IP>/health/ready`、真实建一条短链跳一下
2. **影响面多大？** —— 全站 5xx？只有写接口？只有某台机器？（看 Nginx 日志和 Grafana 错误率）
3. **最近改了什么？** —— `sudo ./scripts/rollback.sh --list`、`git log --oneline -5`、`last`、`journalctl --since '30 min ago'`

> 线上事故 80% 由变更引起。"最近改了什么"永远是最值钱的一问。

### 没有告警时，值班第一件事：看日报

```bash
sudo cat /var/log/ops-platform/report/latest.txt
```

日报每天 08:00 自动生成（`ops-report.timer`），一页里包含：服务状态、抓取目标在线数、
活跃告警、近 24 小时请求数/5xx/P95/缓存命中率/可用性、最近一次巡检与备份、证书剩余天数。
交接班只需要贴这一份，不用口头描述"大概还行"。

如果日报本身停了（`ReportStale` 告警），说明**定时任务这一层坏了**，优先级要当故障处理：
`systemctl status ops-report.timer`、`journalctl -u ops-report -n 50`。

## 1. 严重级别与响应

| 级别 | 含义 | 响应时限 | 动作 |
|------|------|---------|------|
| critical | 用户已经受影响（全站挂、数据库挂） | 5 分钟内动手 | 先止血（回滚/重启/切流），再查原因 |
| warning | 快出问题了（磁盘 85%、延迟升高） | 当天处理 | 排计划修，别拖到 critical |
| info | 需要知道（配置重载失败） | 本周 | 顺手修掉 |

止血优先于定位：**先让用户可用，再写复盘**。回滚不是认输，是最快的止血手段。

## 2. 按告警的处置手册

### HostDown / TargetDown
```bash
ping -c3 <IP>; ssh <IP> 'uptime'
sudo systemctl status node_exporter
sudo journalctl -u node_exporter -n 50
sudo ss -lntp | grep 9100
```
- exporter 挂了：`systemctl restart node_exporter`
- 机器挂了：VMware 里看虚拟机状态；NAT 下先确认宿主机网络
- 抓取配置改了没重载：`curl -X POST http://127.0.0.1:9090/-/reload`

### HostHighCPU（>85% 持续 5m）
```bash
top -o %CPU          # 谁在吃
mpstat -P ALL 1 3    # 单核打满还是整体
pidstat -u 1 3       # 进程级
ps -eo pid,ppid,pcpu,pmem,etime,cmd --sort=-pcpu | head
```
- 本项目的演练脚本会打满：`pgrep -a chaos`、`pgrep -af cpu_spike`
- 真实场景：先看是不是流量涨了（Grafana QPS），再决定扩容还是限流（`limit_req` 已生效）

### HostHighMemory（>85%）/ HostOOMKill
```bash
free -h; ps -eo pid,rss,pmem,cmd --sort=-rss | head
sudo dmesg -T | grep -i -E 'oom|killed process' | tail
sudo journalctl -k --since '1 hour ago' | grep -i oom
```
- 有 OOM 记录 → 找出被杀进程，看是内存泄漏（RSS 单调涨）还是配置太大（`innodb_buffer_pool_size`）
- 应急：`systemctl restart <服务>` 释放；把 `vm.swappiness` 调低治标不治本

### HostDiskUsageHigh（>80%）/ HostDiskWillFull
```bash
df -hT; df -i
sudo du -xh --max-depth=1 / 2>/dev/null | sort -h | tail
sudo du -xh --max-depth=1 /var 2>/dev/null | sort -h | tail
sudo journalctl --disk-usage
sudo find /var/log -type f -name '*.log' -size +100M -exec ls -lh {} \;
```
- 常见大户：`/var/log`（journald 没限制）、MySQL binlog、Prometheus TSDB、`/data/backup`
- 应急：`journalctl --vacuum-size=200M`、删过期备份（**先确认最新备份可恢复**）、
  `find /data/backup -name '*.sql.gz' -mtime +7 -delete`
- 演练脚本留下的垃圾：`sudo ops/chaos/02_disk_fill.sh --clean`

### AppDown / AppHighErrorRate / 502
```bash
sudo systemctl status opslink
sudo journalctl -u opslink -n 100 --no-pager
sudo ss -lntp | grep 8000
curl -s http://127.0.0.1:8000/health/ready; echo
sudo tail -100 /var/log/nginx/opslink_access.log | jq -r 'select(.status>=500) | "\(.status) \(.request) \(.upstream_time)"' 2>/dev/null
```
- 进程不在：`systemctl restart opslink`，看日志里的异常栈
- 起来又挂：`Restart` 次数 `systemctl show opslink -p NRestarts` 猛涨 → 代码/依赖问题，回滚
- 502 且应用正常：Nginx upstream 配置、`proxy_read_timeout`、keepalive 与后端不一致

### MySQLDown / MySQLHighConnections / MySQLSlowQueries
```bash
sudo systemctl status mysql
sudo tail -50 /var/log/mysql/error.log
mysql --defaults-file=/root/.my.cnf -e "SHOW PROCESSLIST; SHOW STATUS LIKE 'Threads_connected';"
mysql --defaults-file=/root/.my.cnf -e "SHOW VARIABLES LIKE 'max_connections';"
sudo tail -20 /var/log/mysql/slow.log          # 或 mysqldumpslow
```
- 连接打满：应用连接池泄漏 / 慢查询占连接 → 杀长事务 `KILL <id>`，加索引
- 磁盘满导致 MySQL 只读：先清空间再 `systemctl restart mysql`
- 启动失败看 error.log 最后 20 行，90% 是权限（`/var/lib/mysql` 属主）或磁盘满

### AppCacheDegraded（Redis 不可用）
```bash
redis-cli -a "$REDIS_PASSWORD" --no-auth-warning ping
sudo systemctl status redis-server
sudo tail -50 /var/log/redis/redis-server.log
```
- 业务此时**仍可用**（降级走 MySQL），但要盯 MySQL 连接数和 QPS —— 缓存没了压力全到数据库
- 恢复后确认 `opslink_dependency_up{dependency="redis"}` 回到 1，缓存命中率回升

### AppHighLatencyP95（>0.5s）
```bash
curl -o /dev/null -s -w 'dns=%{time_namelookup} conn=%{time_connect} ttfb=%{time_starttransfer} total=%{time_total}\n' https://<IP>/health/live
# 分段定位：Nginx → 应用 → MySQL/Redis
sudo tail -100 /var/log/nginx/opslink_access.log | jq -r '.upstream_time' | sort -n | tail
mysql --defaults-file=/root/.my.cnf -e "SHOW FULL PROCESSLIST;"
redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --latency
tc qdisc show dev ens33        # 是不是演练残留的 netem
```
- `tc qdisc` 有 `netem delay` → `sudo tc qdisc del dev <网卡> root`

### NginxRateLimited（429 多）
- 正常：真被打（看 IP 分布 `awk` 统计访问日志）
- 异常：阈值太低或前端重试风暴 → 调 `limit_req` 或加白名单

### BackupStale / BackupSizeAnomaly
```bash
ls -lh /data/backup/mysql | tail -5
sudo journalctl -u ops-backup -n 50 --no-pager
sudo /opt/ops-platform/bin/backup_mysql.sh    # 手动跑，看报错
```
- 定时器没装/没 enable：`systemctl list-timers 'ops-*'`
- 备份文件 < 1 KB：dump 失败但脚本没接住 → 看日志里的 mysqldump 报错（权限、磁盘满）

## 3. 命令速查（背下来常用）

```bash
# 服务
systemctl status|start|stop|restart|enable <svc>; journalctl -u <svc> -f --since '10 min ago'
systemctl list-units --failed; systemctl daemon-reload
# 进程/端口/资源
ps aux --sort=-%cpu | head; ss -lntp; lsof -i:8000; top -H -p <pid>
free -h; df -h; iostat -x 1 3; vmstat 1 5; pidstat -dru 1 3
# 网络
ip a; ip r; ping; traceroute; curl -v; tcpdump -i any port 8000 -nn
ss -s; netstat -anp | awk '{print $6}' | sort | uniq -c
# 日志
tail -f /var/log/nginx/opslink_access.log | jq .
awk '{print $1}' 等价 → jq -r '.remote_addr' | sort | uniq -c | sort -rn | head
# 发布
sudo ./scripts/release.sh; sudo ./scripts/rollback.sh --list
```

## 4. 事故记录模板

```markdown
## 事故：<一句话标题>
- 时间：2025-01-01 20:15 发现 / 20:41 恢复
- 影响：<多少用户/接口/时长>
- 级别：critical / warning
- 时间线：
  - 20:15 收到 MySQLDown
  - 20:18 确认 /health/ready 503，短链跳转正常（缓存兜住）
  - 20:22 定位到 /var/lib/mysql 所在分区 100%
  - 20:30 清理 30 天前备份释放 4 GB，重启 MySQL
  - 20:41 指标回落，告警 resolved
- 根因：备份目录与数据同分区，未设保留策略
- 改进：备份迁到独立盘 + 保留策略 + 磁盘水位告警降到 75%
```

## 5. 值班心态

- **不要在没有备份的情况下删数据**。删除前先 `ls` 确认路径，再考虑 `mv` 到 `/tmp` 观察
- 改动前先记下当前状态（`git rev-parse HEAD`、`ip a`、`df -h` 存到笔记里）
- 一次只改一个变量。同时改三处，好了也不知道是哪好的
- 搞不定就回滚 + 上报。**卡住 30 分钟必须升级**，这不是能力问题，是流程
