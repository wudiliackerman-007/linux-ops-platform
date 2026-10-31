#!/usr/bin/env bash
# =============================================================================
# 定时任务安装：备份 / 巡检 / 恢复演练，用 systemd timer 而不是 cron
#
# 为什么用 timer：
#   * 日志统一进 journald（journalctl -u ops-backup），排错不用翻 /var/log
#   * 支持 Persistent=true：机器关机错过触发点，开机后补跑
#   * 支持 RandomizedDelaySec：避免多台机器同时备份打爆存储
#   * 依赖管理（After=mysql.service）比 cron 表达得清楚
#
# 用法：sudo ./scripts/install_timers.sh
# =============================================================================
set -euo pipefail

BIN_DIR="/opt/ops-platform/bin"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0"; exit 1; }

log() { printf '[INFO ] %s\n' "$*"; }

mkdir -p "${BIN_DIR}" /var/log/ops-platform /data/backup/mysql /data/backup/mysql-weekly

# 把仓库里的运维脚本装到固定路径（systemd 单元里引用绝对路径，不依赖仓库位置）
for s in backup_mysql.sh healthcheck.sh restore_test.sh release.sh rollback.sh; do
  if [[ -f "${REPO_ROOT}/scripts/${s}" ]]; then
    install -m 0755 "${REPO_ROOT}/scripts/${s}" "${BIN_DIR}/${s}"
    log "安装 ${BIN_DIR}/${s}"
  fi
done
chown -R root:root "${BIN_DIR}"

# node_exporter 的 textfile 目录要可写（脚本以 root 运行，写 .prom 文件）
chown -R node_exporter:node_exporter /var/lib/node_exporter 2>/dev/null || true

# ---------------------------------------------------------------------------
# 1. 每日备份 03:20
# ---------------------------------------------------------------------------
cat >/etc/systemd/system/ops-backup.service <<'EOF'
[Unit]
Description=MySQL 备份（linux-ops-platform）
After=mysql.service network-online.target
Wants=mysql.service
ConditionPathExists=/opt/ops-platform/bin/backup_mysql.sh

[Service]
Type=oneshot
ExecStart=/opt/ops-platform/bin/backup_mysql.sh
Nice=10
IOSchedulingClass=best-effort
IOSchedulingPriority=7
TimeoutStartSec=1800
EOF

cat >/etc/systemd/system/ops-backup.timer <<'EOF'
[Unit]
Description=每日 03:20 触发 MySQL 备份

[Timer]
OnCalendar=*-*-* 03:20:00
RandomizedDelaySec=300
Persistent=true
Unit=ops-backup.service

[Install]
WantedBy=timers.target
EOF

# ---------------------------------------------------------------------------
# 2. 每 5 分钟巡检
# ---------------------------------------------------------------------------
cat >/etc/systemd/system/ops-healthcheck.service <<'EOF'
[Unit]
Description=全链路健康巡检（linux-ops-platform）
After=network-online.target
ConditionPathExists=/opt/ops-platform/bin/healthcheck.sh

[Service]
Type=oneshot
ExecStart=/opt/ops-platform/bin/healthcheck.sh -q
TimeoutStartSec=120
EOF

cat >/etc/systemd/system/ops-healthcheck.timer <<'EOF'
[Unit]
Description=每 5 分钟触发健康巡检

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
AccuracySec=30s
Persistent=false
Unit=ops-healthcheck.service

[Install]
WantedBy=timers.target
EOF

# ---------------------------------------------------------------------------
# 3. 每周日 04:30 恢复演练（"备份能用"才算备份）
# ---------------------------------------------------------------------------
cat >/etc/systemd/system/ops-restore-test.service <<'EOF'
[Unit]
Description=备份恢复演练（linux-ops-platform）
After=mysql.service network-online.target

[Service]
Type=oneshot
ExecStart=/opt/ops-platform/bin/restore_test.sh
TimeoutStartSec=1800
EOF

cat >/etc/systemd/system/ops-restore-test.timer <<'EOF'
[Unit]
Description=每周日 04:30 恢复演练

[Timer]
OnCalendar=Sun *-*-* 04:30:00
RandomizedDelaySec=600
Persistent=true
Unit=ops-restore-test.service

[Install]
WantedBy=timers.target
EOF

# ---------------------------------------------------------------------------
# 4. 启用
# ---------------------------------------------------------------------------
systemctl daemon-reload
for t in ops-backup.timer ops-healthcheck.timer ops-restore-test.timer; do
  systemctl enable --now "${t}"
  log "已启用 ${t}"
done

log ""
log "定时任务列表："
systemctl list-timers 'ops-*' --no-pager || true
log ""
log "手动触发一次备份验证：sudo systemctl start ops-backup.service && journalctl -u ops-backup -n 30"
log "巡检日志：sudo journalctl -u ops-healthcheck --since '10 min ago'"
