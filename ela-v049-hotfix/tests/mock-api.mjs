import http from 'node:http';

const port = Number.parseInt(process.env.MOCK_API_PORT ?? '4100', 10);

function sendJson(res, status, payload, headers = {}) {
  const body = JSON.stringify(payload);
  res.writeHead(status, {
    'content-type': 'application/json; charset=utf-8',
    'content-length': Buffer.byteLength(body),
    ...headers,
  });
  res.end(body);
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url ?? '/', `http://${req.headers.host ?? 'localhost'}`);
  if (url.pathname === '/api/v1/health/ready') return sendJson(res, 200, { ok: true });

  if (url.pathname === '/api/v1/auth/login' && req.method === 'POST') {
    const body = JSON.parse((await readBody(req)) || '{}');
    if (!body.email || !body.password) return sendJson(res, 400, { message: 'Missing credentials' });
    const role = String(body.email).includes('parent') ? 'PARENT'
      : String(body.email).includes('teacher') ? 'TEACHER'
      : String(body.email).includes('admin') ? 'ADMIN'
      : 'STUDENT';
    return sendJson(res, 200, { ok: true }, {
      'set-cookie': `ela_access_token=${role.toLowerCase()}; HttpOnly; Path=/; SameSite=Lax`,
    });
  }

  if (url.pathname === '/api/v1/auth/logout' && req.method === 'POST') {
    return sendJson(res, 200, { ok: true }, {
      'set-cookie': 'ela_access_token=; HttpOnly; Path=/; SameSite=Lax; Max-Age=0',
    });
  }

  if (url.pathname === '/api/v1/auth/me' && req.method === 'GET') {
    const match = /(?:^|;\s*)ela_access_token=([^;]+)/.exec(req.headers.cookie ?? '');
    if (!match) return sendJson(res, 401, { message: 'Unauthorized' });
    const token = match[1].toUpperCase();
    const role = ['STUDENT', 'PARENT', 'TEACHER', 'ADMIN'].includes(token) ? token : 'STUDENT';
    return sendJson(res, 200, {
      id: `user-${role.toLowerCase()}`,
      displayName: `${role} Demo`,
      email: `${role.toLowerCase()}@example.com`,
      roles: [role],
    });
  }

  return sendJson(res, 404, { message: 'Not found' });
});

server.listen(port, '127.0.0.1', () => console.log(`Mock API on ${port}`));
for (const signal of ['SIGINT', 'SIGTERM']) process.on(signal, () => server.close(() => process.exit(0)));
