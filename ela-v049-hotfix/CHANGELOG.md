# CHANGELOG

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
