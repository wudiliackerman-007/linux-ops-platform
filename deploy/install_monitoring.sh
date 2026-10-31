#!/usr/bin/env bash
# =============================================================================
# 05 - 监控告警全家桶：Prometheus + Alertmanager + 3 个 exporter + Grafana
#
# 为什么全是二进制/apt，不用 Docker：
#   * 这台机器上 Docker Hub 拉不动（国内网络），依赖 Docker 的方案在你这儿跑不通
#   * 运维岗面试更看重「会手工装、会写 systemd、会看进程和端口」，而不是 docker run
#
# 组件职责（一句话版）：
#   Prometheus  拉数据 + 算规则 + 发告警
#   Alertmanager 收告警、去重、分组、抑制、发给接收方
#   exporter    把各种系统的指标翻译成 Prometheus 格式
#   Grafana     人看的界面
#
# 用法：sudo ./deploy/install_monitoring.sh
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

need_root "$@"
check_ubuntu
banner "05 监控告警部署"

IP="$(primary_ip)"
DOWNLOAD_DIR=/tmp/ops-dl
ensure_dir "${DOWNLOAD_DIR}"

# 创建专用系统用户：进程不以 root 跑，被打穿了的损失可控
ensure_user() {
  local u="$1"
  id -u "${u}" >/dev/null 2>&1 || {
    useradd --system --no-create-home --shell /usr/sbin/nologin "${u}"
    log_ok "创建系统用户：${u}"
  }
}

# 从 release 包安装一个二进制到 /usr/local/bin
install_bin_from_tar() {
  # install_bin_from_tar <tar.gz> <包内目录名，留空表示包内直接是文件> <二进制名>
  local tgz="$1" inner="$2" bin="$3" src
  tar -xzf "${tgz}" -C "${DOWNLOAD_DIR}"
  if [[ -n "${inner}" ]]; then
    src="${DOWNLOAD_DIR}/${inner}/${bin}"
  else
    src="${DOWNLOAD_DIR}/${bin}"
  fi
  [[ -f "${src}" ]] || die "压缩包内未找到 ${inner:+${inner}/}${bin}"
  install -m 0755 "${src}" /usr/local/bin/"${bin}"
  log_ok "已安装 /usr/local/bin/${bin} ($(/usr/local/bin/${bin} --version 2>&1 | head -1))"
}

# ---------------------------------------------------------------------------
step "1/8 创建用户、目录与下载缓存"
for u in prometheus alertmanager node_exporter mysqld_exporter; do ensure_user "${u}"; done
ensure_dir /etc/prometheus/rules /var/lib/prometheus
ensure_dir "${PROM_HOME}/consoles" "${PROM_HOME}/console_libraries"
ensure_dir "${AM_CONF}" /var/lib/alertmanager
ensure_dir /var/lib/node_exporter/textfile_collector
ensure_dir "${APP_HOME}/webhook" "${LOG_DIR}"
chown -R prometheus:prometheus /var/lib/prometheus
chown -R alertmanager:alertmanager /var/lib/alertmanager
chown -R node_exporter:node_exporter /var/lib/node_exporter

# ---------------------------------------------------------------------------
step "2/8 安装 Prometheus ${PROM_VERSION} + promtool"
PROM_TGZ="${DOWNLOAD_DIR}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
download "${PROM_TGZ}" \
  "${GH_PROXY}/https://github.com/prometheus/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" \
  "${MIRROR_HW}/prometheus/releases/download/v${PROM_VERSION}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz" \
  "${MIRROR_HW}/prometheus-${PROM_VERSION}.linux-amd64.tar.gz"
tar -xzf "${PROM_TGZ}" -C "${DOWNLOAD_DIR}"
PROM_INNER="${DOWNLOAD_DIR}/prometheus-${PROM_VERSION}.linux-amd64"
install -m 0755 "${PROM_INNER}/prometheus" /usr/local/bin/prometheus
install -m 0755 "${PROM_INNER}/promtool" /usr/local/bin/promtool
cp -r "${PROM_INNER}/consoles/." "${PROM_HOME}/consoles/"
cp -r "${PROM_INNER}/console_libraries/." "${PROM_HOME}/console_libraries/"
log_ok "Prometheus 版本：$(/usr/local/bin/prometheus --version 2>&1 | head -1)"

