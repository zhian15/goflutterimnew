@echo off
rem ============================================================
rem  One-click build: preflight + clean + pub get + config/icons/splash + APK
rem  Usage:
rem    build_app.bat            full build (includes flutter clean)
rem    build_app.bat noclean    skip clean (faster, for daily builds)
rem  Output: build\app\outputs\flutter-apk\app-<abi>-release.apk
rem
rem  All step output is ALSO written to build_log.txt next to this
rem  file. On failure the last 50 log lines are printed back to the
rem  screen - no more "red error flashes and the window closes".
rem
rem  NOTE: keep this file pure ASCII - cmd parses .bat by GBK,
rem        UTF-8 Chinese text here breaks line parsing.
rem ============================================================

setlocal
cd /d %~dp0

set LOG=build_log.txt
echo ===== build start %date% %time% ===== > "%LOG%"

rem ---------- STEP 0: preflight - the usual suspects after copying ----------
echo [STEP 0/5] preflight checks ...
where flutter >nul 2>nul
if errorlevel 1 (
  echo [PREFLIGHT FAIL] "flutter" is not available in PATH.
  echo   Open a normal cmd window and run: flutter --version
  echo   If that fails too, the Flutter SDK bin dir is not on PATH.
  echo [PREFLIGHT FAIL] flutter not in PATH.>> "%LOG%"
  goto :fail
)
if not exist "pubspec.yaml" (
  echo [PREFLIGHT FAIL] pubspec.yaml not found next to this .bat.
  echo   Run build_app.bat from inside the im-app root folder.
  goto :fail
)
if not exist "packages\tencent_trtc_cloud\pubspec.yaml" (
  echo [PREFLIGHT FAIL] packages\tencent_trtc_cloud is MISSING.
  echo   pubspec.yaml references it as a LOCAL path dependency:
  echo     tencent_trtc_cloud: { path: packages/tencent_trtc_cloud }
  echo   When copying im-app elsewhere you MUST copy the "packages" folder too.
  echo [PREFLIGHT FAIL] missing packages/tencent_trtc_cloud - local path dep.>> "%LOG%"
  goto :fail
)
if not exist "tool\apply_config.dart" (
  echo [PREFLIGHT FAIL] tool\apply_config.dart is MISSING.
  echo   Copy the "tool" folder together with the project.
  goto :fail
)
if not exist "android" (
  echo [PREFLIGHT FAIL] android folder is MISSING. Copy the "android" folder too.
  goto :fail
)
echo [STEP 0/5] preflight OK

if "%~1"=="noclean" goto :pubget

echo [STEP 1/5] flutter clean ... (output goes to %LOG%)
call flutter clean >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

:pubget
echo [STEP 2/5] flutter pub get ... (output goes to %LOG%)
call flutter pub get >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo [STEP 3/5] config + icons + splash (apply_config.dart) ...
call dart run tool/apply_config.dart >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo [STEP 4/5] flutter build apk --release --split-per-abi ...
echo   (this step is SLOW, especially the first build - window stays
echo    quiet on purpose, live details are in %LOG%)
call flutter build apk --release --split-per-abi >> "%LOG%" 2>&1
if errorlevel 1 goto :fail

echo.
echo [STEP 5/5] BUILD OK. APK output:
dir /b build\app\outputs\flutter-apk\*.apk
echo.
echo Full path: %CD%\build\app\outputs\flutter-apk\
echo   app-arm64-v8a-release.apk    = for modern phones (store upload)
echo   app-armeabi-v7a-release.apk  = for old devices
echo   app-release.apk              = legacy unsplit apk (ignore)
echo Full log:  %CD%\%LOG%
echo.
goto :end

:fail
echo.
echo [FAILED] The step above returned an error. Build stopped.
echo Full details are in: %CD%\%LOG%
echo ----- last 50 lines of the log -----
powershell -NoProfile -Command "Get-Content -LiteralPath 'build_log.txt' -Tail 50"
echo -----------------------------------

:end
pause
