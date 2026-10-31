#!/usr/bin/env bash
# =============================================================================
# 02 - MySQL 8 + Redis 6 安装与生产化配置
#
# 运维角度，这里做的不是「装上能跑」，而是：
#   1. 只监听 127.0.0.1（数据库绝不直接暴露公网）
#   2. 开慢查询日志 + 合理的 buffer pool
#   3. 应用账号最小权限（只给业务库）
#   4. Redis 设密码、限内存、淘汰策略、RDB 持久化
#   5. 装完立即验证（能启动 ≠ 能用）
#
# 用法：sudo ./deploy/install_middleware.sh
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

need_root "$@"
banner "02 MySQL + Redis 部署"
load_secrets

MYSQL_ROOT_PW="${MYSQL_ROOT_PASSWORD:-$(get_or_create_secret MYSQL_ROOT_PASSWORD 20)}"
MYSQL_APP_PW="${MYSQL_APP_PASSWORD:-$(get_or_create_secret MYSQL_APP_PASSWORD 24)}"
REDIS_PW="${REDIS_PASSWORD:-$(get_or_create_secret REDIS_PASSWORD 24)}"

# ---------------------------------------------------------------------------
step "安装 MySQL 8 与 Redis"
apt_install mysql-server redis-server

# ---------------------------------------------------------------------------
step "配置 MySQL（监听本地、慢查询、字符集）"
# 内存 6G 的机器：buffer pool 1G 够用；这条是「按机器规格算参数」的思维，面试会讲
MEM_MB=$(awk '/MemTotal/ {printf "%d", $2/1024}' /proc/meminfo)
BP_MB=$(( MEM_MB / 4 > 1024 ? 1024 : MEM_MB / 4 ))
CONN=$(( MEM_MB / 16 > 200 ? 200 : MEM_MB / 16 ))

cat >/etc/mysql/mysql.conf.d/99-ops.cnf <<EOF
[mysqld]
# ---------- 网络与安全 ----------
bind-address            = 127.0.0.1
port                    = 3306
mysqlx                  = OFF
skip-name-resolve       = ON

# ---------- 字符集 ----------
character-set-server    = utf8mb4
collation-server        = utf8mb4_unicode_ci

# ---------- 性能（按 ${MEM_MB}MB 内存推算） ----------
innodb_buffer_pool_size = ${BP_MB}M
innodb_log_file_size    = 256M
innodb_flush_log_at_trx_commit = 2
max_connections         = ${CONN}
table_open_cache        = 2000
tmp_table_size          = 64M
max_heap_table_size     = 64M

# ---------- 慢查询（性能问题 90% 靠它定位） ----------
slow_query_log          = ON
slow_query_log_file     = /var/log/mysql/slow.log
long_query_time         = 1
log_queries_not_using_indexes = OFF
min_examined_row_limit  = 100

# ---------- 日志 ----------
log_error               = /var/log/mysql/error.log
log_error_verbosity     = 2

# ---------- 超时 ----------
wait_timeout            = 600
interactive_timeout     = 600
max_connect_errors      = 1000
EOF

systemctl enable --now mysql >/dev/null 2>&1 || true
systemctl restart mysql
for i in $(seq 1 30); do
  mysqladmin ping --silent >/dev/null 2>&1 && break
  sleep 1
done
mysqladmin ping --silent >/dev/null 2>&1 || die "MySQL 启动失败，请查 journalctl -u mysql"
log_ok "MySQL 已启动，版本：$(mysql -N -e 'SELECT VERSION();' 2>/dev/null)"

# root 走 socket 认证；设置密码是为了让运维工具（备份脚本/监控）能连
mysql --protocol=socket -uroot <<SQL
ALTER USER 'root'@'localhost' IDENTIFIED WITH caching_sha2_password BY '${MYSQL_ROOT_PW}';
FLUSH PRIVILEGES;
SQL
log_ok "root 密码已写入 ${SECRETS_FILE}"

# 写 /root/.my.cnf：后续所有运维脚本都免密调用 mysql，
# 既不会在 ps 里暴露密码，也不会每次敲 -p（这是运维基本习惯）
cat >/root/.my.cnf <<EOF
[client]
user=root
password=${MYSQL_ROOT_PW}
host=localhost
EOF
chmod 600 /root/.my.cnf
log_ok "已生成 /root/.my.cnf（600），之后 mysql 命令可免密执行"

# 应用账号：只给 opslink 库权限，且走 mysql_native_password（兼容 PyMySQL 免装 cryptography）
mysql --defaults-file=/root/.my.cnf <<SQL
CREATE DATABASE IF NOT EXISTS opslink DEFAULT CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS 'opslink'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${MYSQL_APP_PW}';
ALTER USER 'opslink'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${MYSQL_APP_PW}';
GRANT SELECT, INSERT, UPDATE, DELETE ON opslink.* TO 'opslink'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
log_ok "应用账号 opslink@127.0.0.1 已创建（最小权限）"

