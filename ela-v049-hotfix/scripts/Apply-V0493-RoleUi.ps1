[CmdletBinding()]
param(
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleRoot = Split-Path -Parent $ScriptDir
$DiscoveryScript = Join-Path $ScriptDir "Apply-V049-AuthHotfix.ps1"
$PatchServer = Join-Path $BundleRoot "patch\apps\web\server.mjs"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BootstrapLogs = Join-Path $BundleRoot "logs"
New-Item -ItemType Directory -Force -Path $BootstrapLogs | Out-Null
$LogFile = Join-Path $BootstrapLogs "v0493_role_ui_$Timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $line = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $line
    Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
}

function Test-ProjectRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    $clean = $Path.Trim().Trim('"')
    return (Test-Path -LiteralPath (Join-Path $clean "docker-compose.yml")) -and
           (Test-Path -LiteralPath (Join-Path $clean "apps\web\server.mjs")) -and
           (Test-Path -LiteralPath (Join-Path $clean "package.json"))
}

function Resolve-ProjectRoot {
    if (Test-ProjectRoot $ProjectRoot) {
        return (Resolve-Path -LiteralPath $ProjectRoot.Trim().Trim('"')).Path
    }
    if (-not (Test-Path -LiteralPath $DiscoveryScript)) {
        throw "Thieu bo do project: $DiscoveryScript"
    }
    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $DiscoveryScript, "-DiscoveryOnly")
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) {
        $args += @("-ProjectRoot", $ProjectRoot.Trim().Trim('"'))
    }
    $output = & powershell.exe @args 2>&1
    $output | ForEach-Object { Write-Host $_ }
    $marker = $output | ForEach-Object { $_.ToString() } | Where-Object { $_ -like "DISCOVERED_PROJECT_ROOT=*" } | Select-Object -Last 1
    if (-not $marker) { throw "Khong xac dinh duoc thu muc project." }
    $resolved = ($marker -split "=", 2)[1].Trim()
    if (-not (Test-ProjectRoot $resolved)) { throw "Thu muc project khong hop le: $resolved" }
    return (Resolve-Path -LiteralPath $resolved).Path
}

function Get-EnvValue {
    param([string]$EnvFile, [string]$Name, [string]$DefaultValue)
    if (-not (Test-Path -LiteralPath $EnvFile)) { return $DefaultValue }
    $line = Get-Content -LiteralPath $EnvFile | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -Last 1
    if (-not $line) { return $DefaultValue }
    $value = ($line -split "=", 2)[1].Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultValue }
    return $value
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

function Invoke-Docker {
    param([string[]]$Arguments)
    Write-Log ("Chay lenh: docker {0}" -f ($Arguments -join " "))
    $output = & docker @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($output) {
        $output | ForEach-Object {
            $text = $_.ToString()
            Write-Host $text
            Add-Content -LiteralPath $LogFile -Value $text -Encoding UTF8
        }
    }
    if ($exitCode -ne 0) {
        throw "Docker that bai voi exit code $exitCode`: docker $($Arguments -join ' ')"
    }
}

function Wait-Http {
    param([string]$Url, [int]$TimeoutSeconds = 300, [string]$ExpectedText = "")
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ""
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8 -Headers @{ "Cache-Control" = "no-cache" }
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                if ([string]::IsNullOrWhiteSpace($ExpectedText) -or $response.Content.Contains($ExpectedText)) { return $true }
                $lastError = "Phan hoi chua co marker '$ExpectedText'."
            }
        } catch { $lastError = $_.Exception.Message }
        Start-Sleep -Seconds 3
    }
    Write-Log "Timeout cho $Url. Loi cuoi: $lastError" "ERROR"
    return $false
}

Write-Log "ENGLISH LEARNING APP v0.4.9.3 - TOP RIGHT LOGIN + ACCOUNT TYPE"

