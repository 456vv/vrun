@echo off
setlocal EnableExtensions EnableDelayedExpansion


REM ================================================================
REM 用法: build.bat ^<输入payload文件^> [输出stub文件]
REM 非 gzip 输入时调用外部 gzip 程序压缩；gzip 不存在则报错。
REM 环境变量: STUB_PKG  stub 源码目录，默认 "."（脚本所在目录）
REM
REM 可从任意工作目录调用：
REM   - 输入/输出参数按调用者当前目录解析
REM   - tools\hash、go build 包路径、payload.gz 以脚本目录为基准
REM ================================================================

set "ORIG_CWD=%CD%"
set "SCRIPT_DIR=%~dp0"
if "%SCRIPT_DIR:~-1%"=="\" set "SCRIPT_DIR=%SCRIPT_DIR:~0,-1%"

set "PAYLOAD_FILE=payload.gz"
set "PAYLOAD_SRC=%~1"
set "OUTPUT=%~2"
set "INPLACE=0"

REM ---------- 默认输出 ----------
if not defined OUTPUT (
    if defined PAYLOAD_SRC (
        REM 未指定输出：原地替换输入文件（先构建到临时文件再 move）
        set "OUTPUT=!PAYLOAD_SRC!"
        set "INPLACE=1"
    ) else (
        set "OUTPUT=installer.exe"
    )
)

REM ---------- 输出路径规范化（按调用者 CWD 判断） ----------
if "%OUTPUT:~-1%"=="\" set "OUTPUT=!OUTPUT!installer.exe"
if "%OUTPUT:~-1%"=="/" set "OUTPUT=!OUTPUT!installer.exe"
if exist "!OUTPUT!\" set "OUTPUT=!OUTPUT!\installer.exe"

REM ---------- 参数绝对化（相对调用者 CWD） ----------
if defined PAYLOAD_SRC (
    for %%A in ("!PAYLOAD_SRC!") do set "PAYLOAD_SRC=%%~fA"
)
if defined OUTPUT (
    for %%A in ("!OUTPUT!") do set "OUTPUT=%%~fA"
)

REM ---------- STUB_PKG ----------
if not defined STUB_PKG (
    set "STUB_PKG=."
) else (
    for %%A in ("!STUB_PKG!") do set "STUB_PKG=%%~fA"
)

REM ---------- 切到脚本目录，后续相对路径均以脚本目录为基准 ----------
if not exist "%SCRIPT_DIR%\" (
    echo [ERROR] 脚本目录不存在: %SCRIPT_DIR% 1>&2
    endlocal & exit /b 1
)
pushd "%SCRIPT_DIR%"
if errorlevel 1 (
    echo [ERROR] 无法进入脚本目录: %SCRIPT_DIR% 1>&2
    endlocal & exit /b 1
)

REM 通过 :main 包裹，保证任意 exit /b 都能回到这里恢复 CWD
call :main
set "RC=%ERRORLEVEL%"
popd
endlocal & exit /b %RC%


REM ================================================================
REM :main 主体（已处于脚本目录）
REM ================================================================
:main

