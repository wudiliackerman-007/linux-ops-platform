#!/usr/bin/env bash
# =============================================================================
# 01 - 系统基线初始化（幂等，可反复执行）
#
# 做四件事：
#   1. 换国内源 + 装运维常用工具（apt 慢是新人第一个坑）
#   2. 目录规范 + 用户规范 + sudo 免密（运维第一原则：不做 root 裸奔）
#   3. 内核/文件句柄/swap 调优 + 时间同步（否则监控曲线会漂）
#   4. 安全基线：SSH 加固、防火墙、fail2ban
#
# 用法：sudo ./deploy/bootstrap.sh
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

need_root "$@"
check_ubuntu

banner "01 系统基线初始化"

# ---------------------------------------------------------------------------
# 1. APT 换源（阿里云；Ubuntu 22.04 用 jammy，架构 arm64/amd64 自动适配）
# ---------------------------------------------------------------------------
step "1/7 配置 APT 镜像源"
if grep -q "mirrors.aliyun.com" /etc/apt/sources.list 2>/dev/null; then
  log_ok "已是阿里云源，跳过"
else
  backup_file /etc/apt/sources.list
  cat >/etc/apt/sources.list <<'EOF'
# 由 linux-ops-platform 部署脚本生成（阿里云镜像）
deb https://mirrors.aliyun.com/ubuntu/ jammy main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ jammy-updates main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ jammy-backports main restricted universe multiverse
deb https://mirrors.aliyun.com/ubuntu/ jammy-security main restricted universe multiverse
EOF
  log_ok "已切换到阿里云 APT 源"
fi

step "1/7 更新软件包索引"
DEBIAN_FRONTEND=noninteractive apt-get update -qq

step "1/7 安装基础运维工具"
apt_install \
  curl wget ca-certificates gnupg lsb-release \
  vim less tree jq unzip zip tar rsync \
  htop iotop sysstat lsof psmisc procps \
  net-tools dnsutils tcpdump telnet traceroute \
  chrony logrotate bash-completion cron \
  python3 python3-pip python3-venv python3-dev \
  openssl sudo
# 说明：不装 build-essential（省 300MB，本项目无需编译）；要装 Docker 时再补

# ---------------------------------------------------------------------------
# 2. 时区与时间同步（监控时间戳、日志排序全靠它）
# ---------------------------------------------------------------------------
step "2/7 时区与时间同步"
timedatectl set-timezone Asia/Shanghai
systemctl enable --now chrony >/dev/null 2>&1 || true
chronyc -a makestep >/dev/null 2>&1 || true
log_ok "时区：$(timedatectl show -p Timezone --value)  时间：$(date '+%F %T')"

# ---------------------------------------------------------------------------
# 3. 用户与目录规范
# ---------------------------------------------------------------------------
step "3/7 创建运维用户与目录规范"
if ! id "${APP_USER}" >/dev/null 2>&1; then
  useradd -m -s /bin/bash "${APP_USER}"
  log_ok "已创建用户 ${APP_USER}"
else
  log_ok "用户 ${APP_USER} 已存在"
fi

# sudo 免密：仅限本项目需要的命令，不是无条件 ALL（面试可讲的细节）
cat >/etc/sudoers.d/90-${APP_USER}-ops <<EOF
# ${APP_USER} 用户可以免密执行运维脚本（生产上建议更细粒度，这里为演示便利）
${APP_USER} ALL=(root) NOPASSWD: /bin/systemctl, /usr/bin/systemctl, \\
  /bin/journalctl, /usr/bin/journalctl, /opt/ops-platform/scripts/, \\
  /usr/sbin/nginx, /usr/bin/rsync, /usr/local/bin/ops-*
EOF
chmod 440 /etc/sudoers.d/90-${APP_USER}-ops
visudo -c -q && log_ok "sudoers 语法校验通过"

ensure_dir "${APP_HOME}" "${APP_RELEASES}" "${APP_SHARED}" "${CONF_DIR}" "${LOG_DIR}" \
           "${DATA_DIR}" "${DATA_DIR}/backup" "${TEXTFILE_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${APP_HOME}" "${LOG_DIR}"
chown -R "${APP_USER}:${APP_USER}" "${DATA_DIR}/backup"
chmod 750 "${CONF_DIR}"

# 运维习惯：日志、代码、数据、配置分开放，出问题好定位，也好做备份策略
cat >"${APP_HOME}/README.layout" <<'EOF'
/opt/ops-platform/releases/<时间戳>/   每次发布的代码副本（保留最近 5 个，便于回滚）
/opt/ops-platform/current -> releases  当前生效版本（软链，切换即发布）
/opt/ops-platform/venv                 Python 虚拟环境（所有版本共用）
/opt/ops-platform/shared               跨版本共享（上传、临时文件）
/data/backup                           MySQL 备份（独立分区/磁盘最好）
/data/mysql                            MySQL 数据目录
/etc/ops-platform                      配置与密钥（600 权限）
/var/log/ops-platform                  应用日志
EOF

