import http from 'node:http';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { access, readFile, stat } from 'node:fs/promises';

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const WEB_PORT = Number.parseInt(process.env.WEB_PORT ?? '3000', 10);
const INTERNAL_API_BASE = (process.env.ELA_INTERNAL_API_URL ?? 'http://api:4000/api/v1').replace(/\/$/, '');
const VERSION = '0.4.9-m4-auth-ux';
const REQUEST_TIMEOUT_MS = 12_000;

const MIME_TYPES = new Map([
  ['.html', 'text/html; charset=utf-8'],
  ['.js', 'text/javascript; charset=utf-8'],
  ['.mjs', 'text/javascript; charset=utf-8'],
  ['.css', 'text/css; charset=utf-8'],
  ['.json', 'application/json; charset=utf-8'],
  ['.svg', 'image/svg+xml'],
  ['.png', 'image/png'],
  ['.jpg', 'image/jpeg'],
  ['.jpeg', 'image/jpeg'],
  ['.gif', 'image/gif'],
  ['.webp', 'image/webp'],
  ['.ico', 'image/x-icon'],
  ['.woff', 'font/woff'],
  ['.woff2', 'font/woff2'],
  ['.ttf', 'font/ttf'],
  ['.wav', 'audio/wav'],
  ['.mp3', 'audio/mpeg'],
  ['.map', 'application/json; charset=utf-8'],
  ['.txt', 'text/plain; charset=utf-8'],
]);

const ROLE_RULES = [
  { prefix: '/student', accepted: new Set(['STUDENT']), home: '/student/today' },
  { prefix: '/parent', accepted: new Set(['PARENT', 'GUARDIAN']), home: '/parent' },
  { prefix: '/teacher', accepted: new Set(['TEACHER']), home: '/teacher' },
  {
    prefix: '/admin',
    accepted: new Set(['ADMIN', 'SYSTEM_ADMIN', 'CONTENT_ADMIN', 'SUPER_ADMIN']),
    home: '/admin',
  },
];

const PUBLIC_PATHS = new Set([
  '/',
  '/login',
  '/student/register',
  '/favicon.ico',
  '/robots.txt',
  '/__ela/health',
]);

function isSafeNext(value) {
  return typeof value === 'string' && value.startsWith('/') && !value.startsWith('//') && !value.includes('\\');
}

function htmlEscape(value) {
  return String(value ?? '')
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;')
    .replaceAll("'", '&#39;');
}

function normalizeRoles(input) {
  const source = Array.isArray(input) ? input : input ? [input] : [];
  return [...new Set(source.flatMap((item) => {
    if (typeof item === 'string') return [item.toUpperCase()];
    if (item && typeof item === 'object') {
      const candidate = item.code ?? item.name ?? item.role ?? item.slug;
      return typeof candidate === 'string' ? [candidate.toUpperCase()] : [];
    }
    return [];
  }))];
}

function normalizeSessionBody(body) {
  if (!body || typeof body !== 'object') return null;
  const candidate = body.user ?? body.data?.user ?? body.data ?? body;
  if (!candidate || typeof candidate !== 'object') return null;
  const roles = normalizeRoles(candidate.roles ?? body.roles ?? candidate.role ?? body.role);
  if (roles.length === 0) return null;
  return {
    id: String(candidate.id ?? candidate.userId ?? body.userId ?? ''),
    displayName: String(
      candidate.displayName ?? candidate.fullName ?? candidate.name ?? candidate.email ?? 'Người dùng',
    ),
    email: typeof candidate.email === 'string' ? candidate.email : undefined,
    roles,
  };
}

function roleHome(roles) {
  const normalized = new Set(normalizeRoles(roles));
  if (normalized.has('STUDENT')) return '/student/today';
  if (normalized.has('PARENT') || normalized.has('GUARDIAN')) return '/parent';
  if (normalized.has('TEACHER')) return '/teacher';
  if ([...normalized].some((role) => role.includes('ADMIN'))) return '/admin';
  return '/';
}

