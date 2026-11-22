# -*- coding: utf-8 -*-
"""素材收割球 · 素材收割模块

抓当前微信/抖音窗口链接 → 解析标题/作者/封面 → 选择下载 → 自动进素材库。

底层脚本随项目一起发布，位于 engine\\ 目录：
  engine\\sph_dl.mjs       解析 + 下载（元宝直连 / 抖音 CDP）
  engine\\wechat_grab.py   微信视频号 UIA 抓链接
  engine\\douyin_grab.py   抖音地址栏 UIA 抓链接

所有路径均可通过 config.json 或环境变量配置，不依赖任何固定的盘符/用户名。
"""
import ctypes
import ctypes.wintypes as wt
import json
import os
import re
import shutil
import subprocess
import sys
import threading
import time

BASE = os.path.dirname(os.path.abspath(__file__))
DATA = os.path.join(BASE, "data")
ENGINE = os.path.join(BASE, "engine")


def _exists(path):
    return bool(path) and os.path.exists(path)


def _first(*paths):
    for p in paths:
        if _exists(p):
            return p
    return paths[-1]


def _load_config():
    """读取 config.json（可选）；缺失或出错时用空配置，全部走默认值。"""
    try:
        with open(os.path.join(BASE, "config.json"), encoding="utf-8-sig") as f:
            d = json.load(f)
            return d if isinstance(d, dict) else {}
    except Exception:
        return {}


CONFIG = _load_config()

# 收割引擎根：环境变量 > config.json > 内置 engine 目录
HARVEST_ROOT = _first(os.environ.get("MARS_HARVEST"),
                      CONFIG.get("engine_dir"),
                      ENGINE)
# 新布局是平铺（发布版），旧布局是 工具\ / 工作\ 两个子目录（兼容老用户）
SPH = _first(os.path.join(HARVEST_ROOT, "sph_dl.mjs"),
             os.path.join(HARVEST_ROOT, "工具", "sph_dl.mjs"))
GRAB_WX = _first(os.path.join(HARVEST_ROOT, "wechat_grab.py"),
                 os.path.join(HARVEST_ROOT, "工作", "wechat_grab.py"))
GRAB_DY = _first(os.path.join(HARVEST_ROOT, "douyin_grab.py"),
                 os.path.join(HARVEST_ROOT, "工作", "douyin_grab.py"))
WORK_DIR = _first(CONFIG.get("work_dir"),
                  os.path.join(HARVEST_ROOT, "工作"),
                  os.path.join(DATA, "harvest"))
CLIP_FILE = os.path.join(WORK_DIR, "link-clip.json")
# 素材库根（下载成品落这里）：环境变量 > config.json > 程序目录下的 library
OUT_ROOT = (os.environ.get("MARS_LIB")
            or CONFIG.get("library_dir")
            or os.path.join(BASE, "library"))

LINK_RE = re.compile(
    r"https?://(?:(?:www\.)?douyin\.com/video/\d{15,}"
    r"|v\.douyin\.com/[\w\-\?=&]+/?"
    r"|(?:www\.)?iesdouyin\.com/share/video/\d+"
    r"|weixin\.qq\.com/sph/[\w\-]+"
    r"|channels\.weixin\.qq\.com/[\w\-/?=&%.]+)",
    re.I,
)

_JOB = threading.Lock()
_LOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "data", "harvest.log")

# 后端跑在 pythonw（无控制台）时，子进程会自己开一个黑框窗口。
# node.exe / python.exe 一律隐藏窗口跑，用户不该看到任何控制台。
CREATE_NO_WINDOW = 0x08000000
_SI = subprocess.STARTUPINFO()
_SI.dwFlags |= subprocess.STARTF_USESHOWWINDOW
_SI.wShowWindow = 0
HIDDEN = {"creationflags": CREATE_NO_WINDOW, "startupinfo": _SI}


