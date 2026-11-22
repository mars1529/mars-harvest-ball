# -*- coding: utf-8 -*-
"""从正在运行的微信视频号窗口自动点「分享 -> 复制链接」，读回链接。

原理：纯 Windows UIA（无障碍）+ 真实鼠标点击，不注入进程、不猜固定坐标。
坐标全部来自 UIA 报出的元素位置，窗口挪动/缩放都无关。

输出一行：@@GRAB@@{"ok":true,"link":"..."} 或 @@GRAB@@{"ok":false,"reason":"..."}
"""
import ctypes
import ctypes.wintypes as wt
import json
import re
import sys
import time

try:
    sys.stdout.reconfigure(encoding='utf-8', errors='replace')
except Exception:
    pass

u = ctypes.windll.user32
k = ctypes.windll.kernel32
u.SetProcessDPIAware()

DEADLINE = time.time() + 30
LINK_RE = re.compile(
    r'https?://(?:weixin\.qq\.com/sph/[\w\-]+|channels\.weixin\.qq\.com/[^\s]+|v\.douyin\.com/[\w\-]+/?)'
)


def emit(obj):
    print('@@GRAB@@' + json.dumps(obj, ensure_ascii=False), flush=True)
    sys.exit(0)


# ---------------- 剪贴板 ----------------
# 必须声明 64 位句柄类型，否则 GetClipboardData 返回值被截断，GlobalLock 必失败
u.OpenClipboard.argtypes = [ctypes.c_void_p]
u.OpenClipboard.restype = ctypes.c_int
u.GetClipboardData.argtypes = [ctypes.c_uint]
u.GetClipboardData.restype = ctypes.c_void_p
u.CloseClipboard.argtypes = []
u.CloseClipboard.restype = ctypes.c_int
k.GlobalLock.argtypes = [ctypes.c_void_p]
k.GlobalLock.restype = ctypes.c_void_p
k.GlobalUnlock.argtypes = [ctypes.c_void_p]
k.GlobalUnlock.restype = ctypes.c_int


def read_clip():
    CF_UNICODETEXT = 13
    for _ in range(6):
        if u.OpenClipboard(None):
            try:
                h = u.GetClipboardData(CF_UNICODETEXT)
                if h:
                    p = k.GlobalLock(h)
                    if p:
                        try:
                            return ctypes.wstring_at(p)
                        finally:
                            k.GlobalUnlock(h)
            finally:
                u.CloseClipboard()
        time.sleep(0.15)
    return ''


# ---------------- UIA ----------------
try:
    import comtypes.client as cc
    cc.GetModule('UIAutomationCore.dll')
    from comtypes.gen import UIAutomationClient as UIA
    uia = cc.CreateObject(UIA.CUIAutomation, interface=UIA.IUIAutomation)
except Exception as e:
    emit({'ok': False, 'reason': 'UIA 不可用: %s' % e.__class__.__name__})


def wx_windows():
    """所有标题为「微信」的 Chromium 窗口（WeChatAppEx 承载视频号）。"""
    hs = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)
    def cb(h, l):
        n = ctypes.create_unicode_buffer(256)
        u.GetWindowTextW(h, n, 256)
        if n.value.strip() == '微信':
            hs.append(h)
        return True

    u.EnumWindows(cb, 0)
    out = []
    for h in hs:
        try:
            el = uia.ElementFromHandle(h)
            if el.CurrentClassName == 'Chrome_WidgetWin_0':
                out.append((h, el))
        except Exception:
            pass
    return out


def client_box(h):
    r = wt.RECT()
    if not u.GetClientRect(h, ctypes.byref(r)):
        return None
    p0 = wt.POINT(0, 0)
    u.ClientToScreen(h, ctypes.byref(p0))
    return (p0.x, p0.y, p0.x + r.right, p0.y + r.bottom)


def visible(h):
    if u.IsIconic(h):
        return False
    r = wt.RECT()
    u.GetWindowRect(h, ctypes.byref(r))
    if r.left <= -30000:
        return False
    return (r.right - r.left) > 200 and (r.bottom - r.top) > 200


def collect(el, pred, maxnodes=6000, budget=18.0):
    """BFS 收集满足 pred 的元素。"""
    out = []
    stack = [(el, 0)]
    cnt = 0
    t0 = time.time()
    while stack and cnt < maxnodes and time.time() - t0 < budget:
        cur, d = stack.pop(0)
        cnt += 1
        try:
            nm = (cur.CurrentName or '').strip()
            if nm and pred(nm, cur):
                out.append(cur)
        except Exception:
            pass
        if d >= 16:
            continue
        try:
            kids = cur.FindAll(UIA.TreeScope_Children, uia.CreateTrueCondition())
            for i in range(kids.Length):
                try:
                    stack.append((kids.GetElement(i), d + 1))
                except Exception:
                    pass
        except Exception:
            pass
    return out


