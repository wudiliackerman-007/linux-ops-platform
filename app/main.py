"""
opslink —— 短链服务（用于承载运维体系的业务演示服务）

设计要点（运维视角，不是业务视角）：
1. 自带 /health/live 与 /health/ready 两个探针，区分「进程活着」和「依赖可用」；
2. 自带 /metrics（Prometheus 文本格式），暴露请求量、延迟、错误、缓存命中；
3. 依赖 MySQL（持久化）+ Redis（缓存），故意让缓存挂掉时接口仍可用（降级）；
4. 所有配置走环境变量，方便不同环境/灰度发布。
"""

from __future__ import annotations

import logging
import os
import random
import string
import time
from contextlib import asynccontextmanager
from typing import Any

import pymysql
import redis
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse, RedirectResponse, Response
from prometheus_client import (
    CONTENT_TYPE_LATEST,
    CollectorRegistry,
    Counter,
    Gauge,
    Histogram,
    generate_latest,
)
from pydantic import BaseModel, Field

# --------------------------------------------------------------------------- #
# 配置（全部来自环境变量，systemd 的 EnvironmentFile 注入）
# --------------------------------------------------------------------------- #
MYSQL_HOST = os.getenv("OPSLINK_MYSQL_HOST", "127.0.0.1")
MYSQL_PORT = int(os.getenv("OPSLINK_MYSQL_PORT", "3306"))
MYSQL_USER = os.getenv("OPSLINK_MYSQL_USER", "opslink")
MYSQL_PASSWORD = os.getenv("OPSLINK_MYSQL_PASSWORD", "")
MYSQL_DB = os.getenv("OPSLINK_MYSQL_DB", "opslink")

REDIS_HOST = os.getenv("OPSLINK_REDIS_HOST", "127.0.0.1")
REDIS_PORT = int(os.getenv("OPSLINK_REDIS_PORT", "6379"))
REDIS_PASSWORD = os.getenv("OPSLINK_REDIS_PASSWORD", "")
REDIS_DB = int(os.getenv("OPSLINK_REDIS_DB", "0"))
CACHE_TTL = int(os.getenv("OPSLINK_CACHE_TTL", "3600"))

SHORT_CODE_LEN = int(os.getenv("OPSLINK_CODE_LEN", "7"))
BASE_DOMAIN = os.getenv("OPSLINK_BASE_DOMAIN", "opslink.local")

# 日志走 stdout，由 systemd 收进 journald（统一日志入口，不用自己写日志文件）
logging.basicConfig(
    level=os.getenv("OPSLINK_LOG_LEVEL", "INFO"),
    format="%(asctime)s %(levelname)s [%(name)s] %(message)s",
)
LOGGER = logging.getLogger("opslink")

# --------------------------------------------------------------------------- #
# Prometheus 指标（业务指标，与 node_exporter 的系统指标互补）
# --------------------------------------------------------------------------- #
REGISTRY = CollectorRegistry()

HTTP_REQUESTS = Counter(
    "opslink_http_requests_total",
    "HTTP 请求总数",
    ["method", "path", "status"],
    registry=REGISTRY,
)
HTTP_LATENCY = Histogram(
    "opslink_http_request_duration_seconds",
    "HTTP 请求耗时",
    ["method", "path"],
    buckets=(0.005, 0.01, 0.025, 0.05, 0.1, 0.25, 0.5, 1, 2.5, 5, 10),
    registry=REGISTRY,
)
LINKS_CREATED = Counter("opslink_links_created_total", "创建的短链总数", registry=REGISTRY)
CACHE_HITS = Counter("opslink_cache_hits_total", "短链解析命中缓存次数", registry=REGISTRY)
CACHE_MISSES = Counter("opslink_cache_misses_total", "短链解析未命中缓存次数", registry=REGISTRY)
DEPENDENCY_UP = Gauge(
    "opslink_dependency_up",
    "依赖可用性 1=正常 0=异常",
    ["dependency"],
    registry=REGISTRY,
)


# --------------------------------------------------------------------------- #
# 极简连接池：把「每次请求新建连接」换成「复用少量连接」，避免压测时打满 MySQL
# --------------------------------------------------------------------------- #
class MySQLPool:
    def __init__(self, size: int = 8) -> None:
        self.size = size
        self._conns: list[pymysql.connections.Connection] = []

    def _new(self) -> pymysql.connections.Connection:
        return pymysql.connect(
            host=MYSQL_HOST,
            port=MYSQL_PORT,
            user=MYSQL_USER,
            password=MYSQL_PASSWORD,
            database=MYSQL_DB,
            charset="utf8mb4",
            autocommit=True,
            connect_timeout=3,
            read_timeout=5,
            write_timeout=5,
        )

    def get(self) -> pymysql.connections.Connection:
        while self._conns:
            conn = self._conns.pop()
            try:
                conn.ping(reconnect=True)
                return conn
            except Exception:  # noqa: BLE001  连接已失效，丢弃
                continue
        return self._new()

    def put(self, conn: pymysql.connections.Connection, broken: bool = False) -> None:
        if broken:
            self._close(conn)
            return
        if len(self._conns) < self.size:
            self._conns.append(conn)
        else:
            self._close(conn)

    @staticmethod
    def _close(conn: pymysql.connections.Connection) -> None:
        try:
            conn.close()
        except Exception:  # noqa: BLE001
            pass

    def close_all(self) -> None:
        while self._conns:
            self._close(self._conns.pop())


