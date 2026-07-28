# Báo cáo triển khai v0.4.9 – Authentication UX, Session Guard & Role Routing

## 1. Phạm vi

Bản v0.4.9 sửa lớp xác thực và điều hướng của English Learning App M4 mà không thay đổi schema hoặc dữ liệu học tập M0–M4.

Các yêu cầu được triển khai:

- Trang đăng nhập chung `/login`.
- Trang chủ v0.4.9 có nút đăng nhập và đăng ký.
- Guard cho `/student`, `/parent`, `/teacher`, `/admin`.
- Deep-link redirect bằng `next`.
- Điều hướng mặc định theo vai trò.
- Session endpoint cùng origin `/api/v1/auth/session`.
- Login/logout proxy cùng origin.
- Tự chuyển tới login khi API trả 401 hoặc JavaScript phát hiện session hết hạn.
- Hiển thị tài khoản và nút đăng xuất trên portal.
- Không còn hiển thị `Missing authentication session.` cho người dùng cuối.
- CSP nonce theo từng response.
- Giữ nguyên PostgreSQL và MinIO volumes.

## 2. Kiến trúc bản vá

Bản v0.4.8 dùng Next.js static export và Web runtime `apps/web/server.mjs`. Bản v0.4.9 thay Web runtime này bằng một authentication gateway sử dụng module chuẩn của Node.js 22.

Gateway thực hiện:

1. Phục vụ static export hiện có.
2. Reverse proxy `/api/v1/*` tới `http://api:4000/api/v1` trong Docker network.
3. Chuyển cookie `Set-Cookie` từ API tới browser.
4. Kiểm tra session qua API `/auth/me` trước khi trả portal HTML.
5. Chặn sai vai trò ở Web edge, trước khi React tải nội dung.
6. Thay API origin đã compile trong JavaScript thành `/api/v1` khi phục vụ.
7. Gắn CSP nonce vào các bootstrap script của Next.js.
8. Chèn runtime xử lý 401 và nút đăng xuất.

Cách này giải quyết đồng thời:

- Web/API chạy khác cổng.
- Cookie HttpOnly không được browser gửi ổn định khi frontend gọi sai origin.
- Portal tĩnh hiển thị trước khi biết trạng thái session.
- Thông báo kỹ thuật xuất hiện thay vì redirect login.

## 3. Luồng sau khi sửa

### Anonymous

```text
/student/today
→ 302 /login?reason=required&next=/student/today
→ đăng nhập
→ kiểm tra /api/v1/auth/session
→ /student/today
```

### Sai vai trò

```text
PARENT mở /student/today
→ Web gateway đọc session
→ 302 /parent?reason=forbidden
```

### Phiên hết hạn

```text
API trả 401
→ global fetch interceptor
→ /login?reason=expired&next=<đường dẫn hiện tại>
```

### Đăng xuất

```text
POST /api/v1/auth/logout
→ API xóa cookie
→ /login?reason=logout
```

## 4. Role routing

| Vai trò | Trang mặc định |
|---|---|
| STUDENT | `/student/today` |
| PARENT / GUARDIAN | `/parent` |
| TEACHER | `/teacher` |
| ADMIN / SYSTEM_ADMIN / CONTENT_ADMIN / SUPER_ADMIN | `/admin` |

## 5. File được thêm hoặc thay thế

Trong gói hotfix:

```text
00_AP_DUNG_V049_VA_CHAY.bat
scripts/Apply-V049-AuthHotfix.ps1
patch/apps/web/server.mjs
README.md
docs/V049_AUTH_IMPLEMENTATION_REPORT.md
docs/V049_TEST_REPORT.md
CHANGELOG.md
```

Khi áp dụng vào repository:

```text
apps/web/server.mjs                         Thay thế
apps/web/server.mjs.v048_backup_<time>     Tạo backup
AUTH_V049_APPLIED.txt                      Tạo marker
logs/v049_auth_hotfix_<time>.log           Tạo log
logs/v049_docker_<time>.log                Tạo Docker snapshot
```

Installer không chỉnh sửa `package.json`, `pnpm-lock.yaml`, migration hoặc seed.

## 6. Dữ liệu

Bản vá không có database migration và không thay đổi seed.

Installer không chạy:

```text
docker compose down -v
docker volume rm
```

PostgreSQL và MinIO volumes được dùng lại.

## 7. Phần chưa hoàn thành

- API forgot/reset-password chưa được thêm; trang login hướng dẫn liên hệ quản trị trong pilot.
- Rotating refresh token và server-side session revocation đầy đủ vẫn thuộc Production Hardening.
- MFA admin chưa thuộc runtime hotfix.
- Parent/Teacher dashboard sâu thuộc M8; v0.4.9 chỉ bảo vệ và điều hướng portal hiện tại.

## 8. Rollback

Web runtime cũ được lưu thành:

```text
apps/web/server.mjs.v048_backup_YYYYMMDD_HHMMSS
```

Khôi phục file backup rồi chạy lại `SUA_LOI_VA_CHAY_LAI.bat`. Không cần rollback database.
