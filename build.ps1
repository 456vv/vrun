<#
.SYNOPSIS
    Usage: .\build.ps1 <input-payload> [output-stub]
    If output is omitted and input is given, replace input in place
    (build to temporary .vrun-stub.tmp then move).
    If input is not gzip, compress it with external `gzip` (error if missing).
    Hash is computed on the decompressed payload (matches stub semantics).

    Can be invoked from any working directory:
      - input/output arguments resolve against the caller's CWD
      - tools/hash, go build package path and payload.gz resolve against
        the script directory
#>
param(
    [Parameter(Position = 0)]
    [string]$PayloadSrc = "",

    [Parameter(Position = 1)]
    [string]$Output = "",

    [string]$StubPkg = "."
)

$ErrorActionPreference = "Stop"

$OrigCwd   = (Get-Location).Path
$ScriptDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($ScriptDir)) {
    $ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
}

function Resolve-FromOrig([string]$p) {
    if ([string]::IsNullOrEmpty($p)) { return $p }
    if ([System.IO.Path]::IsPathRooted($p)) { return [System.IO.Path]::GetFullPath($p) }
    return [System.IO.Path]::GetFullPath((Join-Path $OrigCwd $p))
}

$PayloadFile = "payload.gz"

# ===== 0. Inplace / output defaults =====
$Inplace = $false
if ([string]::IsNullOrEmpty($Output)) {
    if (-not [string]::IsNullOrEmpty($PayloadSrc)) {
        # 未指定输出：原地替换输入（构建到临时文件再 move）
        $Output  = $PayloadSrc
        $Inplace = $true
    } else {
        $Output = "installer.exe"
    }
}

