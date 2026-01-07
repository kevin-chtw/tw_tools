@echo off

:: Define variables
set "SCRIPT_DIR=%~dp0"
set "PARENT_DIR=%SCRIPT_DIR%.."
set "TARGET_BIN_DIR=%PARENT_DIR%\bin"

:: Create target directory
if not exist "%TARGET_BIN_DIR%" mkdir "%TARGET_BIN_DIR%"

echo [INFO] Starting build process...

:: Find and build all services
for /d %%d in ("%PARENT_DIR%\tw_*") do (
    if exist "%%d\main.go" (
        echo [INFO] Building %%~nd...

        :: Save environment variables
        set "ORIGINAL_CGO_ENABLED=%CGO_ENABLED%"
        set "ORIGINAL_GOOS=%GOOS%"
        set "ORIGINAL_GOARCH=%GOARCH%"

        :: Set cross-compilation environment
        set CGO_ENABLED=0
        set GOOS=linux
        set GOARCH=amd64

        cd /d "%%d"
        go build -ldflags="-s -w" -o "%%~nd" 2>nul

        if exist "%%~nd" (
            move "%%~nd" "%TARGET_BIN_DIR%\" >nul
            echo [INFO] Built %%~nd successfully
        ) else (
            echo [ERROR] Failed to build %%~nd
        )

        :: Restore environment variables
        if defined ORIGINAL_CGO_ENABLED (
            set "CGO_ENABLED=%ORIGINAL_CGO_ENABLED%"
        ) else (
            set "CGO_ENABLED="
        )
        if defined ORIGINAL_GOOS (
            set "GOOS=%ORIGINAL_GOOS%"
        ) else (
            set "GOOS="
        )
        if defined ORIGINAL_GOARCH (
            set "GOARCH=%ORIGINAL_GOARCH%"
        ) else (
            set "GOARCH="
        )

        cd /d "%SCRIPT_DIR%"
    )
)

echo [INFO] Build completed