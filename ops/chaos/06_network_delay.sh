#!/usr/bin/env bash
# =============================================================================
# 故障演练 06：网络延迟（tc netem）
# 目的：验证 AppHighLatencyP95 告警，练习用 tc 定位/模拟网络问题
#
# 注意：延迟加在默认网卡上，会同时影响 SSH！所以：
#   * 只用 100~300ms，不要用 5s
#   * 到点自动删除规则（trap EXIT），Ctrl+C 也会清理
#   * 如果你是通过 SSH 连的，建议在 VMware 控制台里跑
#
# 用法：sudo ops/chaos/06_network_delay.sh [延迟毫秒] [秒数]
# =============================================================================
set -euo pipefail

DELAY_MS="${1:-300}"
DURATION="${2:-180}"
[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0 [毫秒] [秒数]"; exit 1; }
(( DELAY_MS >= 50 && DELAY_MS <= 500 )) || { echo "延迟限制在 50~500ms（保护你的 SSH）"; exit 1; }

IFACE="$(ip -4 route show default | awk '{print $5; exit}')"
[[ -n "${IFACE}" ]] || { echo "找不到默认网卡"; exit 1; }

cat <<EOF
[演练] 故障：网卡 ${IFACE} 增加 ${DELAY_MS}ms 延迟，持续 ${DURATION}s
[演练] 预期告警：AppHighLatencyP95（warning，P95 > 0.5s 持续 5 分钟）
[演练] 观察方式：
        ping -c 5 <网关>
        curl -sk -w '耗时: %{time_total}s\\n' -o /dev/null https://127.0.0.1/health/live
        Grafana -> 接口延迟 P95 / P99
[演练] 提示：本地 loopback 不受影响，要看经过 ${IFACE} 的流量（比如从宿主机访问）
EOF

cleanup() {
  local rc=$?
  echo
  echo "[演练] 删除 tc 规则..."
  tc qdisc del dev "${IFACE}" root 2>/dev/null || true
  echo "[演练] 已恢复网络：$(date '+%F %T')"
  exit "${rc}"
}
trap cleanup EXIT INT TERM

tc qdisc add dev "${IFACE}" root netem delay "${DELAY_MS}ms"
echo "[演练] 规则已生效："
tc qdisc show dev "${IFACE}"

echo "[演练] 等待 ${DURATION}s..."
sleep "${DURATION}"
