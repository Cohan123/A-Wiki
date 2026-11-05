@echo off
REM Windows-Start: nutzt "Wiki starten.exe", falls vorhanden (Fensterlos, Tray, keine Konsole).
REM Fallback: PowerShell direkt (Sichtbares Fenster).
if exist "%~dp0Wiki starten.exe" (
  start "" "%~dp0Wiki starten.exe"
  exit /b 0
)
REM Fallback ohne EXE (manuell, ohne Tray). Tipp: einmalig tools\build-windows-exe.bat
REM ausfuehren und danach "Wiki starten.exe" verwenden.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0tools\editor-server.ps1"