def log(msg):
    try:
        os.makedirs(os.path.dirname(_LOG), exist_ok=True)
        if os.path.exists(_LOG) and os.path.getsize(_LOG) > 512 * 1024:
            os.replace(_LOG, _LOG + ".1")
        with open(_LOG, "a", encoding="utf-8") as f:
            f.write("[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), msg))
    except Exception:
        pass


# ---------------------------------------------------------------- 运行时
def node_exe():
    # 环境变量 > 配置 > 内置 runtime > 内置 node > PATH
    cands = [os.environ.get("MARS_NODE"),
             CONFIG.get("node"),
             os.path.join(BASE, "runtime", "node.exe"),
             os.path.join(BASE, "runtime", "node", "node.exe"),
             os.path.join(BASE, "node", "node.exe"),
             shutil.which("node")]
    for c in cands:
        if c:
            if os.path.isabs(c) and not os.path.exists(c):
                continue
            return c
    return "node"


def python_exe():
    """跑 grab 子脚本用的解释器：内置 runtime > 当前解释器 > PATH。"""
    cands = [os.path.join(BASE, "runtime", "python", "python.exe"),
             os.path.join(BASE, "runtime", "python", "pythonw.exe"),
             sys.executable,
             shutil.which("python")]
    for c in cands:
        if c and (not os.path.isabs(c) or os.path.exists(c)):
            return c
    return "python"


def _run(cmd, cwd, timeout, tag=""):
    """跑一条子进程，返回 (code, stdout, stderr)。"""
    t0 = time.time()
    env = dict(os.environ)
    env["PYTHONUTF8"] = "1"
    env["PYTHONIOENCODING"] = "utf-8"
    env["MARS_HARVEST_WORK"] = WORK_DIR      # 元宝 profile / 解析缓存 / cookie 落这里
    env["MARS_LIB"] = OUT_ROOT               # 成品落这里
    try:
        r = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True,
                           encoding="utf-8", errors="replace", timeout=timeout,
                           env=env, **HIDDEN)
        return r.returncode, r.stdout or "", r.stderr or ""
    except subprocess.TimeoutExpired as e:
        return -9, (e.stdout or ""), "超时（%.0fs）" % timeout
    except Exception as e:
        return -1, "", str(e)
    finally:
        log("%s %.1fs %s" % (tag or cmd[0], time.time() - t0, " ".join(cmd[-1:])[:120]))


def _marker(out, tag):
    """取最后一行 @@TAG@@{json} 的 json。"""
    hit = None
    for line in (out or "").splitlines():
        line = line.strip()
        if line.startswith("@@%s@@" % tag):
            hit = line[len(tag) + 4:]
    if not hit:
        return None
    try:
        return json.loads(hit)
    except Exception:
        return None


# ---------------------------------------------------------------- 剪贴板
def read_clipboard():
    u = ctypes.windll.user32
    k = ctypes.windll.kernel32
    u.OpenClipboard.argtypes = [ctypes.c_void_p]
    u.GetClipboardData.argtypes = [ctypes.c_uint]
    u.GetClipboardData.restype = ctypes.c_void_p
    k.GlobalLock.argtypes = [ctypes.c_void_p]
    k.GlobalLock.restype = ctypes.c_void_p
    k.GlobalUnlock.argtypes = [ctypes.c_void_p]
    k.GlobalUnlock.restype = ctypes.c_bool
    if not u.OpenClipboard(None):
        return ""
    try:
        h = u.GetClipboardData(13)  # CF_UNICODETEXT
        if not h:
            return ""
        p = k.GlobalLock(h)
        if not p:
            return ""
        try:
            return ctypes.wstring_at(p)
        finally:
            k.GlobalUnlock(h)
    finally:
        u.CloseClipboard()


def clipboard_link():
    txt = read_clipboard() or ""
    m = LINK_RE.search(txt)
    return m.group(0) if m else ""


# ------------------------------------------------------ 剪贴板新鲜度（手动复制的链接）
_CLIP = {"seq": -1, "link": "", "at": 0.0}


def clipboard_seq():
    try:
        return int(ctypes.windll.user32.GetClipboardSequenceNumber())
    except Exception:
        return -1


