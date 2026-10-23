"""Быстрая проверка сервера: загрузка по частям, библиотека, Range, удаление."""
import os
import sys
import tempfile
from pathlib import Path

tmp = Path(tempfile.mkdtemp())
os.environ.update(APP_PASSWORD="test", MEDIA_DIR=str(tmp / "m"), CACHE_DIR=str(tmp / "c"), UPLOAD_DIR=str(tmp / "u"))
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402
from app.main import app, parse_name  # noqa: E402

c = TestClient(app)
H = {"Authorization": "Bearer test"}


def test_all():
    assert parse_name("Breaking.Bad.S01E02.1080p.mp4") == ("Breaking Bad", 1, 2)
    assert parse_name("Show Name 2x10.mkv") == ("Show Name", 2, 10)
    assert parse_name("random.mp4") == (None, None, None)

    assert c.get("/api/ping").status_code == 401
    assert c.get("/api/ping", headers=H).json()["ok"]
    assert c.get("/").status_code == 200

    data = os.urandom(3_000_000)
    name, total = "Breaking.Bad.S01E02.1080p.mp4", len(data)
    q = f"name={name}&total={total}"
    r = c.put(f"/api/upload/chunk?{q}&offset=0", content=data[:1_000_000], headers=H)
    assert r.json() == {"offset": 1_000_000, "done": False}, r.text
    assert c.get(f"/api/upload/offset?{q}", headers=H).json()["offset"] == 1_000_000
    r = c.put(f"/api/upload/chunk?{q}&offset=0", content=data[:10], headers=H)
    assert r.status_code == 409 and r.json()["offset"] == 1_000_000
    r = c.put(f"/api/upload/chunk?{q}&offset=1000000", content=data[1_000_000:], headers=H)
    assert r.json()["done"] and r.json()["path"] == "Breaking Bad/Season 01/Breaking.Bad.S01E02.1080p.mp4", r.text

    # файл без номера серии, с ручными полями
    r = c.put("/api/upload/chunk?name=clip.mp4&total=5&offset=0&show=Мой сериал&season=2&episode=7", content=b"12345", headers=H)
    assert r.json()["path"] == "Мой сериал/Season 02/Мой сериал S02E07.mp4", r.text

    lib = c.get("/api/library", headers=H).json()
    shows = {s["title"]: s for s in lib["shows"]}
    ep = shows["Breaking Bad"]["seasons"][0]["episodes"][0]
    assert ep["season"] == 1 and ep["episode"] == 2 and ep["size"] == total and ep["ext"] == "mp4"
    assert shows["Мой сериал"]["seasons"][0]["episodes"][0]["episode"] == 7

    full = c.get(f"/api/file/{ep['id']}", headers=H)
    assert full.status_code == 200 and full.content == data
    part = c.get(f"/api/file/{ep['id']}", headers={**H, "Range": "bytes=100-199"})
    assert part.status_code == 206 and part.content == data[100:200]
    assert part.headers["content-range"] == f"bytes 100-199/{total}"
    tail = c.get(f"/api/file/{ep['id']}", headers={**H, "Range": "bytes=-50"})
    assert tail.content == data[-50:]
    assert c.get(f"/api/file/{ep['id']}", headers={**H, "Range": f"bytes={total}-"}).status_code == 416

    assert c.get("/api/file/Li4vLi4vZXRjL3Bhc3N3ZA", headers=H).status_code == 404  # ../../etc/passwd
    assert c.delete(f"/api/file/{ep['id']}", headers=H).json()["ok"]
    titles = [s["title"] for s in c.get("/api/library", headers=H).json()["shows"]]
    assert "Breaking Bad" not in titles
    print("OK")


if __name__ == "__main__":
    test_all()
