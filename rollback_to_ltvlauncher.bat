@echo off
title Rollback Immediato LTvLauncher - AKAI Custom TV
echo ========================================================
echo  ROLLBACK DI EMERGENZA A LTVLAUNCHER
echo ========================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0rollback_to_ltvlauncher.ps1"
pause
