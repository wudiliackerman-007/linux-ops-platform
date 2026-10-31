#!/usr/bin/env bash
# =============================================================================
# 故障演练 02：磁盘写满
# 目的：验证 HostDiskUsageHigh / HostDiskWillFull 告警，练会"磁盘满了怎么救"
#
# 用法：sudo ops/chaos/02_disk_fill.sh 85       # 填到 /data 使用率 85%
#       sudo ops/chaos/02_disk_fill.sh --clean  # 清理演练文件
#
# 注意：只会写 /data/chaos 下的文件，不会碰系统分区；默认 20 分钟自动清理。
# 预期：约 10 分钟后 HostDiskUsageHigh（>80%）
# =============================================================================
set -euo pipefail

TARGET_PCT="${1:-85}"
DURATION="${CHAOS_KEEP_SECONDS:-1200}"   # 保留时间，到点自动删
FILL_DIR="/data/chaos"
FILL_FILE="${FILL_DIR}/disk-fill.bin"

[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0"; exit 1; }

if [[ "${TARGET_PCT}" == "--clean" ]]; then
  rm -f "${FILL_FILE}"
  echo "[演练] 已清理 ${FILL_FILE}"
  df -h /data | tail -1
  exit 0
fi

[[ "${TARGET_PCT}" =~ ^[0-9]+$ ]] || { echo "用法：$0 [目标百分比|--clean]"; exit 1; }
(( TARGET_PCT >= 50 && TARGET_PCT <= 90 )) || { echo "目标百分比限制在 50~90 之间（保护系统）"; exit 1; }

mkdir -p "${FILL_DIR}"
USED_KB="$(df -Pk /data | awk 'NR==2{print $2 - $4}')"
TOTAL_KB="$(df -Pk /data | awk 'NR==2{print $2}')"
NEED_KB=$(( TOTAL_KB * TARGET_PCT / 100 - USED_KB ))

if (( NEED_KB <= 0 )); then
  echo "[演练] /data 已超过 ${TARGET_PCT}%，无需填充"
  df -h /data | tail -1
  exit 0
fi

cat <<EOF
[演练] 故障：把 /data 从 $(( USED_KB * 100 / TOTAL_KB ))% 填到 ${TARGET_PCT}%
[演练] 需要写入约 $(( NEED_KB / 1024 ))MB 到 ${FILL_FILE}
[演练] 预期告警：HostDiskUsageHigh（warning，10 分钟）；如果继续增长会触发 HostDiskWillFull
[演练] 观察方式：
        df -h /data
        du -sh /data/* | sort -h
        http://<IP>:9090/alerts
[演练] ${DURATION}s 后自动清理；也可随时执行：sudo $0 --clean
EOF

cleanup() {
  echo
  rm -f "${FILL_FILE}"
  echo "[演练] 已清理填充文件：$(date '+%F %T')"
  df -h /data | tail -1
}
trap cleanup EXIT INT TERM

# fallocate 瞬间分配，比 dd 快很多（ext4 支持）
if fallocate -l "$(( NEED_KB ))K" "${FILL_FILE}" 2>/dev/null; then
  echo "[演练] fallocate 完成"
else
  echo "[演练] fallocate 不支持，改用 dd（较慢）"
  dd if=/dev/zero of="${FILL_FILE}" bs=1M count="$(( NEED_KB / 1024 ))" status=progress
fi

df -h /data | tail -1
echo "[演练] 等待 ${DURATION}s 后自动恢复..."
sleep "${DURATION}"
