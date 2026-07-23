# English Learning App v0.4.9.1 – Authentication UX Hotfix Path Fix

Bộ vá này áp dụng lên bản **EnglishLearningApp M4 One-Click v0.4.8** đang chạy trên Windows/Docker Desktop. Bộ vá không xóa PostgreSQL, Redis hoặc MinIO volume.

## Lỗi được xử lý

### Lỗi xác thực v0.4.9

- Trang chủ và Student Portal mở được khi chưa đăng nhập.
- Chỉ khi vào nội dung học mới xuất hiện `Missing authentication session.`
- Không có trang đăng nhập rõ ràng.
- Không tự chuyển về đăng nhập khi phiên hết hạn.
- Không điều hướng theo vai trò.
- Không có nút đăng xuất tại portal.
- Web và API chạy khác cổng làm cookie/CORS khó ổn định.

### Lỗi đường dẫn được sửa trong v0.4.9.1

Bản v0.4.9 cũ chỉ tìm repository trong thư mục hotfix và một cấp lân cận. Khi hotfix nằm ở `E:\English\R10` nhưng repository thật nằm ở `E:\English\R9\EnglishLearningApp_M4_OneClick_v0.4.8_FIXED`, script không tìm thấy project; nếu nhấn Enter tại ô nhập đường dẫn thì dừng với lỗi `Thu muc du an khong hop le:`.

Bản v0.4.9.1 đã sửa:

- Tự đọc working directory từ container Docker Compose cũ.
- Tự quét các thư mục cha và các thư mục `R*` lân cận.
- Tìm được project khi đường dẫn chứa khoảng trắng.
- Hiển thị danh sách để chọn khi máy có nhiều bản R6/R7/R8/R9.
- Nhấn Enter sẽ chọn bản cập nhật gần nhất, không tạo đường dẫn rỗng.
- Có cửa sổ chọn thư mục khi không tự tìm thấy.
- Cho phép thử nhập đường dẫn tối đa ba lần.
- Có thể kéo-thả thư mục project vào file BAT.
- Tạo log ngay trong `hotfix\logs`, kể cả khi chưa tìm thấy project.

## Chức năng xác thực

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
- CSP nonce theo từng response.
- Health endpoint: `/__ela/health`.

## Cách áp dụng khuyến nghị

1. Giải nén gói v0.4.9.1 vào một thư mục bất kỳ, ví dụ:

```text
E:\English\R11\EnglishLearningApp_v0.4.9.1_AuthHotfix_PathFix
```

2. Click đúp:

```text
00_AP_DUNG_V049_VA_CHAY.bat
```

3. Script sẽ ưu tiên theo thứ tự:

```text
ProjectRoot được truyền vào
→ ELA_PROJECT_ROOT
→ working directory của container Docker Compose cũ
→ project trong thư mục hotfix/thư mục cha
→ project trong các thư mục R* lân cận
→ Desktop/Downloads/Documents
→ cửa sổ chọn thư mục
→ nhập đường dẫn thủ công
```

4. Nếu tìm thấy nhiều bản, màn hình sẽ hiển thị:

```text
[1] E:\English\R9\EnglishLearningApp_M4_OneClick_v0.4.8_FIXED
[2] E:\English\R8\...
```

Nhấn Enter để chọn mục 1 hoặc nhập số tương ứng.

5. Chờ Docker build lại Web/API/Worker. Trình duyệt tự mở:

```text
http://localhost:<WEB_PORT>/login?next=/student/today
```

## Cách chạy chắc chắn bằng kéo-thả

Khi máy có nhiều thư mục dự án:

1. Mở File Explorer.
2. Giữ chuột vào thư mục project thật, ví dụ:

```text
E:\English\R9\EnglishLearningApp_M4_OneClick_v0.4.8_FIXED
```

3. Kéo thư mục đó thả lên file:

```text
00_AP_DUNG_V049_VA_CHAY.bat
```

BAT sẽ truyền chính xác đường dẫn project vào installer.

## Cách nhận biết đúng thư mục project

Thư mục hợp lệ phải có đủ:

```text
docker-compose.yml
package.json
apps\web\server.mjs
```

Không chọn thư mục chỉ chứa `scripts`, `patch` hoặc file BAT của hotfix.

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

## Log

Log dò đường dẫn và cài đặt luôn được tạo tại:

```text
<THU_MUC_HOTFIX>\logs\v0491_auth_hotfix_YYYYMMDD_HHMMSS.log
```

Khi đã tìm thấy project, log và Docker snapshot cũng được chép vào:

```text
<THU_MUC_PROJECT>\logs
```

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

1. Mở `/student/today` ở cửa sổ ẩn danh → chuyển tới `/login`.
2. Đăng nhập học sinh → chuyển tới `/student/today`.
3. Refresh trang → vẫn giữ phiên.
4. Đăng xuất → quay lại `/login`.
5. Đăng nhập phụ huynh rồi mở `/student/today` → chuyển về `/parent`.
6. Không còn thấy `Missing authentication session.`.

## Technical debt

- Quên mật khẩu hiện hiển thị hướng dẫn liên hệ quản trị; API reset-password chưa thuộc bản vá runtime này.
- Rotating refresh token và session revocation đầy đủ vẫn thuộc Production Hardening.
- Parent/Teacher dashboard đầy đủ thuộc M8; v0.4.9.1 chỉ bảo vệ và điều hướng portal hiện có.
