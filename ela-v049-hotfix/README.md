# English Learning App v0.4.9.3 – Role Login UI

Bộ cập nhật này áp dụng lên English Learning App M4 One-Click đang chạy trên Windows và Docker Desktop. Bộ cập nhật không xóa PostgreSQL, Redis hoặc MinIO volume.

## Nội dung v0.4.9.3

- Nút **Đăng nhập** luôn nằm tại góc phải trên cùng khi chưa có phiên.
- Khi đã đăng nhập, góc phải hiển thị tên, loại tài khoản và nút **Đăng xuất**.
- Trang `/login` có bộ chọn loại tài khoản:
  - Học sinh
  - Phụ huynh
  - Giáo viên
  - Quản trị
- Các thẻ portal trên trang chủ tự mở login và chọn sẵn loại tài khoản tương ứng.
- Loại tài khoản do người dùng chọn chỉ dùng cho giao diện và điều hướng; quyền thực tế luôn lấy từ RBAC của API.
- Khi chọn sai loại tài khoản, hệ thống đăng xuất phiên vừa tạo và yêu cầu chọn lại đúng loại.
- Anonymous mở `/student`, `/parent`, `/teacher` hoặc `/admin` được chuyển tới login với loại tài khoản phù hợp.
- Cookie HttpOnly tiếp tục đi qua same-origin API gateway.
- Giữ nguyên xử lý phiên hết hạn, deep link, CSP nonce và logout.

## Cách áp dụng

1. Giải nén gói ZIP.
2. Click đúp:

```text
00_AP_DUNG_V049_VA_CHAY.bat
```

3. Bộ cài tự tìm project đang chạy. Khi có nhiều project, chọn đúng thư mục đang chứa bản M4 hiện tại.
4. Chờ Docker build lại và trình duyệt tự mở:

```text
http://localhost:<WEB_PORT>/login?accountType=student&next=/student/today
```

Có thể kéo-thả thư mục project vào file BAT để truyền đường dẫn trực tiếp.

## Kiểm tra sau khi cài

Mở:

```text
http://localhost:<WEB_PORT>/__ela/health
```

Kết quả phải có:

```json
{
  "ok": true,
  "version": "0.4.9.3-m4-auth-role-ui",
  "authGateway": true,
  "accountTypeSelector": true,
  "topRightLogin": true
}
```

Kiểm tra thủ công:

1. Đăng xuất rồi mở trang chủ: nút **Đăng nhập** phải nằm ở góc phải trên cùng.
2. Mở `/login`: phải có bộ chọn bốn loại tài khoản.
3. Chọn Học sinh và đăng nhập bằng tài khoản học sinh: chuyển tới `/student/today`.
4. Chọn Phụ huynh nhưng nhập tài khoản học sinh: hệ thống báo chọn sai loại và không giữ phiên.
5. Đăng nhập phụ huynh: chuyển tới `/parent`.
6. Refresh trình duyệt: phiên vẫn được giữ.
7. Đăng xuất: quay lại `/login`.

## Dữ liệu

Script chỉ dừng và tạo lại container, không chạy:

```text
docker compose down -v
docker volume rm
```

Toàn bộ dữ liệu M0–M4 và media được giữ nguyên.

Web runtime trước khi cập nhật được backup tự động:

```text
apps\web\server.mjs.v0492_backup_YYYYMMDD_HHMMSS
```

## Tài khoản demo local

Tài khoản demo chỉ tồn tại khi `.env` có `SEED_DEMO_DATA=true`:

```text
student@example.com
parent@example.com
teacher@example.com
admin@example.com
```

Bộ cập nhật không nhúng mật khẩu demo vào JavaScript hoặc log.

## Technical debt

- Quên mật khẩu hiện vẫn là hướng dẫn liên hệ quản trị trong pilot.
- Rotating refresh token, session revocation và MFA admin thuộc Production Hardening.
- Parent/Teacher dashboard đầy đủ thuộc M8.
