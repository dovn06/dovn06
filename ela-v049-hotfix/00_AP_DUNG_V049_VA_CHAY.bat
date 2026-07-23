@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
echo ===============================================================
echo ENGLISH LEARNING APP v0.4.9.3 - DANG NHAP THEO LOAI TAI KHOAN
echo ===============================================================
echo.
set "PROJECT_ROOT=%~1"
if defined PROJECT_ROOT (
  echo Dang dung thu muc project duoc truyen vao: %PROJECT_ROOT%
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Apply-V0493-RoleUi.ps1" -ProjectRoot "%PROJECT_ROOT%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Apply-V0493-RoleUi.ps1"
)
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" (
  echo Khong the ap dung v0.4.9.3. Xem file log trong thu muc hotfix\logs.
  echo Meo: co the keo-tha thu muc project vao file BAT nay de chay lai.
) else (
  echo Da hoan tat. Trinh duyet se mo trang dang nhap co chon loai tai khoan.
)
echo.
pause
exit /b %EXIT_CODE%
