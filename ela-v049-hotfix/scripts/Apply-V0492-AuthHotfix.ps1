[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$LegacyInstaller = Join-Path $ScriptDir "Apply-V049-AuthHotfix.ps1"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir = Join-Path (Split-Path -Parent $ScriptDir) "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "v0492_wrapper_$Timestamp.log"

function Write-WrapperLog {
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

Write-WrapperLog "ENGLISH LEARNING APP v0.4.9.2 - WINDOWS POWERSHELL STDERR FIX"

$ShimDir = Join-Path $env:TEMP "ela-v0492-docker-shim-$PID-$Timestamp"
$OldPath = $env:PATH
try {
    if ($SelfTest) {
        if ($env:OS -ne "Windows_NT") {
            Write-Output "SELF_TEST_DOCKER_STDERR=SKIPPED_NON_WINDOWS"
            exit 0
        }
        $fakeDocker = Join-Path $ShimDir "fake-docker.cmd"
        New-Item -ItemType Directory -Force -Path $ShimDir | Out-Null
        Set-Content -LiteralPath $fakeDocker -Encoding ASCII -Value "@echo Image english-learning-app-web Building 1>&2`r`n@exit /b 0"
        New-DockerShim $fakeDocker (Join-Path $ShimDir "shim")
        $env:PATH = (Join-Path $ShimDir "shim") + ";" + $OldPath
        $ErrorActionPreference = "Stop"
        & docker info 2>&1 | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "Shim self-test returned $LASTEXITCODE" }
        Write-Output "SELF_TEST_DOCKER_STDERR=PASS"
        exit 0
    }

    if (-not (Test-Path -LiteralPath $LegacyInstaller)) {
        throw "Thieu installer goc: $LegacyInstaller"
    }

    $realDockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
    if (-not $realDockerCommand) {
        $realDockerCommand = Get-Command docker -ErrorAction SilentlyContinue
    }
    if (-not $realDockerCommand) {
        throw "Khong tim thay Docker CLI. Hay mo Docker Desktop va chay lai."
    }

    $realDocker = $realDockerCommand.Source
    Write-WrapperLog "Docker that: $realDocker"
    New-DockerShim $realDocker $ShimDir
    $env:PATH = $ShimDir + ";" + $OldPath
    Write-WrapperLog "Da bat Docker stderr shim. Dong 'Image ... Building' se khong con bi hieu nham la loi."

    $arguments = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $LegacyInstaller)
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $arguments += @("-ProjectRoot", $ProjectRoot.Trim().Trim('"'))
    }

    & powershell.exe @arguments
    $exitCode = $LASTEXITCODE
    Write-WrapperLog "Installer v0.4.9.1 ket thuc voi exit code $exitCode."
    exit $exitCode
}
catch {
    Write-WrapperLog $_.Exception.Message "ERROR"
    exit 1
}
finally {
    $env:PATH = $OldPath
    Remove-Item -LiteralPath $ShimDir -Recurse -Force -ErrorAction SilentlyContinue
}