def rect_of(el):
    try:
        b = el.CurrentBoundingRectangle
        if b.right > b.left and b.bottom > b.top:
            return (b.left, b.top, b.right, b.bottom)
    except Exception:
        pass
    return None


def click(rc):
    x = (rc[0] + rc[2]) // 2
    y = (rc[1] + rc[3]) // 2
    cur = wt.POINT()
    u.GetCursorPos(ctypes.byref(cur))
    u.SetCursorPos(x, y)
    time.sleep(0.15)
    u.mouse_event(0x0002, 0, 0, 0, 0)
    time.sleep(0.06)
    u.mouse_event(0x0004, 0, 0, 0, 0)
    time.sleep(0.15)
    try:
        u.SetCursorPos(cur.x, cur.y)
    except Exception:
        pass
    return (x, y)


def inside(rc, box):
    if not rc or not box:
        return False
    cx = (rc[0] + rc[2]) // 2
    cy = (rc[1] + rc[3]) // 2
    return box[0] <= cx <= box[2] and box[1] <= cy <= box[3]


# ---------------- 主流程 ----------------
before = read_clip()

wins = wx_windows()
if not wins:
    emit({'ok': False, 'reason': '没找到微信窗口，请先打开微信'})

# 1) 找带「分享」按钮的微信窗口；最小化就先还原，拿到真实坐标后再定位
share_el = None
share_hwnd = None
cand_total = 0
note = ''
for h, el in wins:
    shares = collect(el, lambda nm, e: nm.startswith('分享'), maxnodes=6000, budget=6.0)
    if not shares:
        continue
    cand_total += len(shares)
    if not visible(h):
        try:
            u.ShowWindow(h, 9)      # SW_RESTORE
            time.sleep(0.6)
        except Exception:
            pass
    try:
        u.SetForegroundWindow(h)
        time.sleep(0.4)
    except Exception:
        pass
    el2 = uia.ElementFromHandle(h)
    box = client_box(h)
    shares = collect(el2, lambda nm, e: nm.startswith('分享'), maxnodes=6000, budget=6.0)
    picked = None
    for s in shares:
        rc = rect_of(s)
        if inside(rc, box):
            if picked is None or rc[2] > picked[1][2]:
                picked = (s, rc)
    if picked:
        share_el, share_rc = picked
        share_hwnd = h
        break
    note = '分享按钮不在可视区'

if share_el is None:
    if cand_total == 0:
        emit({'ok': False, 'reason': '当前微信窗口里没找到「分享」按钮，请先点开一个视频号视频'})
    emit({'ok': False, 'reason': '找到了分享按钮但不在可视区，请把视频号窗口切到前台再试'})

# 2) 把微信窗口提到前台（否则鼠标点击落到别处）
try:
    if u.IsIconic(share_hwnd):
        u.ShowWindow(share_hwnd, 9)  # SW_RESTORE
    u.SetForegroundWindow(share_hwnd)
    time.sleep(0.35)
except Exception:
    pass

clicked = click(share_rc)
time.sleep(0.9)

# 3) 弹层里找「复制链接」
copy_el = None
copy_rc = None
for h, el in wx_windows():
    items = collect(el, lambda nm, e: ('复制链接' in nm or '复制地址' in nm), maxnodes=8000, budget=5.0)
    for it in items:
        rc = rect_of(it)
        if rc:
            copy_el, copy_rc = it, rc
            break
    if copy_el is not None:
        break

if copy_el is None:
    emit({'ok': False, 'reason': '点了分享但没在弹层里找到「复制链接」（可能被别的弹窗盖住）', 'clicked': clicked})

click(copy_rc)

# 4) 读剪贴板
for _ in range(16):
    time.sleep(0.2)
    txt = read_clip()
    if txt and txt != before:
        m = LINK_RE.search(txt)
        if m:
            emit({'ok': True, 'link': m.group(0), 'clicked': clicked})
    if time.time() > DEADLINE:
        break

txt = read_clip()
m = LINK_RE.search(txt or '')
if m:
    emit({'ok': True, 'link': m.group(0), 'clicked': clicked})
emit({'ok': False, 'reason': '已点「复制链接」，但剪贴板里没读到视频号链接', 'clicked': clicked})
