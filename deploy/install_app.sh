#!/usr/bin/env bash
# =============================================================================
# 03 - 业务应用部署（首次安装）
#
# 关键设计（面试点）：
#   * 代码放在 releases/<时间戳>，current 是软链 —— 发布/回滚 = 换软链，秒级
#   * 进程用 systemd 托管，不是 nohup —— 开机自启、崩溃重启、资源限制、日志进 journald
#   * 依赖装在共享 venv 里，不在线上 pip install -r 直接装到系统 python
#   * 装完必须做冒烟测试（能启动 ≠ 能用）
#
# 用法：sudo ./deploy/install_app.sh
# =============================================================================
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/common.sh"

need_root "$@"
banner "03 业务应用部署"
[[ -f "${APP_ENV_FILE}" ]] || die "缺少 ${APP_ENV_FILE}，请先执行 install_middleware.sh"

TS="$(date +%Y%m%d%H%M%S)"
RELEASE_DIR="${APP_RELEASES}/${TS}"

# ---------------------------------------------------------------------------
step "1/6 准备共享 Python 虚拟环境"
if [[ ! -x "${APP_VENV}/bin/python" ]]; then
  python3 -m venv "${APP_VENV}"
  log_ok "已创建 venv：${APP_VENV}"
else
  log_ok "venv 已存在，复用"
fi
# 国内 pip 源：不换源装依赖经常卡在 0%
"${APP_VENV}/bin/pip" install -q --upgrade pip -i https://pypi.tuna.tsinghua.edu.cn/simple
"${APP_VENV}/bin/pip" install -q -r "${REPO_ROOT}/app/requirements.txt" \
  -i https://pypi.tuna.tsinghua.edu.cn/simple
log_ok "依赖安装完成：$("${APP_VENV}/bin/pip" list 2>/dev/null | grep -Ei 'fastapi|gunicorn|pymysql|redis|prometheus-client' | tr '\n' ' ')"

# ---------------------------------------------------------------------------
step "2/6 创建发布目录（releases/${TS}）"
ensure_dir "${RELEASE_DIR}"
rsync -a --delete "${REPO_ROOT}/app/" "${RELEASE_DIR}/app/"
# 测试代码不进生产包
rm -rf "${RELEASE_DIR}/app/tests"
chown -R "${APP_USER}:${APP_USER}" "${RELEASE_DIR}"
log_ok "代码已就位：${RELEASE_DIR}/app"

# ---------------------------------------------------------------------------
step "3/6 写入 systemd 服务单元"
cat >/etc/systemd/system/${APP_NAME}.service <<EOF
[Unit]
Description=opslink 短链服务 (linux-ops-platform)
Documentation=https://github.com/haipeng-li/linux-ops-platform
After=network-online.target mysql.service redis-server.service
Wants=network-online.target

[Service]
Type=simple
User=${APP_USER}
Group=${APP_USER}
WorkingDirectory=${APP_CURRENT}/app
EnvironmentFile=${APP_ENV_FILE}
Environment=PYTHONUNBUFFERED=1
ExecStart=${APP_VENV}/bin/gunicorn \\
    --config ${APP_CURRENT}/app/gunicorn.conf.py \\
    --chdir ${APP_CURRENT}/app \\
    main:app
# 优雅重启：SIGTERM 后等 30s 处理完在途请求（发布时不断连接）
KillSignal=SIGTERM
TimeoutStopSec=35
Restart=always
RestartSec=3
LimitNOFILE=65535
# ---------- 安全加固（就算应用被打穿，损失也有限） ----------
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${LOG_DIR} ${APP_SHARED}
# ---------- 日志进 journald，便于 journalctl -u opslink 直接查 ----------
StandardOutput=journal
StandardError=journal
SyslogIdentifier=${APP_NAME}

[Install]
WantedBy=multi-user.target
EOF

# journald 限制：日志不能把磁盘写满（磁盘满导致的事故太常见）
ensure_dir /etc/systemd/journald.conf.d
cat >/etc/systemd/journald.conf.d/99-ops.conf <<'EOF'
[Journal]
SystemMaxUse=500M
SystemMaxFileSize=50M
MaxRetentionSec=2week
EOF
systemctl restart systemd-journald

# ---------------------------------------------------------------------------
step "4/6 切换软链并启动"
ln -sfn "${RELEASE_DIR}" "${APP_CURRENT}"
chown -h "${APP_USER}:${APP_USER}" "${APP_CURRENT}"
svc_reload_systemd
svc_restart "${APP_NAME}"

# ---------------------------------------------------------------------------
step "5/6 冒烟测试（真实发请求，不是只看进程在不在）"
wait_http "http://127.0.0.1:8000/health/live" 30 200 || die "存活探针失败"
wait_http "http://127.0.0.1:8000/health/ready" 30 200 || die "就绪探针失败（MySQL 连不上？）"

CODE="$(curl -s -X POST http://127.0.0.1:8000/api/shorten \
  -H 'Content-Type: application/json' \
  -d '{"url":"https://www.ubuntu.com/server"}' | jq -r '.code // empty')"
[[ -n "${CODE}" ]] || die "创建短链失败"
LOC="$(curl -s -o /dev/null -w '%{redirect_url}' "http://127.0.0.1:8000/${CODE}")"
[[ "${LOC}" == "https://www.ubuntu.com/server" ]] || die "跳转异常：${LOC}"
log_ok "冒烟测试通过：创建短码 ${CODE} 并成功 302 跳转"

# ---------------------------------------------------------------------------
step "6/6 生成发布记录"
cat >"${APP_CURRENT}/RELEASE" <<EOF
release=${TS}
commit=$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo unknown)
branch=$(git -C "${REPO_ROOT}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)
deploy_at=$(date '+%F %T')
deploy_by=${SUDO_USER:-root}
EOF
log_ok "发布记录："
cat "${APP_CURRENT}/RELEASE"

# 保留最近 5 个版本，防止磁盘被历史版本吃满
mapfile -t OLD < <(ls -1dt "${APP_RELEASES}"/*/ 2>/dev/null | tail -n +6 || true)
for d in "${OLD[@]:-}"; do
  [[ -n "${d}" ]] && rm -rf "${d}" && log_info "清理旧版本：${d}"
done

banner "03 应用部署完成"
log_info "进程状态：$(systemctl is-active ${APP_NAME})  PID：$(systemctl show -p MainPID --value ${APP_NAME})"
log_info "本机访问：curl http://127.0.0.1:8000/health/live"
log_info "下一步：sudo ./deploy/install_nginx.sh"
