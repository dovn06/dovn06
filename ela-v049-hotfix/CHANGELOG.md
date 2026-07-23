# CHANGELOG

## 0.4.9.3-m4-auth-role-ui — 2026-07-23

### Added

- Nút **Đăng nhập** cố định tại góc phải trên cùng khi chưa có phiên.
- Thanh tài khoản góc phải hiển thị tên, loại tài khoản và nút Đăng xuất khi đã đăng nhập.
- Bộ chọn loại tài khoản tại `/login`: Học sinh, Phụ huynh, Giáo viên và Quản trị.
- Các thẻ portal tự mở login với loại tài khoản tương ứng được chọn sẵn.
- Health flags `accountTypeSelector` và `topRightLogin`.
- Installer Windows v0.4.9.3 và regression test tương ứng.

### Changed

- Redirect anonymous tới login kèm `accountType` và deep link `next`.
- Điều hướng sau đăng nhập dựa trên cả lựa chọn giao diện và vai trò thật từ API.
- Portal toolbar hiển thị nhãn vai trò thân thiện.

### Fixed

- Không còn vùng trống ở góc phải trang chủ khi chưa đăng nhập.
- Chọn sai loại tài khoản không giữ lại phiên đăng nhập và không mở sai portal.
- Nút đăng nhập cũng xuất hiện trên các trang public được phục vụ từ static export.

### Security

- Loại tài khoản do người dùng chọn không làm thay đổi RBAC.
- Quyền thực tế vẫn lấy từ JWT/session và được kiểm tra ở Web guard lẫn API.
- Không nhúng tài khoản hoặc mật khẩu demo vào production JavaScript.

### Data safety

- Không thay đổi database schema hoặc seed.
- Không chạy `docker compose down -v`.
- Không xóa PostgreSQL hoặc MinIO volume.

## 0.4.9-m4-auth-ux — 2026-07-23

### Added

- Trang đăng nhập chung `/login`.
- Same-origin API proxy `/api/v1/*`.
- Session alias `/api/v1/auth/session`.
- Guard cho Student, Parent, Teacher và Admin portal.
- Deep-link `next` sau khi đăng nhập.
- Role routing theo session.
- Global 401 redirect về login.
- Thanh tài khoản và nút Đăng xuất.
- Landing page v0.4.9.
- Web health endpoint `/__ela/health`.
- Bộ cài đặt Windows và log riêng cho auth hotfix.
- Regression test với mock API.

### Changed

- Thay `apps/web/server.mjs` bằng authentication gateway runtime.
- API URL trong static HTML/JavaScript được đổi sang same-origin khi phục vụ.
- CSP script dùng nonce theo từng response.
- Anonymous không còn được tải portal trước khi kiểm tra session.

### Fixed

- Không còn thông báo kỹ thuật `Missing authentication session.` cho người dùng cuối.
- Cookie phiên không còn phụ thuộc vào API port được compile trong frontend.
- Tài khoản sai vai trò không còn mở portal không thuộc quyền.
- Phiên hết hạn tự đưa người dùng về trang đăng nhập.

### Data safety

- Không thay đổi database schema.
- Không thay đổi seed.
- Không xóa PostgreSQL hoặc MinIO volume.

### Known limitations

- Forgot/reset-password API chưa được triển khai trong runtime hotfix.
- Refresh-token rotation, MFA và session revocation đầy đủ vẫn là technical debt Production Hardening.