function expectedRule(pathname) {
  return ROLE_RULES.find(({ prefix }) => pathname === prefix || pathname.startsWith(`${prefix}/`));
}

function roleAllowed(session, rule) {
  if (!rule) return true;
  const roles = new Set(session?.roles ?? []);
  return [...rule.accepted].some((role) => roles.has(role));
}

async function pathExists(candidate) {
  try {
    await access(candidate);
    return true;
  } catch {
    return false;
  }
}

async function detectStaticRoot() {
  const candidates = [
    path.join(__dirname, 'out'),
    path.join(process.cwd(), 'out'),
    path.join(__dirname, '.next', 'server', 'app'),
    path.join(process.cwd(), 'apps', 'web', 'out'),
    path.join('/app', 'apps', 'web', 'out'),
  ];
  for (const candidate of candidates) {
    if (await pathExists(path.join(candidate, 'index.html'))) return candidate;
  }
  throw new Error(`Không tìm thấy Next.js static export. Đã kiểm tra: ${candidates.join(', ')}`);
}

const STATIC_ROOT = await detectStaticRoot();

function newNonce() {
  return crypto.randomBytes(18).toString('base64');
}

function securityHeaders(nonce, contentType = 'text/html; charset=utf-8') {
  return {
    'content-type': contentType,
    'content-security-policy': [
      "default-src 'self'",
      `script-src 'self' 'nonce-${nonce}'`,
      "style-src 'self' 'unsafe-inline'",
      "img-src 'self' data: blob:",
      "font-src 'self' data:",
      "media-src 'self' data: blob:",
      "connect-src 'self'",
      "object-src 'none'",
      "base-uri 'self'",
      "form-action 'self'",
      "frame-ancestors 'none'",
    ].join('; '),
    'referrer-policy': 'strict-origin-when-cross-origin',
    'x-content-type-options': 'nosniff',
    'x-frame-options': 'DENY',
    'permissions-policy': 'camera=(), microphone=(), geolocation=()',
  };
}

function sendHtml(res, status, html, nonce = newNonce(), extraHeaders = {}) {
  res.writeHead(status, {
    ...securityHeaders(nonce),
    'cache-control': 'no-store, max-age=0',
    ...extraHeaders,
  });
  res.end(html);
}

function sendJson(res, status, payload, extraHeaders = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    'cache-control': 'no-store, max-age=0',
    'x-content-type-options': 'nosniff',
    ...extraHeaders,
  });
  res.end(body);
}

function redirect(res, location, status = 302) {
  res.writeHead(status, {
    location,
    'cache-control': 'no-store, max-age=0',
    'x-content-type-options': 'nosniff',
  });
  res.end();
}

async function fetchWithTimeout(url, options = {}, timeoutMs = REQUEST_TIMEOUT_MS) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetch(url, { ...options, signal: controller.signal, redirect: 'manual' });
  } finally {
    clearTimeout(timer);
  }
}

async function inspectSession(req) {
  const cookie = req.headers.cookie;
  if (!cookie) return { status: 'anonymous', user: null };
  try {
    const response = await fetchWithTimeout(`${INTERNAL_API_BASE}/auth/me`, {
      method: 'GET',
      headers: { accept: 'application/json', cookie },
    }, 6_000);
    if (response.status === 401 || response.status === 403) return { status: 'anonymous', user: null };
    if (!response.ok) return { status: 'unavailable', user: null };
    const user = normalizeSessionBody(await response.json().catch(() => null));
    return user ? { status: 'authenticated', user } : { status: 'anonymous', user: null };
  } catch {
    return { status: 'unavailable', user: null };
  }
}