# ---------------------------------------------------------------------------
# 4. 内核参数与句柄上限
# ---------------------------------------------------------------------------
step "4/7 内核参数调优"
cat >/etc/sysctl.d/99-ops.conf <<'EOF'
# ---------- 网络 ----------
net.core.somaxconn = 4096              # 全连接队列上限，Nginx 高并发必需
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.ip_local_port_range = 10240 65000
net.ipv4.tcp_tw_reuse = 1              # 复用 TIME_WAIT，短连接多时明显
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 600
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
# ---------- 文件句柄 ----------
fs.file-max = 1000000
fs.inotify.max_user_watches = 524288
# ---------- 内存 ----------
vm.swappiness = 10                     # 尽量用内存，swap 只做兜底
vm.overcommit_memory = 1               # Redis fork 做 RDB 时避免 fork 失败
vm.dirty_ratio = 20
vm.dirty_background_ratio = 10
# ---------- 连接跟踪（NAT 场景） ----------
net.netfilter.nf_conntrack_max = 262144
EOF
# 只关心我们自己写下去的那些键是否生效。
# `sysctl --system` 会顺带应用 Ubuntu 自带的 /etc/sysctl.d/10-*.conf，
# 其中 net.ipv4.conf.all.accept_source_route / promote_secondaries 在 22.04 的内核上
# 会报 "Invalid argument"（这是内核行为，不是我们的配置写错了），不能让它把日志刷红。
sysctl --system >/tmp/ops-sysctl.log 2>&1 || true
# nf_conntrack 只有在模块加载后才存在 /proc/sys/net/netfilter/nf_conntrack_max。
# 全新系统上这个模块通常还没加载（是 ufw/iptables 的 NAT 规则把它带起来的），
# 所以先尝试加载；加载不到也不影响后面，只是那一项会读到空值。
modprobe nf_conntrack 2>/dev/null || true
ours_total=0
ours_failed=0
ours_missing=""
# 归一化空白：ip_local_port_range 这类键的值本身带空格（"10240 65000"）
norm() { tr -s '[:space:]' ' ' | sed -e 's/^ //' -e 's/ $//'; }
while IFS= read -r line; do
  # 去掉行尾注释，再按第一个 = 切成 key / value
  line="$(printf '%s' "${line}" | sed -E 's/[[:space:]]*#.*$//')"
  key="$(printf '%s' "${line}" | cut -d= -f1 | norm)"
  val="$(printf '%s' "${line}" | cut -d= -f2- | norm)"
  [[ -z "${key}" || -z "${val}" ]] && continue
  ours_total=$((ours_total + 1))
  # 关键：这里必须容忍读取失败。
  # 脚本是 `set -euo pipefail`，而 sysctl 读不存在的键会返回非 0；
  # 一旦直接写 cur="$(sysctl -n ... | norm)"，管道失败会让整个脚本静默退出（rc=255），
  # 表面上只看到 step 4 之后再没有任何输出——第一版就踩了这个坑。
  cur="$(sysctl -n "${key}" 2>/dev/null | norm || true)"
  if [[ -z "${cur}" ]]; then
    ours_missing="${ours_missing} ${key}"
    ours_failed=$((ours_failed + 1))
  elif [[ "${cur}" != "${val}" ]]; then
    log_warn "内核参数未生效：${key}（期望 ${val}，实际 ${cur}）"
    ours_failed=$((ours_failed + 1))
  fi
done < <(grep -E '^[a-z].*=' /etc/sysctl.d/99-ops.conf)
if [[ "${ours_failed}" -eq 0 ]]; then
  log_ok "内核参数全部生效（${ours_total} 项，somaxconn=$(sysctl -n net.core.somaxconn)）"
elif [[ -n "${ours_missing}" ]]; then
  log_warn "有 $(echo "${ours_missing}" | wc -w) 项在当前内核不存在（通常是模块未加载，不影响部署）：$(echo ${ours_missing} | tr ' ' '\n' | sed '/^$/d' | paste -sd, -)"
else
  log_warn "${ours_total} 项里有 ${ours_failed} 项未生效，多半是当前环境不允许（容器/云主机常见）"
fi

cat >/etc/security/limits.d/99-ops.conf <<'EOF'
*    soft nofile 65535
*    hard nofile 65535
root soft nofile 65535
root hard nofile 65535
EOF

# ---------------------------------------------------------------------------
# 5. Swap（16GB 内存的老机器/云主机内存小时很有用；有 swap 才有 OOM 缓冲）
#    注意：只创建一次，重复执行不会重复加 fstab
# ---------------------------------------------------------------------------
step "5/7 配置 swap"
if swapon --show | grep -q '/swapfile'; then
  log_ok "swap 已存在：$(swapon --show=NAME,SIZE --noheadings --raw | head -1)"