REM ---------- 参数处理 ----------
if not defined PAYLOAD_SRC goto :use_existing
if not exist "!PAYLOAD_SRC!" (
    echo [ERROR] 输入文件不存在: !PAYLOAD_SRC! 1>&2
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

REM 优先用 tools\hash\hash.exe（已编译），否则回退 go run ./tools/hash
set "HASH_TOOL="
if exist "tools\hash\hash.exe" (
    set "HASH_TOOL=tools\hash\hash.exe"
) else if exist "tools\hash\main.go" (
    set "HASH_TOOL=go run ./tools/hash"
)

set "HASH="
if defined HASH_TOOL (
    set "HASH_TMP=%CD%\stub_hash_!RANDOM!!RANDOM!.txt"
    if exist "!HASH_TMP!" del "!HASH_TMP!" >nul 2>nul

    !HASH_TOOL! -decompress -file "%PAYLOAD_FILE%" > "!HASH_TMP!"
    set "GO_RC=!ERRORLEVEL!"
    if not "!GO_RC!"=="0" (
        if exist "!HASH_TMP!" del "!HASH_TMP!" >nul 2>nul
        echo [ERROR] 哈希计算失败（!HASH_TOOL! rc=!GO_RC!） 1>&2
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
        echo [ERROR] 未找到 tools\hash.exe / tools\hash，且没有 gzip 可解压 payload.gz 1>&2
        exit /b 1
    )
    where xxhsum >nul 2>nul
    if errorlevel 1 (
        echo [ERROR] 未找到 tools\hash.exe / tools\hash，且没有 xxhsum 可用 1>&2
        exit /b 1
    )
    for /f "usebackq tokens=1" %%i in (`gzip -dc "%PAYLOAD_FILE%" ^| xxhsum -H1`) do set "HASH=%%i"
)
if not defined HASH (
    echo [ERROR] 无法计算 xxh64 1>&2
    exit /b 1
)
echo     payload=%PAYLOAD_FILE%  xxh64=!HASH!

REM ---------- 确保输出目录存在 ----------
set "OUT_DIR="
for %%i in ("!OUTPUT!") do set "OUT_DIR=%%~dpi"
if defined OUT_DIR (
    if not exist "!OUT_DIR!" (
        mkdir "!OUT_DIR!" 2>nul
        if errorlevel 1 (
            echo [ERROR] 无法创建目录 !OUT_DIR! 1>&2
            exit /b 1
        )
    )
)

REM ---------- 构建 stub ----------
set "BUILD_OUT=!OUTPUT!"
if "!INPLACE!"=="1" set "BUILD_OUT=!OUTPUT!.vrun-stub.tmp"

echo ==^> 构建 stub --^> !OUTPUT!
if not "!BUILD_OUT!"=="!OUTPUT!" (
    echo     原地替换模式：先构建到临时文件 "!BUILD_OUT!"
)

go build -trimpath -ldflags="-s -w -X main.realAppXXH64Hex=!HASH!" -o "!BUILD_OUT!" "!STUB_PKG!"
if errorlevel 1 (
    if "!INPLACE!"=="1" del "!BUILD_OUT!" >nul 2>nul
    echo [ERROR] 构建 stub 失败 1>&2
    exit /b 1
)

if "!INPLACE!"=="1" (
    REM 构建成功后才覆盖原文件；失败时原 payload 完好无损
    move /y "!BUILD_OUT!" "!OUTPUT!" >nul
    if errorlevel 1 (
        echo [ERROR] 覆盖 "!OUTPUT!" 失败（文件可能正被占用） 1>&2
        echo         新 stub 已保留在: "!BUILD_OUT!" 1>&2
        echo         关闭占用进程后可手动改名，或重新运行本脚本 1>&2
        exit /b 1
    )
)

echo ==^> 完成: !OUTPUT!

REM ---------- 清理本次生成的 payload.gz ----------
REM 仅当本次通过 PAYLOAD_SRC 生成时删除；无参数复用的 payload.gz 保留。
REM VRUN_KEEP_PAYLOAD=1 可强制保留。
if defined PAYLOAD_SRC (
    if not "%VRUN_KEEP_PAYLOAD%"=="1" (
        if exist "%PAYLOAD_FILE%" (
            del /q "%PAYLOAD_FILE%" >nul 2>nul
            if exist "%PAYLOAD_FILE%" (
                echo [WARN] 无法删除 %PAYLOAD_FILE%（可能被占用），已保留 1>&2
            ) else (
                echo     已清理中间文件 %PAYLOAD_FILE%
            )
        )
    )
)

exit /b 0


REM ================================================================
REM :prep_payload
REM   检测 gzip 魔数（1F 8B）：是则复制，否则用外部 gzip 压缩。
REM ================================================================
:prep_payload
set "PAYLOAD_DST=%PAYLOAD_FILE%"
REM 防御：源文件就是 payload.gz 自身时，复制/压缩都会破坏它
for %%A in ("!PAYLOAD_SRC!") do set "SRC_ABS=%%~fA"
for %%A in ("!PAYLOAD_DST!") do set "DST_ABS=%%~fA"
if /i "!SRC_ABS!"=="!DST_ABS!" (
    echo [ERROR] 输入文件与中间文件 %PAYLOAD_FILE% 相同，无法原地处理 1>&2
    echo         请先把输入另存为其它文件名，或显式指定输出路径 1>&2
    exit /b 1
)
set "IS_GZIP=0"

set "PS_CHECK=%CD%\stub_check_!RANDOM!!RANDOM!.ps1"
if exist "!PS_CHECK!" del "!PS_CHECK!" >nul 2>nul

> "!PS_CHECK!" echo $fs = [System.IO.File]::OpenRead($env:PAYLOAD_SRC)
>>"!PS_CHECK!" echo try {
>>"!PS_CHECK!" echo     $b = New-Object byte[] 2
>>"!PS_CHECK!" echo     $null = $fs.Read($b, 0, 2)
>>"!PS_CHECK!" echo } finally { $fs.Close() }
>>"!PS_CHECK!" echo if ($b[0] -eq 0x1F -and $b[1] -eq 0x8B) { exit 0 } else { exit 1 }

set "PAYLOAD_SRC=!PAYLOAD_SRC!"
powershell -NoProfile -ExecutionPolicy Bypass -File "!PS_CHECK!"
if not errorlevel 1 set "IS_GZIP=1"
if exist "!PS_CHECK!" del "!PS_CHECK!" >nul 2>nul

if "!IS_GZIP!"=="1" (
    echo     input already gzip, copy to %PAYLOAD_DST%
    copy /y "!PAYLOAD_SRC!" "!PAYLOAD_DST!" >nul
    if errorlevel 1 (
        echo [ERROR] 复制 !PAYLOAD_SRC! 失败 1>&2
        exit /b 1
    )
    exit /b 0
)

where gzip >nul 2>nul
if errorlevel 1 (
    echo [ERROR] 输入 !PAYLOAD_SRC! 不是 gzip 格式，但系统未找到 gzip 程序，无法压缩 1>&2
    echo         请安装 gzip（Git for Windows 自带 gzip.exe，或从 https://www.gnu.org/software/gzip/ 获取） 1>&2
    exit /b 1
)
echo     input not gzip, compressing with gzip
gzip -9 -c "!PAYLOAD_SRC!" > "!PAYLOAD_DST!"
if errorlevel 1 (
    echo [ERROR] gzip 压缩失败 1>&2
    del "!PAYLOAD_DST!" >nul 2>nul
    exit /b 1
)
exit /b 0