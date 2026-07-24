@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
echo ===============================================================
echo ENGLISH LEARNING APP v0.4.9.6 - FIX MANH POWERSHELL + OFFLINE IMAGE
echo ===============================================================
echo.
set "PROJECT_ROOT=%~1"
if defined PROJECT_ROOT (
  echo Dang dung thu muc project duoc truyen vao: %PROJECT_ROOT%
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Apply-V0496-NativeStderrFix.ps1" -ProjectRoot "%PROJECT_ROOT%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Apply-V0496-NativeStderrFix.ps1"
)
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" (
  echo Khong the khoi dong v0.4.9.6. Xem file log trong thu muc hotfix\logs.
  echo Hay gui ca hai file v0496_native_stderr_fix_*.log va v0495_offline_reuse_*.log neu van con loi.
) else (
  echo Da khoi dong thanh cong. Trinh duyet se mo trang dang nhap.
)
echo.
pause
exit /b %EXIT_CODE%
