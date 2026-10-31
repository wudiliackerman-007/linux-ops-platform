#!/usr/bin/env bash
# =============================================================================
# 每日巡检日报：把"散在各处"的状态拼成一张纸，早上 8 点自动推到运维手上
#
# 为什么要有它（面试可以这么讲）：
#   * 监控是"出事了喊你"，日报是"没事也要看一眼趋势"，两者不能互相替代
#   * 巡检脚本每 5 分钟跑一次，只回答"现在对不对"；日报回答"昨天一天怎么样"
#   * 日报里的数字全部来自 Prometheus / textfile / 文件系统，不靠人回忆
#
# 输出：
#   /var/log/ops-platform/report/daily-YYYY-MM-DD.txt   当天日报（覆盖写）
#   /var/log/ops-platform/report/latest.txt             最新一份的软链
#   textfile 指标 ops_report_last_success_timestamp_seconds（供 BackupStale 类似的死信告警用）
#
# 用法：
#   sudo ./scripts/daily_report.sh          # 写文件
#   sudo ./scripts/daily_report.sh --stdout # 直接打印，不写文件
# =============================================================================
set -uo pipefail

REPORT_DIR="${REPORT_DIR:-/var/log/ops-platform/report}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
PROM="http://127.0.0.1:9090"
AM="http://127.0.0.1:9093"
DATA_DIR="${DATA_DIR:-/data}"
BACKUP_DIR="${DATA_DIR}/backup/mysql"
CERT="/etc/ssl/opslink/opslink.crt"
TO_STDOUT=0
[[ "${1:-}" == "--stdout" ]] && TO_STDOUT=1

TODAY="$(date +%F)"
OUT="${REPORT_DIR}/daily-${TODAY}.txt"

# --- 小工具 -----------------------------------------------------------------
# Prometheus 即时查询，取第一个样本值；查不到统一返回 n/a，避免日报里出现空行
pq() {
  local expr="$1" raw
  raw="$(curl -s --max-time 10 --get "${PROM}/api/v1/query" --data-urlencode "query=${expr}" 2>/dev/null)" || { echo "n/a"; return; }
  printf '%s' "${raw}" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)["data"]["result"]
    print(d[0]["value"][1] if d else "n/a")
except Exception:
    print("n/a")
' 2>/dev/null || echo "n/a"
}

# 把数字格式化成两位小数，n/a 原样保留
num() { awk -v v="$1" 'BEGIN{ if (v=="n/a" || v=="") print "n/a"; else printf "%.2f", v }'; }

# 百分比：分母为 0 时返回 n/a，避免 nan
pct() { awk -v a="$1" -v b="$2" 'BEGIN{ if (a=="n/a"||b=="n/a"||b+0==0) print "n/a"; else printf "%.2f%%", a*100/b }'; }

section() { printf '\n== %s ==\n' "$*"; }

# --- 采集 -------------------------------------------------------------------
HOST="$(hostname)"
UPTIME_S="$(awk '{print int($1)}' /proc/uptime)"
UPTIME_H="$(awk -v s="${UPTIME_S}" 'BEGIN{printf "%.1f", s/3600}')"
LOAD="$(awk '{print $1", "$2", "$3}' /proc/loadavg)"
MEM_TOTAL_MB="$(awk '/MemTotal/{printf "%d", $2/1024}' /proc/meminfo)"
MEM_AVAIL_MB="$(awk '/MemAvailable/{printf "%d", $2/1024}' /proc/meminfo)"
MEM_USED_PCT="$(awk -v t="${MEM_TOTAL_MB}" -v a="${MEM_AVAIL_MB}" 'BEGIN{ if(t>0) printf "%.1f", (t-a)*100/t; else print "n/a" }')"
DISK_ROOT="$(df -P / | awk 'NR==2{print $5"（剩余 "$4" KB）"}')"
DISK_DATA="$(df -P "${DATA_DIR}" | awk 'NR==2{print $5"（剩余 "$4" KB）"}')"

# 服务状态
SERVICES=(opslink nginx mysql redis-server prometheus alertmanager grafana-server alarm-receiver)
SVC_FAILED=0
SVC_LINES=""
for s in "${SERVICES[@]}"; do
  st="$(systemctl is-active "${s}" 2>/dev/null || true)"
  en="$(systemctl is-enabled "${s}" 2>/dev/null || true)"
  [[ "${st}" == "active" ]] || SVC_FAILED=$((SVC_FAILED + 1))
  SVC_LINES+="$(printf '  %-18s %-10s %s\n' "${s}" "${st:-unknown}" "${en:-unknown}")"$'\n'
done

# 抓取目标
T_UP="$(pq 'count(up == 1)')"
T_ALL="$(pq 'count(up)')"

