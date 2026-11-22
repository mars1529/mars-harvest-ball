# -*- coding: utf-8 -*-
"""自动抓取当前抖音窗口里的视频链接。

和 wechat_grab.py 同一思路：纯 UIA 读当前窗口，不靠固定坐标、不让人手动复制。
抖音网页版的地址栏在 UIA 里叫「地址和搜索栏」，直接读它的 Value 就是当前视频链接。
读不到时退回 Ctrl+L / Ctrl+C 从剪贴板取。

输出：@@GRAB@@{"ok":true,"link":"..."} 或 @@GRAB@@{"ok":false,"reason":"..."}
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
u.GetForegroundWindow.restype = wt.HWND
u.GetWindowThreadProcessId.argtypes = [wt.HWND, ctypes.POINTER(wt.DWORD)]
u.GetWindowThreadProcessId.restype = wt.DWORD
u.AttachThreadInput.argtypes = [wt.DWORD, wt.DWORD, wt.BOOL]
u.AttachThreadInput.restype = wt.BOOL
u.BringWindowToTop.argtypes = [wt.HWND]
u.BringWindowToTop.restype = wt.BOOL
u.SetForegroundWindow.argtypes = [wt.HWND]
u.SetForegroundWindow.restype = wt.BOOL
u.SetFocus.argtypes = [wt.HWND]
u.SetFocus.restype = wt.HWND
u.ShowWindow.argtypes = [wt.HWND, ctypes.c_int]
u.ShowWindow.restype = wt.BOOL
u.keybd_event.argtypes = [ctypes.c_ubyte, ctypes.c_ubyte, ctypes.c_uint, ctypes.c_void_p]

DEADLINE = time.time() + 25
# 抖音 aweme_id 是 19 位；地址栏在搜索页会截断成 10 位，必须排除
LINK_RE = re.compile(
    r'https?://(?:www\.)?douyin\.com/(?:video|share/video)/\d{15,}'
    r'|https?://v\.douyin\.com/[A-Za-z0-9_\-]+/?',
    re.I,
)
ANY_DOUYIN_RE = re.compile(r'(?:https?://)?[^\s"\']*douyin\.com/[^\s"\']*', re.I)


def extract_link(text):
    """地址栏可能是搜索页 ?modal_id=xxx，也能还原成视频直链。"""
    s = str(text or '').strip()
    if s and not s.lower().startswith('http'):
        s = 'https://' + s
    m = LINK_RE.search(s)
    if m:
        return m.group(0)
    m = re.search(r'modal_id=(\d{15,})', s)
    if m:
        return 'https://www.douyin.com/video/' + m.group(1)
    return None

try:
    import comtypes.client as cc
    cc.GetModule('UIAutomationCore.dll')
    from comtypes.gen import UIAutomationClient as UIA
    uia = cc.CreateObject(UIA.CUIAutomation, interface=UIA.IUIAutomation)
except Exception:
    uia = None


def emit(obj):
    print('@@GRAB@@' + json.dumps(obj, ensure_ascii=False), flush=True)
    sys.exit(0)


def read_clip():
    for _ in range(5):
        if u.OpenClipboard(None):
            try:
                h = u.GetClipboardData(13)
                if h:
                    p = k.GlobalLock(h)
                    if p:
                        try:
                            return ctypes.wstring_at(p)
                        finally:
                            k.GlobalUnlock(h)
            finally:
                u.CloseClipboard()
        time.sleep(0.12)
    return ''


def windows():
    found = []

    @ctypes.WINFUNCTYPE(ctypes.c_bool, wt.HWND, wt.LPARAM)
    def cb(h, _):
        if not u.IsWindowVisible(h):
            return True
        n = ctypes.create_unicode_buffer(512)
        u.GetWindowTextW(h, n, 512)
        title = n.value.strip()
        if '抖音' not in title or '素材收割' in title:
            return True
        r = wt.RECT()
        u.GetWindowRect(h, ctypes.byref(r))
        area = max(0, r.right - r.left) * max(0, r.bottom - r.top)
        if area < 200 * 200 and not u.IsIconic(h):
            return True
        found.append((h, title, area))
        return True

    u.EnumWindows(cb, 0)
    fg = u.GetForegroundWindow()
    found.sort(key=lambda x: (x[0] == fg, x[2]), reverse=True)
    return found


def force_foreground(h):
    try:
        if u.IsIconic(h):
            u.ShowWindow(h, 9)
            time.sleep(0.45)
        fg = u.GetForegroundWindow()
        tid_fg = u.GetWindowThreadProcessId(fg, None)
        tid_me = k.GetCurrentThreadId()
        attached = bool(tid_fg and tid_fg != tid_me and
                        u.AttachThreadInput(tid_me, tid_fg, True))
        try:
            u.BringWindowToTop(h)
            u.SetForegroundWindow(h)
            u.SetFocus(h)
            time.sleep(0.25)
        finally:
            if attached:
                u.AttachThreadInput(tid_me, tid_fg, False)
        return u.GetForegroundWindow() == h
    except Exception:
        return False


def read_address_uia(h):
    """从浏览器窗口的 UIA 树里读地址栏 Value（不扫描 root，避免卡死）。"""
    if uia is None:
        return ''
    try:
        root = uia.ElementFromHandle(h)
    except Exception:
        return ''
    stack = [(root, 0)]
    cnt = 0
    t0 = time.time()
    while stack and cnt < 9000 and time.time() - t0 < 10:
        cur, depth = stack.pop(0)
        cnt += 1
        try:
            name = (cur.CurrentName or '').strip()
            cls = cur.CurrentClassName or ''
            ctype = cur.CurrentControlType
            if ('地址' in name or cls == 'OmniboxViewViews' or
                    ctype == 50004):  # ControlType_Edit
                val = ''
                try:
                    pat = cur.GetCurrentPattern(UIA.UIA_ValuePatternId)
                    val = pat.QueryInterface(UIA.IUIAutomationValuePattern).CurrentValue
                except Exception:
                    pass
                if val and ('douyin.com' in val or 'douyin' in val):
                    return val
                if val and ('http://' in val or 'https://' in val):
                    return val
        except Exception:
            pass
        if depth >= 16:
            continue
        try:
            kids = cur.FindAll(UIA.TreeScope_Children, uia.CreateTrueCondition())
            for i in range(kids.Length):
                try:
                    stack.append((kids.GetElement(i), depth + 1))
                except Exception:
                    pass
        except Exception:
            pass
    return ''


def key(vk, up=False):
    u.keybd_event(vk, 0, 0x0002 if up else 0, ctypes.c_void_p(0))


def combo(vk):
    key(0x11)
    key(vk)
    time.sleep(0.1)
    key(vk, True)
    key(0x11, True)
    time.sleep(0.3)


# ---------------- 主流程 ----------------
wins = windows()
if not wins:
    emit({'ok': False, 'reason': '没找到抖音窗口，请先把抖音网页切出来'})

last_clip = ''
last_title = ''
best_url = ''
for h, title, area in wins:
    if time.time() > DEADLINE:
        break
    force_foreground(h)
    last_title = title

    # 1) UIA 直接读地址栏。搜索页 modal_id 常被截断成 10 位，
    #    这里拿不到完整 ID 不能直接判失败，继续走聚焦/剪贴板。
    val = read_address_uia(h)
    if val:
        best_url = val
        m = extract_link(val)
        if m:
            emit({'ok': True, 'link': m, 'window': title})

    # 2) Ctrl+L 聚焦地址栏：Chromium 聚焦后会显示完整 URL，再读一次 UIA
    combo(0x4C)
    val2 = read_address_uia(h)
    if val2:
        best_url = val2
        m = extract_link(val2)
        if m:
            emit({'ok': True, 'link': m, 'window': title})

    # 3) 最后从剪贴板读完整 URL（Ctrl+L 已选中，Ctrl+C 复制全文）
    combo(0x43)
    for _ in range(8):
        time.sleep(0.16)
        last_clip = read_clip() or ''
        m = extract_link(last_clip)
        if m:
            emit({'ok': True, 'link': m, 'window': title})
        if time.time() > DEADLINE:
            break

any_url = ANY_DOUYIN_RE.search(best_url or last_clip)
if any_url:
    emit({'ok': False,
          'reason': '读到的是抖音搜索页/短地址，没拿到完整视频号（' + any_url.group(0)[:70] + '）',
          'window': last_title})
emit({'ok': False, 'reason': '没能从抖音地址栏读到视频链接，请确认正在看一条视频', 'window': last_title})