# ---------------------------------------------------------------------------
step "3/8 安装 Alertmanager ${AM_VERSION}"
AM_TGZ="${DOWNLOAD_DIR}/alertmanager-${AM_VERSION}.linux-amd64.tar.gz"
download "${AM_TGZ}" \
  "${GH_PROXY}/https://github.com/prometheus/alertmanager/releases/download/v${AM_VERSION}/alertmanager-${AM_VERSION}.linux-amd64.tar.gz" \
  "${MIRROR_HW}/alertmanager/releases/download/v${AM_VERSION}/alertmanager-${AM_VERSION}.linux-amd64.tar.gz"
install_bin_from_tar "${AM_TGZ}" "alertmanager-${AM_VERSION}.linux-amd64" alertmanager
install_bin_from_tar "${AM_TGZ}" "alertmanager-${AM_VERSION}.linux-amd64" amtool

# ---------------------------------------------------------------------------
step "4/8 安装三个 exporter"
NE_TGZ="${DOWNLOAD_DIR}/node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
download "${NE_TGZ}" \
  "${GH_PROXY}/https://github.com/prometheus/node_exporter/releases/download/v${NE_VERSION}/node_exporter-${NE_VERSION}.linux-amd64.tar.gz" \
  "${MIRROR_HW}/node_exporter-${NE_VERSION}.linux-amd64.tar.gz"
install_bin_from_tar "${NE_TGZ}" "node_exporter-${NE_VERSION}.linux-amd64" node_exporter

ME_TGZ="${DOWNLOAD_DIR}/mysqld_exporter-${ME_VERSION}.linux-amd64.tar.gz"
download "${ME_TGZ}" \
  "${GH_PROXY}/https://github.com/prometheus/mysqld_exporter/releases/download/v${ME_VERSION}/mysqld_exporter-${ME_VERSION}.linux-amd64.tar.gz" \
  "${MIRROR_HW}/mysqld_exporter-${ME_VERSION}.linux-amd64.tar.gz"
install_bin_from_tar "${ME_TGZ}" "mysqld_exporter-${ME_VERSION}.linux-amd64" mysqld_exporter

NXE_TGZ="${DOWNLOAD_DIR}/nginx-prometheus-exporter-${NXE_VERSION}.linux-amd64.tar.gz"
download "${NXE_TGZ}" \
  "${GH_PROXY}/https://github.com/nginxinc/nginx-prometheus-exporter/releases/download/v${NXE_VERSION}/nginx-prometheus-exporter_${NXE_VERSION}_linux_amd64.tar.gz" \
  "${MIRROR_HW}/nginx-prometheus-exporter-${NXE_VERSION}.linux-amd64.tar.gz"
# nginxinc 的包里没有顶层目录（二进制直接在根），第二个参数留空
install_bin_from_tar "${NXE_TGZ}" "" nginx-prometheus-exporter

# mysqld_exporter 的数据库账号密码已在 install_middleware.sh 写入 600 的 cnf 文件
# （不放命令行，因为 ps aux 能看到密码），这里只校正属主让 exporter 用户能读
[[ -f /etc/mysqld_exporter/.my.cnf ]] \
  || die "缺少 /etc/mysqld_exporter/.my.cnf，请先执行 deploy/install_middleware.sh"
chown mysqld_exporter:mysqld_exporter /etc/mysqld_exporter/.my.cnf
chmod 600 /etc/mysqld_exporter/.my.cnf
log_ok "exporter 凭据文件就绪：/etc/mysqld_exporter/.my.cnf（600）"

# ---------------------------------------------------------------------------
step "5/8 安装 Grafana ${GRAFANA_DEB_VER}（apt 源 + 直接 deb 双保险）"
if dpkg -s grafana >/dev/null 2>&1; then
  log_ok "Grafana 已安装：$(grafana-server -v 2>/dev/null | head -1 || echo installed)"
else
  GRAFANA_DEB="${DOWNLOAD_DIR}/grafana_${GRAFANA_DEB_VER}_amd64.deb"
  download "${GRAFANA_DEB}" \
    "${MIRROR_TUNA}/grafana/apt/pool/main/g/grafana/grafana_${GRAFANA_DEB_VER}_amd64.deb"
  # 直接用 deb，依赖从已配置的 apt 源补齐
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${GRAFANA_DEB}"
  log_ok "Grafana 安装完成：$(grafana-server -v 2>/dev/null | head -1 || true)"
fi

GRAFANA_PW="$(get_or_create_secret GRAFANA_ADMIN_PASSWORD 20)"
# 初始密码不留在默认 admin/admin，改配置文件（systemd 启动时读取）
sed -i "s|^;admin_password = .*|admin_password = ${GRAFANA_PW}|" /etc/grafana/grafana.ini
sed -i "s|^;admin_user = .*|admin_user = admin|" /etc/grafana/grafana.ini
log_ok "Grafana 管理员密码记录在 ${SECRETS_FILE}（GRAFANA_ADMIN_PASSWORD）"

