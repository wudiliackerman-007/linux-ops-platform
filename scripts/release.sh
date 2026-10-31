#!/usr/bin/env bash
# =============================================================================
# 发布脚本（在服务器上执行）：拉代码 -> 新建 release -> 切软链 -> 健康检查 -> 失败自动回滚
#
# 为什么不用 scp 覆盖代码：
#   * 覆盖过程中进程读到的可能是"半个文件"
#   * 出问题无法秒级回退
#   * 不知道线上跑的到底是哪个版本
#
# 用法：
#   sudo /opt/ops-platform/bin/release.sh                # 发布当前仓库 HEAD
#   sudo /opt/ops-platform/bin/release.sh --no-pull      # 用本地代码发布（CI 场景）
# =============================================================================
set -euo pipefail

APP_HOME="/opt/ops-platform"
APP_RELEASES="${APP_HOME}/releases"
APP_CURRENT="${APP_HOME}/current"
APP_VENV="${APP_HOME}/venv"
APP_USER="ops"
REPO="${APP_HOME}/repo"
APP_ENV_FILE="/etc/ops-platform/app.env"
HEALTH_URL="http://127.0.0.1:8000/health/ready"
KEEP_RELEASES=5

PULL=1
[[ "${1:-}" == "--no-pull" ]] && PULL=0

[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0"; exit 1; }

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR $*"; exit 1; }

# ---------- 0. 记录当前版本，用于回滚 ----------
PREV="$(readlink -f "${APP_CURRENT}" 2>/dev/null || true)"
log "当前版本：${PREV:-无}"

# ---------- 1. 拉代码 ----------
if [[ "${PULL}" == "1" ]]; then
  [[ -d "${REPO}/.git" ]] || die "仓库不存在：${REPO}（首次部署请用 deploy/install_app.sh）"
  log "拉取最新代码..."
  sudo -u "${APP_USER}" git -C "${REPO}" fetch --all --prune
  sudo -u "${APP_USER}" git -C "${REPO}" reset --hard origin/main
fi
COMMIT="$(git -C "${REPO}" rev-parse --short HEAD 2>/dev/null || echo unknown)"
BRANCH="$(git -C "${REPO}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)"
TS="$(date +%Y%m%d%H%M%S)"
NEW="${APP_RELEASES}/${TS}"

# ---------- 2. 构建新 release ----------
log "创建 release ${NEW}（commit=${COMMIT} branch=${BRANCH}）"
mkdir -p "${NEW}"
rsync -a --delete "${REPO}/app/" "${NEW}/app/"
rm -rf "${NEW}/app/tests"
chown -R "${APP_USER}:${APP_USER}" "${NEW}"

log "同步依赖到共享 venv..."
"${APP_VENV}/bin/pip" install -q -r "${NEW}/app/requirements.txt" \
  -i https://pypi.tuna.tsinghua.edu.cn/simple

# ---------- 3. 切流量 ----------
log "切换软链 current -> ${TS}"
ln -sfn "${NEW}" "${APP_CURRENT}"
chown -h "${APP_USER}:${APP_USER}" "${APP_CURRENT}"

systemctl restart opslink

# ---------- 4. 健康检查（最多等 30s）----------
log "等待应用就绪..."
OK=0
for _ in $(seq 1 30); do
  if curl -fsS --max-time 3 "${HEALTH_URL}" >/dev/null 2>&1; then OK=1; break; fi
  sleep 1
done

if [[ "${OK}" == "1" ]]; then
  # 就绪探针通过还不够，再打一次真实业务请求
  CODE="$(curl -s -X POST http://127.0.0.1:8000/api/shorten \
    -H 'Content-Type: application/json' \
    -d '{"url":"https://github.com"}' | python3 -c 'import sys,json;print(json.load(sys.stdin).get("code",""))' 2>/dev/null || true)"
  if [[ -n "${CODE}" ]]; then
    cat >"${NEW}/RELEASE" <<EOF
release=${TS}
commit=${COMMIT}
branch=${BRANCH}
deploy_at=$(date '+%F %T')
deploy_by=${SUDO_USER:-root}
previous=${PREV}
EOF
    log "发布成功：${TS}（commit ${COMMIT}），冒烟短码 ${CODE}"
  else
    log "就绪探针通过但业务冒烟失败，触发回滚"
    OK=0
  fi
fi

# ---------- 5. 失败回滚 ----------
if [[ "${OK}" != "1" ]]; then
  log "健康检查失败，最近日志："
  journalctl -u opslink -n 40 --no-pager || true
  if [[ -n "${PREV}" && -d "${PREV}" ]]; then
    log "回滚到 ${PREV}"
    ln -sfn "${PREV}" "${APP_CURRENT}"
    systemctl restart opslink
    sleep 3
    curl -fsS --max-time 3 "${HEALTH_URL}" >/dev/null 2>&1 \
      && log "回滚完成，服务已恢复" || log "回滚后仍不健康，需人工介入！"
  else
    log "没有可回滚的历史版本"
  fi
  exit 1
fi

# ---------- 6. 清理旧版本 ----------
mapfile -t OLD < <(ls -1dt "${APP_RELEASES}"/*/ 2>/dev/null | tail -n +$((KEEP_RELEASES + 1)))
for d in "${OLD[@]:-}"; do
  [[ -n "${d}" && "${d}" != "${NEW}/" ]] && rm -rf "${d}" && log "清理旧版本：${d}"
done

log "完成。当前运行版本：$(readlink -f "${APP_CURRENT}")"
