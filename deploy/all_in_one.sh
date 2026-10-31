#!/usr/bin/env bash
# =============================================================================
# 一键部署：按顺序执行 01~05，任何一步失败立即停止（half-baked 的系统比没有更糟）
#
# 用法（在仓库根目录）：
#   sudo ./deploy/all_in_one.sh
#
# 适用：全新 Ubuntu 22.04 虚拟机。重复执行是幂等的（可用来修复环境）。
# 预计耗时：8~15 分钟（取决于网络）
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

need_root "$@"
check_ubuntu

DEPLOY_LOG="${LOG_DIR}/install-$(date +%Y%m%d-%H%M%S).log"
ensure_dir "${LOG_DIR}"
touch "${DEPLOY_LOG}"
chmod 640 "${DEPLOY_LOG}"
# 整个部署过程同时写日志，出问题可以直接发给别人看
exec > >(tee -a "${DEPLOY_LOG}") 2>&1

banner "linux-ops-platform 一键部署"
log_info "日志：${DEPLOY_LOG}"
log_info "仓库：${REPO_ROOT}"
log_info "开始时间：$(date '+%F %T')"

if [[ "$(readlink -f "${REPO_ROOT}")" != "/opt/ops-platform/repo" ]]; then
  log_warn "建议把仓库放在 /opt/ops-platform/repo（release.sh 默认从那里拉代码）："
  log_warn "  sudo git clone <你的仓库地址> /opt/ops-platform/repo && cd /opt/ops-platform/repo"
  log_warn "当前从 ${REPO_ROOT} 部署，功能不受影响，只是后续自动发布要指定路径。"
fi

TOTAL_START="$(date +%s)"
declare -a STEPS=()
declare -a TIMES=()

run_step() {
  local name="$1" script="$2" t0 t1
  step ">>> ${name}"
  t0="$(date +%s)"
  if bash "${script}"; then
    t1="$(date +%s)"
    STEPS+=("✅ ${name}")
    TIMES+=("$((t1 - t0))s")
    log_ok "${name} 完成（$((t1 - t0))s）"
  else
    log_error "${name} 失败，部署中止。日志：${DEPLOY_LOG}"
    log_error "修复后可直接重跑本脚本（幂等），或单独执行：bash ${script}"
    exit 1
  fi
}

run_step "01 系统初始化"        "${REPO_ROOT}/deploy/bootstrap.sh"
run_step "02 中间件 MySQL/Redis" "${REPO_ROOT}/deploy/install_middleware.sh"
run_step "03 业务应用"           "${REPO_ROOT}/deploy/install_app.sh"
run_step "04 Nginx 反向代理"     "${REPO_ROOT}/deploy/install_nginx.sh"
run_step "05 监控告警"           "${REPO_ROOT}/deploy/install_monitoring.sh"

step ">>> 050 定时任务（备份/巡检/恢复演练）"
if bash "${REPO_ROOT}/scripts/install_timers.sh"; then
  STEPS+=("✅ 050 定时任务")
else
  log_warn "定时任务安装失败（不影响核心链路，可稍后重试 scripts/install_timers.sh）"
  STEPS+=("⚠️ 050 定时任务")
fi

# ---------------------------------------------------------------------------
TOTAL_END="$(date +%s)"
banner "部署完成汇总"
for i in "${!STEPS[@]}"; do
  printf '  %-28s %s\n' "${STEPS[$i]}" "${TIMES[$i]:-}"
done
echo
log_info "总耗时：$(( (TOTAL_END - TOTAL_START) / 60 )) 分 $(( (TOTAL_END - TOTAL_START) % 60 )) 秒"

IP="$(primary_ip)"
cat <<EOF

============================================================
  请立刻做这三件事：
============================================================
  1) 打开监控，确认所有 target 都是 UP
     http://${IP}:9090/targets

  2) 打开看板，确认有数据
     http://${IP}:3000  （账号 admin，密码见 ${SECRETS_FILE}）

  3) 跑一次巡检和备份，确认运维脚本能用
     sudo /opt/ops-platform/bin/healthcheck.sh
     sudo systemctl start ops-backup.service && journalctl -u ops-backup -n 20

  业务入口：https://${IP}/  （自签证书，浏览器点「继续访问」）
  完整验收清单：docs/02-部署手册.md 的「验收清单」一节
============================================================
EOF