function baseDocument({ title, body, nonce, script = '', extraHead = '' }) {
  return `<!doctype html>
<html lang="vi">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="color-scheme" content="light" />
  <title>${htmlEscape(title)}</title>
  ${extraHead}
  <style>
    :root{font-family:Inter,ui-sans-serif,system-ui,-apple-system,"Segoe UI",sans-serif;color:#102a4f;background:#f3f7fc}
    *{box-sizing:border-box}body{margin:0;min-height:100vh;background:linear-gradient(145deg,#eef6ff,#f8fbff 56%,#eef3fa)}
    a{color:#1269b0}.shell{width:min(1120px,calc(100% - 32px));margin:0 auto;padding:48px 0}
    .card{background:#fff;border:1px solid #d4e0ed;border-radius:22px;box-shadow:0 18px 50px rgba(17,54,91,.11)}
    .btn{display:inline-flex;align-items:center;justify-content:center;min-height:46px;padding:0 20px;border:0;border-radius:11px;font-weight:750;font-size:16px;cursor:pointer;text-decoration:none}
    .btn-primary{color:#fff;background:#176db5}.btn-primary:hover{background:#115993}.btn-secondary{color:#16395e;background:#eef5fc;border:1px solid #c7d8e9}
    .muted{color:#5b6f87}.error{background:#fff0f0;border:1px solid #ffc9c9;color:#a31919;padding:12px 14px;border-radius:10px}.success{background:#ecfff2;border:1px solid #bfeccb;color:#176b33;padding:12px 14px;border-radius:10px}
    input{width:100%;height:48px;border:1px solid #bacce0;border-radius:10px;padding:0 13px;font:inherit;color:#102a4f;background:#fff}input:focus{outline:3px solid rgba(23,109,181,.2);border-color:#176db5}
    label{display:block;font-weight:700;margin-bottom:7px}.field{margin-bottom:17px}.row{display:flex;gap:12px;align-items:center;flex-wrap:wrap}
    @media(max-width:640px){.shell{width:min(100% - 20px,1120px);padding:20px 0}.card{border-radius:16px}.btn{width:100%}}
  </style>
</head>
<body>
${body}
${script ? `<script nonce="${nonce}">${script}</script>` : ''}
</body>
</html>`;
}

function landingPage(session, nonce) {
  const user = session?.user;
  const continueHref = user ? roleHome(user.roles) : '/login';
  const authLabel = user ? `Tiếp tục với ${htmlEscape(user.displayName)}` : 'Đăng nhập';
  const roleCards = [
    ['Học sinh', 'Kế hoạch hôm nay, từ vựng, ngữ pháp, nghe và đọc.', '/student'],
    ['Phụ huynh', 'Theo dõi tiến độ và quản lý đồng thuận.', '/parent'],
    ['Giáo viên', 'Quản lý lớp và theo dõi học sinh.', '/teacher'],
    ['Quản trị', 'Quản lý tài khoản, quyền và vận hành.', '/admin'],
  ].map(([title, description, href]) => `
    <a class="role-card" href="${href}"><strong>${title}</strong><span>${description}</span><b>Mở portal →</b></a>`).join('');

  return baseDocument({
    title: 'English Learning App M4',
    nonce,
    body: `<main class="shell">
      <section class="hero card">
        <span class="badge">Phiên bản ${VERSION}</span>
        <h1>English Learning App</h1>
        <p>Nền tảng học tiếng Anh cá nhân hóa dành cho học sinh lớp 5–8.</p>
        <div class="row">
          <a class="btn btn-primary" href="${continueHref}">${authLabel}</a>
          ${user ? '<button id="logoutButton" class="btn btn-secondary" type="button">Đăng xuất</button>' : '<a class="btn btn-secondary" href="/student/register">Đăng ký học sinh</a>'}
        </div>
      </section>
      <section class="roles">${roleCards}</section>
    </main>
    <style>
      .hero{padding:42px;background:linear-gradient(120deg,#173f70,#2f7cbc);color:#fff}.hero h1{font-size:clamp(38px,6vw,64px);line-height:1;margin:16px 0}.hero p{font-size:18px;max-width:760px}.badge{display:inline-block;background:#eef7ff;color:#1764a3;border-radius:999px;padding:7px 12px;font-weight:800}.roles{display:grid;grid-template-columns:repeat(4,1fr);gap:16px;margin-top:22px}.role-card{display:flex;min-height:180px;flex-direction:column;gap:14px;padding:24px;background:#fff;border:1px solid #d4e0ed;border-radius:16px;text-decoration:none;color:#102a4f;box-shadow:0 8px 28px rgba(17,54,91,.07)}.role-card strong{font-size:24px}.role-card span{color:#5b6f87;line-height:1.5;flex:1}@media(max-width:900px){.roles{grid-template-columns:repeat(2,1fr)}}@media(max-width:560px){.roles{grid-template-columns:1fr}}
    </style>`,
    script: user ? `document.getElementById('logoutButton')?.addEventListener('click', async()=>{await fetch('/api/v1/auth/logout',{method:'POST',credentials:'same-origin'}).catch(()=>null);location.replace('/login?reason=logout');});` : '',
  });
}

