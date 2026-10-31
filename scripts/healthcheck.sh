#!/usr/bin/env bash
# =============================================================================
# 全链路健康巡检（每 5 分钟由 systemd timer 触发，也可手动跑）
#
# 和 Prometheus 告警的分工：
#   Prometheus 看"趋势"，这个脚本看"现在到底能不能用"（黑盒探测）
#   两个都失败，才叫真的坏了
#
# 用法：sudo /opt/ops-platform/bin/healthcheck.sh [-q]
# 退出码：0 全部正常 / 1 有异常
# =============================================================================
set -uo pipefail

QUIET=0
[[ "${1:-}" == "-q" ]] && QUIET=1

TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
FAILED=0
CHECKS=0

pass() { CHECKS=$((CHECKS + 1)); [[ "${QUIET}" == "1" ]] || printf '  \033[32m[PASS]\033[0m %s\n' "$*"; }
fail() { CHECKS=$((CHECKS + 1)); FAILED=$((FAILED + 1)); printf '  \033[31m[FAIL]\033[0m %s\n' "$*"; }
warn() { CHECKS=$((CHECKS + 1)); printf '  \033[33m[WARN]\033[0m %s\n' "$*"; }

http_ok() { # http_ok <名称> <url> [期望码]
  local name="$1" url="$2" expect="${3:-200}" code
  # -k：本机自签证书；curl 连接失败时自己也会返回 000，所以这里不能再 echo 000
  code="$(curl -sk -o /dev/null -w '%{http_code}' --max-time 5 "${url}" 2>/dev/null)" || true
  code="${code:-000}"
  if [[ "${code}" == "${expect}" ]]; then pass "${name} (${code})"; else fail "${name} 返回 ${code}，期望 ${expect}"; fi
}

[[ "${QUIET}" == "1" ]] || echo "===== 运维巡检 $(date '+%F %T') ====="

# ---------- 1. 依赖服务 ----------
[[ "${QUIET}" == "1" ]] || echo "-- 依赖服务"
mysqladmin --defaults-file=/root/.my.cnf ping --silent >/dev/null 2>&1 \
  && pass "MySQL 可连接" || fail "MySQL 连不上"

REDIS_PW="$(grep -E '^REDIS_PASSWORD=' /etc/ops-platform/platform.env 2>/dev/null | cut -d= -f2- || true)"
if redis-cli -a "${REDIS_PW}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
  pass "Redis PONG"
else
  fail "Redis 不可用（应用会降级直连 MySQL）"
fi

systemctl is-active --quiet nginx && pass "nginx 运行中" || fail "nginx 未运行"
systemctl is-active --quiet opslink && pass "opslink 运行中" || fail "opslink 未运行"

# ---------- 2. 应用可用性（走真实链路：HTTPS -> nginx -> app -> db/redis）----------
[[ "${QUIET}" == "1" ]] || echo "-- 应用链路"
http_ok "应用存活探针" "http://127.0.0.1:8000/health/live" 200
http_ok "应用就绪探针(含MySQL)" "http://127.0.0.1:8000/health/ready" 200
http_ok "Nginx HTTPS 反代" "https://127.0.0.1/health/live" 200

# 端到端：创建短链再访问，验证"写 -> 读 -> 跳转"整条链
CODE="$(curl -sk -X POST https://127.0.0.1/api/shorten \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://mirrors.tuna.tsinghua.edu.cn/ubuntu/"}' 2>/dev/null \
  | python3 -c 'import sys,json;print(json.load(sys.stdin).get("code",""))' 2>/dev/null || true)"
if [[ -n "${CODE}" ]]; then
  LOC="$(curl -sk -o /dev/null -w '%{redirect_url}' --max-time 5 "https://127.0.0.1/${CODE}")"
  [[ "${LOC}" == "https://mirrors.tuna.tsinghua.edu.cn/ubuntu/" ]] \
    && pass "端到端短链跳转正常（${CODE}）" || fail "短链跳转异常：${LOC}"
else
  fail "创建短链失败（应用/数据库问题）"
fi