def _init_clip():
    """启动时把当前剪贴板记为「已处理过」，避免一启动就把旧链接抓进来。"""
    try:
        _CLIP["seq"] = clipboard_seq()
        _CLIP["link"] = clipboard_link()
        _CLIP["at"] = time.time()
    except Exception:
        pass


def fresh_clip_link(allow_seen=False):
    """剪贴板里有没有还没处理过的视频链接（同一条不重复解析）。"""
    link = clipboard_link()
    if not link:
        return ""
    if not allow_seen and clipboard_seq() == _CLIP["seq"] and link == _CLIP["link"]:
        return ""
    return link


def mark_clip(link):
    _CLIP["seq"] = clipboard_seq()
    _CLIP["link"] = link
    _CLIP["at"] = time.time()


_init_clip()


# ---------------------------------------------------------------- 抓链接
def foreground_hint():
    u = ctypes.windll.user32
    hwnd = u.GetForegroundWindow()
    n = u.GetWindowTextLengthW(hwnd)
    buf = ctypes.create_unicode_buffer(n + 1)
    u.GetWindowTextW(hwnd, buf, n + 1)
    t = buf.value or ""
    if re.search(r"微信|WeChat|视频号", t, re.I):
        return "wx"
    if re.search(r"抖音|douyin", t, re.I):
        return "dy"
    return ""


def grab(platform="auto"):
    """抓链接：手动复制到剪贴板的优先，其次进微信/抖音窗口里点分享复制。"""
    if not _JOB.acquire(blocking=False):
        return {"ok": False, "reason": "上一个收割任务还在跑，稍等一下"}
    try:
        # ① 剪贴板里刚复制的链接（用户自己复制过来的，微信/抖音/任意地方都行）
        if platform in ("auto", "clip"):
            link = fresh_clip_link(allow_seen=(platform == "clip"))
            if link:
                mark_clip(link)
                plat = "dy" if "douyin" in link else "wx"
                log("grab clip %s" % link)
                return {"ok": True, "link": link, "platform": plat, "source": "clip"}
            if platform == "clip":
                return {"ok": False, "reason": "剪贴板里没有微信/抖音视频链接"}

        py = python_exe()
        order = ["wx", "dy"]
        hint = foreground_hint() if platform == "auto" else platform
        if hint == "dy":
            order = ["dy", "wx"]
        elif hint == "wx":
            order = ["wx", "dy"]
        reasons = []
        for plat in order:
            script = GRAB_WX if plat == "wx" else GRAB_DY
            code, out, err = _run([py, script], WORK_DIR, 40, "grab-" + plat)
            data = _marker(out, "GRAB")
            if data and data.get("ok") and data.get("link"):
                data["platform"] = plat
                mark_clip(data["link"])   # 抓取过程会写剪贴板，别让监听再触发一次
                log("grab ok %s %s" % (plat, data["link"]))
                return data
            reasons.append("%s：%s" % ("微信" if plat == "wx" else "抖音",
                                      (data or {}).get("reason") or (err or out or "未知失败")[:120]))
        return {"ok": False, "reason": " / ".join(reasons)}
    finally:
        _JOB.release()


# ---------------------------------------------------------------- 解析 / 下载
def parse(link, timeout=90):
    if not link:
        return {"ok": False, "error": "链接为空"}
    code, out, err = _run([node_exe(), SPH, "--info", "--emit-json", link], os.path.dirname(SPH),
                          timeout, "parse")
    data = _marker(out, "INFO")
    if not data:
        return {"ok": False, "error": (err or out or "解析失败").strip().splitlines()[-1][:200]}
    if data.get("ok"):
        data["link"] = link
        data["platform"] = data.get("platform") or ("dy" if "douyin" in link else "wx")
    return data


def download(link, timeout=300):
    if not link:
        return {"ok": False, "error": "链接为空"}
    code, out, err = _run([node_exe(), SPH, "--emit-json", link, "--dir", OUT_ROOT],
                          os.path.dirname(SPH), timeout, "download")
    data = _marker(out, "RESULT")
    if not data:
        return {"ok": False, "error": (err or out or "下载失败").strip().splitlines()[-1][:200]}
    items = data.get("items") or []
    good = [x for x in items if x.get("ok") and x.get("file")]
    if not good:
        msg = (items[0].get("error") if items else "") or "下载失败"
        return {"ok": False, "error": msg}
    it = good[0]
    return {"ok": True, "file": it.get("file"), "author": it.get("author") or "",
            "desc": it.get("desc") or "", "size": it.get("size") or 0,
            "dir": data.get("dir") or os.path.dirname(it.get("file") or "")}


