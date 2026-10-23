"""Личный сервер для сериалов: загрузка через браузер, библиотека, раздача файлов на айфон."""
import base64
import email.utils
import hashlib
import hmac
import json
import os
import re
import shutil
import threading
import time
from pathlib import Path
from typing import Optional

import httpx
from fastapi import Depends, FastAPI, Header, HTTPException, Query, Request
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse

MEDIA = Path(os.environ.get("MEDIA_DIR", "/data/media"))
CACHE = Path(os.environ.get("CACHE_DIR", "/data/cache"))
UPLOADS = Path(os.environ.get("UPLOAD_DIR", "/data/uploads"))
PASSWORD = os.environ.get("APP_PASSWORD", "")
TMDB_KEY = os.environ.get("TMDB_KEY", "").strip()

VIDEO_EXT = {".mp4", ".m4v", ".mov", ".mkv"}
MIME = {
    ".mp4": "video/mp4",
    ".m4v": "video/x-m4v",
    ".mov": "video/quicktime",
    ".mkv": "video/x-matroska",
}
STATIC = Path(__file__).parent / "static"

for _d in (MEDIA, CACHE / "meta", CACHE / "posters", UPLOADS):
    _d.mkdir(parents=True, exist_ok=True)

if not PASSWORD:
    raise RuntimeError("APP_PASSWORD не задан")

app = FastAPI(docs_url=None, redoc_url=None, openapi_url=None)


# ---------- авторизация ----------

def auth(authorization: Optional[str] = Header(None), token: Optional[str] = Query(None)):
    supplied = token or ""
    if authorization and authorization.startswith("Bearer "):
        supplied = authorization[7:]
    if not supplied or not hmac.compare_digest(supplied.encode(), PASSWORD.encode()):
        time.sleep(0.5)
        raise HTTPException(401, "Неверный пароль")


# ---------- утилиты ----------

def enc(s: str) -> str:
    return base64.urlsafe_b64encode(s.encode()).decode().rstrip("=")


def dec(s: str) -> str:
    try:
        return base64.urlsafe_b64decode(s + "=" * (-len(s) % 4)).decode()
    except Exception:
        raise HTTPException(404, "Не найдено")


def key(name: str) -> str:
    return hashlib.sha1(name.encode()).hexdigest()


def media_path(rel: str) -> Path:
    p = (MEDIA / rel).resolve()
    root = MEDIA.resolve()
    if root != p and root not in p.parents:
        raise HTTPException(404, "Не найдено")
    return p


def sanitize(s: str) -> str:
    s = re.sub(r'[\\/:*?"<>|\x00-\x1f]', "", s or "").strip().strip(".").strip()
    return s[:120]


def clean_title(s: str) -> str:
    s = re.sub(r"[._]+", " ", s)
    s = re.sub(r"\s+", " ", s)
    return s.strip(" -[]()")


EP_PATTERNS = [
    re.compile(r"(?i)^(?P<show>.*?)[\s._\-\[\(]*s(?P<s>\d{1,2})[\s._\-]*e(?P<e>\d{1,3})"),
    re.compile(r"(?i)^(?P<show>.*?)[\s._\-\[\(]*(?P<s>\d{1,2})x(?P<e>\d{1,3})(?!\d)"),
]


def parse_name(name: str):
    """Возвращает (сериал, сезон, серия) из имени файла вида Show.Name.S01E05.mp4."""
    stem = Path(name).stem
    for rx in EP_PATTERNS:
        m = rx.search(stem)
        if m:
            return clean_title(m.group("show")) or None, int(m.group("s")), int(m.group("e"))
    return None, None, None


def disk_info():
    u = shutil.disk_usage(MEDIA)
    return {"total": u.total, "used": u.used, "free": u.free}


def load_meta(show_name: str) -> dict:
    mf = CACHE / "meta" / f"{key(show_name)}.json"
    if mf.exists():
        try:
            return json.loads(mf.read_text())
        except Exception:
            return {}
    return {}


# ---------- библиотека ----------

def collect_files(show_dir: Path):
    """[(сезон, серия|None, файл)] для одного сериала."""
    out = []
    for f in show_dir.rglob("*"):
        if not f.is_file() or f.suffix.lower() not in VIDEO_EXT:
            continue
        _, s, e = parse_name(f.name)
        if s is None:
            m = re.search(r"(\d+)", f.parent.name) if f.parent != show_dir else None
            s = int(m.group(1)) if m else 1
        out.append((s, e, f))
    return out