# 监控用账号：只需要 PROCESS / REPLICATION CLIENT，能看状态但不碰数据
MYSQL_EXPORTER_PW="$(get_or_create_secret MYSQL_EXPORTER_PASSWORD 20)"
mysql --defaults-file=/root/.my.cnf <<SQL
CREATE USER IF NOT EXISTS 'exporter'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${MYSQL_EXPORTER_PW}';
ALTER USER 'exporter'@'127.0.0.1' IDENTIFIED WITH mysql_native_password BY '${MYSQL_EXPORTER_PW}';
GRANT PROCESS, REPLICATION CLIENT, SELECT ON *.* TO 'exporter'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
log_ok "监控账号 exporter 已创建（PROCESS + REPLICATION CLIENT）"

# 初始化表结构（schema.sql 自带 CREATE DATABASE IF NOT EXISTS + USE）
mysql --defaults-file=/root/.my.cnf <"${REPO_ROOT}/app/schema.sql" \
  || die "表结构初始化失败"
log_ok "表结构初始化完成：$(mysql -N -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='opslink';" 2>/dev/null) 张表"

# ---------------------------------------------------------------------------
step "配置 Redis（密码、内存上限、淘汰策略、RDB）"
ensure_dir /var/lib/redis /var/log/redis
chown -R redis:redis /var/lib/redis /var/log/redis 2>/dev/null || true

cat >/etc/redis/ops.conf <<EOF
# 由 linux-ops-platform 部署脚本生成
bind 127.0.0.1
port 6379
protected-mode yes
requirepass ${REDIS_PW}

# 内存上限 + LRU 淘汰：缓存绝不能把机器吃爆（这条是线上事故换来的）
maxmemory 256mb
maxmemory-policy allkeys-lru

# 持久化：RDB 每 5 分钟/100 次写落盘一次
save 300 100
save 60 10000
dbfilename dump.rdb
dir /var/lib/redis
appendonly no

# 安全：禁用危险命令
rename-command FLUSHALL ""
rename-command CONFIG ""

# 日志
logfile /var/log/redis/redis-server.log
loglevel notice
EOF

# 让主配置 include 我们的覆盖文件（放在最后，覆盖前面的默认值）
if ! grep -q 'include /etc/redis/ops.conf' /etc/redis/redis.conf; then
  backup_file /etc/redis/redis.conf
  echo 'include /etc/redis/ops.conf' >>/etc/redis/redis.conf
fi

systemctl enable --now redis-server >/dev/null 2>&1 || true
systemctl restart redis-server
sleep 1
if redis-cli -a "${REDIS_PW}" --no-auth-warning ping 2>/dev/null | grep -q PONG; then
  log_ok "Redis 已启动并带密码认证：$(redis-cli -a "${REDIS_PW}" --no-auth-warning info server 2>/dev/null | awk -F: '/redis_version/{print $2}' | tr -d '\r')"
else
  journalctl -u redis-server -n 20 --no-pager >&2 || true
  die "Redis 启动失败"
fi

# ---------------------------------------------------------------------------
step "验证中间件可用性"
mysql -h127.0.0.1 -uopslink -p"${MYSQL_APP_PW}" -D opslink -e 'SELECT 1 AS ok;' >/dev/null 2>&1 \
  && log_ok "应用账号连接 MySQL 成功" || die "应用账号连接 MySQL 失败"
redis-cli -a "${REDIS_PW}" --no-auth-warning set ops:selftest ok >/dev/null \
  && log_ok "Redis 读写测试成功" || die "Redis 读写失败"
redis-cli -a "${REDIS_PW}" --no-auth-warning del ops:selftest >/dev/null

# 写一份给应用/监控共用的环境文件
cat >"${APP_ENV_FILE}" <<EOF
# 应用运行环境变量（由 deploy/install_middleware.sh 生成）
OPSLINK_MYSQL_HOST=127.0.0.1
OPSLINK_MYSQL_PORT=3306
OPSLINK_MYSQL_USER=opslink
OPSLINK_MYSQL_PASSWORD=${MYSQL_APP_PW}
OPSLINK_MYSQL_DB=opslink
OPSLINK_REDIS_HOST=127.0.0.1
OPSLINK_REDIS_PORT=6379
OPSLINK_REDIS_PASSWORD=${REDIS_PW}
OPSLINK_REDIS_DB=0
OPSLINK_CACHE_TTL=3600
OPSLINK_BASE_DOMAIN=$(primary_ip)
EOF
chown root:"${APP_USER}" "${APP_ENV_FILE}" 2>/dev/null || true
chmod 640 "${APP_ENV_FILE}"
log_ok "环境变量文件已生成：${APP_ENV_FILE}"

# MySQL exporter 的凭据文件（供 mysqld_exporter 使用）
ensure_dir /etc/mysqld_exporter
cat >/etc/mysqld_exporter/.my.cnf <<EOF
[client]
user=exporter
password=${MYSQL_EXPORTER_PW}
host=127.0.0.1
port=3306
EOF
chmod 600 /etc/mysqld_exporter/.my.cnf
chmod 755 /etc/mysqld_exporter

banner "02 中间件部署完成"
log_info "MySQL：127.0.0.1:3306（库 opslink，账号 opslink）"
log_info "Redis：127.0.0.1:6379（带密码，maxmemory 256mb）"
log_info "下一步：sudo ./deploy/install_app.sh"
