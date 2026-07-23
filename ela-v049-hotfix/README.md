# English Learning App v0.4.9 – Authentication UX Hotfix

Bộ vá này áp dụng lên bản **EnglishLearningApp M4 One-Click v0.4.8** đang chạy trên Windows/Docker Desktop. Bộ vá không xóa PostgreSQL, Redis hoặc MinIO volume.

## Lỗi được xử lý

- Trang chủ và Student Portal mở được khi chưa đăng nhập.
- Chỉ khi vào nội dung học mới xuất hiện `Missing authentication session.`
- Không có trang đăng nhập rõ ràng.
- Không tự chuyển về đăng nhập khi phiên hết hạn.
- Không điều hướng theo vai trò.
- Không có nút đăng xuất tại portal.
- Web và API chạy khác cổng làm cookie/CORS khó ổn định.

## Chức năng v0.4.9

- Trang đăng nhập chung tại `/login`.
- Login/logout qua proxy cùng origin `/api/v1`.
- `GET /api/v1/auth/session` ở Web gateway, dựa trên API `/auth/me` hiện có.
- Guard phía Web server cho `/student`, `/parent`, `/teacher`, `/admin`.
- Redirect deep link bằng tham số `next`.
- Role routing:
  - STUDENT → `/student/today`
  - PARENT/GUARDIAN → `/parent`
  - TEACHER → `/teacher`
  - ADMIN → `/admin`
- Tự chuyển về `/login` khi API trả 401 hoặc session hết hạn.
- Thanh tài khoản và nút Đăng xuất trên các portal đã xác thực.
- Reverse proxy API cùng origin để cookie HttpOnly hoạt động ổn định ở cổng Web động.
- Tự thay API URL `localhost:<api-port>` trong static JavaScript thành `/api/v1` khi phục vụ.
- CSP nonce theo từng response, không dùng `unsafe-inline` cho script.
- Health endpoint: `/__ela/health`.

## Cách áp dụng

1. Giải nén gói hotfix.
2. Đặt thư mục hotfix vào bên trong thư mục dự án v0.4.8, hoặc chạy file BAT và nhập đường dẫn dự án khi được hỏi.
3. Click đúp:

```text
00_AP_DUNG_V049_VA_CHAY.bat
```

4. Cho phép PowerShell chạy nếu Windows hỏi.
5. Chờ Docker build lại Web/API/Worker.
6. Trình duyệt tự mở trang:

```text
http://localhost:<WEB_PORT>/login?next=/student/today
```

## Tài khoản demo local

Tài khoản demo chỉ tồn tại khi `.env` đang có `SEED_DEMO_DATA=true`:

```text
student@example.com
parent@example.com
teacher@example.com
admin@example.com
```

Mật khẩu demo được giữ trong README của bản One-Click gốc; bộ hotfix không nhúng mật khẩu vào JavaScript hoặc log.

## Dữ liệu và rollback

Script chỉ chạy:

```text
docker compose down --remove-orphans
docker compose up -d --build --force-recreate --remove-orphans
```

Script **không** chạy `docker compose down -v` và không xóa volume.

Web runtime cũ được backup thành:

```text
apps/web/server.mjs.v048_backup_YYYYMMDD_HHMMSS
```

Để rollback thủ công:

1. Dừng container bằng `DUNG_PHAN_MEM.bat`.
2. Đổi file backup về `apps/web/server.mjs`.
3. Chạy `SUA_LOI_VA_CHAY_LAI.bat` của bản One-Click.

## Kiểm tra sau khi cài

Mở:

```text
http://localhost:<WEB_PORT>/__ela/health
```

Kết quả phải chứa:

```json
{
  "ok": true,
  "version": "0.4.9-m4-auth-ux",
  "authGateway": true
}
```

Kiểm tra thủ công:

1. Mở `/student/today` ở cửa sổ ẩn danh → phải chuyển tới `/login`.
2. Đăng nhập học sinh → chuyển tới `/student/today`.
3. Refresh trang → vẫn giữ phiên.
4. Đăng xuất → quay lại `/login`.
5. Đăng nhập phụ huynh rồi mở `/student/today` → chuyển về `/parent`.
6. Không còn thấy `Missing authentication session.`.

## Technical debt

- Quên mật khẩu hiện hiển thị hướng dẫn liên hệ quản trị; API reset-password chưa thuộc bản vá runtime này.
- Rotating refresh token và session revocation đầy đủ vẫn thuộc Production Hardening.
- Parent/Teacher dashboard đầy đủ thuộc M8; v0.4.9 chỉ bảo vệ và điều hướng portal hiện có.
