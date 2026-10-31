"""接口测试：CI 里跑，保证「改代码不会把线上打挂」这件事有最基本兜底。

注意：这里用 monkeypatch 把 MySQL/Redis 换成内存假实现，
所以测试不依赖真实中间件，CI 里 10 秒内跑完。
"""

from __future__ import annotations

import pymysql
import pytest
from fastapi.testclient import TestClient

import main


class FakeCursor:
    def __init__(self, store):
        self.store = store
        self._rows = []

    def __enter__(self):
        return self

    def __exit__(self, *args):
        return False

    def execute(self, sql, params=()):
        s = " ".join(sql.split()).upper()
        if s.startswith("SELECT 1"):
            self._rows = [(1,)]
        elif s.startswith("INSERT INTO LINKS"):
            code, url = params
            if code in self.store:
                raise pymysql.err.IntegrityError(1062, "dup")
            self.store[code] = {"url": url, "hit": 0, "created_at": "2025-01-01 00:00:00"}
            self._rows = []
        elif s.startswith("UPDATE LINKS SET HIT_COUNT"):
            code = params[0]
            if code not in self.store:
                self.rowcount = 0
                self._rows = []
            else:
                self.store[code]["hit"] += 1
                self.rowcount = 1
                self._rows = []
        elif s.startswith("SELECT URL FROM LINKS"):
            row = self.store.get(params[0])
            self._rows = [(row["url"],)] if row else []
        elif s.startswith("SELECT CODE, URL, HIT_COUNT"):
            row = self.store.get(params[0])
            self._rows = (
                [(params[0], row["url"], row["hit"], row["created_at"])] if row else []
            )
        else:
            self._rows = []
        self.rowcount = getattr(self, "rowcount", 0)

    def fetchone(self):
        return self._rows[0] if self._rows else None

    def close(self):
        pass


class FakeConn:
    def __init__(self, store):
        self.store = store
        self.rowcount = 0

    def cursor(self):
        return FakeCursor(self.store)

    def ping(self, reconnect=True):
        return True

    def close(self):
        pass


@pytest.fixture()
def client(monkeypatch):
    store: dict = {}
    monkeypatch.setattr(main.pool, "get", lambda: FakeConn(store))
    monkeypatch.setattr(main.pool, "put", lambda conn: None)
    # 让 Redis 永远「不可用」，从而强制走数据库回源分支（也就覆盖了降级逻辑）
    monkeypatch.setattr(type(main.cache), "client", property(lambda self: None))
    with TestClient(main.app) as c:
        yield c


def test_health_live(client):
    r = client.get("/health/live")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_health_ready_ok(client):
    r = client.get("/health/ready")
    assert r.status_code == 200
    assert r.json()["checks"]["mysql"] == "ok"


def test_shorten_and_redirect(client):
    r = client.post("/api/shorten", json={"url": "https://example.com/a/very/long/path"})
    assert r.status_code == 200
    code = r.json()["code"]
    assert len(code) == 7

    r2 = client.get(f"/{code}", follow_redirects=False)
    assert r2.status_code == 302
    assert r2.headers["location"] == "https://example.com/a/very/long/path"

    r3 = client.get(f"/api/stats/{code}")
    assert r3.status_code == 200
    assert r3.json()["hit_count"] == 1


def test_shorten_rejects_bad_url(client):
    r = client.post("/api/shorten", json={"url": "not-a-url"})
    assert r.status_code == 400


def test_unknown_code_404(client):
    r = client.get("/doesnotexist")
    assert r.status_code == 404


def test_metrics_uses_route_template(client):
    client.get("/health/live")
    body = client.get("/metrics").text
    assert "opslink_http_requests_total" in body
    # 关键断言：不能把真实路径当 label，否则指标高基数
    assert "/health/live" in body