class RedisCache:
    """Redis 不可用时自动降级为「无缓存」，保证读接口不被缓存故障拖死。"""

    def __init__(self) -> None:
        self._client: redis.Redis | None = None

    @property
    def client(self) -> redis.Redis | None:
        if self._client is None:
            try:
                client = redis.Redis(
                    host=REDIS_HOST,
                    port=REDIS_PORT,
                    password=REDIS_PASSWORD or None,
                    db=REDIS_DB,
                    socket_connect_timeout=1,
                    socket_timeout=1,
                    decode_responses=True,
                )
                client.ping()
                self._client = client
            except Exception:  # noqa: BLE001
                return None
        return self._client

    def reset(self) -> None:
        self._client = None


pool = MySQLPool()
cache = RedisCache()


# --------------------------------------------------------------------------- #
# 生命周期
# --------------------------------------------------------------------------- #
@asynccontextmanager
async def lifespan(_: FastAPI):
    yield
    pool.close_all()


app = FastAPI(title="opslink", version="1.0.0", lifespan=lifespan)


# --------------------------------------------------------------------------- #
# 中间件：统一记录请求量/延迟/状态码 + 注入 X-Request-Id（便于日志串联）
# --------------------------------------------------------------------------- #
@app.middleware("http")
async def metrics_middleware(request: Request, call_next):
    start = time.perf_counter()
    # 给每个请求打上唯一 id，Nginx access_log 与应用日志都带上，排查时能对上
    request_id = request.headers.get("X-Request-Id") or "".join(
        random.choices(string.ascii_lowercase + string.digits, k=12)
    )

    def route_path() -> str:
        # 关键：指标 label 必须用「路由模板」而不是真实 URL。
        # 否则 /{code} 会把每个短码变成一个 label，直接把 Prometheus 撑爆（高基数）
        route = request.scope.get("route")
        return getattr(route, "path", "unmatched")

    try:
        response = await call_next(request)
    except Exception:  # noqa: BLE001  未捕获异常也要计数，否则 5xx 告警失效
        HTTP_REQUESTS.labels(request.method, route_path(), "500").inc()
        raise
    elapsed = time.perf_counter() - start
    status = str(response.status_code)
    path = route_path()
    HTTP_REQUESTS.labels(request.method, path, status).inc()
    HTTP_LATENCY.labels(request.method, path).observe(elapsed)
    response.headers["X-Request-Id"] = request_id
    return response


# --------------------------------------------------------------------------- #
# 数据模型
# --------------------------------------------------------------------------- #
class ShortenRequest(BaseModel):
    url: str = Field(..., min_length=4, max_length=2048)


class ShortenResponse(BaseModel):
    code: str
    short_url: str


class StatsResponse(BaseModel):
    code: str
    url: str
    hit_count: int
    created_at: str


# --------------------------------------------------------------------------- #
# 工具函数
# --------------------------------------------------------------------------- #
def _gen_code() -> str:
    alphabet = string.ascii_letters + string.digits
    return "".join(random.choices(alphabet, k=SHORT_CODE_LEN))


def _db_call(fn):
    """统一的连接获取/归还，异常时把坏连接丢弃。

    DB 不可用时抛 503 而不是 500：这是「依赖不可用」，不是「代码有 bug」，
    监控和调用方据此能区分是运维问题还是程序缺陷。
    """
    try:
        conn = pool.get()
    except Exception:  # noqa: BLE001  连不上数据库（服务没起 / 端口不通）
        LOGGER.exception("获取数据库连接失败")
        raise HTTPException(status_code=503, detail="数据库暂时不可用，请稍后重试") from None
    try:
        result = fn(conn)
    except HTTPException:
        pool.put(conn)
        raise
    except Exception:  # noqa: BLE001
        LOGGER.exception("数据库操作失败")
        pool.put(conn, broken=True)
        raise HTTPException(status_code=503, detail="数据库暂时不可用，请稍后重试") from None
    pool.put(conn)
    return result


# --------------------------------------------------------------------------- #
# 路由：健康检查（K8s / Nginx / 巡检脚本都会调用）
# --------------------------------------------------------------------------- #
@app.get("/health/live", include_in_schema=False)
def health_live() -> dict[str, Any]:
    """存活探针：只看进程本身，不查依赖。依赖挂了不该重启进程。"""
    return {"status": "ok", "service": "opslink"}


