#!/usr/bin/env bash
# =============================================================================
# 备份恢复演练（每周日 04:30 自动跑）
#
# 为什么需要它：很多人"有备份"，但真出事时发现备份打不开/恢复不了。
# 这个脚本每次把最新备份恢复到临时库 opslink_restore_check，比对行数，然后删掉。
#
# 用法：sudo /opt/ops-platform/bin/restore_test.sh
# =============================================================================
set -uo pipefail

BACKUP_DIR="${BACKUP_DIR:-/data/backup/mysql}"
TEST_DB="opslink_restore_check"
TEXTFILE_DIR="${TEXTFILE_DIR:-/var/lib/node_exporter/textfile_collector}"
MYSQL_CNF="/root/.my.cnf"
START="$(date +%s)"
OK=0
ROWS_SRC=0
ROWS_DST=0

log() { printf '[%s] %s\n' "$(date '+%F %T')" "$*"; }

finish() {
  mkdir -p "${TEXTFILE_DIR}"
  local tmp
  tmp="$(mktemp "${TEXTFILE_DIR}/.restore.XXXXXX")"
  cat >"${tmp}" <<EOF
# HELP ops_restore_test_last_run_timestamp_seconds 恢复演练执行时间
# TYPE ops_restore_test_last_run_timestamp_seconds gauge
ops_restore_test_last_run_timestamp_seconds $(date +%s)
# HELP ops_restore_test_ok 恢复演练是否成功 1=成功
# TYPE ops_restore_test_ok gauge
ops_restore_test_ok ${OK}
# HELP ops_restore_test_duration_seconds 恢复演练耗时
# TYPE ops_restore_test_duration_seconds gauge
ops_restore_test_duration_seconds $(( $(date +%s) - START ))
# HELP ops_restore_test_rows_source 生产库 links 表行数
# TYPE ops_restore_test_rows_source gauge
ops_restore_test_rows_source ${ROWS_SRC}
# HELP ops_restore_test_rows_restored 恢复库 links 表行数
# TYPE ops_restore_test_rows_restored gauge
ops_restore_test_rows_restored ${ROWS_DST}
EOF
  mv "${tmp}" "${TEXTFILE_DIR}/ops_restore_test.prom"
  chmod 644 "${TEXTFILE_DIR}/ops_restore_test.prom"
  exit "${1:-0}"
}

LATEST="$(ls -1t "${BACKUP_DIR}"/opslink-*.sql.gz 2>/dev/null | head -1 || true)"
if [[ -z "${LATEST}" ]]; then
  log "ERROR 找不到任何备份文件（${BACKUP_DIR}）"
  OK=0
  finish 1
fi

log "===== 恢复演练开始：${LATEST} ====="
log "文件大小：$(du -h "${LATEST}" | cut -f1)"

# 1. 完整性检查
if ! gzip -t "${LATEST}" 2>/dev/null; then
  log "ERROR 备份文件损坏"
  finish 1
fi

# 2. 建临时库
mysql --defaults-file="${MYSQL_CNF}" -e "DROP DATABASE IF EXISTS \`${TEST_DB}\`; CREATE DATABASE \`${TEST_DB}\` DEFAULT CHARACTER SET utf8mb4;" \
  || { log "ERROR 创建临时库失败"; finish 1; }

# 3. 恢复（把 dump 里的库名改到临时库，避免影响生产库）
#    dump 由 mysqldump --databases 生成，含 CREATE DATABASE/USE `opslink`
if zcat "${LATEST}" \
    | sed -e "s/\`opslink\`/\`${TEST_DB}\`/g" \
    | mysql --defaults-file="${MYSQL_CNF}" 2>/dev/null; then
  log "恢复导入完成"
else
  log "ERROR 恢复导入失败"
  mysql --defaults-file="${MYSQL_CNF}" -e "DROP DATABASE IF EXISTS \`${TEST_DB}\`;" 2>/dev/null
  finish 1
fi

# 4. 对比数据
ROWS_SRC="$(mysql --defaults-file="${MYSQL_CNF}" -N -e 'SELECT COUNT(*) FROM opslink.links;' 2>/dev/null || echo 0)"
ROWS_DST="$(mysql --defaults-file="${MYSQL_CNF}" -N -e "SELECT COUNT(*) FROM \`${TEST_DB}\`.links;" 2>/dev/null || echo 0)"

if [[ "${ROWS_DST}" -gt 0 && "${ROWS_SRC}" -eq "${ROWS_DST}" ]]; then
  log "数据校验通过：生产 ${ROWS_SRC} 行，恢复库 ${ROWS_DST} 行"
  OK=1
elif [[ "${ROWS_DST}" -gt 0 && "${ROWS_DST}" -le "${ROWS_SRC}" ]]; then
  log "WARN 行数不一致（生产 ${ROWS_SRC}，恢复 ${ROWS_DST}）—— 说明备份早于最新写入，属正常，但请注意 RPO"
  OK=1
else
  log "ERROR 恢复库里没有数据（生产 ${ROWS_SRC}，恢复 ${ROWS_DST}）"
fi

# 5. 清理
mysql --defaults-file="${MYSQL_CNF}" -e "DROP DATABASE IF EXISTS \`${TEST_DB}\`;" 2>/dev/null || true
log "临时库已删除"

if [[ "${OK}" == "1" ]]; then
  log "===== 恢复演练成功 ====="
  finish 0
else
  log "===== 恢复演练失败 ====="
  finish 1
fi