# ---------------------------------------------------------------------------
step "6/8 写入配置（Prometheus / Alertmanager / Grafana provisioning）"
# --- Prometheus：从仓库模板渲染，换机器只改变量 ---
sed "s|__INSTANCE_IP__|${IP}|g" "${REPO_ROOT}/monitoring/prometheus/prometheus.yml" \
  >"${PROM_CONF}/prometheus.yml"
rm -f "${PROM_CONF}/rules/"*.yml
cp "${REPO_ROOT}/monitoring/prometheus/rules/"*.yml "${PROM_CONF}/rules/"
chown -R prometheus:prometheus "${PROM_CONF}"
chmod -R 644 "${PROM_CONF}/prometheus.yml" "${PROM_CONF}/rules/"*.yml

# 先用 promtool 校验，别把坏配置推上线（这就是 CI 里该做的事）
/usr/local/bin/promtool check config "${PROM_CONF}/prometheus.yml" || die "Prometheus 配置校验失败"
/usr/local/bin/promtool check rules "${PROM_CONF}/rules/"*.yml >/dev/null || die "告警规则校验失败"
log_ok "promtool 校验通过（配置 + 规则）"

# --- Alertmanager：webhook 指向本机接收器 ---
sed "s|__WEBHOOK_URL__|http://127.0.0.1:5001/webhook|g" \
  "${REPO_ROOT}/monitoring/alertmanager/alertmanager.yml" >"${AM_CONF}/alertmanager.yml"
chown alertmanager:alertmanager "${AM_CONF}/alertmanager.yml"
/usr/local/bin/amtool check-config "${AM_CONF}/alertmanager.yml" || die "Alertmanager 配置校验失败"
log_ok "amtool 校验通过"

# --- Grafana：数据源 + 看板自动加载（不用手点页面）---
ensure_dir /etc/grafana/provisioning/datasources /etc/grafana/provisioning/dashboards
ensure_dir /var/lib/grafana/dashboards
cp "${REPO_ROOT}/monitoring/grafana/provisioning/datasources/prometheus.yml" \
  /etc/grafana/provisioning/datasources/prometheus.yml
cp "${REPO_ROOT}/monitoring/grafana/provisioning/dashboards/default.yml" \
  /etc/grafana/provisioning/dashboards/ops-dashboards.yml
