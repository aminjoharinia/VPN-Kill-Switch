@echo off
rem Builds VPN Kill Switch on Windows, then offers to install it.
rem
rem   build.cmd              this PC's architecture (amd64 or arm64)
rem   build.cmd arm64        one architecture
rem   build.cmd -Yes         build and install without asking
rem
rem Needs Go 1.26+. NSIS (makensis) is optional: with it, an installer is
rem built too. The work is done by windows\build.ps1.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0windows\build.ps1" %*
exit /b %ERRORLEVEL%