# 告警
FIRING_N="$(curl -s --max-time 10 "${AM}/api/v2/alerts?active=true&silenced=false&inhibited=false" 2>/dev/null \
  | python3 -c 'import sys,json
try:
    print(len(json.load(sys.stdin)))
except Exception:
    print("n/a")' 2>/dev/null || echo "n/a")"
FIRING_LIST="$(curl -s --max-time 10 "${AM}/api/v2/alerts?active=true&silenced=false&inhibited=false" 2>/dev/null \
  | python3 -c 'import sys,json
try:
    for a in json.load(sys.stdin):
        name=a.get("labels",{}).get("alertname","?")
        sev=a.get("labels",{}).get("severity","?")
        print("  - %-28s [%s]" % (name, sev))
except Exception:
    print("  （读取告警失败）")' 2>/dev/null || echo "  （读取告警失败）")"
[[ -z "${FIRING_LIST}" ]] && FIRING_LIST="  （无）"

# 应用：24 小时
# 注意：计数器 increase() 在"这段时间根本没出现过该标签"时返回空，不是 0；
# 日报里必须显示 0（"没有 5xx"是有价值的信息，"n/a"会让人以为查询写错了）。
pq0() { local v; v="$(pq "$1")"; [[ "${v}" == "n/a" ]] && v=0; printf '%s' "${v}"; }
ms() { awk -v v="$1" 'BEGIN{ if (v=="n/a" || v=="") print "n/a"; else printf "%.1f", v }'; }

REQ_24H="$(num "$(pq0 'sum(increase(opslink_http_requests_total[24h]))')")"
ERR_24H="$(num "$(pq0 'sum(increase(opslink_http_requests_total{status=~"5.."}[24h]))')")"
ERR_PCT="$(pct "$(pq0 'sum(increase(opslink_http_requests_total{status=~"5.."}[24h]))')" "$(pq0 'sum(increase(opslink_http_requests_total[24h]))')")"
# 延迟用毫秒展示，秒级两位小数在 P95 只有几毫秒时会全变成 0.00
P95_MS="$(ms "$(pq 'histogram_quantile(0.95, sum by (le) (rate(opslink_http_request_duration_seconds_bucket[1h]))) * 1000')")"
HIT_PCT="$(pct "$(pq0 'sum(increase(opslink_cache_hits_total[24h]))')" "$(pq0 'sum(increase(opslink_cache_hits_total[24h])) + sum(increase(opslink_cache_misses_total[24h]))')")"
AVAIL="$(num "$(pq 'avg_over_time(up{job="opslink"}[24h]) * 100')")"

# 巡检最近一次结果（读 textfile，根因：脚本写的是 1=正常）
TF_OK="$(awk '/^ops_healthcheck_ok /{print $2}' "${TEXTFILE_DIR}/ops_healthcheck.prom" 2>/dev/null || echo "n/a")"
TF_TS="$(awk '/^ops_healthcheck_last_run_timestamp_seconds /{print $2}' "${TEXTFILE_DIR}/ops_healthcheck.prom" 2>/dev/null || echo "0")"
if [[ "${TF_OK}" == "1" ]]; then TF_TXT="通过"; else TF_TXT="失败"; fi
if [[ "${TF_TS}" =~ ^[0-9]+$ ]] && [[ "${TF_TS}" -gt 0 ]]; then
  TF_AGO="$(( ( $(date +%s) - TF_TS ) / 60 )) 分钟前"
else
  TF_AGO="未知"
fi

# 指标文件里必须是数字：读不到告警时写 0，不能把 n/a 写进去（Prometheus 会拒收整行）
[[ "${FIRING_N}" =~ ^[0-9]+$ ]] || FIRING_N=0

# 备份
LAST_BAK="$(find "${BACKUP_DIR}" -maxdepth 1 -name 'opslink-*.sql.gz' -printf '%T@ %f %s\n' 2>/dev/null | sort -nr | head -1)"
if [[ -n "${LAST_BAK}" ]]; then
  BAK_TS="$(echo "${LAST_BAK}" | awk '{printf "%d", $1}')"
  BAK_NAME="$(echo "${LAST_BAK}" | awk '{print $2}')"
  BAK_SIZE="$(echo "${LAST_BAK}" | awk '{printf "%.1f KB", $3/1024}')"
  BAK_AGE_H="$(awk -v t="${BAK_TS}" -v n="$(date +%s)" 'BEGIN{printf "%.1f", (n-t)/3600}')"
  BAK_TXT="${BAK_NAME}（${BAK_SIZE}，${BAK_AGE_H} 小时前）"
else
  BAK_TXT="没有找到备份文件"
fi

