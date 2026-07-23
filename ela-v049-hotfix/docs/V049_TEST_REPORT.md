# Báo cáo kiểm thử v0.4.9 Authentication Hotfix

## Môi trường CI

```text
GitHub Actions ubuntu-24.04
Node.js 24 runner default
PowerShell Core
Bash + curl
```

## Kết quả lệnh thực tế

| Quality gate | Kết quả |
|---|---|
| `node --check patch/apps/web/server.mjs` | PASS |
| `node --check tests/mock-api.mjs` | PASS |
| PowerShell parser cho installer | PASS |
| Quét lệnh xóa Docker volume | PASS |
| Auth gateway regression E2E | PASS |
| Quét `.env` và runtime secret | PASS |
| Tạo ZIP | PASS |
| `unzip -tq` | PASS |
| Upload workflow artifact | PASS |

Workflow:

```text
Build ELA v0.4.9 Auth Hotfix
Run 5
Conclusion: success
```

## Regression cases đã chạy

1. Health endpoint trả version `0.4.9-m4-auth-ux`.
2. `/login` hiển thị form đăng nhập.
3. Anonymous mở `/student/today` nhận HTTP 302 tới login, có giữ `next`.
4. Login đi qua same-origin proxy và browser nhận cookie HttpOnly mô phỏng.
5. `/api/v1/auth/session` trả `authenticated=true` sau login.
6. STUDENT mở `/student/today` thành công.
7. HTML portal có nút Đăng xuất.
8. HTML và script có CSP nonce.
9. API origin `http://localhost:4000/api/v1` trong HTML được đổi thành `/api/v1`.
10. Static JavaScript asset được rewrite API origin.
11. PARENT mở Student route bị chuyển về `/parent?reason=forbidden`.
12. Logout xóa cookie và session trở thành anonymous.
13. Security header có `Content-Security-Policy` và `X-Frame-Options: DENY`.
14. Không có lệnh `docker compose down -v` hoặc `docker volume rm` trong script chạy.
15. Không đóng gói `.env`, JWT secret hoặc database credential.

## Phạm vi chưa kiểm thử trong CI này

Do source repository v0.4.8 được cung cấp dưới dạng file hội thoại và sandbox local bị lỗi, CI của hotfix không chạy lại toàn bộ monorepo `pnpm build/lint/test`. Installer trên máy Windows sẽ chạy Docker `up -d --build`, vì vậy Web/API/Worker của repository thực tế vẫn được build lại trước khi mở trình duyệt.

Mã nghiệp vụ M0–M4, migration và database schema không thay đổi trong hotfix.

## Checklist trên máy Windows

Sau khi áp dụng:

```text
GET http://localhost:<WEB_PORT>/__ela/health
```

phải trả:

```json
{
  "ok": true,
  "version": "0.4.9-m4-auth-ux",
  "authGateway": true
}
```

Kiểm tra browser:

- Cửa sổ ẩn danh mở `/student/today` phải chuyển tới login.
- Login học sinh phải vào `/student/today`.
- Refresh phải giữ phiên.
- Logout phải quay lại login.
- Login phụ huynh không được mở Student portal.
- Không còn chuỗi `Missing authentication session.`.