def scan():
    shows = []
    for show_dir in sorted((p for p in MEDIA.iterdir() if p.is_dir()), key=lambda p: p.name.lower()):
        files = collect_files(show_dir)
        if not files:
            continue
        meta = load_meta(show_dir.name)
        titles = meta.get("episodes", {})
        show_title = meta.get("name") or show_dir.name
        show_id = enc(show_dir.name)
        seasons = {}
        for s, e, f in files:
            seasons.setdefault(s, []).append((e, f))
        out_seasons = []
        for s in sorted(seasons):
            items = sorted(seasons[s], key=lambda x: (x[0] is None, x[0] or 0, x[1].name.lower()))
            eps = []
            used = set()
            for i, (e, f) in enumerate(items):
                num = e if e is not None else i + 1
                while e is None and num in used:
                    num += 1
                used.add(num)
                eps.append({
                    "id": enc(f.relative_to(MEDIA).as_posix()),
                    "showId": show_id,
                    "showTitle": show_title,
                    "season": s,
                    "episode": num,
                    "title": titles.get(f"{s}-{num}", "") or "",
                    "size": f.stat().st_size,
                    "ext": f.suffix.lower().lstrip("."),
                })
            out_seasons.append({"number": s, "episodes": eps})
        shows.append({
            "id": show_id,
            "title": show_title,
            "folder": show_dir.name,
            "overview": meta.get("overview") or "",
            "hasPoster": (CACHE / "posters" / f"{key(show_dir.name)}.jpg").exists(),
            "seasons": out_seasons,
        })
    return shows


# ---------- TMDB (постеры и названия) ----------

_meta_lock = threading.Lock()
_meta_running = False


def refresh_meta_async():
    global _meta_running
    if not TMDB_KEY:
        return
    with _meta_lock:
        if _meta_running:
            return
        _meta_running = True
    threading.Thread(target=_refresh_meta, daemon=True).start()


def _tmdb(client: httpx.Client, path: str, **params):
    params = {"language": "ru-RU", **params}
    headers = {}
    if len(TMDB_KEY) > 40:  # токен v4
        headers["Authorization"] = f"Bearer {TMDB_KEY}"
    else:
        params["api_key"] = TMDB_KEY
    r = client.get(f"https://api.themoviedb.org/3{path}", params=params, headers=headers, timeout=15)
    r.raise_for_status()
    return r.json()


def _refresh_meta():
    global _meta_running
    try:
        with httpx.Client() as c:
            for show_dir in list(MEDIA.iterdir()):
                if not show_dir.is_dir():
                    continue
                k = key(show_dir.name)
                mf = CACHE / "meta" / f"{k}.json"
                meta = load_meta(show_dir.name) if mf.exists() else None
                try:
                    if meta is None:
                        query, year = show_dir.name, None
                        m = re.search(r"\s*\(?((?:19|20)\d{2})\)?\s*$", query)
                        if m:
                            year, query = m.group(1), query[: m.start()].strip()
                        params = {"query": query}
                        if year:
                            params["first_air_date_year"] = year
                        results = _tmdb(c, "/search/tv", **params).get("results") or []
                        if not results:
                            mf.write_text(json.dumps({"tmdbId": None}))
                            continue
                        t = results[0]
                        meta = {
                            "tmdbId": t["id"],
                            "name": t.get("name"),
                            "overview": t.get("overview"),
                            "episodes": {},
                            "seasonsFetched": [],
                        }
                        if t.get("poster_path"):
                            img = c.get(f"https://image.tmdb.org/t/p/w500{t['poster_path']}", timeout=30)
                            if img.status_code == 200:
                                (CACHE / "posters" / f"{k}.jpg").write_bytes(img.content)
                    if meta.get("tmdbId"):
                        present = {s for s, _, _ in collect_files(show_dir)}
                        for s in sorted(present - set(meta.get("seasonsFetched", []))):
                            try:
                                data = _tmdb(c, f"/tv/{meta['tmdbId']}/season/{s}")
                                for e in data.get("episodes", []):
                                    meta.setdefault("episodes", {})[f"{s}-{e['episode_number']}"] = e.get("name") or ""
                            except Exception:
                                pass
                            meta.setdefault("seasonsFetched", []).append(s)
                    mf.write_text(json.dumps(meta, ensure_ascii=False))
                except Exception as ex:
                    print("TMDB:", show_dir.name, ex, flush=True)
    finally:
        _meta_running = False


