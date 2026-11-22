// 视频号 sph 短链 → 明文 mp4
// 链路：元宝 get_parse_result（登录态）→ 取 token/eid → 视频号 get_feed_info → h264VideoInfo.videoUrl → 下载
// 用法：
//   node sph_dl.mjs https://weixin.qq.com/sph/xxxx
//   node sph_dl.mjs 链接1 链接2 链接3
//   node sph_dl.mjs --file links.txt
//   node sph_dl.mjs --clip              # 从剪贴板读链接
//   node sph_dl.mjs --dir "某目录" https://...
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawn } from 'node:child_process';

// ---------- 路径：全部相对项目根，可通过环境变量覆盖，无写死盘符 ----------
const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const PROJECT_ROOT = path.dirname(SCRIPT_DIR);
const WORK = process.env.MARS_HARVEST_WORK || path.join(PROJECT_ROOT, 'data', 'harvest');
const EDGE_CANDS = [
  process.env.MARS_EDGE || '',
  'C:\\Program Files (x86)\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Microsoft\\Edge\\Application\\msedge.exe',
  'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe',
  'C:\\Program Files (x86)\\Google\\Chrome\\Application\\chrome.exe',
];
const EDGE = EDGE_CANDS.find((p) => p && fs.existsSync(p)) || EDGE_CANDS[1];
const PROFILE = path.join(WORK, 'yb-profile');
const PORT = Number(process.env.CDP_PORT || 9450);
const CDP = `http://127.0.0.1:${PORT}`;
const UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/148.0.0.0 Safari/537.36';

// ---------- 参数 ----------
const argv = process.argv.slice(2);
let outDir = process.env.MARS_LIB || path.join(PROJECT_ROOT, 'library');
let emitJson = false;
let infoMode = false;
const inputs = [];
for (let i = 0; i < argv.length; i++) {
  const a = argv[i];
  if (a === '--dir') { outDir = argv[++i]; continue; }
  if (a === '--emit-json') { emitJson = true; continue; }
  if (a === '--info') { infoMode = true; continue; }
  if (a.startsWith('--dir=')) { outDir = a.slice(6); continue; }
  if (a === '--file') { const p = argv[++i]; if (p && fs.existsSync(p)) inputs.push(...fs.readFileSync(p, 'utf8').split(/[\r\n]+/).filter(Boolean)); continue; }
  if (a === '--clip') { try { const { execSync } = await import('node:child_process'); inputs.push(execSync('powershell -NoProfile -Command Get-Clipboard -Raw', { encoding: 'utf8' }).trim()); } catch {} continue; }
  if (a.startsWith('--')) continue; // 未知开关直接忽略，别当成链接
  inputs.push(a);
}
if (!inputs.length) {
  console.error('用法: node sph_dl.mjs <链接...> | --clip | --file links.txt  [--dir 输出目录]');
  process.exit(1);
}

// ---------- 通用超时：任何一步卡住都不能拖死整条链路 ----------
function withTimeout(p, ms, label) {
  let timer;
  return Promise.race([
    p.finally(() => clearTimeout(timer)),
    new Promise((_, rej) => { timer = setTimeout(() => rej(new Error(label + ' 超时 (' + ms + 'ms)')), ms); }),
  ]);
}

// ---------- 浏览器保障 ----------
async function cdpUp() {
  try {
    const r = await fetch(CDP + '/json/version', { signal: AbortSignal.timeout(1500) });
    return r.ok;
  } catch { return false; }
}
async function ensureBrowser() {
  if (await cdpUp()) return;
  console.log('启动解析用浏览器…');
  const child = spawn(EDGE, [
    '--headless=new', `--remote-debugging-port=${PORT}`, `--user-data-dir=${PROFILE}`,
    '--no-first-run', '--no-default-browser-check', '--disable-gpu', '--window-size=1200,900',
    '--disable-features=LocalNetworkAccessChecks', 'about:blank',
  ], { detached: true, stdio: 'ignore', windowsHide: true });
  child.unref();
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 500));
    if (await cdpUp()) return;
  }
  throw new Error('浏览器启动失败');
}