# 证书
CERT_DAYS="n/a"
if [[ -r "${CERT}" ]]; then
  END="$(date -d "$(openssl x509 -in "${CERT}" -noout -enddate | cut -d= -f2)" +%s 2>/dev/null || echo 0)"
  [[ "${END}" -gt 0 ]] && CERT_DAYS="$(( (END - $(date +%s)) / 86400 ))"
fi

# 最近一次发布
CURRENT="$(readlink -f /opt/ops-platform/current 2>/dev/null || echo "未知")"
CURRENT_TS="$(basename "${CURRENT}" 2>/dev/null || echo "未知")"

# --- 渲染 -------------------------------------------------------------------
render() {
  printf 'linux-ops-platform 每日巡检日报\n'
  printf '日期：%s    主机：%s    uptime：%s 小时\n' "${TODAY}" "${HOST}" "${UPTIME_H}"
  printf '生成时间：%s\n' "$(date '+%F %T %Z')"

  section "一句话结论"
  if [[ "${SVC_FAILED}" == "0" && "${FIRING_N}" == "0" && "${TF_OK}" == "1" ]]; then
    printf '  全部服务正常、无活跃告警、最近一次巡检通过。\n'
  else
    printf '  服务异常 %s 个、活跃告警 %s 条、最近巡检 %s —— 需要处理。\n' "${SVC_FAILED}" "${FIRING_N}" "${TF_TXT}"
  fi

  section "主机"
  printf '  load(1/5/15)：%s\n' "${LOAD}"
  printf '  内存：已用 %s%%（总 %s MB，可用 %s MB）\n' "${MEM_USED_PCT}" "${MEM_TOTAL_MB}" "${MEM_AVAIL_MB}"
  printf '  根分区：%s\n' "${DISK_ROOT}"
  printf '  %s：%s\n' "${DATA_DIR}" "${DISK_DATA}"

  section "服务"
  printf '%s' "${SVC_LINES}"

  section "监控与告警"
  printf '  抓取目标：%s / %s 在线\n' "${T_UP}" "${T_ALL}"
  printf '  活跃告警：%s 条\n' "${FIRING_N}"
  printf '%s\n' "${FIRING_LIST}"

  section "应用（近 24 小时）"
  printf '  请求总数：%s    5xx：%s（%s）\n' "${REQ_24H}" "${ERR_24H}" "${ERR_PCT}"
  printf '  近 1 小时 P95 延迟：%s 毫秒\n' "${P95_MS}"
  printf '  缓存命中率：%s\n' "${HIT_PCT}"
  printf '  可用性（avg_over_time）：%s%%\n' "${AVAIL}"

  section "巡检与备份"
  printf '  最近巡检：%s（%s）\n' "${TF_TXT}" "${TF_AGO}"
  printf '  最近备份：%s\n' "${BAK_TXT}"
  printf '  当前发布版本：%s\n' "${CURRENT_TS}"

  section "证书"
  printf '  opslink.crt 剩余：%s 天\n' "${CERT_DAYS}"
  printf '\n'
}

if [[ "${TO_STDOUT}" == "1" ]]; then
  render
  exit 0
fi

mkdir -p "${REPORT_DIR}"
TMP="$(mktemp "${REPORT_DIR}/.daily-XXXXXX")"
render >"${TMP}"
cat "${TMP}" >"${OUT}"
ln -sfn "${OUT}" "${REPORT_DIR}/latest.txt"
rm -f "${TMP}"
chmod 0644 "${OUT}" || true
render

# 写 textfile 指标：日报自己也值得被监控（"日报三天没生成"这种事要能告警）
mkdir -p "${TEXTFILE_DIR}"
if [[ -d "${TEXTFILE_DIR}" ]]; then
  MET="$(mktemp "${TEXTFILE_DIR}/.ops_report.XXXXXX")"
  {
    printf '# HELP ops_report_last_success_timestamp_seconds 日报最后一次成功生成的时间\n'
    printf '# TYPE ops_report_last_success_timestamp_seconds gauge\n'
    printf 'ops_report_last_success_timestamp_seconds %s\n' "$(date +%s)"
    printf '# HELP ops_report_active_alerts 生成日报时的活跃告警数\n'
    printf '# TYPE ops_report_active_alerts gauge\n'
    printf 'ops_report_active_alerts %s\n' "${FIRING_N}"
    printf '# HELP ops_report_failed_services 生成日报时非 active 的服务数\n'
    printf '# TYPE ops_report_failed_services gauge\n'
    printf 'ops_report_failed_services %s\n' "${SVC_FAILED}"
  } >"${MET}"
  chmod 0644 "${MET}"
  mv -f "${MET}" "${TEXTFILE_DIR}/ops_report.prom"
fi

printf '[INFO ] 日报已写入 %s\n' "${OUT}"
