@echo off
chcp 65001 >nul
title Турич — сервер HUD
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0hud-server.ps1"
