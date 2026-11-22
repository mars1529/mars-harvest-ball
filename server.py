# -*- coding: utf-8 -*-
"""素材收割球 · 本地后端

只做一件事：给悬浮球提供「抓链接 / 解析 / 下载 / 素材库」接口。
所有接口只监听 127.0.0.1，不对外网开放，不上传任何数据。

与完整版火星工具不同，本精简版不含去字幕、云通道、登录态相关代码。
"""
import ctypes
import hashlib
import json
import mimetypes
import os
import re
import subprocess
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, urlparse

BASE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(BASE, "data")
os.makedirs(DATA, exist_ok=True)
sys.path.insert(0, BASE)
import harvest as HV  # noqa: E402


def _load_config():
    try:
        with open(os.path.join(BASE, "config.json"), encoding="utf-8-sig") as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


CONFIG = _load_config()
# 素材库根：环境变量 > config.json > 程序目录下的 library
LIB_ROOT = (os.environ.get("MARS_LIB")
            or CONFIG.get("library_dir")
            or os.path.join(BASE, "library"))
os.makedirs(LIB_ROOT, exist_ok=True)
HV.OUT_ROOT = LIB_ROOT

VIDEO_EXT = (".mp4", ".mov", ".m4v")
LOCK = threading.Lock()
LIB = {}
EXTRA = {}
HARVEST_STATE = {"seq": 0, "ok": False, "link": "", "info": None,
                 "error": "", "source": "", "at": 0}
LIB_STATE = {"seq": 0, "n": 0}
LIB_LOCK = threading.Lock()


# ---------------------------------------------------------------- 工具
def vid(path):
    return hashlib.sha1(os.path.normpath(path).lower().encode("utf-8")).hexdigest()[:12]


def refresh_library():
    before = set(LIB)
    LIB.clear()
    roots = [LIB_ROOT] + list(EXTRA.keys())
    for root in roots:
        if root in EXTRA:
            paths = [root]
        else:
            if not os.path.isdir(root):
                continue
            paths = []
            for dirpath, _, files in os.walk(root):
                for fn in files:
                    if fn.lower().endswith(VIDEO_EXT):
                        paths.append(os.path.join(dirpath, fn))
        for p in paths:
            if not os.path.isfile(p) or not p.lower().endswith(VIDEO_EXT):
                continue
            try:
                st = os.stat(p)
            except OSError:
                continue
            dirpath, fn = os.path.split(p)
            LIB[vid(p)] = {
                "id": vid(p), "name": fn, "path": p, "size": st.st_size,
                "mtime": int(st.st_mtime), "date": os.path.basename(dirpath),
                "source": "下载素材" if root == LIB_ROOT else "外部导入",
            }
    after = set(LIB)
    if after != before:
        with LIB_LOCK:
            LIB_STATE["seq"] += 1
            LIB_STATE["n"] = len(after)
    return sorted(LIB.values(), key=lambda x: x["mtime"], reverse=True)


# ---------------------------------------------------------------- 收割
def harvest_parse_link(link):
    info = HV.parse(link)
    if info.get("ok"):
        info.setdefault("link", link)
        HV.clip_upsert(info)
    return info


def harvest_download(link):
    res = HV.download(link)
    if res.get("ok"):
        HV.clip_mark_done(link, res.get("file"))
        refresh_library()
        item = LIB.get(vid(res["file"]))
        res["itemId"] = (item or {}).get("id", "")
    return res


def open_folder(path=None):
    path = os.path.abspath(path or LIB_ROOT)
    if os.name == "nt":
        os.startfile(path)
    elif sys.platform == "darwin":
        subprocess.Popen(["open", path])
    else:
        subprocess.Popen(["xdg-open", path])


# ---------------------------------------------------------------- HTTP
def json_out(h, obj, code=200):
    body = json.dumps(obj, ensure_ascii=False).encode("utf-8")
    h.send_response(code)
    h.send_header("Content-Type", "application/json; charset=utf-8")
    h.send_header("Content-Length", str(len(body)))
    h.end_headers()
    h.wfile.write(body)


