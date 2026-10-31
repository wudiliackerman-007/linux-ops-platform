#!/usr/bin/env bash
# =============================================================================
# cleanup.sh —— 把本平台从这台机器上拆掉（用于「我想从头再装一遍」或交给别人前清场）
#
# 用法：
#   sudo ./deploy/cleanup.sh --dry-run     # 只打印会做什么，不动手（第一次建议先跑这个）
#   sudo ./deploy/cleanup.sh               # 停服务、卸 systemd 单元、删站点配置，保留数据
#   sudo ./deploy/cleanup.sh --purge       # 连数据、密钥、日志、备份一起删（不可恢复）
#
# 默认（不加 --purge）会保留：
#   /opt/ops-platform/{releases,venv}   发布版本与虚拟环境
#   /data/backup                        备份
#   /etc/ops-platform/platform.env      密钥（重装后密码不变，这点很重要）
#   MySQL 里的 opslink 库、Redis 里的缓存
#   apt 装的 mysql-server / redis-server / nginx / grafana
#
# 为什么默认不删数据：
#   多数「我想重装」其实是「我想重跑一遍部署脚本」，而 all_in_one.sh 本来就是幂等的。
#   真删数据是另一个量级的操作，必须显式加 --purge。
# =============================================================================
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/common.sh
. "${SCRIPT_DIR}/lib/common.sh"

DRY_RUN=0
PURGE=0
for arg in "$@"; do
  case "${arg}" in
    --dry-run) DRY_RUN=1 ;;
    --purge)   PURGE=1 ;;
    -h|--help) sed -n '2,25p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) die "未知参数：${arg}（可用：--dry-run / --purge / --help）" ;;
  esac
done

need_root

# 我们自己的 unit（含定时器）。grafana-server 是 deb 包自带的服务，只停不删单元文件。
OUR_UNITS=(
  alarm-receiver.service
  opslink.service
  prometheus.service
  alertmanager.service
  node_exporter.service
  mysqld_exporter.service
  nginx-prometheus-exporter.service
  grafana-server.service
  ops-backup.timer ops-healthcheck.timer ops-restore-test.timer ops-report.timer
)

UNIT_FILES=(
  /etc/systemd/system/alarm-receiver.service
  /etc/systemd/system/opslink.service
  /etc/systemd/system/prometheus.service
  /etc/systemd/system/alertmanager.service
  /etc/systemd/system/node_exporter.service
  /etc/systemd/system/mysqld_exporter.service
  /etc/systemd/system/nginx-prometheus-exporter.service
  /etc/systemd/system/ops-backup.service /etc/systemd/system/ops-backup.timer
  /etc/systemd/system/ops-healthcheck.service /etc/systemd/system/ops-healthcheck.timer
  /etc/systemd/system/ops-restore-test.service /etc/systemd/system/ops-restore-test.timer
  /etc/systemd/system/ops-report.service /etc/systemd/system/ops-report.timer
)

run() {
  # 统一的「打印 + 执行」，--dry-run 时只打印
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    printf '[DRY ] %s\n' "$*"
  else
    printf '[RUN ] %s\n' "$*"
    "$@" || return 1
  fi
}

echo "============================================================"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  echo " 清理预演（--dry-run）：下面只打印准备做什么，不会真的执行"
elif [[ "${PURGE}" -eq 1 ]]; then
  echo " 彻底清理（--purge）：服务 + 数据 + 密钥 + 日志全部删除"
else
  echo " 清理（保留数据）：只停服务和单元，数据和密钥都留着"
fi
echo "============================================================"

# ---------------------------------------------------------------------------
# 1. 停定时器与服务
# ---------------------------------------------------------------------------
echo
echo "==> 1/5 停止定时器与自有服务"
for u in "${OUR_UNITS[@]}"; do
  if systemctl cat "${u}" >/dev/null 2>&1; then
    run systemctl stop "${u}" || log_warn "停止 ${u} 失败（可能本来就没在跑）"
  fi
done

# ---------------------------------------------------------------------------
# 2. 删 systemd 单元文件
# ---------------------------------------------------------------------------
echo
echo "==> 2/5 删除 systemd 单元文件"
for f in "${UNIT_FILES[@]}"; do
  [[ -f "${f}" ]] && run rm -f "${f}"