# ---------- раздача файлов с поддержкой Range ----------

def _iter_file(path: Path, start: int, end: int, chunk: int = 1024 * 1024):
    with open(path, "rb") as f:
        f.seek(start)
        remaining = end - start + 1
        while remaining > 0:
            data = f.read(min(chunk, remaining))
            if not data:
                break
            remaining -= len(data)
            yield data


def file_response(path: Path, request: Request):
    st = path.stat()
    size = st.st_size
    etag = f'"{int(st.st_mtime)}-{size}"'
    last_mod = email.utils.formatdate(st.st_mtime, usegmt=True)
    headers = {
        "Accept-Ranges": "bytes",
        "ETag": etag,
        "Last-Modified": last_mod,
        "Content-Type": MIME.get(path.suffix.lower(), "application/octet-stream"),
    }
    rng = request.headers.get("range")
    if_range = request.headers.get("if-range")
    if rng and (not if_range or if_range in (etag, last_mod)):
        m = re.match(r"bytes=(\d*)-(\d*)$", rng.strip())
        if m and (m.group(1) or m.group(2)):
            s, e = m.groups()
            if s == "":
                start, end = max(0, size - int(e)), size - 1
            else:
                start = int(s)
                end = min(int(e), size - 1) if e else size - 1
            if start >= size or start > end:
                return Response(status_code=416, headers={"Content-Range": f"bytes */{size}"})
            headers["Content-Range"] = f"bytes {start}-{end}/{size}"
            headers["Content-Length"] = str(end - start + 1)
            return StreamingResponse(_iter_file(path, start, end), status_code=206, headers=headers)
    headers["Content-Length"] = str(size)
    return StreamingResponse(_iter_file(path, 0, size - 1), headers=headers)


# ---------- размещение загруженных файлов ----------

def place(name: str, show: str, season: int, episode: int) -> Path:
    p_show, p_season, p_ep = parse_name(name)
    show = sanitize(show) or sanitize(p_show or "") or "Разное"
    s = season or p_season or 1
    folder = MEDIA / show / f"Season {s:02d}"
    folder.mkdir(parents=True, exist_ok=True)
    suffix = Path(name).suffix.lower()
    fname = sanitize(Path(name).name) or f"video{suffix}"
    if episode and (p_ep != episode or p_season not in (None, s)):
        fname = f"{show} S{s:02d}E{episode:02d}{suffix}"
    dest = folder / fname
    i = 1
    while dest.exists():
        dest = folder / f"{Path(fname).stem} ({i}){suffix}"
        i += 1
    return dest


def _upload_part(name: str, total: int) -> Path:
    return UPLOADS / f"{hashlib.sha1(f'{name}|{total}'.encode()).hexdigest()}.part"


def _cleanup_parts():
    week = time.time() - 7 * 86400
    for p in UPLOADS.glob("*.part"):
        try:
            if p.stat().st_mtime < week:
                p.unlink()
        except OSError:
            pass


_cleanup_parts()


# ---------- маршруты ----------

@app.get("/")
def index():
    return FileResponse(STATIC / "index.html", media_type="text/html")


@app.get("/api/ping", dependencies=[Depends(auth)])
def ping():
    return {"ok": True, "tmdb": bool(TMDB_KEY), "disk": disk_info()}


@app.get("/api/library", dependencies=[Depends(auth)])
def library():
    refresh_meta_async()
    return {"shows": scan(), "disk": disk_info()}


@app.get("/api/poster/{show_id}", dependencies=[Depends(auth)])
def poster(show_id: str):
    p = CACHE / "posters" / f"{key(dec(show_id))}.jpg"
    if not p.exists():
        raise HTTPException(404, "Нет постера")
    return FileResponse(p, media_type="image/jpeg")


@app.get("/api/file/{file_id}", dependencies=[Depends(auth)])
def get_file(file_id: str, request: Request):
    p = media_path(dec(file_id))
    if not p.is_file():
        raise HTTPException(404, "Файл не найден")
    return file_response(p, request)


