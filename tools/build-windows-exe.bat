@echo off
REM Baut "Wiki starten.exe" ohne Zusatztools (nur .NET Framework, auf jedem Windows dabei).
setlocal
set ROOT=%~dp0..
set SRC=%~dp0launcher\WikiLauncher.cs
set MANIFEST=%~dp0launcher\app.manifest
set OUT=%ROOT%\Wiki starten.exe
set CSC=C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe

if not exist "%CSC%" (
  echo FEHLER: csc.exe nicht gefunden: %CSC%
  exit /b 1
)
if not exist "%SRC%" (
  echo FEHLER: Quelle nicht gefunden: %SRC%
  exit /b 1
)

"%CSC%" /nologo /target:winexe /platform:anycpu /optimize ^
  /out:"%OUT%" ^
  /win32manifest:"%MANIFEST%" ^
  /reference:System.Windows.Forms.dll /reference:System.Drawing.dll ^
  "%SRC%"
if errorlevel 1 (
  echo FEHLER: Kompilieren fehlgeschlagen.
  exit /b 1
)

echo OK: "%OUT%"
