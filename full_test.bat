@echo off
REM full_test.bat - Windows full test suite entrypoint (cmd.exe).
REM
REM Locates the boot minilang.exe, then delegates to the bash orchestrator
REM (full_test.sh) under Git Bash when available. If Git Bash is absent it
REM falls back to a direct cmd smoke run of every tests\*.mil through the
REM boot executable.
REM
REM Environment:
REM   MINILANG_BOOT  built boot minilang.exe (auto-detected if unset)
REM   MINILANG_DIR   compiler repo root (defaults to this script's dir)
REM   CC             native build driver (cl / clang / g++)
REM   SKIP_EXT=1     skip the extension shared-library suite
setlocal
cd /d "%~dp0"

if "%MINILANG_DIR%"=="" set "MINILANG_DIR=%CD%"

if not "%MINILANG_BOOT%"=="" goto :haveboot
if exist "minilang-boot\build\Release\minilang.exe" (
    set "MINILANG_BOOT=%CD%\minilang-boot\build\Release\minilang.exe"
    goto :haveboot
)
if exist "minilang-boot\minilang.exe" (
    set "MINILANG_BOOT=%CD%\minilang-boot\minilang.exe"
    goto :haveboot
)
echo Boot compiler not found. Build minilang-boot first, or set MINILANG_BOOT.
exit /b 1

:haveboot
echo MINILANG_BOOT=%MINILANG_BOOT%
echo MINILANG_DIR=%MINILANG_DIR%

where bash >nul 2>nul
if %ERRORLEVEL%==0 (
    bash "%~dp0full_test.sh"
    goto :done
)

echo No Git Bash on PATH; running direct cmd smoke over tests\*.mil
for %%f in (tests\*.mil) do (
    echo --- %%f ---
    "%MINILANG_BOOT%" run "%%f" || exit /b 1
)

:done
endlocal
