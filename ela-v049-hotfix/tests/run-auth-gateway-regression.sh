#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP="$(mktemp -d)"
cleanup() {
  set +e
  [[ -n "${WEB_PID:-}" ]] && kill "$WEB_PID" 2>/dev/null
  [[ -n "${API_PID:-}" ]] && kill "$API_PID" 2>/dev/null
  rm -rf "$TMP"
}
trap cleanup EXIT

mkdir -p "$TMP/apps/web/out/student/today" "$TMP/apps/web/out/parent" "$TMP/apps/web/out/teacher" "$TMP/apps/web/out/admin" "$TMP/apps/web/out/_next/static/chunks"
cp "$ROOT/patch/apps/web/server.mjs" "$TMP/apps/web/server.mjs"
cat > "$TMP/apps/web/out/index.html" <<'HTML'
<!doctype html><html><body><h1>Old landing</h1><script>window.__BOOT=true</script></body></html>
HTML
cat > "$TMP/apps/web/out/student/today/index.html" <<'HTML'
<!doctype html><html><body><main id="student-content">Kế hoạch hôm nay</main><script>fetch('http://localhost:4000/api/v1/auth/me')</script></body></html>
HTML
cat > "$TMP/apps/web/out/parent/index.html" <<'HTML'
<!doctype html><html><body><main>Parent portal</main><script>window.__PARENT=true</script></body></html>
HTML
cat > "$TMP/apps/web/out/teacher/index.html" <<'HTML'
<!doctype html><html><body><main>Teacher portal</main></body></html>
HTML
cat > "$TMP/apps/web/out/admin/index.html" <<'HTML'
<!doctype html><html><body><main>Admin portal</main></body></html>
HTML
cat > "$TMP/apps/web/out/404.html" <<'HTML'
<!doctype html><html><body>404</body></html>
HTML
cat > "$TMP/apps/web/out/_next/static/chunks/app.js" <<'JS'
fetch("http://localhost:4000/api/v1/auth/me");
JS

MOCK_API_PORT=4100 node "$ROOT/tests/mock-api.mjs" >"$TMP/mock-api.log" 2>&1 &
API_PID=$!
(
  cd "$TMP/apps/web"
  WEB_PORT=3100 ELA_INTERNAL_API_URL=http://127.0.0.1:4100/api/v1 node server.mjs >"$TMP/web.log" 2>&1
) &
WEB_PID=$!

for _ in $(seq 1 40); do
  if curl -fsS http://127.0.0.1:3100/__ela/health >/dev/null; then break; fi
  sleep 0.25
done

HEALTH="$(curl -fsS http://127.0.0.1:3100/__ela/health)"
grep -q '0.4.9-m4-auth-ux' <<<"$HEALTH"
grep -q '"authGateway":true' <<<"$HEALTH"

LOGIN_HTML="$(curl -fsS 'http://127.0.0.1:3100/login?next=%2Fstudent%2Ftoday')"
grep -q 'Đăng nhập' <<<"$LOGIN_HTML"
grep -q '/api/v1/auth/login' <<<"$LOGIN_HTML"

HEADERS="$(curl -sS -D - -o /dev/null http://127.0.0.1:3100/student/today)"
grep -qi '^HTTP/.* 302' <<<"$HEADERS"
grep -qi '^location: /login?reason=required&next=%2Fstudent%2Ftoday' <<<"$HEADERS"

curl -fsS -c "$TMP/student.cookies" -H 'content-type: application/json' \
  -d '{"email":"student@example.com","password":"Demo123!"}' \
  http://127.0.0.1:3100/api/v1/auth/login >/dev/null
SESSION="$(curl -fsS -b "$TMP/student.cookies" http://127.0.0.1:3100/api/v1/auth/session)"
grep -q '"authenticated":true' <<<"$SESSION"
grep -q 'STUDENT' <<<"$SESSION"

STUDENT_HTML="$(curl -fsS -b "$TMP/student.cookies" http://127.0.0.1:3100/student/today)"
grep -q 'Kế hoạch hôm nay' <<<"$STUDENT_HTML"
grep -q 'elaLogoutButton' <<<"$STUDENT_HTML"
grep -q 'nonce=' <<<"$STUDENT_HTML"
if grep -q 'http://localhost:4000/api/v1' <<<"$STUDENT_HTML"; then
  echo 'API origin was not rewritten in HTML' >&2
  exit 1
fi

grep -q "fetch(\"/api/v1/auth/me\")" <(curl -fsS http://127.0.0.1:3100/_next/static/chunks/app.js)

curl -fsS -c "$TMP/parent.cookies" -H 'content-type: application/json' \
  -d '{"email":"parent@example.com","password":"Demo123!"}' \
  http://127.0.0.1:3100/api/v1/auth/login >/dev/null
PARENT_HEADERS="$(curl -sS -b "$TMP/parent.cookies" -D - -o /dev/null http://127.0.0.1:3100/student/today)"
grep -qi '^HTTP/.* 302' <<<"$PARENT_HEADERS"
grep -qi '^location: /parent?reason=forbidden' <<<"$PARENT_HEADERS"

curl -fsS -b "$TMP/student.cookies" -c "$TMP/student.cookies" -X POST http://127.0.0.1:3100/api/v1/auth/logout >/dev/null
POST_LOGOUT="$(curl -fsS -b "$TMP/student.cookies" http://127.0.0.1:3100/api/v1/auth/session)"
grep -q '"authenticated":false' <<<"$POST_LOGOUT"

CSP="$(curl -sS -D - -o /dev/null -b "$TMP/parent.cookies" http://127.0.0.1:3100/parent)"
grep -qi '^content-security-policy:.*nonce-' <<<"$CSP"
grep -qi '^x-frame-options: DENY' <<<"$CSP"

echo 'v0.4.9 auth gateway regression: PASS'
