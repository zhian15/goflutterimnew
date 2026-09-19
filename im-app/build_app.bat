@echo off
rem ============================================================
rem  One-click build: preflight + clean + pub get + config/icons/splash + APK
rem  Usage:
rem    build_app.bat            ask: first-time build / daily build / config only
rem    build_app.bat clean      force clean + full rebuild (first-time mode)
rem    build_app.bat noclean    skip clean (daily mode, no prompt)
rem    build_app.bat config     edit config/app_build.json + apply, NO build
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
if errorlevel 1 call :findflutter
where flutter >nul 2>nul
if errorlevel 1 (
  echo [PREFLIGHT FAIL] "flutter" is not available in PATH and was not found
  echo   in any common install dir either. Open a normal cmd window and run:
  echo     flutter --version
  echo   If that fails, find your flutter.bat, then in cmd run:
  echo     set PATH^=^<flutter bin dir^>;%PATH%
  echo     build_app.bat
  echo   (probed: D:\flutter\flutter\bin D:\flutter\bin C:\flutter\flutter\bin
  echo     C:\flutter\bin C:\src\flutter\bin %%USERPROFILE%%\flutter\bin
  echo     %%LOCALAPPDATA%%\flutter\bin)
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

rem ---------- build mode: arg override or interactive choice ----------
rem  build_app.bat noclean = daily build (skip clean)
rem  build_app.bat clean   = first-time build (force clean)
rem  build_app.bat config  = edit config + apply, NO build
rem  no argument           = ask interactively
if "%~1"=="noclean" goto :pubget
if "%~1"=="clean" goto :clean
if "%~1"=="config" goto :configonly

echo.
echo  Select mode:
echo    [1] First-time build  = flutter clean + full rebuild
echo        (slowest, use after copying project / changing deps / weird errors)
echo    [2] Daily build       = keep cache, skip clean
echo        (much faster, use for normal code-only changes)
echo    [3] Config only       = NO build. Edit app name / package name /
echo        api address / icon (config\app_build.json), then apply them.
choice /c 123 /n /m "  Press 1, 2 or 3: "
if errorlevel 3 goto :configonly
if errorlevel 2 goto :pubget

:clean
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

rem ---------- mode 3: config only (no build) ----------
:configonly
if not exist "config\app_build.json" (
  echo [CONFIG FAIL] config\app_build.json not found next to this .bat.
  goto :end
)
echo [CONFIG 1/3] opening config\app_build.json ...
echo   Edit the values, then SAVE and CLOSE notepad to continue.
echo   (appName / packageName / iosPackageName / versionName / versionCode /
echo    apiBase / wsBase / jpushAppKey / icon)
start "" /wait notepad "config\app_build.json"
echo [CONFIG 2/3] flutter pub get ... (output goes to %LOG%)
call flutter pub get >> "%LOG%" 2>&1
if errorlevel 1 goto :fail
echo [CONFIG 3/3] applying: name / package / api / icon / splash ...
call dart run tool\apply_config.dart
if errorlevel 1 goto :fail
echo.
echo [CONFIG] DONE. No APK was built.
echo   Notes:
echo   - changed packageName? build with option 1 (clean) next time, and
echo     update JPush AppKey (it is bound to the package name).
echo   - icon source = assets\icon\app_icon.png (already regenerated above,
echo     force again: dart run tool\apply_config.dart --icons --splash)
echo   - iOS: iosPackageName must equal your provisioning profile, and
echo     codemagic.yaml bundle_identifier must match too.
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
goto :eof

rem ---------- helper: probe common flutter install dirs ----------
rem  flutter not on PATH -> add the first existing dir to PATH for this run.
rem  Only affects THIS cmd instance, nothing is written to system settings.
:findflutter
for %%P in (
  "D:\flutter\flutter\bin"
  "D:\flutter\bin"
  "C:\flutter\flutter\bin"
  "C:\flutter\bin"
  "C:\src\flutter\bin"
  "%USERPROFILE%\flutter\bin"
  "%LOCALAPPDATA%\flutter\bin"
) do (
  if exist "%%~P\flutter.bat" (
    set "PATH=%%~P;%PATH%"
    echo [PREFLIGHT] flutter found at %%~P - added to PATH for this run.
    goto :eof
  )
)
goto :eof
