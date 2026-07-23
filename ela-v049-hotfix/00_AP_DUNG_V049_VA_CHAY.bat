@echo off
setlocal
chcp 65001 >nul
cd /d "%~dp0"
echo ===============================================================
echo ENGLISH LEARNING APP v0.4.9 - DANG NHAP VA PHAN QUYEN
echo ===============================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\Apply-V049-AuthHotfix.ps1"
set "EXIT_CODE=%ERRORLEVEL%"
echo.
if not "%EXIT_CODE%"=="0" (
  echo Khong the ap dung v0.4.9. Vui long xem file log trong thu muc logs.
) else (
  echo Da hoan tat. Trinh duyet se mo trang dang nhap.
)
echo.
pause
exit /b %EXIT_CODE%
