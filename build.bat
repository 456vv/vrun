@echo off
setlocal EnableExtensions EnableDelayedExpansion

REM ================================================================
REM 方案 B 构建脚本（Windows / 批处理，无 UPX）。
REM 用法: build.bat ^<输入payload文件^> [输出stub文件]
REM 非 gzip 输入时调用外部 gzip 程序压缩；gzip 不存在则报错。
REM 环境变量: STUB_PKG  stub 源码目录，默认 "."
REM ================================================================

set "PAYLOAD_SRC=%~1"
set "OUTPUT=%~2"
if "%OUTPUT%"=="" set "OUTPUT=installer.exe"
if "%STUB_PKG%"=="" set "STUB_PKG=."
set "PAYLOAD_FILE=payload.gz"

REM ---------- 参数处理 ----------
if "%PAYLOAD_SRC%"=="" goto :use_existing
if not exist "%PAYLOAD_SRC%" (
    echo [ERROR] 输入文件不存在: %PAYLOAD_SRC% 1>&2
    exit /b 1
)

echo ==^> 准备 %PAYLOAD_FILE%
call :prep_payload
if errorlevel 1 (
    echo [ERROR] 准备 payload.gz 失败 1>&2
    exit /b 1
)
goto :hash_step

:use_existing
if not exist "%PAYLOAD_FILE%" (
    echo 用法: %~nx0 ^<输入payload文件^> [输出stub文件] 1>&2
    exit /b 2
)
echo ==^> 未指定输入，复用已存在的 %PAYLOAD_FILE%

REM ---------- 计算 xxh64（解压后真实程序的哈希） ----------
:hash_step
echo ==^> 计算 xxh64 哈希 ^(^-decompress^)
set "HASH="
if exist "tools\hash" (
    set "HASH_TMP=%CD%\stub_hash_!RANDOM!!RANDOM!.txt"
    if exist "!HASH_TMP!" del "!HASH_TMP!" >nul 2>nul

    go run ./tools/hash -decompress -file "%PAYLOAD_FILE%" > "!HASH_TMP!"
    set "GO_RC=!ERRORLEVEL!"
    if not "!GO_RC!"=="0" (
        if exist "!HASH_TMP!" del "!HASH_TMP!" >nul 2>nul
        echo [ERROR] go run ./tools/hash 失败（rc=!GO_RC!） 1>&2
        exit /b 1
    )
    if not exist "!HASH_TMP!" (
        echo [ERROR] 无法创建临时文件: !HASH_TMP! 1>&2
        exit /b 1
    )
    set /p HASH=<"!HASH_TMP!"
    del "!HASH_TMP!" >nul 2>nul
) else (
    where gzip >nul 2>nul
    if errorlevel 1 (
        echo [ERROR] 未找到 tools\hash，且没有 gzip 可解压 payload.gz 1>&2
        exit /b 1
    )
    where xxhsum >nul 2>nul
    if errorlevel 1 (
        echo [ERROR] 未找到 tools\hash，且没有 xxhsum 可用 1>&2
        exit /b 1
    )
    for /f "usebackq tokens=1" %%i in (`gzip -dc "%PAYLOAD_FILE%" ^| xxhsum -H1`) do set "HASH=%%i"
)
if not defined HASH (
    echo [ERROR] 需要 tools\hash 或 [gzip + xxhsum] 来计算哈希 1>&2
    exit /b 1
)
echo     payload=%PAYLOAD_FILE%  xxh64=!HASH!

REM ---------- 确保输出目录存在 ----------
set "OUT_DIR="
for %%i in ("%OUTPUT%") do set "OUT_DIR=%%~dpi"
if not "!OUT_DIR!"=="" (
    if not exist "!OUT_DIR!" (
        mkdir "!OUT_DIR!" 2>nul
        if errorlevel 1 (
            echo [ERROR] 无法创建目录 !OUT_DIR! 1>&2
            exit /b 1
        )
    )
)

REM ---------- 构建 stub ----------
echo ==^> 构建 stub --^> %OUTPUT%
go build -ldflags="-X main.realAppXXH64Hex=!HASH!" -o "%OUTPUT%" "%STUB_PKG%"
if errorlevel 1 (
    echo [ERROR] 构建 stub 失败 1>&2
    exit /b 1
)

echo ==^> 完成: %OUTPUT%
endlocal
exit /b 0


REM ================================================================
REM :prep_payload
REM   检测 gzip 魔数（1F 8B）：是则复制，否则用外部 gzip 压缩。
REM ================================================================
:prep_payload
set "PAYLOAD_DST=%PAYLOAD_FILE%"
set "IS_GZIP=0"

set "PS_CHECK=%CD%\stub_check_!RANDOM!!RANDOM!.ps1"
if exist "!PS_CHECK!" del "!PS_CHECK!" >nul 2>nul

> "!PS_CHECK!" echo $fs = [System.IO.File]::OpenRead($env:PAYLOAD_SRC)
>>"!PS_CHECK!" echo try {
>>"!PS_CHECK!" echo     $b = New-Object byte[] 2
>>"!PS_CHECK!" echo     $null = $fs.Read($b, 0, 2)
>>"!PS_CHECK!" echo } finally { $fs.Close() }
>>"!PS_CHECK!" echo if ($b[0] -eq 0x1F -and $b[1] -eq 0x8B) { exit 0 } else { exit 1 }

powershell -NoProfile -ExecutionPolicy Bypass -File "!PS_CHECK!"
if not errorlevel 1 set "IS_GZIP=1"
if exist "!PS_CHECK!" del "!PS_CHECK!" >nul 2>nul

if "!IS_GZIP!"=="1" (
    echo     input already gzip, copy to %PAYLOAD_DST%
    copy /y "%PAYLOAD_SRC%" "%PAYLOAD_DST%" >nul
    if errorlevel 1 (
        echo [ERROR] 复制 %PAYLOAD_SRC% 失败 1>&2
        exit /b 1
    )
    exit /b 0
)

where gzip >nul 2>nul
if errorlevel 1 (
    echo [ERROR] 输入 %PAYLOAD_SRC% 不是 gzip 格式，但系统未找到 gzip 程序，无法压缩 1>&2
    echo         请安装 gzip（Git for Windows 自带 gzip.exe，或从 https://www.gnu.org/software/gzip/ 获取） 1>&2
    exit /b 1
)
echo     input not gzip, compressing with gzip
gzip -9 -c "%PAYLOAD_SRC%" > "%PAYLOAD_DST%"
if errorlevel 1 (
    echo [ERROR] gzip 压缩失败 1>&2
    del "%PAYLOAD_DST%" >nul 2>nul
    exit /b 1
)
exit /b 0