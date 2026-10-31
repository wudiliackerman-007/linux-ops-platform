# Gunicorn 配置：生产上由 systemd 托管，worker 用 uvicorn（ASGI）
# 参数不是拍脑袋的，面试会被问「为什么 4 个 worker」
import multiprocessing
import os

bind = os.getenv("OPSLINK_BIND", "127.0.0.1:8000")

# worker 数经验公式：2 * CPU 核数 + 1。
# 本机 4 vCPU -> 9 个撑不住 1GB 内存，所以这里取 min(公式, 内存约束)，
# 实际压测后定在 4（见 docs/04-故障演练报告.md 的压测章节）。
_cores = multiprocessing.cpu_count()
workers = int(os.getenv("OPSLINK_WORKERS", str(max(2, min(2 * _cores + 1, 8)))))

worker_class = "uvicorn.workers.UvicornWorker"
timeout = 30          # 超过 30s 认为 worker 卡死，直接杀掉重启（防止雪崩）
graceful_timeout = 30 # 优雅退出：等在途请求处理完
keepalive = 5
max_requests = 5000   # 处理 5000 个请求后重启 worker，规避潜在内存泄漏
max_requests_jitter = 500
accesslog = "-"       # 交给 journald 收集
errorlog = "-"
loglevel = os.getenv("OPSLINK_LOG_LEVEL", "info")
access_log_format = (
    '%(h)s %(l)s %(u)s %(t)s "%(r)s" %(s)s %(b)s "%(f)s" "%(a)s" %(L)s'
)
proc_name = "opslink"
