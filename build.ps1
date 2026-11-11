<#
.SYNOPSIS
    Build stub (no UPX).
    Usage: .\build.ps1 <input-payload> [output-stub]
    If input is not gzip, compress it with external `gzip` (error if missing).
    Hash is computed on the decompressed payload (matches stub semantics).
#>
param(
    [Parameter(Position = 0)]
    [string]$PayloadSrc = "",

    [Parameter(Position = 1)]
    [string]$Output = "installer.exe",

    [string]$StubPkg = "."
)

$ErrorActionPreference = "Stop"

$CurrentDir  = (Get-Location).Path
$PayloadFile = "payload.gz"
$PayloadPath = Join-Path $CurrentDir $PayloadFile

# ===== 1. Prepare payload.gz =====
if (-not $PayloadSrc) {
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
$hashDir = Join-Path $CurrentDir "tools\hash"
if (Test-Path $hashDir) {
    $raw = & go run ./tools/hash -decompress -file $PayloadFile 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "go run ./tools/hash failed (rc=$LASTEXITCODE): $raw"
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
    # gzip -dc | xxhsum -H1
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

Write-Host "==> Building stub -> $Output"
& go build -ldflags="-X main.realAppXXH64Hex=$Hash" -o $Output $StubPkg
if ($LASTEXITCODE -ne 0) { throw "go build failed" }

Write-Host "==> Done: $Output"