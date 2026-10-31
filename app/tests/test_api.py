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
