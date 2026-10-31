#!/usr/bin/env bash
# =============================================================================
# 故障演练 03：MySQL 宕机
# 目的：验证 MySQLDown（critical）、应用是否优雅返回 503、以及恢复流程
# 这是最经典的事故：数据库挂了，业务还在不在？会返回 500 还是 503？
#
# 用法：sudo ops/chaos/03_mysql_down.sh [宕机秒数]
# =============================================================================
set -euo pipefail

DURATION="${1:-120}"
[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0"; exit 1; }

cat <<EOF
[演练] 故障：停止 MySQL ${DURATION}s
[演练] 预期告警：MySQLDown（critical，1 分钟）
[演练] 观察方式：
        systemctl status mysql
        journalctl -u opslink -f                    # 应用日志里应有连接失败
        curl -sk -o /dev/null -w '%{http_code}\\n' https://127.0.0.1/api/stats/abc
        # 期望返回 503（服务不可用），而不是 500（代码 bug）
        http://<IP>:9090/alerts
[演练] 开始：$(date '+%F %T')
EOF

START_TS="$(date +%s)"
restore() {
  local rc=$?
  echo
  echo "[演练] 恢复 MySQL..."
  systemctl start mysql
  for _ in $(seq 1 60); do
    mysqladmin --defaults-file=/root/.my.cnf ping --silent >/dev/null 2>&1 && break
    sleep 1
  done
  if mysqladmin --defaults-file=/root/.my.cnf ping --silent >/dev/null 2>&1; then
    echo "[演练] MySQL 已恢复，耗时 $(($(date +%s) - START_TS))s"
    # 应用有连接池，DB 恢复后要确认真能连上
    curl -fsS --max-time 5 http://127.0.0.1:8000/health/ready >/dev/null 2>&1 \
      && echo "[演练] 应用就绪探针已恢复 200" \
      || echo "[演练] WARN 应用就绪探针仍异常，查看 journalctl -u opslink -n 50"
  else
    echo "[演练] ERROR MySQL 未能恢复，请手动检查 /var/log/mysql/error.log"
  fi
  echo "[演练] 结束：$(date '+%F %T')"
  exit "${rc}"
}
trap restore EXIT INT TERM

systemctl stop mysql
echo "[演练] MySQL 已停止：$(date '+%F %T')"
echo "[演练] 现在立刻发一个请求，看应用怎么响应："
curl -sk -o /dev/null -w '  /health/ready -> %{http_code}（期望 503）\n' https://127.0.0.1/health/ready || true
curl -sk -o /dev/null -w '  /{code}      -> %{http_code}（期望 503，不是 500）\n' https://127.0.0.1/abc || true
curl -sk -o /dev/null -w '  /api/shorten -> %{http_code}（期望 503）\n' -X POST https://127.0.0.1/api/shorten \
  -H 'Content-Type: application/json' -d '{"url":"https://example.com/chaos"}' || true

echo "[演练] 等待 ${DURATION}s..."
sleep "${DURATION}"