let ws, send;
async function connect() {
  const list = await (await fetch(CDP + '/json/list', { signal: AbortSignal.timeout(3000) })).json();
  let page = list.find((x) => x.type === 'page' && /yuanbao\.tencent\.com/.test(x.url));
  if (!page) {
    const nu = await (await fetch(CDP + '/json/new?https://yuanbao.tencent.com/chat/naQivTmsDa', { method: 'PUT' })).json();
    page = nu;
    await new Promise((r) => setTimeout(r, 4000));
  }
  ws = await withTimeout(new Promise((res, rej) => {
    const w = new WebSocket(page.webSocketDebuggerUrl);
    w.onopen = () => res(w);
    w.onerror = () => rej(new Error('CDP 连接失败'));
  }), 6000, 'CDP 连接');
  let seq = 0; const pend = new Map();
  ws.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id && pend.has(m.id)) { const x = pend.get(m.id); pend.delete(m.id); m.error ? x.rej(new Error(JSON.stringify(m.error))) : x.res(m.result); } };
  send = (method, params = {}) => withTimeout(new Promise((res, rej) => {
    const i = ++seq; pend.set(i, { res, rej });
    ws.send(JSON.stringify({ id: i, method, params }));
  }), 15000, 'CDP ' + method);
}

// ---------- 元宝 Cookie：从浏览器取一次，落盘缓存，直连接口用 ----------
const COOKIE_FILE = path.join(WORK, 'yb-cookie.json');
const COOKIE_TTL = 6 * 60 * 60 * 1000; // 6 小时后强制回浏览器刷新
async function loadYuanbaoCookie(force = false) {
  if (!force && fs.existsSync(COOKIE_FILE)) {
    try {
      const j = JSON.parse(fs.readFileSync(COOKIE_FILE, 'utf8'));
      if (Date.now() - (j.ts || 0) < COOKIE_TTL && j.cookie) return j.cookie;
    } catch { }
  }
  await ensureBrowser();
  const list = await (await fetch(CDP + '/json/list', { signal: AbortSignal.timeout(3000) })).json();
  let page = list.find((x) => x.type === 'page' && /yuanbao\.tencent\.com/.test(x.url));
  if (!page) {
    const nu = await (await fetch(CDP + '/json/new?https://yuanbao.tencent.com/chat/naQivTmsDa', { method: 'PUT', signal: AbortSignal.timeout(4000) })).json();
    page = nu;
    await new Promise((r) => setTimeout(r, 3500));
  }
  const w = await withTimeout(new Promise((res, rej) => {
    const ws2 = new WebSocket(page.webSocketDebuggerUrl);
    ws2.onopen = () => res(ws2); ws2.onerror = () => rej(new Error('cookie CDP 连接失败'));
  }), 6000, 'cookie CDP');
  const cookie = await withTimeout(new Promise((res, rej) => {
    const id = 9001;
    w.onmessage = (e) => { const m = JSON.parse(e.data); if (m.id === id) { m.error ? rej(new Error(JSON.stringify(m.error))) : res((m.result?.cookies || []).map((c) => c.name + '=' + c.value).join('; ')); } };
    w.send(JSON.stringify({ id, method: 'Network.getCookies', params: { urls: ['https://yuanbao.tencent.com/'] } }));
  }), 6000, 'getCookies');
  try { w.close(); } catch { }
  if (!cookie) throw new Error('取不到元宝登录 Cookie，可能登录已过期');
  fs.mkdirSync(path.dirname(COOKIE_FILE), { recursive: true });
  fs.writeFileSync(COOKIE_FILE, JSON.stringify({ ts: Date.now(), cookie }, null, 2));
  console.log('  (已刷新元宝 Cookie)');
  return cookie;
}