$ShimDir = Join-Path $env:TEMP "ela-v0493-docker-shim-$PID-$Timestamp"
$OldPath = $env:PATH
$Root = $null
try {
    $Root = Resolve-ProjectRoot
    Write-Log "Thu muc du an: $Root" "OK"

    if (-not (Test-Path -LiteralPath $PatchServer)) { throw "Thieu file Web patch: $PatchServer" }
    $realDockerCommand = Get-Command docker.exe -ErrorAction SilentlyContinue
    if (-not $realDockerCommand) { $realDockerCommand = Get-Command docker -ErrorAction SilentlyContinue }
    if (-not $realDockerCommand) { throw "Khong tim thay Docker CLI. Hay mo Docker Desktop va chay lai." }

    New-DockerShim $realDockerCommand.Source $ShimDir
    $env:PATH = $ShimDir + ";" + $OldPath
    Invoke-Docker @("info")
    Invoke-Docker @("compose", "version")

    $TargetServer = Join-Path $Root "apps\web\server.mjs"
    $BackupServer = "$TargetServer.v0492_backup_$Timestamp"
    Copy-Item -LiteralPath $TargetServer -Destination $BackupServer -Force
    Copy-Item -LiteralPath $PatchServer -Destination $TargetServer -Force
    Write-Log "Da backup Web runtime: $BackupServer"
    Write-Log "Da cai giao dien dang nhap v0.4.9.3." "OK"

    $Marker = @"
English Learning App v0.4.9.3 Role Login UI
Applied at: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Previous runtime backup: $BackupServer
PostgreSQL and MinIO volumes were preserved.
"@
    Set-Content -LiteralPath (Join-Path $Root "AUTH_V0493_APPLIED.txt") -Value $Marker -Encoding UTF8

    $Compose = Join-Path $Root "docker-compose.yml"
    Push-Location $Root
    try {
        Invoke-Docker @("compose", "--project-name", "english-learning-app", "-f", $Compose, "config", "--quiet")
        Invoke-Docker @("compose", "--project-name", "english-learning-app", "-f", $Compose, "down", "--remove-orphans")
        Invoke-Docker @("compose", "--project-name", "english-learning-app", "-f", $Compose, "up", "-d", "--build", "--force-recreate", "--remove-orphans")
    } finally { Pop-Location }

    $EnvFile = Join-Path $Root ".env"
    $WebPort = [int](Get-EnvValue $EnvFile "ELA_WEB_PORT" "3000")
    $ApiPort = [int](Get-EnvValue $EnvFile "ELA_API_PORT" "4000")
    $ApiHealth = "http://localhost:$ApiPort/api/v1/health/ready"
    $WebHealth = "http://localhost:$WebPort/__ela/health"
    $LoginUrl = "http://localhost:$WebPort/login?accountType=student&next=%2Fstudent%2Ftoday&ela_build=0.4.9.3&cache_bust=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

    if (-not (Wait-Http $ApiHealth 300)) { throw "API readiness khong dat." }
    Write-Log "API da san sang." "OK"
    if (-not (Wait-Http $WebHealth 300 "0.4.9.3-m4-auth-role-ui")) { throw "Web v0.4.9.3 khong dat." }
    Write-Log "Web v0.4.9.3 da san sang." "OK"
    if (-not (Wait-Http "http://localhost:$WebPort/login?accountType=parent" 60 'id="accountType"')) { throw "Trang dang nhap thieu bo chon loai tai khoan." }
    if (-not (Wait-Http "http://localhost:$WebPort/" 60 'id="topLoginButton"')) { throw "Trang chu thieu nut Dang nhap goc phai." }

    $ProjectLogs = Join-Path $Root "logs"
    New-Item -ItemType Directory -Force -Path $ProjectLogs | Out-Null
    Copy-Item -LiteralPath $LogFile -Destination (Join-Path $ProjectLogs (Split-Path -Leaf $LogFile)) -Force
    & docker compose --project-name english-learning-app -f $Compose ps -a 2>&1 | Out-File (Join-Path $ProjectLogs "v0493_docker_$Timestamp.log") -Encoding UTF8

    Start-Process $LoginUrl
    Write-Log "Mo trinh duyet: $LoginUrl" "OK"
    Write-Host ""
    Write-Host "HOAN TAT - v0.4.9.3 DANG CHAY" -ForegroundColor Green
    exit 0
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    Write-Host ""
    Write-Host "Khong the ap dung v0.4.9.3. Xem log: $LogFile" -ForegroundColor Red
    exit 1
}
finally {
    $env:PATH = $OldPath
    Remove-Item -LiteralPath $ShimDir -Recurse -Force -ErrorAction SilentlyContinue
}