function loginPage({ nonce, next, reason }) {
  const notices = {
    expired: 'Phiên đăng nhập đã hết hạn. Vui lòng đăng nhập lại.',
    forbidden: 'Tài khoản của bạn không có quyền mở khu vực vừa chọn.',
    logout: 'Bạn đã đăng xuất an toàn.',
    required: 'Vui lòng đăng nhập để tiếp tục.',
  };
  const notice = notices[reason] ?? '';
  const safeNext = isSafeNext(next) ? next : '';
  return baseDocument({
    title: 'Đăng nhập | English Learning App',
    nonce,
    body: `<main class="shell login-shell">
      <section class="login-card card" aria-labelledby="loginTitle">
        <a href="/" class="back">← Trang chủ</a>
        <span class="badge">English Learning App M4</span>
        <h1 id="loginTitle">Đăng nhập</h1>
        <p class="muted">Sử dụng tài khoản học sinh, phụ huynh, giáo viên hoặc quản trị.</p>
        ${notice ? `<div class="${reason === 'logout' ? 'success' : 'error'}" role="status">${htmlEscape(notice)}</div>` : ''}
        <div id="message" class="error" role="alert" hidden></div>
        <form id="loginForm" novalidate>
          <div class="field"><label for="email">Email</label><input id="email" name="email" type="email" autocomplete="username" maxlength="254" required /></div>
          <div class="field"><label for="password">Mật khẩu</label><div class="password-row"><input id="password" name="password" type="password" autocomplete="current-password" maxlength="128" required /><button id="togglePassword" type="button" class="show-button" aria-label="Hiện mật khẩu">Hiện</button></div></div>
          <button id="submitButton" class="btn btn-primary submit" type="submit">Đăng nhập</button>
        </form>
        <div class="login-links"><a href="/student/register">Đăng ký tài khoản học sinh</a><button id="forgotButton" type="button" class="link-button">Quên mật khẩu?</button></div>
        <p id="forgotHelp" class="muted small" hidden>Phiên bản pilot: vui lòng liên hệ quản trị viên để đặt lại mật khẩu.</p>
      </section>
    </main>
    <style>
      .login-shell{display:grid;place-items:center;min-height:100vh;padding-top:24px;padding-bottom:24px}.login-card{width:min(480px,100%);padding:34px}.login-card h1{font-size:38px;margin:14px 0 8px}.badge{display:inline-block;background:#eaf4ff;color:#1269b0;border-radius:999px;padding:6px 10px;font-weight:800}.back{display:block;margin-bottom:22px;text-decoration:none;font-weight:700}.password-row{display:grid;grid-template-columns:1fr auto}.password-row input{border-radius:10px 0 0 10px}.show-button{min-width:72px;border:1px solid #bacce0;border-left:0;border-radius:0 10px 10px 0;background:#eef5fc;font-weight:700;cursor:pointer}.submit{width:100%;margin-top:2px}.login-links{display:flex;justify-content:space-between;gap:12px;margin-top:22px;flex-wrap:wrap}.link-button{border:0;background:none;padding:0;color:#1269b0;text-decoration:underline;font:inherit;cursor:pointer}.small{font-size:14px}
    </style>`,
    script: `
      const safeNext = ${JSON.stringify(safeNext)};
      const form = document.getElementById('loginForm');
      const message = document.getElementById('message');
      const submit = document.getElementById('submitButton');
      const password = document.getElementById('password');
      const toggle = document.getElementById('togglePassword');
      toggle.addEventListener('click',()=>{const visible=password.type==='text';password.type=visible?'password':'text';toggle.textContent=visible?'Hiện':'Ẩn';toggle.setAttribute('aria-label',visible?'Hiện mật khẩu':'Ẩn mật khẩu');});
      document.getElementById('forgotButton').addEventListener('click',()=>{document.getElementById('forgotHelp').hidden=false;});
      function homeFor(roles){const set=new Set((roles||[]).map(r=>String(typeof r==='string'?r:(r?.code||r?.name||'')).toUpperCase()));if(set.has('STUDENT'))return '/student/today';if(set.has('PARENT')||set.has('GUARDIAN'))return '/parent';if(set.has('TEACHER'))return '/teacher';if([...set].some(r=>r.includes('ADMIN')))return '/admin';return '/';}
      form.addEventListener('submit',async(event)=>{
        event.preventDefault();message.hidden=true;submit.disabled=true;submit.textContent='Đang đăng nhập…';
        try{
          const response=await fetch('/api/v1/auth/login',{method:'POST',headers:{'content-type':'application/json'},credentials:'same-origin',body:JSON.stringify({email:form.email.value.trim(),password:form.password.value})});
          if(!response.ok){const data=await response.json().catch(()=>({}));throw new Error(data.message||data.error?.message||'Email hoặc mật khẩu không đúng.');}
          const sessionResponse=await fetch('/api/v1/auth/session',{credentials:'same-origin',cache:'no-store'});
          const session=await sessionResponse.json().catch(()=>({authenticated:false}));
          if(!session.authenticated)throw new Error('Không thể tạo phiên đăng nhập. Vui lòng thử lại.');
          const home=homeFor(session.user?.roles);
          const target=safeNext&&safeNext.startsWith(home.split('/').slice(0,2).join('/'))?safeNext:home;
          location.replace(target);
        }catch(error){message.textContent=error instanceof Error?error.message:'Đăng nhập thất bại.';message.hidden=false;submit.disabled=false;submit.textContent='Đăng nhập';}
      });
    `,
  });
}

