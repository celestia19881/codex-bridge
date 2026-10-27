@echo off
rem One-line launcher for codex-run.ps1 (bypasses the RemoteSigned execution policy
rem for this single process, without changing any machine-wide setting).
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0codex-run.ps1" %*
exit /b %ERRORLEVEL%
