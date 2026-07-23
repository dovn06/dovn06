[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$SelfTest
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleRoot = Split-Path -Parent $ScriptDir
$DiscoveryScript = Join-Path $ScriptDir "Apply-V049-AuthHotfix.ps1"
$PatchServer = Join-Path $BundleRoot "patch\apps\web\server.mjs"
$PatchDockerDir = Join-Path $BundleRoot "patch\infrastructure\docker"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogDir = Join-Path $BundleRoot "logs"
New-Item -ItemType Directory -Force -Path $LogDir | Out-Null
$LogFile = Join-Path $LogDir "v0495_offline_reuse_$Timestamp.log"

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
    $args = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $DiscoveryScript, "-DiscoveryOnly")
    if (-not [string]::IsNullOrWhiteSpace($ProjectRoot)) { $args += @("-ProjectRoot", $ProjectRoot.Trim().Trim('"')) }
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

function Set-EnvValue {
    param([string]$EnvFile, [string]$Name, [string]$Value)
    $content = if (Test-Path -LiteralPath $EnvFile) { Get-Content -LiteralPath $EnvFile -Raw } else { "" }
    $escaped = [regex]::Escape($Name)
    if ($content -match "(?m)^$escaped=") {
        $content = [regex]::Replace($content, "(?m)^$escaped=.*$", "$Name=$Value")
    } else {
        if ($content -and -not $content.EndsWith("`n")) { $content += "`r`n" }
        $content += "$Name=$Value`r`n"
    }
    [IO.File]::WriteAllText($EnvFile, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function New-Secret {
    $bytes = New-Object byte[] 48
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Ensure-Environment {
    param([string]$Root)
    $envFile = Join-Path $Root ".env"
    $example = Join-Path $Root ".env.example"
    if (-not (Test-Path -LiteralPath $envFile)) {
        if (-not (Test-Path -LiteralPath $example)) { throw "Khong co .env hoac .env.example." }
        Copy-Item -LiteralPath $example -Destination $envFile -Force
        Write-Log "Da tao lai .env tu .env.example." "OK"
    }
    $secret = Get-EnvValue $envFile "JWT_SECRET" ""
    if ($secret.Length -lt 32 -or $secret -eq "replace-with-at-least-32-characters") {
        Set-EnvValue $envFile "JWT_SECRET" (New-Secret)
        Write-Log "Da sinh JWT_SECRET an toan." "OK"
    }
    foreach ($entry in @(
        @{ N = "ELA_WEB_PORT"; V = "3000" },
        @{ N = "ELA_API_PORT"; V = "4000" },
        @{ N = "ELA_MINIO_API_PORT"; V = "9000" },
        @{ N = "ELA_MINIO_CONSOLE_PORT"; V = "9001" },
        @{ N = "ELA_MAILPIT_SMTP_PORT"; V = "1025" },
        @{ N = "ELA_MAILPIT_UI_PORT"; V = "8025" },
        @{ N = "SEED_DEMO_DATA"; V = "true" }
    )) {
        if ([string]::IsNullOrWhiteSpace((Get-EnvValue $envFile $entry.N ""))) { Set-EnvValue $envFile $entry.N $entry.V }
    }
    $webPort = Get-EnvValue $envFile "ELA_WEB_PORT" "3000"
    $apiPort = Get-EnvValue $envFile "ELA_API_PORT" "4000"
    Set-EnvValue $envFile "NEXT_PUBLIC_API_URL" "http://localhost:$apiPort/api/v1"
    Set-EnvValue $envFile "CORS_ORIGINS" "http://localhost:$webPort,http://127.0.0.1:$webPort"
    Set-EnvValue $envFile "WEB_CONNECT_ORIGINS" "http://localhost:$apiPort,http://127.0.0.1:$apiPort"
    return $envFile
}

function Invoke-Native {
    param([string]$File, [string[]]$Arguments, [switch]$AllowFailure)
    Write-Log ("Chay lenh: {0} {1}" -f $File, ($Arguments -join " "))
    $output = & $File @Arguments 2>&1
    $code = $LASTEXITCODE
    if ($output) {
        $output | ForEach-Object {
            $text = $_.ToString()
            Write-Host $text
            Add-Content -LiteralPath $LogFile -Value $text -Encoding UTF8
        }
    }
    if ($code -ne 0 -and -not $AllowFailure) { throw "$File that bai voi exit code $code" }
    return $code
}

function Wait-Url {
    param([string]$Url, [int]$Seconds = 240, [string]$Marker = "")
    $deadline = (Get-Date).AddSeconds($Seconds)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri $Url -UseBasicParsing -TimeoutSec 8 -Headers @{ "Cache-Control" = "no-cache" }
            if ($r.StatusCode -ge 200 -and $r.StatusCode -lt 400) {
                if ([string]::IsNullOrWhiteSpace($Marker) -or $r.Content.Contains($Marker)) { return $true }
            }
        } catch { }
        Start-Sleep -Seconds 3
    }
    return $false
}

function Write-RuntimeOverride {
    param([string]$Root)
    $override = Join-Path $Root "docker-compose.v0495.runtime.yml"
    @"
services:
  web:
    volumes:
      - type: bind
        source: ./apps/web/server.mjs
        target: /app/apps/web/server.mjs
        read_only: true
"@ | Set-Content -LiteralPath $override -Encoding UTF8
    return $override
}

function Install-NetworkDockerfiles {
    param([string]$Root)
    $targetDir = Join-Path $Root "infrastructure\docker"
    foreach ($name in @("api.Dockerfile", "worker.Dockerfile", "web.Dockerfile")) {
        $source = Join-Path $PatchDockerDir $name
        $target = Join-Path $targetDir $name
        if (-not (Test-Path -LiteralPath $source)) { throw "Thieu Dockerfile patch: $source" }
        if (Test-Path -LiteralPath $target) { Copy-Item $target "$target.v0495_backup_$Timestamp" -Force }
        Copy-Item $source $target -Force
    }
    Write-Log "Da cai Dockerfile co PNPM cache, timeout dai va retry." "OK"
}

if ($SelfTest) {
    $tmp = Join-Path $env:TEMP "ela-v0495-test-$PID-$Timestamp"
    try {
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp "apps\web") | Out-Null
        New-Item -ItemType Directory -Force -Path (Join-Path $tmp "infrastructure\docker") | Out-Null
        Set-Content (Join-Path $tmp "package.json") "{}"
        Set-Content (Join-Path $tmp "docker-compose.yml") "services: {}"
        Set-Content (Join-Path $tmp "apps\web\server.mjs") "console.log('x')"
        Set-Content (Join-Path $tmp ".env.example") "JWT_SECRET=replace-with-at-least-32-characters`nELA_WEB_PORT=3000`nELA_API_PORT=4000"
        $envFile = Ensure-Environment $tmp
        $override = Write-RuntimeOverride $tmp
        Install-NetworkDockerfiles $tmp
        if (-not (Test-Path $envFile)) { throw "Self-test thieu .env" }
        if (-not (Select-String -LiteralPath $override -Pattern "/app/apps/web/server.mjs" -Quiet)) { throw "Self-test override sai" }
        if (-not (Select-String -LiteralPath (Join-Path $tmp "infrastructure\docker\api.Dockerfile") -Pattern "ela-pnpm-store" -Quiet)) { throw "Self-test cache sai" }
        Write-Output "SELF_TEST_OFFLINE_REUSE=PASS"
        exit 0
    } finally { Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue }
}