def test_metrics_content_type_and_request_id(client):
    r = client.get("/health/live")
    assert r.headers["X-Request-Id"]
    m = client.get("/metrics")
    assert m.status_code == 200
    assert m.headers["content-type"].startswith("text/plain")
    assert "opslink_http_request_duration_seconds_bucket" in m.text


def test_request_id_is_passed_through(client):
    r = client.get("/health/live", headers={"X-Request-Id": "trace-me-123"})
    assert r.headers["X-Request-Id"] == "trace-me-123"


def test_stats_unknown_code_404(client):
    assert client.get("/api/stats/nosuchcode").status_code == 404


def test_shorten_rejects_missing_scheme(client):
    # 有长度但不合法的 URL → 业务校验 400
    for bad in ("example.com/x", "ftp://example.com"):
        assert client.post("/api/shorten", json={"url": bad}).status_code == 400
    # 长度本身不合规（空串）由 pydantic 先拦下 → 422，这两种语义要分开
    assert client.post("/api/shorten", json={"url": ""}).status_code == 422


class FakeRedis:
    """只实现代码用到的那几个命令，用来覆盖「缓存命中」分支。"""

    def __init__(self):
        self.data: dict[str, str] = {}
        self.ping_calls = 0

    def ping(self):
        self.ping_calls += 1
        return True

    def get(self, key):
        return self.data.get(key)

    def setex(self, key, ttl, value):
        self.data[key] = value


@pytest.fixture()
def cached_client(monkeypatch):
    """缓存可用、数据库一调用就炸：用来证明「命中缓存时根本不查库」。"""
    store: dict = {}
    fake = FakeRedis()

    def boom(*_a, **_kw):
        raise AssertionError("命中缓存时不应该查数据库")

    monkeypatch.setattr(main.pool, "get", boom)
    monkeypatch.setattr(type(main.cache), "client", property(lambda self: fake))
    with TestClient(main.app) as c:
        yield c, fake, store


def test_cache_hit_avoids_database(cached_client):
    client, fake, _ = cached_client
    fake.data["link:cached1"] = "https://example.com/from-cache"

    r = client.get("/cached1", follow_redirects=False)
    assert r.status_code == 302
    assert r.headers["location"] == "https://example.com/from-cache"

    # 第二次仍然走缓存，且指标里能看到命中计数
    client.get("/cached1", follow_redirects=False)
    body = client.get("/metrics").text
    assert "opslink_cache_hits_total" in body


def test_cache_miss_falls_back_to_database(client):
    # client 这个 fixture 里 Redis 不可用，等于「缓存整体降级」，读接口仍然可用
    r = client.post("/api/shorten", json={"url": "https://example.com/degraded"})
    code = r.json()["code"]
    r2 = client.get(f"/{code}", follow_redirects=False)
    assert r2.status_code == 302
    assert "opslink_cache_misses_total" in client.get("/metrics").text


@pytest.fixture()
def db_down_client(monkeypatch):
    def boom(*_a, **_kw):
        raise RuntimeError("connection refused")

    monkeypatch.setattr(main.pool, "get", boom)
    monkeypatch.setattr(type(main.cache), "client", property(lambda self: None))
    with TestClient(main.app) as c:
        yield c


def test_ready_503_when_mysql_down(db_down_client):
    r = db_down_client.get("/health/ready")
    assert r.status_code == 503
    assert r.json()["checks"]["mysql"].startswith("error:")
    # Redis 不可用只是 degraded，不该让就绪探针失败
    assert r.json()["checks"]["redis"] == "degraded"


def test_dependency_errors_are_503_not_500(db_down_client):
    """依赖挂了要返回 503（运维问题），不能是 500（程序缺陷）。"""
    assert db_down_client.post("/api/shorten", json={"url": "https://example.com/x"}).status_code == 503
    assert db_down_client.get("/anycode", follow_redirects=False).status_code == 503
    assert db_down_client.get("/api/stats/anycode").status_code == 503
    # 存活探针不查依赖，数据库挂了进程也应该是活的
    assert db_down_client.get("/health/live").status_code == 200
