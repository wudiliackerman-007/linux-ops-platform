#!/usr/bin/env python3
"""Alertmanager webhook 接收器（教学用最小实现）。

为什么需要它：
  * 告警光在 UI 里红着没用，要有人/系统"收到"。生产用企业微信/钉钉/PagerDuty，
    演练环境用这个接收器最直观：告警一到，终端和日志里立刻能看到。

它做什么：
  * 监听 :5001，接收 POST /webhook（Alertmanager 标准 payload）
  * 把每条告警的一行摘要追加到 /var/log/ops-platform/alerts.log
  * 同时在 stdout 打印（journalctl -u alarm-receiver -f 可以直接看）

安全：只监听 127.0.0.1，不对外暴露；不解析成任意代码，只做 JSON 读取和文本落盘。
"""
import json
import os
import sys
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

LOG_FILE = os.getenv("ALERT_LOG", "/var/log/ops-platform/alerts.log")
BIND = os.getenv("ALERT_BIND", "127.0.0.1")
PORT = int(os.getenv("ALERT_PORT", "5001"))


def short(text: str, limit: int = 200) -> str:
    text = " ".join(str(text).split())
    return text if len(text) <= limit else text[: limit - 3] + "..."


class Handler(BaseHTTPRequestHandler):
    server_version = "opslab-alert-receiver/1.0"

    def log_message(self, fmt, *args):  # 关掉默认的每请求访问日志
        pass

    def _reply(self, code: int, payload: dict):
        body = json.dumps(payload, ensure_ascii=False).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self):  # noqa: N802
        if self.path in ("/healthz", "/"):
            return self._reply(200, {"status": "ok"})
        return self._reply(404, {"error": "not found"})

    def do_POST(self):  # noqa: N802
        if self.path != "/webhook":
            return self._reply(404, {"error": "not found"})
        try:
            length = int(self.headers.get("Content-Length", "0"))
            payload = json.loads(self.rfile.read(length) or b"{}")
        except (ValueError, json.JSONDecodeError) as exc:
            return self._reply(400, {"error": f"bad json: {exc}"})

        now = datetime.now(timezone.utc).astimezone().strftime("%F %T%z")
        alerts = payload.get("alerts") or []
        lines = [f"[{now}] status={payload.get('status')} alerts={len(alerts)}"]
        for a in alerts:
            labels = a.get("labels", {})
            ann = a.get("annotations", {})
            lines.append(
                "  - {status:8s} {name:24s} {sev:8s} {inst:16s} {summary}".format(
                    status=a.get("status", "?"),
                    name=short(labels.get("alertname", "-"), 24),
                    sev=short(labels.get("severity", "-"), 8),
                    inst=short(labels.get("instance", "-"), 16),
                    summary=short(ann.get("summary", "")),
                )
            )

        text = "\n".join(lines)
        print(text, flush=True)
        try:
            with open(LOG_FILE, "a", encoding="utf-8") as fh:
                fh.write(text + "\n")
        except OSError as exc:
            print(f"WARN 写日志失败 {LOG_FILE}: {exc}", file=sys.stderr)

        return self._reply(200, {"status": "received", "count": len(alerts)})


def main() -> None:
    os.makedirs(os.path.dirname(LOG_FILE), exist_ok=True)
    print(f"alert receiver listening on {BIND}:{PORT}, log -> {LOG_FILE}", flush=True)
    ThreadingHTTPServer((BIND, PORT), Handler).serve_forever()


if __name__ == "__main__":
    main()
