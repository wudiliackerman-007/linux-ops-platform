#!/usr/bin/env bash
# =============================================================================
# 故障演练 01：CPU 打满
# 目的：验证 HostHighCPU 告警、看板上 CPU 曲线、以及你能否用 top/pidstat 定位
#
# 用法：sudo ops/chaos/01_cpu_spike.sh [核心数] [持续秒数]
#      默认 4 核、180 秒（到点自动恢复，不需要你手动清理）
# 预期：约 5 分钟后收到 HostHighCPU（warning）
# =============================================================================
set -euo pipefail

NPROC="${1:-4}"
DURATION="${2:-180}"

[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0"; exit 1; }

cat <<EOF
[演练] 故障：CPU 打满 ${NPROC} 核，持续 ${DURATION}s
[演练] 预期告警：HostHighCPU（warning，需持续 5 分钟）
[演练] 观察方式：
        watch -n1 'uptime'                          # 看 load 飙升
        top -o %CPU                                 # 看是哪些进程
        http://<IP>:9090/alerts                     # 看告警状态
        Grafana -> OpsLink 运维总览 -> CPU 使用率
[演练] 开始：$(date '+%F %T')
EOF

PIDS=()
cleanup() {
  echo
  echo "[演练] 清理中..."
  for p in "${PIDS[@]:-}"; do kill "${p}" 2>/dev/null || true; done
  wait 2>/dev/null || true
  echo "[演练] 已恢复：$(date '+%F %T')"
}
trap cleanup EXIT INT TERM

# 用纯 bash 死循环烧 CPU：不依赖 stress-ng，任何机器都能跑
for i in $(seq 1 "${NPROC}"); do
  ( end=$((SECONDS + DURATION)); while (( SECONDS < end )); do :; done ) &
  PIDS+=("$!")
  echo "[演练] 已启动压测进程 PID=$! "
done

echo "[演练] ${DURATION}s 后自动结束，Ctrl+C 可提前终止"
wait
