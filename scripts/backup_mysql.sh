#!/usr/bin/env bash
# =============================================================================
# MySQL 备份脚本（每天 03:20 由 systemd timer 触发）
#
# 设计要点（面试可讲）：
#   1. --single-transaction：InnoDB 一致性快照，不锁表，业务无感
#   2. 备份完必须"验证"：gzip -t + 检查 Dump completed + 文件大小
#   3. 结果写成 Prometheus textfile 指标 → 备份失败会被 Alertmanager 告警
#      （"没有监控的备份等于没有备份"）
#   4. 本地保留 7 天 + 每周一份保留 4 周
#
# 用法：sudo /opt/ops-platform/bin/backup_mysql.sh
# 退出码：0 成功 / 1 失败（cron/timer 据此判断）
# =============================================================================
set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-/data/backup/mysql}"
WEEKLY_DIR="${WEEKLY_DIR:-/data/backup/mysql-weekly}"
LOG_FILE="${LOG_FILE:-/var/log/ops-platform/backup.log}"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
KEEP_DAYS="${KEEP_DAYS:-7}"
KEEP_WEEKS="${KEEP_WEEKS:-4}"
DB_NAME="${DB_NAME:-opslink}"
MYSQL_CNF="${MYSQL_CNF:-/root/.my.cnf}"

TS="$(date +%Y%m%d-%H%M%S)"
OUT="${BACKUP_DIR}/${DB_NAME}-${TS}.sql.gz"
START="$(date +%s)"
STATUS=1
SIZE=0

mkdir -p "${BACKUP_DIR}" "${WEEKLY_DIR}" "${TEXTFILE_DIR}"
touch "${LOG_FILE}"

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*" | tee -a "${LOG_FILE}"; }

# 把备份结果写给 node_exporter 的 textfile collector（原子写，避免读到半个文件）
write_metrics() {
  local ok="$1" size="$2" dur="$3" tmp
  tmp="$(mktemp "${TEXTFILE_DIR}/.backup.XXXXXX")"
  cat >"${tmp}" <<EOF
# HELP ops_backup_last_success_timestamp_seconds 最近一次备份成功的 Unix 时间戳
# TYPE ops_backup_last_success_timestamp_seconds gauge
ops_backup_last_success_timestamp_seconds $( [[ "${ok}" == "1" ]] && date +%s || echo 0 )
# HELP ops_backup_last_size_bytes 最近一次备份文件大小
# TYPE ops_backup_last_size_bytes gauge
ops_backup_last_size_bytes ${size}
# HELP ops_backup_duration_seconds 最近一次备份耗时
# TYPE ops_backup_duration_seconds gauge
ops_backup_duration_seconds ${dur}
# HELP ops_backup_last_run_ok 最近一次备份是否成功 1=成功
# TYPE ops_backup_last_run_ok gauge
ops_backup_last_run_ok ${ok}
EOF
  mv "${tmp}" "${TEXTFILE_DIR}/ops_backup.prom"
  chmod 644 "${TEXTFILE_DIR}/ops_backup.prom"
}

cleanup_and_exit() {
  local dur=$(( $(date +%s) - START )) okflag=1
  # 注意两套约定：脚本里 STATUS 是退出码（0=成功），指标里 ok 是 1=成功
  [[ "${STATUS}" == "0" ]] || okflag=0
  write_metrics "${okflag}" "${SIZE}" "${dur}"
  if [[ "${STATUS}" == "0" ]]; then
    log "备份成功：${OUT} (${SIZE} 字节, ${dur}s)"
    exit 0
  fi
  log "备份失败（详见上方错误）"
  exit 1
}

log "===== 开始备份 ${DB_NAME} ====="

# ---------- 1. 前置检查 ----------
if ! mysqladmin --defaults-file="${MYSQL_CNF}" ping --silent >/dev/null 2>&1; then
  log "ERROR MySQL 连不上（mysqladmin ping 失败）"
  cleanup_and_exit
fi

AVAIL_KB="$(df -Pk "${BACKUP_DIR}" | awk 'NR==2{print $4}')"
if [[ "${AVAIL_KB}" -lt 102400 ]]; then   # 留 100MB 余量
  log "ERROR 备份目录剩余空间不足 100MB（当前 $((AVAIL_KB / 1024))MB）"
  cleanup_and_exit
fi
log "MySQL 可连接，备份目录剩余 $((AVAIL_KB / 1024))MB"

# ---------- 2. 导出 ----------
# 用 PIPESTATUS 拿 mysqldump 的退出码（管道后 $? 是 gzip 的）
set -o pipefail
if ! mysqldump --defaults-file="${MYSQL_CNF}" \
      --single-transaction --quick --routines --triggers --events \
      --no-tablespaces --default-character-set=utf8mb4 \
      --databases "${DB_NAME}" 2>>"${LOG_FILE}" | gzip -6 >"${OUT}"; then
  log "ERROR mysqldump 失败"
  rm -f "${OUT}"
  cleanup_and_exit
fi

# ---------- 3. 验证备份（这一步不能省） ----------
if ! gzip -t "${OUT}" 2>>"${LOG_FILE}"; then
  log "ERROR 备份文件损坏（gzip -t 失败）"
  rm -f "${OUT}"
  cleanup_and_exit
fi

SIZE="$(stat -c %s "${OUT}")"
if [[ "${SIZE}" -lt 1024 ]]; then
  log "ERROR 备份文件只有 ${SIZE} 字节，疑似备份失败"
  cleanup_and_exit
fi

if ! zcat "${OUT}" | tail -5 | grep -q 'Dump completed'; then
  log "ERROR 备份内容不完整（缺少 'Dump completed'）"
  cleanup_and_exit
fi

STATUS=0
log "校验通过：gzip 完整、含 Dump completed、大小 $((SIZE / 1024))KB"

# ---------- 4. 每周留一份归档 ----------
if [[ "$(date +%u)" == "7" ]]; then
  cp -a "${OUT}" "${WEEKLY_DIR}/"
  log "已归档周备份：${WEEKLY_DIR}/$(basename "${OUT}")"
fi

# ---------- 5. 清理过期文件 ----------
DELETED="$(find "${BACKUP_DIR}" -maxdepth 1 -name "${DB_NAME}-*.sql.gz" -mtime +"${KEEP_DAYS}" -print -delete | wc -l)"
DELETED_W="$(find "${WEEKLY_DIR}" -maxdepth 1 -name "${DB_NAME}-*.sql.gz" -mtime +$(( KEEP_WEEKS * 7 )) -print -delete | wc -l)"
log "清理过期备份：日备 ${DELETED} 个，周备 ${DELETED_W} 个"

cleanup_and_exit
