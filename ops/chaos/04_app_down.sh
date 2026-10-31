#!/usr/bin/env bash
# =============================================================================
# 故障演练 04：应用挂掉 / 应用崩溃
#
# 两种模式，讲的东西完全不同：
#   crash  —— kill -9 主进程：systemd 3 秒内自动拉起，用户几乎无感（要讲 Restart=always）
#   stop   —— systemctl stop：服务真的没了，Nginx 返回 502，1 分钟后 AppDown 告警
#
# 用法：sudo ops/chaos/04_app_down.sh [crash|stop] [秒数]
# =============================================================================
set -euo pipefail

MODE="${1:-crash}"
DURATION="${2:-90}"
[[ ${EUID} -eq 0 ]] || { echo "请用 root 执行：sudo $0 [crash|stop] [秒数]"; exit 1; }

case "${MODE}" in
  crash)
    cat <<EOF
[演练] 故障：kill -9 应用主进程
[演练] 预期结果：systemd 自动重启（Restart=always, RestartSec=3），
        如果你没盯着看，可能连告警都不会触发 —— 这正是我们要的效果。
[演练] 观察方式：
        watch -n1 'systemctl status opslink --no-pager | head -5'
        journalctl -u opslink -n 30 --no-pager     # 能看到 "Stopped" / "Started" 记录
EOF
    PID="$(systemctl show -p MainPID --value opslink)"
    echo "[演练] 当前主进程 PID=${PID}，执行 kill -9"
    T0="$(date +%s)"
    kill -9 "${PID}" || true
    for _ in $(seq 1 30); do
      sleep 1
      NEWPID="$(systemctl show -p MainPID --value opslink)"
      if [[ -n "${NEWPID}" && "${NEWPID}" != "0" && "${NEWPID}" != "${PID}" ]] \
         && curl -fsS --max-time 2 http://127.0.0.1:8000/health/live >/dev/null 2>&1; then
        echo "[演练] ✅ 已自动恢复：新 PID=${NEWPID}，耗时 $(($(date +%s) - T0))s"
        echo "[演练] 这说明：单进程崩溃不等于服务中断，前提是 systemd 托管 + 健康检查探针"
        exit 0
      fi
    done
    echo "[演练] ❌ 30s 内没有恢复，请检查：journalctl -u opslink -n 50"
    exit 1
    ;;
  stop)
    cat <<EOF
[演练] 故障：停止应用 ${DURATION}s
[演练] 预期告警：AppDown（critical，1 分钟）；Nginx 访问会 502
[演练] 观察方式：
        curl -sk -o /dev/null -w '%{http_code}\\n' https://127.0.0.1/health/live
        tail -f /var/log/nginx/opslink_error.log
        http://<IP>:9090/alerts
EOF
    restore() {
      local rc=$?
      echo
      echo "[演练] 启动应用..."
      systemctl start opslink
      for _ in $(seq 1 30); do
        curl -fsS --max-time 2 http://127.0.0.1:8000/health/ready >/dev/null 2>&1 && break
        sleep 1
      done
      if curl -fsS --max-time 3 https://127.0.0.1/health/live >/dev/null 2>&1; then
        echo "[演练] 服务已恢复"
      else
        echo "[演练] WARN 服务未恢复，检查 journalctl -u opslink -n 50"
      fi
      exit "${rc}"
    }
    trap restore EXIT INT TERM
    systemctl stop opslink
    echo "[演练] 应用已停止"
    curl -sk -o /dev/null -w '  Nginx -> 应用状态码：%{http_code}\n' https://127.0.0.1/health/live || true
    sleep "${DURATION}"
    ;;
  *)
    echo "用法：$0 [crash|stop] [秒数]"; exit 1;;
esac