# ---------- 3. 监控组件 ----------
[[ "${QUIET}" == "1" ]] || echo "-- 监控组件"
http_ok "Prometheus" "http://127.0.0.1:9090/-/ready" 200
http_ok "Alertmanager" "http://127.0.0.1:9093/-/ready" 200
http_ok "Grafana" "http://127.0.0.1:3000/api/health" 200
http_ok "node_exporter" "http://127.0.0.1:9100/metrics" 200
http_ok "mysqld_exporter" "http://127.0.0.1:9104/metrics" 200
http_ok "nginx_exporter" "http://127.0.0.1:9113/metrics" 200
http_ok "告警接收器" "http://127.0.0.1:5001/healthz" 200

# ---------- 4. 容量与证书 ----------
[[ "${QUIET}" == "1" ]] || echo "-- 容量与证书"
DISK_PCT="$(df -P / | awk 'NR==2{gsub("%","",$5); print $5}')"
if [[ "${DISK_PCT}" -lt 85 ]]; then pass "根分区使用率 ${DISK_PCT}%"; else fail "根分区使用率 ${DISK_PCT}%（>85%）"; fi

DATA_PCT="$(df -P /data 2>/dev/null | awk 'NR==2{gsub("%",""); print $5}')"
if [[ -n "${DATA_PCT}" ]]; then
  if [[ "${DATA_PCT}" -lt 85 ]]; then pass "/data 使用率 ${DATA_PCT}%"; else fail "/data 使用率 ${DATA_PCT}%（>85%）"; fi
fi

MEM_AVAIL="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)"
if [[ "${MEM_AVAIL}" -gt 200 ]]; then pass "可用内存 ${MEM_AVAIL}MB"; else fail "可用内存仅 ${MEM_AVAIL}MB"; fi

if [[ -f /etc/ssl/opslink/opslink.crt ]]; then
  DAYS="$(openssl x509 -enddate -noout -in /etc/ssl/opslink/opslink.crt \
    | cut -d= -f2 | xargs -I{} date -d {} +%s | awk -v now="$(date +%s)" '{print int(($1-now)/86400)}')"
  if [[ "${DAYS}" -gt 15 ]]; then pass "TLS 证书剩余 ${DAYS} 天"; else fail "TLS 证书剩余 ${DAYS} 天（尽快续期）"; fi
fi

LATEST_BAK="$(find /data/backup/mysql -maxdepth 1 -name '*.sql.gz' -printf '%T@\n' 2>/dev/null | sort -nr | head -1)"
BAK_AGE_H=""
if [[ -n "${LATEST_BAK}" ]]; then
  BAK_AGE_H="$(awk -v now="$(date +%s)" -v t="${LATEST_BAK}" 'BEGIN{printf "%d", (now - t) / 3600}')"
fi
if [[ -n "${BAK_AGE_H}" && "${BAK_AGE_H}" -lt 26 ]]; then
  pass "最近备份距今 ${BAK_AGE_H} 小时"
else
  fail "最近备份距今 ${BAK_AGE_H:-无} 小时（>26h 或没有备份）"
fi

# ---------- 汇总 & 写指标 ----------
[[ "${QUIET}" == "1" ]] || echo
if [[ "${FAILED}" -eq 0 ]]; then
  [[ "${QUIET}" == "1" ]] || printf '\033[32m全部通过：%d 项检查\033[0m\n' "${CHECKS}"
else
  printf '\033[31m%d/%d 项检查失败\033[0m\n' "${FAILED}" "${CHECKS}"
fi

mkdir -p "${TEXTFILE_DIR}"
TMP="$(mktemp "${TEXTFILE_DIR}/.health.XXXXXX")"
cat >"${TMP}" <<EOF
# HELP ops_healthcheck_last_run_timestamp_seconds 巡检执行时间
# TYPE ops_healthcheck_last_run_timestamp_seconds gauge
ops_healthcheck_last_run_timestamp_seconds $(date +%s)
# HELP ops_healthcheck_ok 巡检是否全部通过 1=通过 0=有失败
# TYPE ops_healthcheck_ok gauge
ops_healthcheck_ok $([[ "${FAILED}" -eq 0 ]] && echo 1 || echo 0)
# HELP ops_healthcheck_failed_total 本次失败检查项数量
# TYPE ops_healthcheck_failed_total gauge
ops_healthcheck_failed_total ${FAILED}
EOF
mv "${TMP}" "${TEXTFILE_DIR}/ops_healthcheck.prom"
chmod 644 "${TEXTFILE_DIR}/ops_healthcheck.prom"

[[ "${FAILED}" -eq 0 ]] && exit 0 || exit 1
