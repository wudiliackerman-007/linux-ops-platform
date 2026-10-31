#!/usr/bin/env bash
# =============================================================================
# 手动回滚：把 current 指向上一个（或指定）release，然后重启
# 用途：发布后发现问题，但还没到自动回滚的地步（比如业务逻辑错误、非探针级别）
#
# 用法：
#   sudo /opt/ops-platform/bin/rollback.sh            # 回滚到上一个"好"版本
#   sudo /opt/ops-platform/bin/rollback.sh --list     # 列出所有版本（含坏版本标记）
#   sudo /opt/ops-platform/bin/rollback.sh 20250101120000
#   sudo /opt/ops-platform/bin/rollback.sh --force 20250101120000   # 强制（即使是坏版本）
#
# 为什么要有 BROKEN 标记：
#   release.sh 发布失败时会自动回滚，但失败的 release 目录会保留（现场用于排查）。
#   如果手动回滚只看"时间上上一个版本"，就会正好滚回到那个已知坏的版本——
#   这是实测踩到的问题，所以 rollback.sh 默认跳过带 BROKEN 的目录。
# =============================================================================
set -euo pipefail

APP_HOME="/opt/ops-platform"
APP_RELEASES="${APP_HOME}/releases"
APP_CURRENT="${APP_HOME}/current"
HEALTH_URL="http://127.0.0.1:8000/health/ready"

[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0"; exit 1; }

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
is_broken() { [[ -f "${1%/}/BROKEN" ]]; }

if [[ "${1:-}" == "--list" ]]; then
  CUR="$(readlink -f "${APP_CURRENT}" 2>/dev/null || true)"
  printf '%-20s %-8s %-10s %s\n' "版本" "当前" "提交" "状态"
  while read -r d; do
    name="$(basename "${d}")"
    state=""
    [[ -n "${CUR}" && "${d%/}" == "${CUR}" ]] && state="*"
    mark="正常"
    is_broken "${d}" && mark="坏版本（BROKEN，发布失败）"
    printf '%-20s %-8s %-10s %s\n' "${name}" "${state}" \
      "$(grep -h '^commit=' "${d}RELEASE" 2>/dev/null | cut -d= -f2 || echo -)" "${mark}"
  done < <(ls -1dt "${APP_RELEASES}"/*/ 2>/dev/null)
  exit 0
fi

FORCE=0
if [[ "${1:-}" == "--force" ]]; then
  FORCE=1
  shift
fi

TARGET="${1:-}"
if [[ -z "${TARGET}" ]]; then
  # 默认：按时间倒序，跳过当前版本与坏版本，取第一个可用的
  CUR="$(readlink -f "${APP_CURRENT}" 2>/dev/null || true)"
  TARGET=""
  while read -r d; do
    [[ -n "${CUR}" && "${d%/}" == "${CUR}" ]] && continue
    is_broken "${d}" && continue
    TARGET="${d}"
    break
  done < <(ls -1dt "${APP_RELEASES}"/*/ 2>/dev/null)
  [[ -n "${TARGET}" ]] || { echo "没有可回滚的「好」版本（可能只有一个版本，或其余都是 BROKEN）"; exit 1; }
  TARGET_DIR="${TARGET%/}"
else
  TARGET_DIR="${APP_RELEASES}/${TARGET}"
fi

[[ -d "${TARGET_DIR}" ]] || { echo "版本不存在：${TARGET_DIR}"; exit 1; }

if is_broken "${TARGET_DIR}" && [[ "${FORCE}" != "1" ]]; then
  echo "拒绝回滚到坏版本：${TARGET_DIR}（$(cat "${TARGET_DIR}/BROKEN" 2>/dev/null | tr '\n' ' ')）"
  echo "确实要回滚到它，请加 --force；想找好版本用 sudo $0 --list"
  exit 1
fi

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