@app.delete("/api/file/{file_id}", dependencies=[Depends(auth)])
def delete_file(file_id: str):
    p = media_path(dec(file_id))
    if not p.is_file():
        raise HTTPException(404, "Файл не найден")
    p.unlink()
    parent = p.parent
    while parent != MEDIA.resolve() and parent != MEDIA and not any(parent.iterdir()):
        parent.rmdir()
        parent = parent.parent
    return {"ok": True, "disk": disk_info()}


@app.delete("/api/show/{show_id}", dependencies=[Depends(auth)])
def delete_show(show_id: str):
    name = dec(show_id)
    p = media_path(name)
    if not p.is_dir() or p == MEDIA.resolve():
        raise HTTPException(404, "Сериал не найден")
    shutil.rmtree(p)
    return {"ok": True, "disk": disk_info()}


@app.get("/api/upload/offset", dependencies=[Depends(auth)])
def upload_offset(name: str, total: int):
    p = _upload_part(name, total)
    return {"offset": p.stat().st_size if p.exists() else 0}


@app.put("/api/upload/chunk", dependencies=[Depends(auth)])
async def upload_chunk(request: Request, name: str, total: int, offset: int,
                       show: str = "", season: int = 0, episode: int = 0):
    if Path(name).suffix.lower() not in VIDEO_EXT:
        raise HTTPException(400, "Формат не поддерживается: нужен mp4, m4v, mov или mkv")
    if total <= 0:
        raise HTTPException(400, "Пустой файл")
    part = _upload_part(name, total)
    current = part.stat().st_size if part.exists() else 0
    if offset != current:
        return JSONResponse({"offset": current, "done": False}, status_code=409)
    if current == 0 and shutil.disk_usage(UPLOADS).free < total + 200 * 1024 * 1024:
        raise HTTPException(507, "На сервере не хватает места")
    with open(part, "ab") as f:
        async for chunk in request.stream():
            f.write(chunk)
    new_size = part.stat().st_size
    if new_size > total:
        part.unlink()
        raise HTTPException(400, "Размер файла не совпал, начни загрузку заново")
    if new_size < total:
        return {"offset": new_size, "done": False}
    dest = place(name, show, season, episode)
    shutil.move(str(part), dest)
    refresh_meta_async()
    return {"offset": new_size, "done": True, "path": dest.relative_to(MEDIA).as_posix()}


@app.post("/api/upload/cancel", dependencies=[Depends(auth)])
def upload_cancel(name: str, total: int):
    p = _upload_part(name, total)
    if p.exists():
        p.unlink()
    return {"ok": True}


# ---------- Internet Archive: свободные фильмы и сериалы ----------

import html as _html
import queue as _queue
import uuid as _uuid
from urllib.parse import quote as _quote

from pydantic import BaseModel

ARCHIVE = "https://archive.org"
# Коллекции архива с фильмами и передачами, которые можно свободно смотреть и скачивать
ARCHIVE_COLLECTIONS = [
    "feature_films", "classic_tv", "classic_cartoons", "silent_films",
    "film_noir", "sci-fi_horror", "comedy_films", "prelinger",
]
ARCHIVE_VIDEO_EXT = {".mp4", ".m4v", ".mov"}
ARCHIVE_ID = re.compile(r"^[A-Za-z0-9._-]{1,120}$")
(CACHE / "archive").mkdir(parents=True, exist_ok=True)


def _archive_get(path: str, params=None) -> httpx.Response:
    """Все запросы к архиву идут через эту функцию (в тестах её подменяют)."""
    r = httpx.get(ARCHIVE + path, params=params, timeout=25, follow_redirects=True)
    r.raise_for_status()
    return r


def _archive_stream(path: str):
    client = httpx.Client(follow_redirects=True, timeout=httpx.Timeout(30.0, read=120.0))
    return client, client.stream("GET", ARCHIVE + path)


def _plain(value, limit: int) -> str:
    if isinstance(value, list):
        value = " ".join(str(v) for v in value)
    s = re.sub(r"<[^>]+>", " ", str(value or ""))
    s = _html.unescape(s)
    s = re.sub(r"\s+", " ", s).strip()
    return s[:limit]


