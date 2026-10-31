#!/usr/bin/env bash
# =============================================================================
# 手动回滚：把 current 指向上一个（或指定）release，然后重启
# 用途：发布后发现问题，但还没到自动回滚的地步（比如业务逻辑错误、非探针级别）
#
# 用法：
#   sudo /opt/ops-platform/bin/rollback.sh            # 回滚到上一个版本
#   sudo /opt/ops-platform/bin/rollback.sh --list     # 列出所有版本
#   sudo /opt/ops-platform/bin/rollback.sh 20250101120000
# =============================================================================
set -euo pipefail

APP_HOME="/opt/ops-platform"
APP_RELEASES="${APP_HOME}/releases"
APP_CURRENT="${APP_HOME}/current"
HEALTH_URL="http://127.0.0.1:8000/health/ready"

[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0"; exit 1; }

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

if [[ "${1:-}" == "--list" ]]; then
  CUR="$(readlink -f "${APP_CURRENT}")"
  printf '%-20s %-10s %s\n' "版本" "状态" "提交"
  while read -r d; do
    name="$(basename "${d}")"
    state="  "
    [[ "${d%/}" == "${CUR}" ]] && state="* "
    printf '%-20s %-6s %s\n' "${name}" "${state}" "$(grep -h '^commit=' "${d}RELEASE" 2>/dev/null | cut -d= -f2 || echo -)"
  done < <(ls -1dt "${APP_RELEASES}"/*/ 2>/dev/null)
  exit 0
fi

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  # 默认：当前版本的"上一个"（按修改时间倒序的第二项）
  TARGET="$(ls -1dt "${APP_RELEASES}"/*/ 2>/dev/null | tail -n +2 | head -1)"
  [[ -n "${TARGET}" ]] || { echo "没有可回滚的历史版本"; exit 1; }
  TARGET_DIR="${TARGET%/}"
else
  TARGET_DIR="${APP_RELEASES}/${TARGET}"
fi

[[ -d "${TARGET_DIR}" ]] || { echo "版本不存在：${TARGET_DIR}"; exit 1; }

PREV="$(readlink -f "${APP_CURRENT}")"
log "当前版本：${PREV}"
log "回滚目标：${TARGET_DIR}"

ln -sfn "${TARGET_DIR}" "${APP_CURRENT}"
chown -h ops:ops "${APP_CURRENT}"
systemctl restart opslink

for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "${HEALTH_URL}" >/dev/null 2>&1; then
    log "回滚成功，服务健康。当前版本：$(readlink -f "${APP_CURRENT}")"
    log "如需撤销回滚：sudo $0 $(basename "${PREV}")"
    exit 0
  fi
  sleep 1
done

log "回滚后健康检查失败，最近日志："
journalctl -u opslink -n 40 --no-pager || true
exit 1
