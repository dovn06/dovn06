[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleRoot = Split-Path -Parent $ScriptDir
$InnerScript = Join-Path $ScriptDir "Apply-V0495-OfflineReuse.ps1"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir = Join-Path $BundleRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "v0496_native_stderr_fix_$Timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function New-DockerShim {
    param([string]$RealDocker, [string]$Directory)
    New-Item -ItemType Directory -Force -Path $Directory | Out-Null
    $escaped = $RealDocker.Replace('%', '%%')
    $content = @"
@echo off
"$escaped" %* 2>&1
exit /b %ERRORLEVEL%
"@
    Set-Content -LiteralPath (Join-Path $Directory "docker.cmd") -Value $content -Encoding ASCII
}

function Invoke-ChildInstaller {
    param([string]$ScriptPath, [string]$Root)
    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $ScriptPath)
    if (-not [string]::IsNullOrWhiteSpace($Root)) {
        $arguments += @("-ProjectRoot", $Root.Trim().Trim('"'))
    }

    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $output = & powershell.exe @arguments 2>&1
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $previousPreference
    }

    if ($output) {
        $output | ForEach-Object {
            $text = $_.ToString()
            Write-Host $text
            Add-Content -LiteralPath $LogFile -Value $text -Encoding UTF8
        }
    }
    return $exitCode
}

if ($SelfTest) {
    $testRoot = Join-Path $env:TEMP "ela-v0496-native-test-$PID-$Timestamp"
    $realDir = Join-Path $testRoot "real"
    $shimDir = Join-Path $testRoot "shim"
    $oldPath = $env:PATH
    try {
        New-Item -ItemType Directory -Force -Path $realDir | Out-Null
        $fakeDocker = Join-Path $realDir "docker-real.cmd"
        @"
@echo off
echo Network english-learning-app_default Creating 1>&2
echo Container english-learning-app-web Starting 1>&2
exit /b 0
"@ | Set-Content -LiteralPath $fakeDocker -Encoding ASCII
        New-DockerShim $fakeDocker $shimDir
        $env:PATH = $shimDir + ";" + $oldPath
        $previousPreference = $ErrorActionPreference
        $ErrorActionPreference = "Stop"
        try {
            $result = & docker test 2>&1
            $code = $LASTEXITCODE
        }
        finally {
            $ErrorActionPreference = $previousPreference
        }
        $text = ($result | ForEach-Object { $_.ToString() }) -join "`n"
        if ($code -ne 0) { throw "Shim self-test exit code sai: $code" }
        if ($text -notmatch "Network english-learning-app_default Creating") { throw "Shim self-test mat stderr network." }
        if ($text -notmatch "Container english-learning-app-web Starting") { throw "Shim self-test mat stderr container." }
        Write-Output "SELF_TEST_NATIVE_STDERR=PASS"
        exit 0
    }
    finally {
        $env:PATH = $oldPath
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Log "ENGLISH LEARNING APP v0.4.9.6 - NATIVE STDERR FIX + OFFLINE IMAGE REUSE"

if (-not (Test-Path -LiteralPath $InnerScript)) {
    Write-Log "Thieu installer nen: $InnerScript" "ERROR"
    exit 1
}

$dockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
if (-not $dockerCommand) { $dockerCommand = Get-Command docker -ErrorAction SilentlyContinue }
if (-not $dockerCommand) {
    Write-Log "Khong tim thay Docker CLI. Hay mo Docker Desktop va chay lai." "ERROR"
    exit 1
}

$shimDir = Join-Path $env:TEMP "ela-v0496-docker-shim-$PID-$Timestamp"
$oldPath = $env:PATH
try {
    New-DockerShim $dockerCommand.Source $shimDir
    $env:PATH = $shimDir + ";" + $oldPath
    Write-Log "Da bat Docker native shim; stderr se duoc ghi log nhu tien trinh binh thuong." "OK"
    $code = Invoke-ChildInstaller $InnerScript $ProjectRoot
    if ($code -ne 0) {
        Write-Log "Installer nen v0.4.9.5 that bai voi exit code $code." "ERROR"
        exit $code
    }
    Write-Log "v0.4.9.6 hoan tat; Docker stderr khong con lam PowerShell dung gia." "OK"
    exit 0
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    exit 1
}
finally {
    $env:PATH = $oldPath
    Remove-Item -LiteralPath $shimDir -Recurse -Force -ErrorAction SilentlyContinue
}
