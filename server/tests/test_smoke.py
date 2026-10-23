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


class _FakeResp:
    def __init__(self, payload=None, content=b"", headers=None):
        self._payload, self.content, self.headers = payload, content, headers or {}

    def json(self):
        return self._payload

    def raise_for_status(self):
        pass

    def iter_bytes(self, n):
        for i in range(0, len(self.content), n):
            yield self.content[i:i + n]

    def __enter__(self):
        return self

    def __exit__(self, *a):
        return False


def test_archive():
    import time
    import app.main as m

    video = os.urandom(2_500_000)

    def fake_get(path, params=None):
        if path == "/advancedsearch.php":
            query = dict(params)["q"]
            assert "collection:(feature_films" in query and "mediatype:(movies)" in query
            return _FakeResp({"response": {"numFound": 1, "docs": [
                {"identifier": "Nosferatu_1922", "title": "Nosferatu", "year": "1922",
                 "description": "<b>Silent</b> horror", "downloads": 100},
                {"identifier": "bad/../id", "title": "x"}]}})
        if path == "/metadata/Nosferatu_1922":
            return _FakeResp({"metadata": {"title": "Nosferatu", "description": "A &amp; B", "year": "1922"},
                              "files": [{"name": "nosferatu.mp4", "format": "h.264", "size": str(len(video)), "length": "01:34:00"},
                                        {"name": "nosferatu.ogv", "format": "Ogg Video", "size": "5"},
                                        {"name": "nosferatu_512kb.mp4", "format": "512Kb MPEG4", "size": "1000", "length": "5640.5"}]})
        if path.startswith("/services/img/"):
            return _FakeResp(content=b"\xff\xd8fakejpg")
        raise AssertionError(path)

    def fake_stream(path):
        assert path == "/download/Nosferatu_1922/nosferatu.mp4", path
        return None, _FakeResp(content=video, headers={"content-length": str(len(video))})

    m._archive_get, m._archive_stream = fake_get, fake_stream

    r = c.get("/api/archive/search?q=nosferatu", headers=H).json()
    assert [i["id"] for i in r["items"]] == ["Nosferatu_1922"] and r["items"][0]["description"] == "Silent horror"
    assert c.get("/api/archive/search?q=%20", headers=H).status_code == 400

    item = c.get("/api/archive/item/Nosferatu_1922", headers=H).json()
    assert [f["name"] for f in item["files"]] == ["nosferatu.mp4", "nosferatu_512kb.mp4"]
    assert item["files"][0]["length"] == 5640.0 and item["description"] == "A & B"
    assert c.get("/api/archive/item/..%2Fetc", headers=H).status_code == 404

    r = c.post("/api/archive/download", headers=H, json={
        "identifier": "Nosferatu_1922", "title": "Nosferatu", "files": ["nosferatu.mp4"],
        "sizes": [len(video)], "description": "Silent horror"})
    job = r.json()["jobs"][0]
    assert job["episode"] == 1 and job["state"] == "queued", r.text
    for _ in range(100):
        jobs = c.get("/api/archive/jobs", headers=H).json()["jobs"]
        state = next(j for j in jobs if j["id"] == job["id"])["state"]
        if state in ("done", "error"):
            break
        time.sleep(0.05)
    assert state == "done", jobs

    lib = {s["title"]: s for s in c.get("/api/library", headers=H).json()["shows"]}
    show = lib["Nosferatu"]
    assert show["overview"] == "Silent horror" and show["hasPoster"]
    ep = show["seasons"][0]["episodes"][0]
    assert ep["episode"] == 1 and ep["size"] == len(video)
    assert c.get(f"/api/file/{ep['id']}", headers=H).content == video

    # повторная загрузка того же фильма становится следующей серией, а не затирает файл
    r = c.post("/api/archive/download", headers=H, json={
        "identifier": "Nosferatu_1922", "title": "Nosferatu", "files": ["nosferatu.mp4"]})
    assert r.json()["jobs"][0]["episode"] == 2
    print("archive OK")


if __name__ == "__main__":
    test_all()
    test_archive()