cp "${REPO_ROOT}/monitoring/grafana/dashboards/"*.json /var/lib/grafana/dashboards/
chown -R grafana:grafana /etc/grafana/provisioning /var/lib/grafana/dashboards
chmod -R 640 /var/lib/grafana/dashboards/*.json

# --- webhook 接收器 ---
install -m 0755 -o "${APP_USER}" -g "${APP_USER}" \
  "${REPO_ROOT}/scripts/webhook_receiver.py" "${APP_HOME}/webhook/receiver.py"

# ---------------------------------------------------------------------------
step "7/8 写入 systemd 单元并启动"

cat >/etc/systemd/system/prometheus.service <<'EOF'
[Unit]
Description=Prometheus Server
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=prometheus
Group=prometheus
ExecStart=/usr/local/bin/prometheus \
  --config.file=/etc/prometheus/prometheus.yml \
  --storage.tsdb.path=/var/lib/prometheus \
  --storage.tsdb.retention.time=15d \
  --storage.tsdb.retention.size=8GB \
  --web.console.templates=/opt/prometheus/consoles \
  --web.console.libraries=/opt/prometheus/console_libraries \
  --web.listen-address=0.0.0.0:9090 \
  --web.enable-lifecycle
Restart=always
RestartSec=5
LimitNOFILE=65536
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/prometheus
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/alertmanager.service <<'EOF'
[Unit]
Description=Alertmanager
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=alertmanager
Group=alertmanager
ExecStart=/usr/local/bin/alertmanager \
  --config.file=/etc/alertmanager/alertmanager.yml \
  --storage.path=/var/lib/alertmanager \
  --web.listen-address=0.0.0.0:9093 \
  --cluster.listen-address=
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/alertmanager
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/node_exporter.service <<'EOF'
[Unit]
Description=Prometheus Node Exporter
After=network-online.target

[Service]
Type=simple
User=node_exporter
Group=node_exporter
ExecStart=/usr/local/bin/node_exporter \
  --web.listen-address=127.0.0.1:9100 \
  --collector.textfile.directory=/var/lib/node_exporter/textfile_collector
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/node_exporter
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/mysqld_exporter.service <<'EOF'
[Unit]
Description=Prometheus MySQL Exporter
After=network-online.target mysql.service
Wants=mysql.service

[Service]
Type=simple
User=mysqld_exporter
Group=mysqld_exporter
ExecStart=/usr/local/bin/mysqld_exporter \
  --config.my-cnf=/etc/mysqld_exporter/.my.cnf \
  --web.listen-address=127.0.0.1:9104
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/nginx-prometheus-exporter.service <<'EOF'
[Unit]
Description=Prometheus Nginx Exporter (scrapes stub_status)
After=network-online.target nginx.service
Wants=nginx.service

[Service]
Type=simple
User=nobody
Group=nogroup
ExecStart=/usr/local/bin/nginx-prometheus-exporter \
  --nginx.scrape-uri=http://127.0.0.1:8081/stub_status \
  --web.listen-address=127.0.0.1:9113
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
[Install]
WantedBy=multi-user.target
EOF

cat >/etc/systemd/system/alarm-receiver.service <<'EOF'
[Unit]
Description=Alertmanager Webhook Receiver (opslab)
After=network-online.target

[Service]
Type=simple
User=ops
Group=ops
WorkingDirectory=/opt/ops-platform/webhook
ExecStart=/usr/bin/python3 /opt/ops-platform/webhook/receiver.py
Environment=ALERT_PORT=5001
Environment=ALERT_LOG=/var/log/ops-platform/alerts.log
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/log/ops-platform
[Install]
WantedBy=multi-user.target
EOF

svc_reload_systemd
for s in prometheus alertmanager node_exporter mysqld_exporter nginx-prometheus-exporter alarm-receiver; do
  svc_restart "${s}" || log_warn "${s} 启动失败，继续（稍后统一检查）"
done
systemctl enable --now grafana-server >/dev/null 2>&1 || true
systemctl restart grafana-server
sleep 3
systemctl is-active --quiet grafana-server && log_ok "服务 grafana-server 运行中" || log_warn "grafana-server 未启动"

# ---------------------------------------------------------------------------
step "8/8 端到端验证（每个组件都真发请求）"
wait_http "http://127.0.0.1:9090/-/ready" 60 200 || die "Prometheus 未就绪"
wait_http "http://127.0.0.1:9093/-/ready" 30 200 || log_warn "Alertmanager 未就绪"
wait_http "http://127.0.0.1:5001/healthz" 30 200 || log_warn "告警接收器未就绪"
wait_http "http://127.0.0.1:3000/api/health" 60 200 || log_warn "Grafana 未就绪（首次启动较慢）"

for pair in "node_exporter:9100" "mysqld_exporter:9104" "nginx-prometheus-exporter:9113"; do
  name="${pair%%:*}"; port="${pair##*:}"
  if curl -fsS --max-time 5 "http://127.0.0.1:${port}/metrics" >/dev/null 2>&1; then
    log_ok "${name} 指标端口正常 (${port})"
  else
    log_warn "${name} 指标端口异常 (${port})"
  fi
done

# 看 Prometheus 里 target 是否都 UP —— 这是判断监控"真的在工作"的唯一标准
sleep 10
TARGETS="$(curl -s 'http://127.0.0.1:9090/api/v1/targets?state=active' \
  | python3 -c 'import sys,json;d=json.load(sys.stdin)["data"]["activeTargets"];print("\n".join(f"{t[\"labels\"][\"job\"]:28s} {t[\"health\"]}" for t in d))' 2>/dev/null || true)"
if [[ -n "${TARGETS}" ]]; then
  echo "${TARGETS}"
  if echo "${TARGETS}" | grep -qv ' up$'; then
    log_warn "有 target 不是 up，见上表（刚启动的 exporter 可能还在第一次抓取）"
  fi
fi

banner "05 监控告警部署完成"
cat <<EOF
访问入口：
  Prometheus   http://${IP}:9090
  Alertmanager http://${IP}:9093
  Grafana      http://${IP}:3000   （admin / 见 ${SECRETS_FILE} 的 GRAFANA_ADMIN_PASSWORD）
  Targets 页   http://${IP}:9090/targets
  Alerts  页   http://${IP}:9090/alerts
  Grafana 看板：Dashboards -> Ops Platform -> OpsLink 运维总览

下一步：sudo ./deploy/all_in_one.sh 里已包含备份、巡检的安装；或单独执行
  sudo ./scripts/install_timers.sh   （备份 + 巡检 定时任务）
EOF
