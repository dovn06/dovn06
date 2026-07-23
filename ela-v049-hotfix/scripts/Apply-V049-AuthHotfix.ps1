[CmdletBinding()]
param(
    [string]$ProjectRoot = ""
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleRoot = Split-Path -Parent $ScriptDir
$PatchServer = Join-Path $BundleRoot "patch\apps\web\server.mjs"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"

function Test-ProjectRoot {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $false }
    return (Test-Path (Join-Path $Path "docker-compose.yml")) -and
           (Test-Path (Join-Path $Path "apps\web\server.mjs")) -and
           (Test-Path (Join-Path $Path "package.json"))
}

function Find-ProjectRoot {
    $candidates = New-Object System.Collections.Generic.List[string]
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $candidates.Add($ProjectRoot) }
    $candidates.Add($BundleRoot)
    $candidates.Add((Split-Path -Parent $BundleRoot))
    $candidates.Add((Get-Location).Path)

    foreach ($base in @($BundleRoot, (Split-Path -Parent $BundleRoot), (Get-Location).Path)) {
        if (-not (Test-Path $base)) { continue }
        Get-ChildItem -Path $base -Directory -ErrorAction SilentlyContinue | ForEach-Object {
            $candidates.Add($_.FullName)
        }
    }

    foreach ($candidate in $candidates) {
        try {
            $resolved = (Resolve-Path $candidate -ErrorAction Stop).Path
            if (Test-ProjectRoot $resolved) { return $resolved }
        } catch { }
    }

    Write-Host "" 
    Write-Host "Khong tu dong tim thay thu muc English Learning App." -ForegroundColor Yellow
    Write-Host "Hay nhap duong dan thu muc dang chua docker-compose.yml." -ForegroundColor Yellow
    $manual = Read-Host "Duong dan project (vi du E:\English\R9\EnglishLearningApp_M4_OneClick_v0.4.8_FIXED)"
    if (Test-ProjectRoot $manual) { return (Resolve-Path $manual).Path }
    throw "Thu muc du an khong hop le: $manual"
}

function Get-EnvValue {
    param([string]$EnvFile, [string]$Name, [string]$DefaultValue)
    if (-not (Test-Path $EnvFile)) { return $DefaultValue }
    $line = Get-Content $EnvFile | Where-Object { $_ -match "^$([regex]::Escape($Name))=" } | Select-Object -Last 1
    if (-not $line) { return $DefaultValue }
    $value = ($line -split "=", 2)[1].Trim()
    if ([string]::IsNullOrWhiteSpace($value)) { return $DefaultValue }
    return $value
}

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $entry
    Add-Content -Path $script:LogFile -Value $entry -Encoding UTF8
}

function Invoke-Logged {
    param(
        [string]$Executable,
        [string[]]$Arguments,
        [switch]$AllowFailure
    )
    Write-Log ("Chay lenh: {0} {1}" -f $Executable, ($Arguments -join " "))
    $output = & $Executable @Arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($output) {
        $output | ForEach-Object {
            $text = $_.ToString()
            Write-Host $text
            Add-Content -Path $script:LogFile -Value $text -Encoding UTF8
        }
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "Lenh that bai voi exit code $exitCode`: $Executable $($Arguments -join ' ')"
    }
    return $exitCode
}

function Wait-Http {
    param(
        [string]$Url,
        [int]$TimeoutSeconds = 300,
        [string]$ExpectedText = ""
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastError = ""
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8 -Headers @{ "Cache-Control" = "no-cache" }
            if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 400) {
                if ([string]::IsNullOrWhiteSpace($ExpectedText) -or $response.Content.Contains($ExpectedText)) {
                    return $true
                }
                $lastError = "Noi dung phan hoi chua co marker '$ExpectedText'."
            }
        } catch {
            $lastError = $_.Exception.Message
        }
        Start-Sleep -Seconds 3
    }
    Write-Log "Timeout cho $Url. Loi cuoi: $lastError" "ERROR"
    return $false
}

function Update-PackageVersion {
    param([string]$FilePath)
    if (-not (Test-Path $FilePath)) { return }
    try {
        $json = Get-Content $FilePath -Raw | ConvertFrom-Json
        $json.version = "0.4.9-m4-auth-ux"
        $json | ConvertTo-Json -Depth 100 | Set-Content -Path $FilePath -Encoding UTF8
        Write-Log "Da cap nhat version: $FilePath"
    } catch {
        Write-Log "Khong cap nhat duoc version trong $FilePath; bo qua de khong anh huong build. $($_.Exception.Message)" "WARN"
    }
}

if (-not (Test-Path $PatchServer)) {
    throw "Thieu file patch: $PatchServer"
}

$Root = Find-ProjectRoot
$LogsDir = Join-Path $Root "logs"
New-Item -ItemType Directory -Force -Path $LogsDir | Out-Null
$script:LogFile = Join-Path $LogsDir "v049_auth_hotfix_$Timestamp.log"

Write-Log "======================================================================="
Write-Log "ENGLISH LEARNING APP v0.4.9 - AUTH UX HOTFIX"
Write-Log "======================================================================="
Write-Log "Thu muc du an: $Root"
Write-Log "Log: $script:LogFile"