def _first(value):
    return value[0] if isinstance(value, list) and value else value


def _parse_length(value):
    if value is None:
        return None
    try:
        return float(value)
    except (TypeError, ValueError):
        pass
    try:
        parts = [float(p) for p in str(value).split(":")]
        total = 0.0
        for p in parts:
            total = total * 60 + p
        return total
    except ValueError:
        return None


def _check_id(identifier: str):
    if not ARCHIVE_ID.match(identifier or ""):
        raise HTTPException(404, "Не найдено")


@app.get("/api/archive/search", dependencies=[Depends(auth)])
def archive_search(q: str, page: int = 1):
    words = re.sub(r'[\\":(){}\[\]^~*?!/+\-&|]', " ", q).split()
    if not words:
        raise HTTPException(400, "Пустой запрос")
    query = (f"({' '.join(words)}) AND mediatype:(movies) AND "
             f"collection:({' OR '.join(ARCHIVE_COLLECTIONS)})")
    params = [("q", query), ("rows", "40"), ("page", str(max(1, page))), ("output", "json"),
              ("sort[]", "downloads desc")]
    params += [("fl[]", f) for f in ("identifier", "title", "year", "description", "downloads")]
    try:
        data = _archive_get("/advancedsearch.php", params).json()
    except Exception as ex:
        raise HTTPException(502, f"Архив недоступен: {ex}")
    resp = data.get("response") or {}
    items = []
    for d in resp.get("docs", []):
        ident = d.get("identifier")
        if not ident or not ARCHIVE_ID.match(ident):
            continue
        year = str(_first(d.get("year")) or "")[:4]
        items.append({
            "id": ident,
            "title": _plain(_first(d.get("title")), 200) or ident,
            "year": year or None,
            "description": _plain(d.get("description"), 300) or None,
            "downloads": d.get("downloads"),
        })
    return {"items": items, "total": resp.get("numFound", 0)}


@app.get("/api/archive/item/{identifier}", dependencies=[Depends(auth)])
def archive_item(identifier: str):
    _check_id(identifier)
    try:
        data = _archive_get(f"/metadata/{identifier}").json()
    except Exception as ex:
        raise HTTPException(502, f"Архив недоступен: {ex}")
    md = data.get("metadata") or {}
    if not md:
        raise HTTPException(404, "Не найдено")
    files = []
    for f in data.get("files", []):
        name = f.get("name") or ""
        if Path(name).suffix.lower() not in ARCHIVE_VIDEO_EXT:
            continue
        try:
            size = int(f.get("size") or 0)
        except (TypeError, ValueError):
            size = 0
        files.append({"name": name, "format": f.get("format") or "", "size": size,
                      "length": _parse_length(f.get("length"))})
    files.sort(key=lambda x: x["name"].lower())
    year = str(_first(md.get("year")) or _first(md.get("date")) or "")[:4]
    return {
        "id": identifier,
        "title": _plain(_first(md.get("title")), 200) or identifier,
        "description": _plain(md.get("description"), 1500) or None,
        "year": year or None,
        "files": files,
    }


def _archive_thumb_path(identifier: str) -> Optional[Path]:
    p = CACHE / "archive" / f"{identifier}.jpg"
    if not p.exists():
        try:
            p.write_bytes(_archive_get(f"/services/img/{identifier}").content)
        except Exception:
            return None
    return p


@app.get("/api/archive/thumb/{identifier}", dependencies=[Depends(auth)])
def archive_thumb(identifier: str):
    _check_id(identifier)
    p = _archive_thumb_path(identifier)
    if not p:
        raise HTTPException(404, "Нет обложки")
    return FileResponse(p, media_type="image/jpeg")


# --- очередь загрузок с архива на сервер ---

_jobs: dict = {}
_job_queue: "_queue.Queue[str]" = _queue.Queue()


class _Cancelled(Exception):
    pass


def _public(job: dict) -> dict:
    return {k: job[k] for k in ("id", "identifier", "title", "file", "episode", "received", "total", "state", "error")}