// ---------- 元宝解析：Node 直连（快 ~10x），失败回退页面内 fetch ----------
async function yuanbaoParse(shareUrl, attempt = 1) {
  const body = JSON.stringify({ type: 'video_channel_url', url: shareUrl, scene: 1 });
  let txt = '';
  // 1) 首选 Node 直连
  try {
    const cookie = await loadYuanbaoCookie(attempt >= 3);
    const r = await fetch('https://yuanbao.tencent.com/api/weixin/get_parse_result', {
      method: 'POST',
      headers: {
        'content-type': 'application/json', 'accept': 'application/json, text/plain, */*',
        'cookie': cookie, 'origin': 'https://yuanbao.tencent.com', 'referer': 'https://yuanbao.tencent.com/',
        'user-agent': UA,
      },
      body, signal: AbortSignal.timeout(10000),
    });
    txt = await r.text();
  } catch (e) {
    // 2) 直连失败，回退：浏览器页面内 fetch（带页面登录态）
    if (attempt === 1) console.log('  (直连失败，回退页面内解析: ' + e.message + ')');
    try {
      await ensureBrowser(); await connect();
      const expr = `(async()=>{const r=await fetch('https://yuanbao.tencent.com/api/weixin/get_parse_result',{method:'POST',headers:{'content-type':'application/json','accept':'application/json, text/plain, */*'},body:${JSON.stringify(body)}});return (await r.text());})()`;
      const ev = await send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
      txt = ev?.result?.value;
    } catch (e2) {
      if (attempt < 3) { await new Promise((r) => setTimeout(r, 1000 * attempt)); return yuanbaoParse(shareUrl, attempt + 1); }
      throw new Error('元宝解析失败(直连+页面均失败): ' + e2.message);
    }
  }
  let j; try { j = JSON.parse(txt); } catch { throw new Error('元宝返回异常: ' + String(txt).slice(0, 200)); }
  if (j.code !== 0) {
    if (attempt < 3) { await new Promise((r) => setTimeout(r, 800 * attempt)); return yuanbaoParse(shareUrl, attempt + 1); }
    throw new Error('元宝解析失败: ' + (j.msg || JSON.stringify(j).slice(0, 200)) + '（若为登录过期，删除 yb-cookie.json 后会自动刷新）');
  }
  if (!j.data?.playable_url) {
    if (attempt < 2) { await new Promise((r) => setTimeout(r, 800)); return yuanbaoParse(shareUrl, attempt + 1); }
    throw new Error('元宝没给可播放地址：链接可能失效／已删除，或不是视频号视频（图文、直播回放不支持）');
  }
  return j.data;
}