# ---------------------------------------------------------------- 链接剪贴板
def _read_json(path, default):
    try:
        with open(path, encoding="utf-8-sig") as f:
            return json.load(f)
    except Exception:
        return default


def _write_json(path, data):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, ensure_ascii=False, indent=1)
    os.replace(tmp, path)


def clips(limit=60):
    data = _read_json(CLIP_FILE, [])
    if not isinstance(data, list):
        return []
    seen = set()
    uniq = []
    for x in reversed(data):
        if not isinstance(x, dict) or not x.get("link"):
            continue
        if x["link"] in seen:
            continue
        seen.add(x["link"])
        uniq.append(x)
        if len(uniq) >= limit:
            break
    out = []
    for x in uniq:
        if not isinstance(x, dict) or not x.get("link"):
            continue
        cover = x.get("cover") or ""
        out.append({
            "link": x["link"], "platform": x.get("platform") or "",
            "id": x.get("id") or "", "author": x.get("author") or "",
            "desc": x.get("desc") or "", "ts": x.get("ts") or "",
            "done": bool(x.get("done")), "file": x.get("file") or "",
            "cover": bool(cover and os.path.exists(cover)),
        })
    return out


def clip_cover(link):
    for x in reversed(_read_json(CLIP_FILE, [])):
        if isinstance(x, dict) and x.get("link") == link:
            p = x.get("cover") or ""
            return p if p and os.path.exists(p) else ""
    return ""


def clip_upsert(info):
    """把一条解析结果写进链接剪贴板（同链接去重，保留最新信息）。"""
    link = info.get("link")
    if not link:
        return
    data = _read_json(CLIP_FILE, [])
    if not isinstance(data, list):
        data = []
    data = [x for x in data if isinstance(x, dict) and x.get("link") != link]
    data.append({
        "link": link,
        "platform": info.get("platform") or ("dy" if "douyin" in link else "wx"),
        "id": info.get("id") or "",
        "author": info.get("author") or "",
        "desc": info.get("desc") or "",
        "cover": info.get("cover") or "",
        "ts": time.strftime("%m-%d %H:%M"),
        "done": bool(info.get("done")),
        "file": info.get("file") or "",
    })
    _write_json(CLIP_FILE, data[-200:])


def clip_mark_done(link, file):
    data = _read_json(CLIP_FILE, [])
    for x in data:
        if isinstance(x, dict) and x.get("link") == link:
            x["done"] = True
            x["file"] = file
    _write_json(CLIP_FILE, data)


def clip_delete(link, with_file=False):
    """删除历史记录；with_file=True 时同时删除该条已入库的视频文件。

    返回 {removed: 是否有记录, file: 实际删除的文件路径或 ''}。
    删除文件前严格校验路径位于素材库目录内，避免误删任意路径。
    """
    data = _read_json(CLIP_FILE, [])
    hit = next((x for x in data if isinstance(x, dict) and x.get("link") == link), None)
    removed_file = ""
    if with_file and hit:
        fp = hit.get("file") or ""
        root = os.path.abspath(OUT_ROOT)
        if fp:
            try:
                ap = os.path.abspath(fp)
                # 只允许删除素材库根目录下的文件（含子目录）
                if os.path.commonpath([root, ap]) == root and os.path.isfile(ap):
                    os.remove(ap)
                    removed_file = ap
            except Exception:
                removed_file = ""
    kept = [x for x in data if not (isinstance(x, dict) and x.get("link") == link)]
    _write_json(CLIP_FILE, kept)
    if removed_file:
        refresh = globals().get("refresh_library")
        if callable(refresh):
            try:
                refresh()
            except Exception:
                pass
    return {"removed": hit is not None, "file": removed_file}