def _save_archive_meta(folder: str, job: dict):
    k = key(folder)
    mf = CACHE / "meta" / f"{k}.json"
    meta = load_meta(folder) if mf.exists() else {"tmdbId": None, "name": job["title"],
                                                  "overview": job["description"], "episodes": {}}
    if len(job["siblings"]) > 1:
        meta.setdefault("episodes", {})[f"1-{job['episode']}"] = clean_title(Path(job["file"]).stem)
    mf.write_text(json.dumps(meta, ensure_ascii=False))
    poster = CACHE / "posters" / f"{k}.jpg"
    if not poster.exists():
        thumb = _archive_thumb_path(job["identifier"])
        if thumb:
            shutil.copy(thumb, poster)


def _run_job(job: dict):
    job["state"] = "downloading"
    part = UPLOADS / f"archive-{job['id']}.part"
    client = None
    try:
        client, stream = _archive_stream(f"/download/{job['identifier']}/{_quote(job['file'])}")
        with stream as r:
            r.raise_for_status()
            length = int(r.headers.get("content-length") or 0)
            if length:
                job["total"] = length
            with open(part, "wb") as f:
                for chunk in r.iter_bytes(1024 * 1024):
                    if job["cancel"]:
                        raise _Cancelled()
                    f.write(chunk)
                    job["received"] += len(chunk)
        dest = place(Path(job["file"]).name, job["title"], 1, job["episode"])
        shutil.move(str(part), dest)
        _save_archive_meta(dest.parent.parent.name, job)
        job["state"] = "done"
    except _Cancelled:
        job["state"] = "cancelled"
    except Exception as ex:
        job["state"] = "error"
        job["error"] = str(ex)[:200]
    finally:
        job["finishedAt"] = time.time()
        if client:
            client.close()
        if part.exists():
            part.unlink()


def _job_worker():
    while True:
        job = _jobs.get(_job_queue.get())
        if job and job["state"] == "queued":
            _run_job(job)


threading.Thread(target=_job_worker, daemon=True).start()


class ArchiveDownload(BaseModel):
    identifier: str
    title: str
    files: list[str]
    sizes: list[int] = []
    description: str = ""


@app.post("/api/archive/download", dependencies=[Depends(auth)])
def archive_download(req: ArchiveDownload):
    _check_id(req.identifier)
    files = [f for f in req.files if f and ".." not in f and Path(f).suffix.lower() in ARCHIVE_VIDEO_EXT]
    if not files:
        raise HTTPException(400, "Не выбраны видеофайлы")
    need = sum(req.sizes) if req.sizes else 0
    if need and shutil.disk_usage(UPLOADS).free < need + 300 * 1024 * 1024:
        raise HTTPException(507, f"На сервере не хватает места: нужно {need // 1024 ** 2} МБ")
    title = sanitize(req.title) or req.identifier
    show_dir = MEDIA / title
    start = 1
    if show_dir.is_dir():
        numbers = [e for s, e, _ in collect_files(show_dir) if s == 1 and e]
        start = max(numbers, default=0) + 1
    created = []
    for i, name in enumerate(files):
        jid = _uuid.uuid4().hex[:12]
        job = {
            "id": jid, "identifier": req.identifier, "title": title, "file": name,
            "episode": start + i, "received": 0,
            "total": req.sizes[i] if i < len(req.sizes) else 0,
            "state": "queued", "error": None, "cancel": False,
            "description": _plain(req.description, 1500), "siblings": files,
            "createdAt": time.time(), "finishedAt": None,
        }
        _jobs[jid] = job
        _job_queue.put(jid)
        created.append(_public(job))
    return {"jobs": created}


@app.get("/api/archive/jobs", dependencies=[Depends(auth)])
def archive_jobs():
    hour_ago = time.time() - 3600
    for jid in [j for j, job in _jobs.items() if job["finishedAt"] and job["finishedAt"] < hour_ago]:
        _jobs.pop(jid, None)
    jobs = sorted(_jobs.values(), key=lambda j: j["createdAt"])
    return {"jobs": [_public(j) for j in jobs]}


@app.delete("/api/archive/jobs/{job_id}", dependencies=[Depends(auth)])
def archive_cancel(job_id: str):
    job = _jobs.get(job_id)
    if not job:
        raise HTTPException(404, "Нет такой загрузки")
    if job["state"] == "queued":
        job["state"] = "cancelled"
        job["finishedAt"] = time.time()
    elif job["state"] == "downloading":
        job["cancel"] = True
    else:
        _jobs.pop(job_id, None)
    return {"ok": True}
