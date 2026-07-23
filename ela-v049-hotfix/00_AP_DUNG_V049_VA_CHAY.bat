@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
echo ===============================================================
echo ENGLISH LEARNING APP v0.4.9.4 - KHOI PHUC MOI TRUONG VA DANG NHAP
echo ===============================================================
echo.
set "PROJECT_ROOT=%~1"
if defined PROJECT_ROOT (
  echo Dang dung thu muc project duoc truyen vao: %PROJECT_ROOT%
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Apply-V0494-EnvironmentRecovery.ps1" -ProjectRoot "%PROJECT_ROOT%"
) else (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Apply-V0494-EnvironmentRecovery.ps1"
)
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" (
  echo Khong the ap dung v0.4.9.4. Xem file log trong thu muc hotfix\logs.
  echo Meo: co the keo-tha thu muc project vao file BAT nay de chay lai.
) else (
  echo Da khoi phuc .env va khoi dong thanh cong. Trinh duyet se mo trang dang nhap.
)
echo.
pause
exit /b %EXIT_CODE%