// ---------- feed 信息 ----------
async function feedInfo(token, eid) {
  const rid = Date.now().toString(16) + '-' + Math.random().toString(16).slice(2, 10);
  const url = `https://channels.weixin.qq.com/finder-preview/api/feed/get_feed_info?_rid=${rid}&_pageUrl=https:%2F%2Fchannels.weixin.qq.com%2Ffinder-preview%2Fpages%2Fsph`;
  const referer = `https://channels.weixin.qq.com/finder-preview/pages/feed?entry_card_type=48&comment_scene=39&appid=0&token=${encodeURIComponent(token)}&entry_scene=0&eid=${encodeURIComponent(eid)}`;
  const r = await fetch(url, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json', Accept: 'application/json, text/plain, */*', Referer: referer, Origin: 'https://channels.weixin.qq.com', 'User-Agent': UA },
    body: JSON.stringify({ baseReq: { generalToken: token }, exportId: eid }),
    signal: AbortSignal.timeout(10000),
  });
  const t = await r.text();
  try { return JSON.parse(t); } catch { return { _raw: t.slice(0, 300) }; }
}

function normId(input) {
  const m = input.match(/sph\/([A-Za-z0-9_-]+)/) || input.match(/[?&]id=([A-Za-z0-9_-]+)/);
  if (m) return m[1];
  if (/^[A-Za-z0-9_-]{6,}$/.test(input.trim())) return input.trim();
  return null;
}

// ---------- 抖音 ----------
const MOBILE_UA = 'Mozilla/5.0 (iPhone; CPU iPhone OS 17_2 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Mobile/15E148 Safari/604.1';
const isDouyin = (s) => /douyin\.com/i.test(s);
// 从整段分享文案里抠出抖音链接
function dyUrl(s) {
  const m = String(s).match(/https?:\/\/[^\s，,。、）)】"'”]+/g) || [];
  return m.find((u) => /douyin\.com/i.test(u)) || null;
}

function dyId(s) {
  let m = s.match(/(?:video|share\/video)\/(\d{15,})/);
  if (m) return m[1];
  m = s.match(/modal_id=(\d{15,})/);
  if (m) return m[1];
  return null;
}

// 从 idx 处的 '{' 开始，按括号配对切出完整 JSON 文本
function sliceJson(text, idx) {
  let depth = 0, inStr = false, esc = false;
  for (let i = idx; i < text.length; i++) {
    const c = text[i];
    if (inStr) {
      if (esc) esc = false;
      else if (c === '\\') esc = true;
      else if (c === '"') inStr = false;
      continue;
    }
    if (c === '"') inStr = true;
    else if (c === '{') depth++;
    else if (c === '}') { depth--; if (depth === 0) return text.slice(idx, i + 1); }
  }
  return null;
}

function findVideoItem(obj) {
  const stack = [obj];
  while (stack.length) {
    const o = stack.pop();
    if (!o || typeof o !== 'object') continue;
    const v = o.video;
    if (v && Array.isArray(v.play_addr?.url_list) && v.play_addr.url_list.length) return o;
    for (const k in o) stack.push(o[k]);
  }
  return null;
}

async function followRedirects(url, max = 8) {
  let cur = url;
  for (let i = 0; i < max; i++) {
    const r = await fetch(cur, { redirect: 'manual', headers: { 'User-Agent': MOBILE_UA }, signal: AbortSignal.timeout(3000) });
    const loc = r.headers.get('location');
    if (!loc) return cur;
    cur = new URL(loc, cur).href;
    if (dyId(cur)) return cur;
  }
  return cur;
}

// 开一个新标签页并拿到它的 CDP 连接
async function openTab(url) {
  const tab = await (await fetch(CDP + '/json/new?about:blank', { method: 'PUT', signal: AbortSignal.timeout(4000) })).json();
  const w = await new Promise((res, rej) => { const ws2 = new WebSocket(tab.webSocketDebuggerUrl); ws2.onopen = () => res(ws2); ws2.onerror = () => rej(new Error('CDP 连接失败')); });
  let seq = 0; const pend = new Map(); const listeners = [];
  w.onmessage = (e) => {
    const m = JSON.parse(e.data);
    if (m.id && pend.has(m.id)) { const x = pend.get(m.id); pend.delete(m.id); m.error ? x.rej(new Error(JSON.stringify(m.error))) : x.res(m.result); return; }
    for (const fn of listeners) { try { fn(m); } catch { } }
  };
  const send2 = (method, params = {}) => withTimeout(new Promise((res, rej) => { const i = ++seq; pend.set(i, { res, rej }); w.send(JSON.stringify({ id: i, method, params })); }), 15000, 'CDP ' + method);
  return {
    send: send2,
    on: (fn) => listeners.push(fn),
    close: async () => { try { w.close(); } catch { } try { await fetch(CDP + '/json/close/' + tab.id); } catch { } },
    navigate: async (u) => { try { await send2('Page.navigate', { url: u }); } catch { } },
  };
}

// 抖音：用真实浏览器打开视频页，抓 aweme/detail 的返回（自带签名，绕开 Argus 风控）
async function douyinBrowser(id) {
  const tab = await openTab();
  let detailId = null; const mp4s = [];
  tab.on((m) => {
    if (m.method === 'Network.responseReceived') {
      const u = m.params.response.url;
      if (/aweme\/v1\/web\/aweme\/detail/i.test(u)) detailId = m.params.requestId;
      else if (/douyinvod\.com.*video\/tos/i.test(u)) mp4s.push(u);
    }
  });
  try {
    await tab.send('Network.enable');
    // 只保留接口和视频流，挡掉图片/字体，减少页面加载开销
    await tab.send('Network.setBlockedURLs', { urls: ['*.png', '*.jpg', '*.jpeg', '*.gif', '*.webp', '*.svg', '*.woff', '*.woff2', '*.ttf', '*.otf'] });
    // detail 响应一落地就立刻取，不再固定轮询 22 秒
    await tab.send('Network.setCacheDisabled', { cacheDisabled: true });
    await tab.navigate('https://www.douyin.com/video/' + id);
    for (let i = 0; i < 120 && !detailId; i++) await new Promise((r) => setTimeout(r, 200));
    if (detailId) {
      const b = await tab.send('Network.getResponseBody', { requestId: detailId });
      const j = JSON.parse(b.body);
      const d = j.aweme_detail || j.aweme_details?.[0];
      if (d) {
        let best = '';
        const brs = (d.video?.bit_rate || []).filter((x) => x.play_addr?.url_list?.length);
        if (brs.length) {
          brs.sort((a, b2) => (b2.bit_rate || 0) - (a.bit_rate || 0));
          best = brs[0].play_addr.url_list[0];
        }
        if (!best) best = d.video?.play_addr?.url_list?.[0] || '';
        if (best) {
          return {
            videoUrl: best.replace(/^http:/, 'https:'),
            author: d.author?.nickname || '抖音',
            desc: d.desc || '',
            id,
            coverUrl: d.video?.cover?.url_list?.[0] || d.video?.origin_cover?.url_list?.[0] || '',
            duration: d.video?.duration || 0,
            shareUrl: 'https://www.douyin.com/video/' + id,
            extra: { like: d.statistics?.digg_count, comment: d.statistics?.comment_count, aweme_id: id },
          };
        }
      }
    }
    if (mp4s.length) {
      return { videoUrl: mp4s[0].replace(/^http:/, 'https:'), author: '抖音', desc: '', id, shareUrl: 'https://www.douyin.com/video/' + id, extra: { aweme_id: id } };
    }
    throw new Error('抖音页面没给出播放地址（可能被风控或视频已删除）');
  } finally {
    await tab.close();
  }
}

async function douyinParse(shareInput) {
  await browserWarm; // 抖音解析依赖浏览器
  let id = dyId(shareInput);
  let finalUrl = shareInput;
  if (!id) {
    finalUrl = await followRedirects(shareInput);
    id = dyId(finalUrl);
  }
  if (!id) throw new Error('没识别出抖音视频 ID（短链可能已失效）');
  const d = await douyinBrowser(id);
  d.shareUrl = shareInput;
  return d;
}

// ---------- 统一保存 ----------
async function saveVideo({ videoUrl, author, desc, shareUrl, tag, extra, referer }) {
  fs.mkdirSync(dayDir, { recursive: true });
  const file = path.join(dayDir, `${bad(author || '视频')}_${tag}.mp4`);
  if (fs.existsSync(file)) {
    console.log('已存在，跳过:', file);
    return { ok: true, file, author, size: fs.statSync(file).size, skipped: true, desc: (desc || '').replace(/\s+/g, ' ').slice(0, 60) };
  }
  const res = await fetch(videoUrl, { headers: { 'User-Agent': UA, Referer: referer }, signal: AbortSignal.timeout(90000) });
  if (!res.ok) throw new Error('下载失败 HTTP ' + res.status);
  const buf = Buffer.from(await res.arrayBuffer());
  if (buf.subarray(4, 8).toString('latin1') !== 'ftyp') throw new Error('文件头不是 mp4（可能是反爬页面）');
  fs.writeFileSync(file, buf);
  // 元数据/索引不留在成品目录，统一进归档（会被 4 小时清理）
  const dayName = path.basename(dayDir);
  const metaDir = path.join(META_ROOT, dayName);
  fs.mkdirSync(metaDir, { recursive: true });
  fs.writeFileSync(path.join(metaDir, path.basename(file).replace(/\.mp4$/, '.json')), JSON.stringify({
    shareUrl, author, desc, videoUrl, ...extra, savedAt: new Date().toISOString(),
  }, null, 2));
  console.log(`✓ ${author} | ${(buf.length / 1048576).toFixed(2)}MB`);
  console.log('  ' + file);
  indexRows.push([new Date().toISOString().slice(0, 19), path.basename(file), author || '', (desc || '').replace(/\s+/g, ' ').slice(0, 60), shareUrl].join('\t'));
  try {
    const linkDir = path.join(ARCHIVE, '链接');
    fs.mkdirSync(linkDir, { recursive: true });
    fs.appendFileSync(path.join(linkDir, '链接_' + dayName + '.txt'),
      `${new Date().toISOString().slice(0, 19)}\t${author || ''}\t${shareUrl}\n`);
  } catch { }
  return { ok: true, file, author, size: buf.length, desc: (desc || '').replace(/\s+/g, ' ').slice(0, 60) };
}

const results = [];
const bad = (s) => s.replace(/[\\/:*?"<>|\r\n\t]/g, '_').replace(/\s+/g, ' ').trim().slice(0, 60);
const now = new Date(); const pad = (n) => String(n).padStart(2, '0');
const dayDir = path.join(outDir, `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`);
const COVERS = path.join(WORK, 'covers');
// 非 mp4 产物统一进归档，成品目录只留 mp4
const ARCHIVE = path.join(WORK, '归档');
const META_ROOT = path.join(ARCHIVE, '元数据');
const INDEX_ROOT = path.join(ARCHIVE, '索引');
const CACHE_ROOT = path.join(WORK, 'parse-cache');
const ERROR_LOG = path.join(WORK, 'sph-errors.log');
const CACHE_TTL = 6 * 60 * 60 * 1000; // 6 小时：直链有效期内重复抓/下秒开（直链过期会自动删缓存重解析）

// 封面落本地，界面直接读文件
async function saveCover(coverUrl, key, referer) {
  if (!coverUrl) return '';
  try {
    fs.mkdirSync(COVERS, { recursive: true });
    const f = path.join(COVERS, bad(key) + '.jpg');
    if (fs.existsSync(f) && fs.statSync(f).size > 800) return f;
    const r = await fetch(coverUrl, {
      headers: { 'User-Agent': UA, Referer: referer || 'https://channels.weixin.qq.com/' },
      signal: AbortSignal.timeout(2500),
    });
    if (!r.ok) return '';
    const b = Buffer.from(await r.arrayBuffer());
    if (b.length < 800) return '';
    fs.writeFileSync(f, b);
    return f;
  } catch { return ''; }
}

// ---------- 解析缓存：同一条链接预览/下载只解析一次 ----------
function cacheKey(platform, id) { return `${platform}_${id}`; }
function cacheLoad(platform, id) {
  try {
    const f = path.join(CACHE_ROOT, bad(cacheKey(platform, id)) + '.json');
    if (!fs.existsSync(f)) return null;
    const j = JSON.parse(fs.readFileSync(f, 'utf8'));
    if (Date.now() - (j.ts || 0) > CACHE_TTL) return null;
    return j.data || null;
  } catch { return null; }
}
function cacheSave(platform, id, data) {
  try {
    fs.mkdirSync(CACHE_ROOT, { recursive: true });
    const f = path.join(CACHE_ROOT, bad(cacheKey(platform, id)) + '.json');
    fs.writeFileSync(f, JSON.stringify({ ts: Date.now(), data }, null, 2));
  } catch { }
}
function cacheDrop(platform, id) {
  try { fs.unlinkSync(path.join(CACHE_ROOT, bad(cacheKey(platform, id)) + '.json')); } catch { }
}

// 只解析，不下载：返回统一结构
async function resolveVideo(raw) {
  const lines = String(raw).split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  const dyLine = lines.find((l) => /douyin\.com/i.test(l));
  const dyClean = dyLine ? dyUrl(dyLine) : null;
  const one = dyClean || lines.find((l) => /sph\//.test(l)) || lines.find((l) => /[?&]id=[A-Za-z0-9_-]{6,}/.test(l)) || String(raw).trim();

  if (isDouyin(one)) {
    const did = dyId(one);
    const cached = did ? cacheLoad('dy', did) : null;
    if (cached) { console.log('  (命中解析缓存)'); return cached; }
    const d = await douyinParse(one);
    const r = {
      platform: 'dy', id: d.id, shareUrl: d.shareUrl, author: d.author, desc: d.desc,
      coverUrl: d.coverUrl || '', videoUrl: d.videoUrl, extra: d.extra,
      referer: 'https://www.douyin.com/', tag: 'dy' + d.id, duration: d.duration || 0,
    };
    if (d.id) cacheSave('dy', d.id, r);
    return r;
  }

  const id = normId(one);
  if (!id) throw new Error('没识别出链接，请复制「分享 → 复制链接」那条');
  const cached = cacheLoad('wx', id);
  if (cached) { console.log('  (命中解析缓存)'); return cached; }
  const shareUrl = 'https://weixin.qq.com/sph/' + id;
  const d = await yuanbaoParse(shareUrl);
  const pu = new URL(d.playable_url);
  const token = pu.searchParams.get('token') || '';
  const eid = pu.searchParams.get('eid') || '';
  const fi = await feedInfo(token, eid);
  const f = fi?.data?.feedInfo || {};
  let videoUrl = f.videoUrl || f.h264VideoInfo?.videoUrl || f.h265VideoInfo?.videoUrl || '';
  if (!videoUrl) throw new Error('视频号未返回直链：' + (fi?.data?.errMsg?.title || '内容不可播放（可能已下架或仅限作者可见）'));
  videoUrl = videoUrl.replace(/[?&]X-snsvideoflag=[^&]*/, '');
  const r = {
    platform: 'wx', id, shareUrl, author: d.author || '视频号', desc: d.desc || '',
    coverUrl: d.cover_url || f.coverUrl || '', videoUrl, referer: 'https://channels.weixin.qq.com/',
    tag: id, duration: f.duration || 0,
    extra: { eid, like: f.likeCountFmt, fav: f.favCountFmt, forward: f.forwardCountFmt, createtime: f.createtime },
  };
  cacheSave('wx', id, r);
  return r;
}

