#!/usr/bin/env bash
# =============================================================================
# 04 - Nginx 反向代理 + TLS + 限流 + 结构化日志 + 监控端点
#
# 为什么不是「应用直接对外 8000」：
#   * 静态资源/压缩/TLS 卸载交给 Nginx
#   * 限流（挡刷接口）、连接数控制
#   * JSON 结构化访问日志，才能被 Promtail/Loki、AWStats 之类消费
#   * stub_status 给 nginx-prometheus-exporter 抓取，Nginx 自身也有监控
#
# 用法：sudo ./deploy/install_nginx.sh
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

need_root "$@"
banner "04 Nginx 部署"

step "1/5 安装 Nginx"
apt_install nginx

IP="$(primary_ip)"
LOG_JSON_DIR="/var/log/nginx"

# ---------------------------------------------------------------------------
step "2/5 生成自签证书（换真证书只改两个路径，见 docs/02）"
SSL_DIR=/etc/ssl/opslink
ensure_dir "${SSL_DIR}"
if [[ ! -f "${SSL_DIR}/opslink.crt" ]]; then
  openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
    -keyout "${SSL_DIR}/opslink.key" -out "${SSL_DIR}/opslink.crt" \
    -subj "/C=CN/ST=Shanghai/L=Shanghai/O=OpsPlatform/CN=${IP}" \
    -addext "subjectAltName=IP:${IP},DNS:localhost,IP:127.0.0.1" >/dev/null 2>&1
  chmod 600 "${SSL_DIR}/opslink.key"
  log_ok "自签证书已生成（365 天，CN=${IP}）"
else
  log_ok "证书已存在，跳过生成（剩余 $(openssl x509 -enddate -noout -in ${SSL_DIR}/opslink.crt | cut -d= -f2) 到期）"
fi

# ---------------------------------------------------------------------------
step "3/5 写入站点配置"
cat >/etc/nginx/sites-available/${APP_NAME}.conf <<EOF
# ===================== 限流与缓存区域定义 =====================
# 每秒 20 个请求、burst 40：既能挡住刷接口，又不影响正常压测
limit_req_zone \$binary_remote_addr zone=api_limit:10m rate=20r/s;
# 单 IP 并发连接上限
limit_conn_zone \$binary_remote_addr zone=conn_limit:10m;

# ===================== 日志格式（JSON，方便采集） =====================
log_format ops_json escape=json
  '{"time":"\$time_iso8601","remote_addr":"\$remote_addr","x_forwarded_for":"\$http_x_forwarded_for",'
  '"request":"\$request","status":\$status,"body_bytes":\$body_bytes_sent,'
  '"request_time":\$request_time,"upstream_time":"\$upstream_response_time",'
  '"request_id":"\$http_x_request_id","host":"\$host","user_agent":"\$http_user_agent"}';

upstream ${APP_NAME}_backend {
    server 127.0.0.1:8000;
    keepalive 32;                 # 长连接到后端，省掉每次 TCP 握手
}