function serviceUnavailablePage(nonce) {
  return baseDocument({
    title: 'Hệ thống đang khởi động',
    nonce,
    body: `<main class="shell"><section class="card" style="padding:34px;max-width:720px;margin:10vh auto"><h1>Hệ thống đang khởi động</h1><p class="muted">API chưa sẵn sàng. Dữ liệu của bạn không bị mất.</p><button class="btn btn-primary" onclick="location.reload()">Thử lại</button></section></main>`,
  });
}

function injectRuntime(html, nonce, session) {
  const user = session?.user;
  const toolbar = user ? `<div id="elaAuthToolbar" style="position:fixed;z-index:2147483000;right:14px;top:12px;display:flex;align-items:center;gap:9px;background:#fff;border:1px solid #cbd9e8;border-radius:999px;padding:7px 9px 7px 13px;box-shadow:0 8px 28px rgba(16,42,79,.18);font:600 13px/1.2 system-ui;color:#16395e"><span>${htmlEscape(user.displayName)}</span><button id="elaLogoutButton" type="button" style="border:0;border-radius:999px;background:#eaf3fb;color:#16395e;padding:7px 11px;font-weight:750;cursor:pointer">Đăng xuất</button></div>` : '';
  const runtime = `<script nonce="${nonce}">(function(){
    const originalFetch=window.fetch.bind(window);
    window.fetch=async function(...args){const response=await originalFetch(...args);if(response.status===401&&!location.pathname.startsWith('/login')){const next=location.pathname+location.search+location.hash;location.replace('/login?reason=expired&next='+encodeURIComponent(next));}return response;};
    window.addEventListener('unhandledrejection',function(event){const text=String(event.reason?.message||event.reason||'');if(text.includes('Missing authentication session')){event.preventDefault();const next=location.pathname+location.search+location.hash;location.replace('/login?reason=expired&next='+encodeURIComponent(next));}});
    document.getElementById('elaLogoutButton')?.addEventListener('click',async function(){this.disabled=true;await fetch('/api/v1/auth/logout',{method:'POST',credentials:'same-origin'}).catch(()=>null);location.replace('/login?reason=logout');});
  })();</script>`;
  let output = rewriteApiOrigins(html);
  output = output.replace(/<script(?![^>]*\bnonce=)/gi, `<script nonce="${nonce}"`);
  if (output.includes('</body>')) output = output.replace('</body>', `${toolbar}${runtime}</body>`);
  else output += `${toolbar}${runtime}`;
  return output;
}