// ---------- 主流程：浏览器按需启动（微信走直连不用等浏览器） ----------
// 预启动浏览器（不阻塞），抖音解析或 cookie 刷新会用到；微信直连命中时不等待
const browserWarm = ensureBrowser().catch(() => {});
async function needBrowser() { await browserWarm; await ensureBrowser(); }

// --info：只解析，给悬浮面板做预览
if (infoMode) {
  let info = null, err = '';
  try {
    const r = await resolveVideo(inputs[0] || '');
    const cover = await saveCover(r.coverUrl, `${r.platform}_${r.id}`, r.referer);
    info = {
      platform: r.platform, id: r.id, shareUrl: r.shareUrl, author: r.author,
      desc: (r.desc || '').replace(/\s+/g, ' ').slice(0, 120), cover, duration: r.duration,
    };
  } catch (e) {
    err = e.message;
    try { fs.appendFileSync(ERROR_LOG, `[${new Date().toISOString().slice(0, 19)}] INFO ${String(inputs[0]).slice(0, 60)} :: ${e.message}\n`); } catch { }
  }
  console.log('@@INFO@@' + JSON.stringify(info ? { ok: true, ...info } : { ok: false, error: err }));
  process.exit(0);
}

let ok = 0, fail = 0;
const indexRows = [];
for (const raw of inputs) {
  console.log('\n=== ' + String(raw).replace(/\s+/g, ' ').slice(0, 80) + ' ===');
  let retried = false;
  while (true) {
  try {
    const r = await resolveVideo(raw);
    console.log('  [' + (r.platform === 'dy' ? '抖音' : '视频号') + '] ID:', r.id, '| 作者:', r.author);
    const cover = await saveCover(r.coverUrl, `${r.platform}_${r.id}`, r.referer);
    const item = await saveVideo({
      videoUrl: r.videoUrl, author: r.author, desc: r.desc, shareUrl: r.shareUrl,
      tag: r.tag, extra: { ...r.extra, platform: r.platform, cover }, referer: r.referer,
    });
    ok++;
    results.push(item);
    break;
  } catch (e) {
    // 缓存里的直链过期 → 删缓存重解析一次
    if (!retried && /HTTP 4\d\d|文件头不是 mp4|下载失败/.test(e.message)) {
      const guessId = (raw.match(/video\/(\d{6,})/) || raw.match(/sph\/([\w-]+)/) || [])[1];
      const plat = /douyin/.test(raw) ? 'dy' : 'wx';
      if (guessId) { console.log('  (疑似直链过期，清缓存重试)'); cacheDrop(plat, guessId); }
      retried = true; continue;
    }
    console.log('✗ 失败:', e.message);
    try { fs.appendFileSync(ERROR_LOG, `[${new Date().toISOString().slice(0, 19)}] ${String(raw).slice(0, 80)} :: ${e.message}\n`); } catch { }
    fail++;
    results.push({ ok: false, error: e.message });
    break;
  }
  }
}

if (indexRows.length) {
  fs.mkdirSync(INDEX_ROOT, { recursive: true });
  const idx = path.join(INDEX_ROOT, '_索引_' + path.basename(dayDir) + '.tsv');
  const head = fs.existsSync(idx) ? '' : '时间\t文件名\t作者\t文案\t来源\n';
  fs.appendFileSync(idx, head + indexRows.join('\n') + '\n');
  console.log('\n索引已写入', idx);
}
console.log(`\n完成：成功 ${ok}，失败 ${fail}`);
// 供外部界面（悬浮按钮）解析的机器可读行
if (process.env.EMIT_JSON === '1' || emitJson) {
  console.log('@@RESULT@@' + JSON.stringify({ ok: ok > 0 && fail === 0, success: ok, failed: fail, items: results, dir: dayDir }));
}
process.exit(fail ? 1 : 0);
