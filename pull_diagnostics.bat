@echo off
title Recupero Telemetria Autonoma - AKAI Custom TV
echo ========================================================
echo  AKAI Custom TV — RECUPERO LOG DIAGNOSTICI AUTONOMI
echo ========================================================
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\10_pull_diagnostics.ps1"
echo.
pause