function rewriteApiOrigins(text) {
  return text.replace(/https?:\\?\/\\?\/(?:localhost|127\.0\.0\.1):\d+\\?\/api\\?\/v1/g, '/api/v1');
}

async function resolveStaticFile(pathname) {
  let decoded;
  try { decoded = decodeURIComponent(pathname); } catch { return null; }
  if (decoded.includes('\0') || decoded.includes('\\')) return null;
  const relative = decoded.replace(/^\/+/, '');
  const candidates = relative === ''
    ? ['index.html']
    : [relative, `${relative}.html`, path.join(relative, 'index.html')];
  for (const candidate of candidates) {
    const absolute = path.resolve(STATIC_ROOT, candidate);
    if (!absolute.startsWith(`${path.resolve(STATIC_ROOT)}${path.sep}`) && absolute !== path.resolve(STATIC_ROOT, 'index.html')) continue;
    try {
      const info = await stat(absolute);
      if (info.isFile()) return absolute;
    } catch { /* continue */ }
  }
  return null;
}

async function proxyApi(req, res, url) {
  if (url.pathname === '/api/v1/auth/session' && req.method === 'GET') {
    const session = await inspectSession(req);
    if (session.status === 'unavailable') return sendJson(res, 503, { authenticated: false, unavailable: true });
    return sendJson(res, 200, { authenticated: session.status === 'authenticated', user: session.user });
  }

  const targetPath = `${url.pathname.replace(/^\/api\/v1/, '')}${url.search}`;
  const target = `${INTERNAL_API_BASE}${targetPath}`;
  const chunks = [];
  if (!['GET', 'HEAD'].includes(req.method ?? 'GET')) {
    for await (const chunk of req) chunks.push(chunk);
  }
  const headers = new Headers();
  for (const name of ['accept', 'accept-language', 'content-type', 'cookie', 'user-agent', 'x-request-id']) {
    const value = req.headers[name];
    if (typeof value === 'string') headers.set(name, value);
  }
  try {
    const upstream = await fetchWithTimeout(target, {
      method: req.method,
      headers,
      body: chunks.length ? Buffer.concat(chunks) : undefined,
    });
    const responseBody = Buffer.from(await upstream.arrayBuffer());
    const responseHeaders = {
      'cache-control': 'no-store, max-age=0',
      'x-content-type-options': 'nosniff',
    };
    for (const name of ['content-type', 'retry-after', 'x-request-id']) {
      const value = upstream.headers.get(name);
      if (value) responseHeaders[name] = value;
    }
    const setCookies = typeof upstream.headers.getSetCookie === 'function'
      ? upstream.headers.getSetCookie()
      : upstream.headers.get('set-cookie') ? [upstream.headers.get('set-cookie')] : [];
    if (setCookies.length) responseHeaders['set-cookie'] = setCookies;
    res.writeHead(upstream.status, responseHeaders);
    if (req.method === 'HEAD') res.end(); else res.end(responseBody);
  } catch (error) {
    sendJson(res, 502, { message: 'Không thể kết nối API.', code: 'API_UNAVAILABLE' });
  }
}

