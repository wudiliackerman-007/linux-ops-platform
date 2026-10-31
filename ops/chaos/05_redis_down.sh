#!/usr/bin/env bash
# =============================================================================
# 故障演练 05：Redis 宕机（降级演练）
# 目的：证明"缓存挂了业务还能用"，以及 AppCacheDegraded 告警、命中率掉零
#
# 这类故障最容易被忽略：接口 200，但 MySQL QPS 翻倍，晚高峰会雪崩。
#
# 用法：sudo ops/chaos/05_redis_down.sh [秒数]
# =============================================================================
set -euo pipefail

DURATION="${1:-300}"
[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0 [秒数]"; exit 1; }
REDIS_PW="$(grep -E '^REDIS_PASSWORD=' /etc/ops-platform/platform.env | cut -d= -f2-)"

cat <<EOF
[演练] 故障：停止 Redis ${DURATION}s
[演练] 预期现象：
        - 接口仍然 200/302（应用自动降级直连 MySQL，这是设计目标）
        - opslink_dependency_up{dependency="redis"} = 0
        - 缓存命中率掉到 0，MySQL 连接数上升
[演练] 预期告警：AppCacheDegraded（warning，持续 10 分钟才报，避免抖动误报）
[演练] 观察方式：
        curl -sk -o /dev/null -w '%{http_code}\\n' https://127.0.0.1/$(openssl rand -hex 3)
        mysql -e 'SHOW STATUS LIKE "Threads_connected";'
        Grafana -> 依赖可用性 / 缓存命中率 两个面板
EOF

restore() {
  local rc=$?
  echo
  echo "[演练] 恢复 Redis..."
  systemctl start redis-server
  for _ in $(seq 1 30); do
    redis-cli -a "${REDIS_PW}" --no-auth-warning ping 2>/dev/null | grep -q PONG && break
    sleep 1
  done
  if redis-cli -a "${REDIS_PW}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
    echo "[演练] Redis 已恢复。应用会自动重连（连接失败时降级，恢复后自动回归）"
  else
    echo "[演练] ERROR Redis 未恢复，检查 journalctl -u redis-server -n 50"
  fi
  exit "${rc}"
}
trap restore EXIT INT TERM

systemctl stop redis-server
echo "[演练] Redis 已停止：$(date '+%F %T')"

# 连续打 20 次，全部应该成功（这就是降级的意义）
FAIL=0
for i in $(seq 1 20); do
  CODE="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "https://127.0.0.1/$(openssl rand -hex 3)")"
  [[ "${CODE}" == "302" || "${CODE}" == "404" ]] || { FAIL=$((FAIL + 1)); echo "  异常状态码：${CODE}"; }
done
echo "[演练] 20 次请求完成，异常 ${FAIL} 次（0 次说明降级生效）"

echo "[演练] 等待 ${DURATION}s..."
sleep "${DURATION}"