@app.get("/health/ready", include_in_schema=False)
def health_ready() -> JSONResponse:
    """就绪探针：依赖不可用返回 503，让调用方（发布脚本/负载均衡）摘流量。"""
    details: dict[str, Any] = {"status": "ok", "checks": {}}
    ok = True

    try:
        def ping_db(conn):
            with conn.cursor() as cur:
                cur.execute("SELECT 1")
                return cur.fetchone()

        _db_call(ping_db)
        details["checks"]["mysql"] = "ok"
        DEPENDENCY_UP.labels("mysql").set(1)
    except Exception as exc:  # noqa: BLE001
        ok = False
        # 把 HTTPException 的 detail 带出来，值班的人一眼知道是「连不上」还是「SQL 出错」，
        # 而不是看到一个光秃秃的异常类名
        reason = getattr(exc, "detail", None) or exc.__class__.__name__
        details["checks"]["mysql"] = f"error: {reason}"
        DEPENDENCY_UP.labels("mysql").set(0)

    if cache.client is not None:
        details["checks"]["redis"] = "ok"
        DEPENDENCY_UP.labels("redis").set(1)
    else:
        # Redis 只是缓存，降级可用，所以不算「不就绪」
        details["checks"]["redis"] = "degraded"
        DEPENDENCY_UP.labels("redis").set(0)

    return JSONResponse(status_code=200 if ok else 503, content=details)


# --------------------------------------------------------------------------- #
# 路由：业务
# --------------------------------------------------------------------------- #
@app.post("/api/shorten", response_model=ShortenResponse)
def shorten(payload: ShortenRequest) -> ShortenResponse:
    target = payload.url.strip()
    if not target.startswith(("http://", "https://")):
        raise HTTPException(status_code=400, detail="url 必须以 http:// 或 https:// 开头")

    def insert(conn):
        with conn.cursor() as cur:
            for _ in range(5):  # 短码冲突重试
                code = _gen_code()
                try:
                    cur.execute(
                        "INSERT INTO links(code, url, created_at) VALUES(%s, %s, NOW())",
                        (code, target),
                    )
                    return code
                except pymysql.err.IntegrityError:
                    continue
            raise RuntimeError("短码生成冲突，请重试")

    code = _db_call(insert)
    LINKS_CREATED.inc()

    client = cache.client
    if client is not None:
        try:
            client.setex(f"link:{code}", CACHE_TTL, target)
        except Exception:  # noqa: BLE001
            cache.reset()

    return ShortenResponse(code=code, short_url=f"http://{BASE_DOMAIN}/{code}")


@app.get("/api/stats/{code}", response_model=StatsResponse)
def stats(code: str) -> StatsResponse:
    def query(conn):
        with conn.cursor() as cur:
            cur.execute(
                "SELECT code, url, hit_count, created_at FROM links WHERE code = %s", (code,)
            )
            return cur.fetchone()

    row = _db_call(query)
    if not row:
        raise HTTPException(status_code=404, detail="短链不存在")
    return StatsResponse(
        code=row[0], url=row[1], hit_count=int(row[2]), created_at=str(row[3])
    )


# --------------------------------------------------------------------------- #
# 路由：指标
# --------------------------------------------------------------------------- #
@app.get("/metrics", include_in_schema=False)
def metrics() -> Response:
    return Response(generate_latest(REGISTRY), media_type=CONTENT_TYPE_LATEST)


# --------------------------------------------------------------------------- #
# 路由：短链跳转（必须最后注册）
# 说明：/{code} 只匹配单个路径段，会吃掉 /metrics 这类单段路由，
#       因此这个兜底路由一定要放在所有固定路径路由之后。
# --------------------------------------------------------------------------- #
@app.get("/{code}", include_in_schema=False)
def redirect(code: str):
    # 1) 先查缓存
    client = cache.client
    if client is not None:
        try:
            cached = client.get(f"link:{code}")
            if cached:
                CACHE_HITS.inc()
                return RedirectResponse(url=cached, status_code=302)
            CACHE_MISSES.inc()
        except Exception:  # noqa: BLE001
            cache.reset()

    # 2) 回源数据库 + 回填缓存
    def query(conn):
        with conn.cursor() as cur:
            cur.execute("UPDATE links SET hit_count = hit_count + 1 WHERE code = %s", (code,))
            if cur.rowcount == 0:
                return None
            cur.execute("SELECT url FROM links WHERE code = %s", (code,))
            row = cur.fetchone()
            return row[0] if row else None

    url = _db_call(query)
    if not url:
        raise HTTPException(status_code=404, detail="短链不存在")

    if client is not None:
        try:
            client.setex(f"link:{code}", CACHE_TTL, url)
        except Exception:  # noqa: BLE001
            cache.reset()

    return RedirectResponse(url=url, status_code=302)