def serve_file(h, path, content_type=None, download_name=None):
    if not os.path.isfile(path):
        h.send_error(404)
        return
    size = os.path.getsize(path)
    ctype = content_type or mimetypes.guess_type(path)[0] or "application/octet-stream"
    start, end, partial = 0, size - 1, False
    rng = (h.headers.get("Range") or "").strip()
    m = re.match(r"bytes=(\d*)-(\d*)$", rng) if rng else None
    if m and (m.group(1) or m.group(2)):
        try:
            if m.group(1):
                start = int(m.group(1))
                if m.group(2):
                    end = min(int(m.group(2)), size - 1)
            else:
                n = int(m.group(2))
                start = max(0, size - n)
                end = size - 1
        except ValueError:
            start, end = 0, size - 1
        if start >= size:
            h.send_response(416)
            h.send_header("Content-Range", "bytes */%d" % size)
            h.send_header("Content-Length", "0")
            h.end_headers()
            return
        if end < start:
            end = size - 1
        partial = True
    length = end - start + 1
    h.send_response(206 if partial else 200)
    h.send_header("Content-Type", ctype)
    h.send_header("Accept-Ranges", "bytes")
    h.send_header("Content-Length", str(length))
    if partial:
        h.send_header("Content-Range", "bytes %d-%d/%d" % (start, end, size))
    if download_name:
        from urllib.parse import quote
        h.send_header("Content-Disposition", "attachment; filename*=UTF-8''%s" % quote(download_name))
    h.end_headers()
    if h.command == "HEAD":
        return
    try:
        with open(path, "rb") as f:
            f.seek(start)
            left = length
            while left > 0:
                chunk = f.read(min(1024 * 512, left))
                if not chunk:
                    break
                h.wfile.write(chunk)
                left -= len(chunk)
    except (BrokenPipeError, ConnectionResetError, ConnectionAbortedError):
        return


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, fmt, *args):
        pass

    def do_GET(self):
        u = urlparse(self.path)
        q = parse_qs(u.query)
        p = u.path
        try:
            if p == "/api/ping":
                json_out(self, {"ok": True, "name": "素材收割球", "time": int(time.time())})
            elif p == "/api/library":
                json_out(self, {"items": refresh_library(), "dir": LIB_ROOT})
            elif p == "/api/harvest/clips":
                json_out(self, {"items": HV.clips(), "dir": HV.OUT_ROOT})
            elif p == "/api/harvest/cover":
                cp = HV.clip_cover((q.get("link") or [""])[0])
                if not cp:
                    json_out(self, {"error": "无封面"}, 404)
                else:
                    serve_file(self, cp, "image/jpeg")
            elif p == "/api/harvest/event":
                try:
                    since = int((q.get("since") or ["0"])[0])
                except ValueError:
                    since = 0
                with LOCK:
                    snap = dict(HARVEST_STATE)
                with LIB_LOCK:
                    lib = dict(LIB_STATE)
                json_out(self, {"seq": snap["seq"], "fresh": snap["seq"] > since,
                                "event": snap if snap["seq"] > since else None,
                                "libSeq": lib["seq"], "libN": lib["n"]})
            elif p == "/api/media":
                item = LIB.get((q.get("id") or [""])[0])
                if not item:
                    refresh_library()
                    item = LIB.get((q.get("id") or [""])[0])
                if not item:
                    json_out(self, {"error": "视频不存在"}, 404)
                else:
                    serve_file(self, item["path"],
                               mimetypes.guess_type(item["path"])[0] or "video/mp4")
            else:
                json_out(self, {"error": "not found"}, 404)
        except BrokenPipeError:
            pass
        except Exception as e:
            try:
                json_out(self, {"error": str(e)}, 500)
            except Exception:
                pass

    def do_POST(self):
        u = urlparse(self.path)
        p = u.path
        length = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(length) if length else b""
        try:
            if p == "/api/harvest/grab":
                d = json.loads(body.decode("utf-8") or "{}")
                plat = str(d.get("platform") or "auto")
                if plat not in ("auto", "wx", "dy", "clip"):
                    plat = "auto"
                g = HV.grab(plat)
                if not g.get("ok") or not g.get("link"):
                    json_out(self, {"ok": False, "error": g.get("reason") or "没抓到链接"}, 400)
                    return
                info = harvest_parse_link(g["link"])
                if info.get("ok"):
                    info["source"] = "button"
                    with LOCK:
                        HARVEST_STATE.update({"seq": HARVEST_STATE["seq"] + 1, "ok": True,
                                              "link": g["link"], "info": info, "error": "",
                                              "source": "button", "at": int(time.time())})
                json_out(self, {"ok": True, "link": g["link"], "info": info})
            elif p == "/api/harvest/parse":
                d = json.loads(body.decode("utf-8") or "{}")
                link = str(d.get("link") or "").strip() or HV.clipboard_link()
                if not link:
                    json_out(self, {"ok": False, "error": "没给链接，剪贴板里也没有"}, 400)
                    return
                info = harvest_parse_link(link)
                json_out(self, info if info.get("ok") else
                         {"ok": False, "error": info.get("error") or "解析失败", "link": link})
            elif p == "/api/harvest/download":
                d = json.loads(body.decode("utf-8") or "{}")
                link = str(d.get("link") or "").strip()
                if not link:
                    json_out(self, {"ok": False, "error": "链接为空"}, 400)
                    return
                json_out(self, harvest_download(link))
            elif p == "/api/harvest/clip/delete":
                d = json.loads(body.decode("utf-8") or "{}")
                link = str(d.get("link") or "").strip()
                with_file = bool(d.get("file"))
                res = HV.clip_delete(link, with_file=with_file)
                json_out(self, {"ok": True, "removed": res.get("removed", False),
                                "fileRemoved": bool(res.get("file"))})
            elif p == "/api/open-folder":
                try:
                    open_folder()
                    json_out(self, {"ok": True})
                except Exception as e:
                    json_out(self, {"ok": False, "error": str(e)}, 500)
            else:
                json_out(self, {"error": "not found"}, 404)
        except Exception as e:
            json_out(self, {"ok": False, "error": str(e)}, 500)