Write-Log "ENGLISH LEARNING APP v0.4.9.5 - OFFLINE IMAGE REUSE + RESILIENT BUILD"
$Root = $null
try {
    $Root = Resolve-ProjectRoot
    Write-Log "Thu muc du an: $Root" "OK"
    Invoke-Native "docker" @("info") | Out-Null
    Invoke-Native "docker" @("compose", "version") | Out-Null

    $envFile = Ensure-Environment $Root
    $webPort = [int](Get-EnvValue $envFile "ELA_WEB_PORT" "3000")
    $apiPort = [int](Get-EnvValue $envFile "ELA_API_PORT" "4000")

    Copy-Item (Join-Path $Root "apps\web\server.mjs") (Join-Path $Root "apps\web\server.mjs.v0495_backup_$Timestamp") -Force
    Copy-Item $PatchServer (Join-Path $Root "apps\web\server.mjs") -Force
    $override = Write-RuntimeOverride $Root
    $compose = Join-Path $Root "docker-compose.yml"

    Push-Location $Root
    try {
        Invoke-Native "docker" @("compose", "--project-name", "english-learning-app", "-f", $compose, "-f", $override, "config", "--quiet") | Out-Null
        Invoke-Native "docker" @("compose", "--project-name", "english-learning-app", "-f", $compose, "-f", $override, "down", "--remove-orphans") -AllowFailure | Out-Null

        Write-Log "Thu khoi dong bang image cu, khong build va khong truy cap npm." "INFO"
        $noBuild = Invoke-Native "docker" @("compose", "--project-name", "english-learning-app", "-f", $compose, "-f", $override, "up", "-d", "--no-build", "--force-recreate", "--remove-orphans") -AllowFailure
        $ready = $false
        if ($noBuild -eq 0) {
            $ready = (Wait-Url "http://localhost:$apiPort/api/v1/health/ready" 180) -and (Wait-Url "http://localhost:$webPort/__ela/health" 180 "0.4.9.3-m4-auth-role-ui")
        }

        if (-not $ready) {
            Write-Log "Image cu khong day du hoac chua san sang; chuyen sang build co cache va retry." "WARN"
            Invoke-Native "docker" @("compose", "--project-name", "english-learning-app", "-f", $compose, "-f", $override, "down", "--remove-orphans") -AllowFailure | Out-Null
            Install-NetworkDockerfiles $Root
            $env:DOCKER_BUILDKIT = "1"
            $env:COMPOSE_PARALLEL_LIMIT = "1"
            $built = $false
            for ($attempt = 1; $attempt -le 4; $attempt++) {
                Write-Log "Build attempt $attempt/4. Cache PNPM se duoc giu neu mang timeout." "INFO"
                $code = Invoke-Native "docker" @("compose", "--project-name", "english-learning-app", "-f", $compose, "-f", $override, "build", "--progress", "plain") -AllowFailure
                if ($code -eq 0) { $built = $true; break }
                if ($attempt -lt 4) { Start-Sleep -Seconds (15 * $attempt) }
            }
            if (-not $built) { throw "Build that bai sau 4 lan. Goi chan doan se chua log day du." }
            Invoke-Native "docker" @("compose", "--project-name", "english-learning-app", "-f", $compose, "-f", $override, "up", "-d", "--no-build", "--force-recreate", "--remove-orphans") | Out-Null
            $ready = (Wait-Url "http://localhost:$apiPort/api/v1/health/ready" 300) -and (Wait-Url "http://localhost:$webPort/__ela/health" 300 "0.4.9.3-m4-auth-role-ui")
        }

        if (-not $ready) { throw "API hoac Web chua san sang sau khi khoi dong." }
    } finally { Pop-Location }

    $login = "http://localhost:$webPort/login?accountType=student&next=%2Fstudent%2Ftoday&ela_build=0.4.9.5&cache_bust=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
    Start-Process $login
    Write-Log "Mo trinh duyet: $login" "OK"
    Write-Host ""
    Write-Host "HOAN TAT - v0.4.9.5 DANG CHAY" -ForegroundColor Green
    exit 0
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    if ($Root -and (Test-Path $Root)) {
        $projectLogs = Join-Path $Root "logs"
        New-Item -ItemType Directory -Force -Path $projectLogs | Out-Null
        Copy-Item $LogFile (Join-Path $projectLogs (Split-Path -Leaf $LogFile)) -Force -ErrorAction SilentlyContinue
    }
    Write-Host "Khong the khoi dong v0.4.9.5. Xem log: $LogFile" -ForegroundColor Red
    exit 1
}