try {
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
        throw "Khong tim thay docker.exe. Hay cai/mo Docker Desktop truoc."
    }
    Invoke-Logged "docker" @("info") | Out-Null
    Invoke-Logged "docker" @("compose", "version") | Out-Null

    $TargetServer = Join-Path $Root "apps\web\server.mjs"
    $BackupServer = "$TargetServer.v048_backup_$Timestamp"
    Copy-Item $TargetServer $BackupServer -Force
    Copy-Item $PatchServer $TargetServer -Force
    Write-Log "Da backup Web runtime cu: $BackupServer"
    Write-Log "Da cai Web auth gateway v0.4.9: $TargetServer"

    Update-PackageVersion (Join-Path $Root "package.json")
    Update-PackageVersion (Join-Path $Root "apps\web\package.json")

    $Marker = @"
English Learning App v0.4.9 Authentication UX Hotfix
Applied at: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Previous web runtime backup: $BackupServer
Data volumes were preserved. No docker compose down -v was executed.
"@
    Set-Content -Path (Join-Path $Root "AUTH_V049_APPLIED.txt") -Value $Marker -Encoding UTF8

    Push-Location $Root
    try {
        Invoke-Logged "docker" @("compose", "--project-name", "english-learning-app", "-f", (Join-Path $Root "docker-compose.yml"), "config", "--quiet") | Out-Null
        Write-Log "Dung container cu nhung GIU NGUYEN PostgreSQL/MinIO volume." "WARN"
        Invoke-Logged "docker" @("compose", "--project-name", "english-learning-app", "-f", (Join-Path $Root "docker-compose.yml"), "down", "--remove-orphans") | Out-Null
        Invoke-Logged "docker" @("compose", "--project-name", "english-learning-app", "-f", (Join-Path $Root "docker-compose.yml"), "up", "-d", "--build", "--force-recreate", "--remove-orphans") | Out-Null
    } finally {
        Pop-Location
    }

    $EnvFile = Join-Path $Root ".env"
    $WebPort = [int](Get-EnvValue $EnvFile "ELA_WEB_PORT" "3000")
    $ApiPort = [int](Get-EnvValue $EnvFile "ELA_API_PORT" "4000")
    $WebHealth = "http://localhost:$WebPort/__ela/health"
    $ApiHealth = "http://localhost:$ApiPort/api/v1/health/ready"
    $LoginUrl = "http://localhost:$WebPort/login?next=%2Fstudent%2Ftoday&ela_build=0.4.9&cache_bust=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

    Write-Log "Cho API tai: $ApiHealth"
    if (-not (Wait-Http $ApiHealth 300)) { throw "API readiness khong dat." }
    Write-Log "API da san sang." "OK"

    Write-Log "Cho Web auth gateway tai: $WebHealth"
    if (-not (Wait-Http $WebHealth 300 '0.4.9-m4-auth-ux')) { throw "Web auth gateway khong dat." }
    Write-Log "Web auth gateway v0.4.9 da san sang." "OK"

    $LoginCheck = "http://localhost:$WebPort/login?next=%2Fstudent%2Ftoday"
    if (-not (Wait-Http $LoginCheck 60 'Đăng nhập')) { throw "Trang dang nhap khong tra ve noi dung mong doi." }
    Write-Log "Trang dang nhap da duoc kiem tra." "OK"

    $SnapshotLog = Join-Path $LogsDir "v049_docker_$Timestamp.log"
    & docker compose --project-name english-learning-app -f (Join-Path $Root "docker-compose.yml") ps -a 2>&1 | Out-File $SnapshotLog -Encoding UTF8
    & docker compose --project-name english-learning-app -f (Join-Path $Root "docker-compose.yml") logs --no-color --timestamps --tail 500 2>&1 | Out-File $SnapshotLog -Append -Encoding UTF8

    Start-Process $LoginUrl
    Write-Log "Mo trinh duyet: $LoginUrl" "OK"
    Write-Log "======================================================================="
    Write-Log "HOAN TAT - v0.4.9 DANG CHAY"
    Write-Log "======================================================================="
    Write-Host ""
    Write-Host "Da cai thanh cong v0.4.9. Trinh duyet se mo trang dang nhap." -ForegroundColor Green
    Write-Host "Log: $script:LogFile" -ForegroundColor Cyan
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    try {
        $FailureLog = Join-Path $LogsDir "v049_failure_$Timestamp.log"
        & docker compose --project-name english-learning-app -f (Join-Path $Root "docker-compose.yml") ps -a 2>&1 | Out-File $FailureLog -Encoding UTF8
        & docker compose --project-name english-learning-app -f (Join-Path $Root "docker-compose.yml") logs --no-color --timestamps --tail 1200 2>&1 | Out-File $FailureLog -Append -Encoding UTF8
        Write-Log "Da luu Docker diagnostic: $FailureLog" "WARN"
    } catch { }
    Write-Host ""
    Write-Host "Ap dung v0.4.9 that bai. Xem log: $script:LogFile" -ForegroundColor Red
    exit 1
}
