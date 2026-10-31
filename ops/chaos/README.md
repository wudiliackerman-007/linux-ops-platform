# 故障演练手册（Chaos Drills）

> 目标不是"搞坏机器"，而是**把线上会发生的故障，在你能控制的时间里提前演一遍**。
> 每一次演练都要能回答三个问题：告警响了吗？我是怎么定位的？多久恢复的？

## 演练前检查

```bash
# 1. 确认监控是活的（targets 全 UP、有数据）
curl -s http://127.0.0.1:9090/api/v1/targets?state=active | grep -o '"health":"[a-z]*"' | sort | uniq -c

# 2. 确认告警能送达（手动打一条测试告警）
curl -s -X POST http://127.0.0.1:5001/webhook \
  -H 'Content-Type: application/json' \
  -d '{"status":"firing","alerts":[{"status":"firing","labels":{"alertname":"DrillTest","severity":"warning","instance":"127.0.0.1:9100"},"annotations":{"summary":"这是一条演练测试告警"}}]}'

# 3. 全程开两个窗口
journalctl -u alarm-receiver -f
#   另一个窗口看：http://<IP>:9090/alerts
```

## 六个演练

| 脚本 | 用法 | 模拟的故障 | 预期告警（触发时间） | 恢复方式 |
|------|------|-----------|---------------------|---------|
| `01_cpu_spike.sh` | `[核数] [秒]` | CPU 打满 | `HostHighCPU` warning（5min） | 脚本到点自动结束 |
| `02_disk_fill.sh` | `85` / `--clean` | 磁盘写满 | `HostDiskUsageHigh` warning（10min） | `--clean` 或到点自动清 |
| `03_mysql_down.sh` | `120` | MySQL 宕机 | `MySQLDown` critical（1min） | 脚本退出时自动 start |
| `04_app_down.sh` | `crash` | 进程被杀 | 通常不告警（systemd 3s 内拉起） | 自动 |
| `04_app_down.sh` | `stop 90` | 应用下线 | `AppDown` critical（1min）+ Nginx 502 | 脚本退出时自动 start |
| `05_redis_down.sh` | `300` | 缓存宕机 | `AppCacheDegraded` warning（10min） | 脚本退出时自动 start |
| `06_network_delay.sh` | `300 180` | 网络延迟（tc netem） | `AppHighLatencyP95` warning（5min） | 脚本退出自动删 tc 规则 |

> 时间说明：告警规则里的 `for: 5m` 表示**持续**满足条件 5 分钟才发。
> 这是故意的 —— 抖一下就告警的监控，运维会直接关掉它。

## 每次演练要记录的东西（写进 `docs/04-故障演练记录.md`）

```markdown
### 演练 03：MySQL 宕机
- 时间：2025-01-01 20:15 - 20:19
- 操作：systemctl stop mysql（120s）
- 告警：MySQLDown 于 20:16:05 触发（critical），20:18:40 resolved
- 业务影响：/health/ready 返回 503，短链跳转 302 正常（读走 Redis 缓存）
- 定位过程：curl 探针 → systemctl status mysql → tail /var/log/mysql/error.log
- 恢复耗时：约 40 秒（systemctl start mysql + 连接池重连）
- 结论：应用对 DB 故障"半可用"；建议给 /health/ready 加 Redis 检查项
```

## 演练节奏建议（1 周内做完）

- 第 1 天：01 CPU + 04 crash —— 熟悉"正常告警"和"自动恢复"
- 第 2 天：03 MySQL —— 练最经典的数据库事故
- 第 3 天：07 网络延迟 —— 练 P95 告警和 tc/traceroute
- 第 4 天：05 应用下线 + 06 Redis —— 练降级和 502 排查
- 第 5 天：02 磁盘 —— 练容量问题，顺便写一条清理脚本

## 这段怎么讲

> "我做了一套带故障演练的环境。比如 MySQL 宕机那一次，我先确认告警在 1 分钟内到，
> 然后看应用返回的是 503 而不是 500 —— 说明我们的错误处理是对的；
> 再看 Redis 缓存顶着读流量，短链跳转没受影响，这就是降级设计的意义。
> 恢复后我在 Grafana 上确认指标回落，并把这个过程写进了演练记录。"

关键点：**不要只说"我练过故障"，要说清告警时间、业务影响面、恢复耗时和后续改进**。