class Server(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = True

    def handle_error(self, request, client_address):
        exc = sys.exc_info()[1]
        if isinstance(exc, (ConnectionAbortedError, ConnectionResetError, BrokenPipeError)):
            return
        super().handle_error(request, client_address)


_SINGLETON_HANDLE = None


def single_instance():
    global _SINGLETON_HANDLE
    if os.name != "nt":
        return True
    try:
        k32 = ctypes.WinDLL("kernel32", use_last_error=True)
        k32.CreateMutexW.restype = ctypes.c_void_p
        k32.CreateMutexW.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_wchar_p]
        h = k32.CreateMutexW(None, 0, "Global\\HarvestBallServer")
        if not h:
            return True
        if ctypes.get_last_error() == 183:
            k32.CloseHandle(ctypes.c_void_p(h))
            return False
        _SINGLETON_HANDLE = h
        return True
    except Exception:
        return True


def main():
    if "--force" not in sys.argv and not single_instance():
        print("已有一个后端在跑，本进程退出", flush=True)
        return
    refresh_library()
    port = int(CONFIG.get("port") or 8765)
    for _ in range(20):
        try:
            srv = Server(("127.0.0.1", port), Handler)
            break
        except OSError:
            port += 1
    else:
        raise SystemExit("找不到可用端口")
    with open(os.path.join(DATA, "port.txt"), "w", encoding="utf-8") as f:
        f.write(str(port))
    print("素材收割球后端 http://127.0.0.1:%d" % port, flush=True)
    print("素材库: %s" % LIB_ROOT, flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