async function serveStatic(req, res, pathname, session) {
  const file = await resolveStaticFile(pathname);
  if (!file) {
    const notFound = await resolveStaticFile('/404');
    if (!notFound) return sendJson(res, 404, { message: 'Không tìm thấy trang.' });
    const body = await readFile(notFound);
    res.writeHead(404, { 'content-type': 'text/html; charset=utf-8' });
    return res.end(body);
  }
  const extension = path.extname(file).toLowerCase();
  const contentType = MIME_TYPES.get(extension) ?? 'application/octet-stream';
  const isText = ['.html', '.js', '.mjs', '.css', '.json', '.map', '.txt'].includes(extension);
  let body = await readFile(file);
  const headers = {
    'content-type': contentType,
    'x-content-type-options': 'nosniff',
    'cache-control': extension === '.html' ? 'no-store, max-age=0' : 'public, max-age=31536000, immutable',
  };
  if (isText) {
    let text = body.toString('utf8');
    if (extension === '.html') {
      const nonce = newNonce();
      text = injectRuntime(text, nonce, session);
      Object.assign(headers, securityHeaders(nonce, contentType));
    } else if (extension === '.js' || extension === '.mjs') {
      text = rewriteApiOrigins(text);
      headers['cache-control'] = 'no-store, max-age=0';
    }
    body = Buffer.from(text);
  }
  headers['content-length'] = body.length;
  res.writeHead(200, headers);
  if (req.method === 'HEAD') res.end(); else res.end(body);
}

const server = http.createServer(async (req, res) => {
  const requestUrl = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
  const pathname = requestUrl.pathname.replace(/\/$/, '') || '/';

  try {
    if (pathname.startsWith('/api/v1/')) return await proxyApi(req, res, requestUrl);
    if (pathname === '/__ela/health') {
      return sendJson(res, 200, {
        ok: true,
        version: VERSION,
        authGateway: true,
        apiProxy: INTERNAL_API_BASE,
        staticRoot: path.basename(STATIC_ROOT),
      });
    }

    const staticAsset = pathname.startsWith('/_next/') || /\.[a-zA-Z0-9]{2,6}$/.test(pathname);
    if (staticAsset) return await serveStatic(req, res, pathname, null);

    const session = await inspectSession(req);
    if (pathname === '/') {
      const nonce = newNonce();
      return sendHtml(res, 200, landingPage(session.status === 'authenticated' ? session : null, nonce), nonce);
    }
    if (pathname === '/login') {
      const next = requestUrl.searchParams.get('next') ?? '';
      if (session.status === 'authenticated') return redirect(res, isSafeNext(next) ? next : roleHome(session.user.roles));
      const nonce = newNonce();
      return sendHtml(res, 200, loginPage({ nonce, next, reason: requestUrl.searchParams.get('reason') ?? '' }), nonce);
    }

    const rule = expectedRule(pathname);
    const isPublic = PUBLIC_PATHS.has(pathname);
    if (rule && !isPublic) {
      if (session.status === 'unavailable') {
        const nonce = newNonce();
        return sendHtml(res, 503, serviceUnavailablePage(nonce), nonce);
      }
      if (session.status !== 'authenticated') {
        const next = `${pathname}${requestUrl.search}`;
        return redirect(res, `/login?reason=required&next=${encodeURIComponent(next)}`);
      }
      if (!roleAllowed(session.user, rule)) {
        return redirect(res, `${roleHome(session.user.roles)}?reason=forbidden`);
      }
    }

    return await serveStatic(req, res, pathname, session.status === 'authenticated' ? session : null);
  } catch (error) {
    console.error('web_request_failed', { path: pathname, message: error instanceof Error ? error.message : String(error) });
    sendJson(res, 500, { message: 'Web server gặp lỗi.', code: 'WEB_RUNTIME_ERROR' });
  }
});

server.listen(WEB_PORT, '0.0.0.0', () => {
  console.log(`ELA v0.4.9 auth gateway listening on http://0.0.0.0:${WEB_PORT}`);
  console.log(`Static root: ${STATIC_ROOT}`);
  console.log(`Internal API: ${INTERNAL_API_BASE}`);
});

function shutdown(signal) {
  console.log(`Received ${signal}; shutting down web server.`);
  server.close(() => process.exit(0));
  setTimeout(() => process.exit(1), 8_000).unref();
}

process.on('SIGTERM', () => shutdown('SIGTERM'));
process.on('SIGINT', () => shutdown('SIGINT'));