done
[[ -f /etc/systemd/journald.conf.d/99-ops.conf ]] && run rm -f /etc/systemd/journald.conf.d/99-ops.conf
run systemctl daemon-reload
run systemctl reset-failed || true

# ---------------------------------------------------------------------------
# 3. 撤掉 Nginx 站点（nginx 本身是系统包，留着）
# ---------------------------------------------------------------------------
echo
echo "==> 3/5 撤掉 Nginx 站点配置"
[[ -f /etc/nginx/sites-enabled/opslink.conf ]] && run rm -f /etc/nginx/sites-enabled/opslink.conf
[[ -f /etc/nginx/sites-available/opslink.conf ]] && run rm -f /etc/nginx/sites-available/opslink.conf
[[ -f /etc/nginx/proxy_params_ops ]] && run rm -f /etc/nginx/proxy_params_ops
if [[ "${DRY_RUN}" -eq 0 ]] && has_cmd nginx; then
  if nginx -t >/dev/null 2>&1; then
    systemctl reload nginx 2>/dev/null || true
  else
    log_warn "nginx -t 没通过，跳过 reload（检查 /etc/nginx/sites-enabled/ 是否还有坏配置）"
  fi
fi

# ---------------------------------------------------------------------------
# 4. 数据：默认全留，--purge 才删
# ---------------------------------------------------------------------------
echo
echo "==> 4/5 处理数据"
if [[ "${PURGE}" -eq 1 ]]; then
  if [[ -f /root/.my.cnf ]] && has_cmd mysql; then
    mysql --defaults-file=/root/.my.cnf -e 'DROP DATABASE IF EXISTS opslink;' \
      && log_ok "已删除数据库 opslink" \
      || log_warn "删库失败（MySQL 可能没启动）"
  fi
  run rm -rf "${APP_HOME}" "${CONF_DIR}" "${LOG_DIR}"
  run rm -rf /data/ops-platform /data/backup /data/chaos
  run rm -rf "${PROM_CONF}" "${AM_CONF}" "${PROM_HOME}" "${AM_HOME}" "${NE_HOME}" "${ME_HOME}" "${NXE_HOME}"
  run rm -rf /var/lib/prometheus /var/lib/alertmanager /var/lib/grafana/dashboards /var/lib/node_exporter
  run rm -f /etc/mysqld_exporter/.my.cnf /etc/redis/ops.conf /etc/redis/redis-ops.conf
  run rm -rf /etc/ssl/opslink
  run rm -f /usr/local/bin/prometheus /usr/local/bin/promtool \
            /usr/local/bin/alertmanager /usr/local/bin/amtool \
            /usr/local/bin/node_exporter /usr/local/bin/mysqld_exporter \
            /usr/local/bin/nginx-prometheus-exporter
  log_warn "数据、密钥、日志、备份已删除（不可恢复）"
else
  log_info "保留 ${APP_HOME}（发布版本与 venv）"
  log_info "保留 ${CONF_DIR}（密钥文件，重装后密码不变）"
  log_info "保留 ${LOG_DIR} 与 /data/backup（日志与备份）"
  if [[ -f /root/.my.cnf ]] && has_cmd mysql; then
    if mysql --defaults-file=/root/.my.cnf -N -e "SHOW DATABASES LIKE 'opslink';" 2>/dev/null | grep -q opslink; then
      log_info "保留数据库 opslink（想清掉用 --purge）"
    fi
  fi
fi

# ---------------------------------------------------------------------------
# 5. 收尾
# ---------------------------------------------------------------------------
echo
echo "==> 5/5 完成"
if [[ "${DRY_RUN}" -eq 1 ]]; then
  log_info "这只是预演。确认无误后去掉 --dry-run 再跑一次。"
else
  log_ok "平台已停止并卸载单元"
  if [[ "${PURGE}" -eq 0 ]]; then
    log_info "数据和密钥都还在，装回来：sudo ./deploy/all_in_one.sh（约 1 分钟，不用重新下载）"
  else
    log_info "彻底清理完成，装回来：sudo ./deploy/all_in_one.sh（会重新下载约 160 MB）"
  fi
  log_info "apt 装的 mysql-server / redis-server / nginx / grafana 没动；要连它们一起删就自己 apt purge"
fi