else
  if [[ ! -f /swapfile ]]; then
    fallocate -l 2G /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=2048 status=none
    chmod 600 /swapfile
    mkswap /swapfile >/dev/null
  fi
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >>/etc/fstab
  log_ok "swap 2G 已启用"
fi

# ---------------------------------------------------------------------------
# 6. SSH 安全加固（关键：没有密钥就绝不关密码登录，否则你会把自己锁在外面）
# ---------------------------------------------------------------------------
step "6/7 SSH 安全加固"
SSH_DIR="/home/${APP_USER}/.ssh"
if [[ -f /root/.ssh/authorized_keys && ! -s "${SSH_DIR}/authorized_keys" ]]; then
  mkdir -p "${SSH_DIR}"
  cp /root/.ssh/authorized_keys "${SSH_DIR}/authorized_keys"
  chown -R "${APP_USER}:${APP_USER}" "${SSH_DIR}"
  chmod 700 "${SSH_DIR}"
  chmod 600 "${SSH_DIR}/authorized_keys"
  log_ok "已把 root 的公钥复制给 ${APP_USER}（免密登录可用）"
fi

if [[ -s "${SSH_DIR}/authorized_keys" ]]; then
  cat >/etc/ssh/sshd_config.d/99-ops-hardening.conf <<'EOF'
# 禁止 root 用密码登录（保留密钥，便于急救）
PermitRootLogin prohibit-password
# 禁用弱算法
KexAlgorithms curve25519-sha256,curve25519-sha256@libssh.org,diffie-hellman-group16-sha512
Ciphers chacha20-poly1305@openssh.com,aes256-gcm@openssh.com,aes128-gcm@openssh.com
MACs hmac-sha2-512-etm@openssh.com,hmac-sha2-256-etm@openssh.com
MaxAuthTries 4
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
EOF
  # 只有确认密钥可用才关掉密码登录
  if ssh-keygen -l -f "${SSH_DIR}/authorized_keys" >/dev/null 2>&1; then
    cat >>/etc/ssh/sshd_config.d/99-ops-hardening.conf <<'EOF'
PasswordAuthentication no
PubkeyAuthentication yes
AllowUsers ops
EOF
    log_ok "已关闭密码登录（仅保留密钥），当前可用用户：ops"
  fi
  sshd -t && systemctl reload ssh
  log_ok "sshd 配置校验通过并已 reload"
else
  log_warn "未发现 ${APP_USER} 的 authorized_keys，已跳过「关闭密码登录」（避免把自己锁死）"
  log_warn "配好密钥后重新执行本脚本即可完成加固：ssh-copy-id ops@<本机IP>"
fi

# ---------------------------------------------------------------------------
# 7. 防火墙 + 入侵防护
# ---------------------------------------------------------------------------
step "7/7 防火墙与 fail2ban"
apt_install ufw fail2ban

ufw --force reset >/dev/null
ufw default deny incoming >/dev/null
ufw default allow outgoing >/dev/null
ufw allow 22/tcp comment 'SSH' >/dev/null
ufw allow 80/tcp comment 'HTTP' >/dev/null
ufw allow 443/tcp comment 'HTTPS' >/dev/null
ufw allow 3000/tcp comment 'Grafana' >/dev/null
ufw allow 9090/tcp comment 'Prometheus' >/dev/null
ufw allow 9093/tcp comment 'Alertmanager' >/dev/null
ufw --force enable >/dev/null
log_ok "ufw 已启用（放行 22/80/443/3000/9090/9093）"

cat >/etc/fail2ban/jail.d/sshd.local <<'EOF'
[sshd]
enabled  = true
port     = 22
maxretry = 5
findtime = 600
bantime  = 3600
EOF
systemctl enable --now fail2ban >/dev/null 2>&1 || true
systemctl restart fail2ban
log_ok "fail2ban 已启用（10 分钟内 5 次失败即封 1 小时）"

# ---------------------------------------------------------------------------
# 生成/复用平台密钥文件
# ---------------------------------------------------------------------------
step "生成平台密钥"
MYSQL_ROOT_PW="$(get_or_create_secret MYSQL_ROOT_PASSWORD 20)"
MYSQL_APP_PW="$(get_or_create_secret MYSQL_APP_PASSWORD 24)"
REDIS_PW="$(get_or_create_secret REDIS_PASSWORD 24)"
GRAFANA_PW="$(get_or_create_secret GRAFANA_ADMIN_PASSWORD 16)"
log_ok "密钥已写入 ${SECRETS_FILE}（600 权限，勿提交到 Git）"

banner "01 系统基线初始化完成"
log_info "机器 IP：$(primary_ip)"
log_info "下一步：sudo ./deploy/install_middleware.sh"