# ===================== HTTP：全量跳 HTTPS =====================
server {
    listen 80 default_server;
    listen [::]:80 default_server;
    server_name _;

    # Let's Encrypt 续期验证要用 80 端口，必须放行
    location /.well-known/acme-challenge/ { root /var/www/html; }

    location / { return 301 https://\$host\$request_uri; }
}

# ===================== HTTPS 主站 =====================
server {
    listen 443 ssl http2 default_server;
    listen [::]:443 ssl http2 default_server;
    server_name _;

    ssl_certificate     ${SSL_DIR}/opslink.crt;
    ssl_certificate_key ${SSL_DIR}/opslink.key;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers HIGH:!aNULL:!MD5;
    ssl_session_cache shared:SSL:10m;
    ssl_session_timeout 10m;

    # 安全响应头
    add_header X-Content-Type-Options nosniff always;
    add_header X-Frame-Options SAMEORIGIN always;
    add_header Referrer-Policy strict-origin-when-cross-origin always;
    add_header Strict-Transport-Security "max-age=31536000" always;

    access_log ${LOG_JSON_DIR}/opslink_access.log ops_json;
    error_log  ${LOG_JSON_DIR}/opslink_error.log warn;
    client_max_body_size 2m;
    limit_conn conn_limit 50;

    # 探针：不记访问日志，避免刷日志（K8s/LB 每秒都在打）
    location = /health/live  { access_log off; proxy_pass http://${APP_NAME}_backend; }
    location = /health/ready { access_log off; proxy_pass http://${APP_NAME}_backend; }

    # 业务指标只允许内网抓取
    location = /metrics {
        allow 127.0.0.1;
        allow 192.168.0.0/16;
        allow 10.0.0.0/8;
        deny all;
        proxy_pass http://${APP_NAME}_backend;
    }

    location /api/ {
        limit_req zone=api_limit burst=40 nodelay;
        limit_req_status 429;
        proxy_pass http://${APP_NAME}_backend;
        include /etc/nginx/proxy_params_ops;
    }

    location / {
        proxy_pass http://${APP_NAME}_backend;
        include /etc/nginx/proxy_params_ops;
    }

    # ===== stub_status：给 nginx-prometheus-exporter 抓（只监听本地）=====
    location = /stub_status {
        stub_status;
        access_log off;
        allow 127.0.0.1;
        deny all;
    }
}

# ===================== Nginx 自身指标端口（仅本地） =====================
server {
    listen 127.0.0.1:8081;
    server_name _;
    access_log off;
    location = /stub_status {
        stub_status;
        allow 127.0.0.1;
        deny all;
    }
    location / { return 404; }
}
EOF

cat >/etc/nginx/proxy_params_ops <<'EOF'
proxy_http_version 1.1;
proxy_set_header Host $host;
proxy_set_header X-Real-IP $remote_addr;
proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
proxy_set_header X-Forwarded-Proto $scheme;
proxy_set_header Connection "";
proxy_connect_timeout 5s;
proxy_send_timeout 30s;
proxy_read_timeout 30s;
proxy_next_upstream error timeout http_502 http_503 http_504;
EOF

ln -sfn /etc/nginx/sites-available/${APP_NAME}.conf /etc/nginx/sites-enabled/${APP_NAME}.conf
rm -f /etc/nginx/sites-enabled/default

# ---------------------------------------------------------------------------
step "4/5 校验并重载"
nginx -t || die "Nginx 配置语法错误"
systemctl enable --now nginx >/dev/null 2>&1 || true
systemctl reload nginx
# reload 是异步的：老 worker 处理完在途请求才退出，这里给 1 秒再验证，避免误报
sleep 1
svc_restart_note() { systemctl is-active --quiet nginx && log_ok "Nginx 运行中"; }
svc_restart_note

# ---------------------------------------------------------------------------
step "5/5 验证（HTTP 跳转 / HTTPS 代理 / 限流 / stub_status）"
# 重试几次：首次访问可能落到还没换配置的老 worker 上
code80=""
for _ in 1 2 3 4 5; do
  code80="$(curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1/health/live)"
  [[ "${code80}" == "301" ]] && break
  sleep 1
done
[[ "${code80}" == "301" ]] && log_ok "80 -> 301 跳转正常" || log_warn "80 端口返回 ${code80}（期望 301）"

code443="$(curl -sk -o /dev/null -w '%{http_code}' https://127.0.0.1/health/live)"
[[ "${code443}" == "200" ]] && log_ok "HTTPS 反代应用正常（200）" || die "HTTPS 反代失败：${code443}"

curl -s http://127.0.0.1:8081/stub_status | grep -q 'Active connections' \
  && log_ok "stub_status 正常（monitoring 会抓这个）" || log_warn "stub_status 异常"

banner "04 Nginx 部署完成"
log_info "访问地址：http://${IP}/   https://${IP}/"
log_info "日志：${LOG_JSON_DIR}/opslink_access.log（JSON 格式）"
log_info "下一步：sudo ./deploy/install_monitoring.sh"