# 输出路径规范化（按调用者 CWD 判断目录语义）
if ((Test-Path $Output -PathType Container) -or $Output.EndsWith('\') -or $Output.EndsWith('/')) {
    $Output = Join-Path $Output "installer.exe"
}

# 参数绝对化（相对调用者 CWD）
$PayloadSrc = Resolve-FromOrig $PayloadSrc
$Output     = Resolve-FromOrig $Output

# STUB_PKG：默认 "."（= 脚本目录）；显式给出的相对路径按调用者 CWD 解析
if ([string]::IsNullOrEmpty($StubPkg) -or $StubPkg -eq ".") {
    $StubPkg = "."
} else {
    $StubPkg = Resolve-FromOrig $StubPkg
}

# ===== 切到脚本目录，后续相对路径均以脚本目录为基准 =====
Push-Location $ScriptDir
try {
    $PayloadPath = Join-Path $ScriptDir $PayloadFile

    # ===== 1. Prepare payload.gz =====
    if ([string]::IsNullOrEmpty($PayloadSrc)) {
        if (Test-Path $PayloadPath) {
            Write-Host "==> No input specified, reusing existing $PayloadFile"
        } else {
            Write-Host "Usage: .\build.ps1 <input-payload> [output-stub]" -ForegroundColor Red
            exit 2
        }
    } else {
        if (-not (Test-Path $PayloadSrc)) {
            Write-Host "ERROR: input file not found: $PayloadSrc" -ForegroundColor Red
            exit 1
        }
        $srcFull = (Resolve-Path $PayloadSrc).Path
        $dstFull = [System.IO.Path]::GetFullPath($PayloadPath)

        # 防御：源文件就是 payload.gz 自身时，复制/压缩都会破坏它
        if ($srcFull -eq $dstFull) {
            Write-Host "ERROR: input file is the same as intermediate $PayloadFile" -ForegroundColor Red
            Write-Host "       rename the input or specify an explicit output path" -ForegroundColor Red
            exit 1
        }

        # Detect gzip magic 1f 8b
        $fs = [System.IO.File]::OpenRead($srcFull)
        try {
            $buf = New-Object byte[] 2
            $n = $fs.Read($buf, 0, 2)
        } finally { $fs.Dispose() }
        $isGzip = ($n -eq 2 -and $buf[0] -eq 0x1F -and $buf[1] -eq 0x8B)

        if ($isGzip) {
            Write-Host "==> Input is gzip: $PayloadSrc -> $PayloadFile"
            Copy-Item -Force $srcFull $PayloadPath
        } else {
            $gzipCmd = Get-Command gzip -ErrorAction SilentlyContinue
            if (-not $gzipCmd) {
                Write-Host "ERROR: input $PayloadSrc is not gzip, and `gzip` was not found in PATH" -ForegroundColor Red
                Write-Host "       Install gzip (Git for Windows ships gzip.exe) and retry." -ForegroundColor Red
                exit 1
            }
            Write-Host "==> Input is not gzip, compressing: $PayloadSrc -> $PayloadFile"
            $proc = Start-Process -FilePath $gzipCmd.Source `
                -ArgumentList @("-9", "-c", $srcFull) `
                -RedirectStandardOutput $PayloadPath `
                -NoNewWindow -Wait -PassThru
            if ($proc.ExitCode -ne 0) {
                Remove-Item -Force $PayloadPath -ErrorAction SilentlyContinue
                Write-Host "ERROR: gzip failed (exit code $($proc.ExitCode))" -ForegroundColor Red
                exit 1
            }
        }
    }

    # ===== 2. Compute xxh64 (on decompressed payload, matches stub semantics) =====
    Write-Host "==> Computing xxh64 hash (-decompress)"
    $Hash = ""
    $HashTool = ""
    if (Test-Path "tools\hash\hash.exe") {
        $HashTool = "tools\hash\hash.exe"
    } elseif (Test-Path "tools\hash\main.go") {
        $HashTool = "go run ./tools/hash"
    }

    if ($HashTool -ne "") {
        if ($HashTool -eq "go run ./tools/hash") {
            $raw = & go run ./tools/hash -decompress -file $PayloadFile 2>&1
        } else {
            $raw = & $HashTool -decompress -file $PayloadFile 2>&1
        }
        if ($LASTEXITCODE -ne 0) {
            throw "hash failed (rc=$LASTEXITCODE): $raw"
        }
        $Hash = ("$raw").Trim()
    } else {
        $gzipCmd = Get-Command gzip -ErrorAction SilentlyContinue
        if (-not $gzipCmd) {
            Write-Host "ERROR: need tools\hash, or gzip + xxhsum to compute hash" -ForegroundColor Red
            exit 1
        }
        if (-not (Get-Command xxhsum -ErrorAction SilentlyContinue)) {
            Write-Host "ERROR: need tools\hash, or gzip + xxhsum to compute hash" -ForegroundColor Red
            exit 1
        }
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = "cmd.exe"
        $psi.Arguments = "/c `"`"$($gzipCmd.Source)`" -dc `"$PayloadFile`" | xxhsum -H1`""
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $proc = [System.Diagnostics.Process]::Start($psi)
        $out = $proc.StandardOutput.ReadToEnd()
        $proc.WaitForExit()
        if ($proc.ExitCode -ne 0) {
            throw "gzip -dc | xxhsum failed (rc=$($proc.ExitCode))"
        }
        $Hash = (($out -split '\s+')[0]).Trim()
    }
    if (-not $Hash) {
        Write-Host "ERROR: computed xxh64 is empty" -ForegroundColor Red
        exit 1
    }
    Write-Host "    payload=$PayloadFile  xxh64=$Hash"

    # ===== 3. Build stub =====
    $outDir = Split-Path -Parent $Output
    if ($outDir -and -not (Test-Path $outDir)) {
        New-Item -ItemType Directory -Force -Path $outDir | Out-Null
    }

    $BuildOut = $Output
    if ($Inplace) { $BuildOut = "$Output.vrun-stub.tmp" }

    Write-Host "==> Building stub -> $Output"
    if ($BuildOut -ne $Output) {
        Write-Host "    inplace mode: build to temporary $BuildOut"
    }

    & go build -trimpath -ldflags="-s -w -X main.realAppXXH64Hex=$Hash" -o $BuildOut $StubPkg
    if ($LASTEXITCODE -ne 0) {
        if ($Inplace -and (Test-Path $BuildOut)) {
            Remove-Item -Force $BuildOut -ErrorAction SilentlyContinue
        }
        throw "go build failed"
    }

    # Only move over original after a successful build
    if ($Inplace) {
        try {
            Move-Item -Force -Path $BuildOut -Destination $Output
        } catch {
            Write-Host "ERROR: failed to overwrite $Output (file may be in use)" -ForegroundColor Red
            Write-Host "       New stub preserved at: $BuildOut" -ForegroundColor Red
            Write-Host "       After releasing the lock, run: Move-Item -Force '$BuildOut' '$Output'" -ForegroundColor Red
            Write-Host "       Do NOT re-run this script on an already-replaced file (nested stub)" -ForegroundColor Red
            exit 1
        }
    }

    # ===== 4. Cleanup generated payload.gz =====
    # Only remove when generated from $PayloadSrc this run; reused payload.gz kept.
    # Set VRUN_KEEP_PAYLOAD=1 to force keep.
    if (-not [string]::IsNullOrEmpty($PayloadSrc) -and $env:VRUN_KEEP_PAYLOAD -ne "1") {
        if (Test-Path $PayloadPath) {
            try {
                Remove-Item -Force $PayloadPath -ErrorAction Stop
                Write-Host "==> Cleaned up intermediate $PayloadFile"
            } catch {
                Write-Host "==> WARN: could not remove $PayloadFile (in use?), kept it" -ForegroundColor Yellow
            }
        }
    }

    Write-Host "==> Done: $Output"
} finally {
    # 恢复调用者 CWD（成功、失败、exit 都会执行）
    Pop-Location
}