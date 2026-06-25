@echo off
setlocal

set TARGET=%~1
if "%TARGET%"=="" set TARGET=all

set DETAIL=%~2
if /I "%TARGET%"=="verbose" (
    set TARGET=all
    set DETAIL=verbose
)

set EXTRA=
if /I "%DETAIL%"=="verbose" set EXTRA=-Detailed
if /I "%DETAIL%"=="detail" set EXTRA=-Detailed
if /I "%DETAIL%"=="detailed" set EXTRA=-Detailed

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\run_matrix_tests.ps1" -Only %TARGET% %EXTRA%
exit /b %ERRORLEVEL%
