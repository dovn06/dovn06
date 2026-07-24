[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$EnvironmentSelfTest
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
$LogFile = Join-Path $BootstrapLogs "v0494_environment_recovery_$Timestamp.log"

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

function Get-EnvMap {
    param([string]$EnvFile)
    $map = @{}
    if (-not (Test-Path -LiteralPath $EnvFile)) { return $map }
    foreach ($line in Get-Content -LiteralPath $EnvFile) {
        $trimmed = $line.Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed -notmatch '=') { continue }
        $parts = $trimmed.Split('=', 2)
        $map[$parts[0].Trim()] = $parts[1].Trim()
    }
    return $map
}

function Get-EnvValue {
    param([string]$EnvFile, [string]$Name, [string]$DefaultValue)
    $map = Get-EnvMap $EnvFile
    if ($map.ContainsKey($Name) -and -not [string]::IsNullOrWhiteSpace([string]$map[$Name])) {
        return [string]$map[$Name]
    }
    return $DefaultValue
}

function Set-EnvValue {
    param([string]$EnvFile, [string]$Name, [string]$Value)
    $content = if (Test-Path -LiteralPath $EnvFile) { Get-Content -LiteralPath $EnvFile -Raw } else { "" }
    $escaped = [regex]::Escape($Name)
    if ($content -match "(?m)^$escaped=") {
        $content = [regex]::Replace($content, "(?m)^$escaped=.*$", "$Name=$Value")
    }
    else {
        if ($content -and -not $content.EndsWith("`n")) { $content += "`r`n" }
        $content += "$Name=$Value`r`n"
    }
    [IO.File]::WriteAllText($EnvFile, $content, (New-Object System.Text.UTF8Encoding($false)))
}

function New-SecureSecret {
    $bytes = New-Object byte[] 48
    $rng = [Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Test-PortAvailable {
    param([int]$Port)
    try {
        $listeners = [System.Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()
        return -not ($listeners | Where-Object { $_.Port -eq $Port })
    }
    catch {
        try {
            $probe = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
            $probe.Start()
            $probe.Stop()
            return $true
        }
        catch { return $false }
    }
}

function Find-FreePort {
    param([int]$PreferredPort, [int[]]$ReservedPorts = @())
    for ($candidate = $PreferredPort; $candidate -le ($PreferredPort + 200); $candidate++) {
        if ($ReservedPorts -contains $candidate) { continue }
        if (Test-PortAvailable $candidate) { return $candidate }
    }
    throw "Khong tim thay cong TCP trong khoang $PreferredPort-$($PreferredPort + 200)."
}

function Get-ExistingComposePort {
    param([string]$Service, [int]$ContainerPort)
    try {
        $ids = @(& docker ps -aq --filter "label=com.docker.compose.project=english-learning-app" --filter "label=com.docker.compose.service=$Service" 2>$null)
        foreach ($id in $ids) {
            if ([string]::IsNullOrWhiteSpace([string]$id)) { continue }
            $raw = (& docker inspect ([string]$id).Trim() 2>$null | Out-String)
            if ([string]::IsNullOrWhiteSpace($raw)) { continue }
            $objects = $raw | ConvertFrom-Json
            $bindings = $objects[0].HostConfig.PortBindings
            if ($null -eq $bindings) { continue }
            $property = $bindings.PSObject.Properties["$ContainerPort/tcp"]
            if ($null -ne $property -and $null -ne $property.Value -and $property.Value.Count -gt 0) {
                $hostPort = [string]$property.Value[0].HostPort
                if ($hostPort -match '^\d+$') { return [int]$hostPort }
            }
        }
    }
    catch {
        Write-Log "Khong doc duoc cong container cu cua service $Service; se tim cong trong. $($_.Exception.Message)" "WARN"
    }
    return $null
}

function Ensure-EnvironmentFile {
    param([string]$Root, [switch]$SkipDockerInspection)

    $envFile = Join-Path $Root ".env"
    $exampleFile = Join-Path $Root ".env.example"
    if (-not (Test-Path -LiteralPath $exampleFile)) {
        throw "Khong tim thay .env.example tai $exampleFile. Hay dung thu muc ma nguon day du."
    }

    if (Test-Path -LiteralPath $envFile) {
        $backup = "$envFile.v0494_backup_$Timestamp"
        Copy-Item -LiteralPath $envFile -Destination $backup -Force
        Write-Log "Da backup .env hien tai: $backup"
    }
    else {
        Copy-Item -LiteralPath $exampleFile -Destination $envFile -Force
        Write-Log "Da khoi phuc .env tu .env.example." "OK"
    }

    $secret = Get-EnvValue $envFile "JWT_SECRET" ""
    if ([string]::IsNullOrWhiteSpace($secret) -or $secret -eq "replace-with-at-least-32-characters" -or $secret.Length -lt 32) {
        Set-EnvValue $envFile "JWT_SECRET" (New-SecureSecret)
        Write-Log "Da sinh JWT_SECRET ngau nhien; cac phien cu se dang nhap lai mot lan." "OK"
    }

    $map = Get-EnvMap $envFile
    $definitions = @(
        @{ Key = "ELA_WEB_PORT"; Legacy = "WEB_PORT"; Default = 3000; Service = "web"; Container = 3000 },
        @{ Key = "ELA_API_PORT"; Legacy = "API_PORT"; Default = 4000; Service = "api"; Container = 4000 },
        @{ Key = "ELA_MINIO_API_PORT"; Legacy = ""; Default = 9000; Service = "minio"; Container = 9000 },
        @{ Key = "ELA_MINIO_CONSOLE_PORT"; Legacy = ""; Default = 9001; Service = "minio"; Container = 9001 },
        @{ Key = "ELA_MAILPIT_SMTP_PORT"; Legacy = ""; Default = 1025; Service = "mailpit"; Container = 1025 },
        @{ Key = "ELA_MAILPIT_UI_PORT"; Legacy = ""; Default = 8025; Service = "mailpit"; Container = 8025 }
    )

    $reserved = New-Object System.Collections.Generic.List[int]
    $chosen = @{}
    foreach ($definition in $definitions) {
        $preferred = [int]$definition.Default
        if ($map.ContainsKey($definition.Key) -and [string]$map[$definition.Key] -match '^\d+$') {
            $preferred = [int]$map[$definition.Key]
        }
        elseif ($definition.Legacy -and $map.ContainsKey($definition.Legacy) -and [string]$map[$definition.Legacy] -match '^\d+$') {
            $preferred = [int]$map[$definition.Legacy]
        }

        $existing = $null
        if (-not $SkipDockerInspection) {
            $existing = Get-ExistingComposePort $definition.Service $definition.Container
        }

        if ($null -ne $existing -and -not $reserved.Contains([int]$existing)) {
            $port = [int]$existing
            Write-Log "Giu cong container cu cho $($definition.Key): $port"
        }
        elseif ((Test-PortAvailable $preferred) -and -not $reserved.Contains($preferred)) {
            $port = $preferred
        }
        else {
            $port = Find-FreePort $preferred $reserved.ToArray()
            if ($port -ne $preferred) {
                Write-Log "Cong $preferred dang ban; chuyen $($definition.Key) sang $port." "WARN"
            }
        }
        $reserved.Add($port)
        $chosen[$definition.Key] = $port
        Set-EnvValue $envFile $definition.Key ([string]$port)
    }

    Set-EnvValue $envFile "NODE_ENV" "development"
    Set-EnvValue $envFile "WEB_PORT" ([string]$chosen.ELA_WEB_PORT)
    Set-EnvValue $envFile "API_PORT" ([string]$chosen.ELA_API_PORT)
    Set-EnvValue $envFile "NEXT_PUBLIC_API_URL" ("http://localhost:{0}/api/v1" -f $chosen.ELA_API_PORT)
    Set-EnvValue $envFile "CORS_ORIGINS" ("http://localhost:{0},http://127.0.0.1:{0}" -f $chosen.ELA_WEB_PORT)
    Set-EnvValue $envFile "WEB_CONNECT_ORIGINS" ("http://localhost:{0},http://127.0.0.1:{0}" -f $chosen.ELA_API_PORT)
    Set-EnvValue $envFile "OBJECT_STORAGE_ENDPOINT" ("http://localhost:{0}" -f $chosen.ELA_MINIO_API_PORT)
    Set-EnvValue $envFile "DATABASE_URL" "postgresql://ela:ela_dev_password@localhost:5432/ela"
    Set-EnvValue $envFile "REDIS_URL" "redis://localhost:6379"
    Set-EnvValue $envFile "SEED_DEMO_DATA" "true"

    Write-Log ("Cau hinh cong: Web={0}, API={1}, MinIO={2}/{3}, Mailpit={4}/{5}" -f $chosen.ELA_WEB_PORT, $chosen.ELA_API_PORT, $chosen.ELA_MINIO_API_PORT, $chosen.ELA_MINIO_CONSOLE_PORT, $chosen.ELA_MAILPIT_SMTP_PORT, $chosen.ELA_MAILPIT_UI_PORT) "OK"
    return $envFile
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
        }
        catch { $lastError = $_.Exception.Message }
        Start-Sleep -Seconds 3
    }
    Write-Log "Timeout cho $Url. Loi cuoi: $lastError" "ERROR"
    return $false
}

if ($EnvironmentSelfTest) {
    $testRoot = Join-Path $env:TEMP "ela-v0494-env-test-$PID-$Timestamp"
    try {
        New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
        @"
NODE_ENV=development
WEB_PORT=3000
API_PORT=4000
ELA_WEB_PORT=3000
ELA_API_PORT=4000
ELA_MINIO_API_PORT=9000
ELA_MINIO_CONSOLE_PORT=9001
ELA_MAILPIT_SMTP_PORT=1025
ELA_MAILPIT_UI_PORT=8025
JWT_SECRET=replace-with-at-least-32-characters
NEXT_PUBLIC_API_URL=http://localhost:4000/api/v1
CORS_ORIGINS=http://localhost:3000
WEB_CONNECT_ORIGINS=http://localhost:4000
SEED_DEMO_DATA=true
"@ | Set-Content -LiteralPath (Join-Path $testRoot ".env.example") -Encoding UTF8
        $first = Ensure-EnvironmentFile $testRoot -SkipDockerInspection
        $jwt1 = Get-EnvValue $first "JWT_SECRET" ""
        if (-not (Test-Path -LiteralPath $first)) { throw "Self-test khong tao .env." }
        if ($jwt1.Length -lt 32 -or $jwt1 -eq "replace-with-at-least-32-characters") { throw "Self-test JWT khong an toan." }
        $second = Ensure-EnvironmentFile $testRoot -SkipDockerInspection
        $jwt2 = Get-EnvValue $second "JWT_SECRET" ""
        if ($jwt1 -ne $jwt2) { throw "Self-test da thay JWT hop le khi chay lai." }
        foreach ($key in @("ELA_WEB_PORT", "ELA_API_PORT", "NEXT_PUBLIC_API_URL", "CORS_ORIGINS", "WEB_CONNECT_ORIGINS")) {
            if ([string]::IsNullOrWhiteSpace((Get-EnvValue $second $key ""))) { throw "Self-test thieu $key." }
        }
        Write-Output "SELF_TEST_ENV_RECOVERY=PASS"
        exit 0
    }
    finally {
        Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Log "ENGLISH LEARNING APP v0.4.9.4 - ENVIRONMENT RECOVERY + ROLE LOGIN UI"

$ShimDir = Join-Path $env:TEMP "ela-v0494-docker-shim-$PID-$Timestamp"
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

    $EnvFile = Ensure-EnvironmentFile $Root
    Write-Log "File moi truong da san sang: $EnvFile" "OK"

    $TargetServer = Join-Path $Root "apps\web\server.mjs"
    $BackupServer = "$TargetServer.v0493_backup_$Timestamp"
    Copy-Item -LiteralPath $TargetServer -Destination $BackupServer -Force
    Copy-Item -LiteralPath $PatchServer -Destination $TargetServer -Force
    Write-Log "Da backup Web runtime: $BackupServer"
    Write-Log "Da cai giao dien dang nhap theo loai tai khoan." "OK"

    $Marker = @"
English Learning App v0.4.9.4 Environment Recovery
Applied at: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Previous runtime backup: $BackupServer
Environment file recovered and validated.
PostgreSQL and MinIO volumes were preserved.
"@
    Set-Content -LiteralPath (Join-Path $Root "AUTH_V0494_APPLIED.txt") -Value $Marker -Encoding UTF8

    $Compose = Join-Path $Root "docker-compose.yml"
    Push-Location $Root
    try {
        Invoke-Docker @("compose", "--project-name", "english-learning-app", "-f", $Compose, "config", "--quiet")
        Invoke-Docker @("compose", "--project-name", "english-learning-app", "-f", $Compose, "down", "--remove-orphans")
        Invoke-Docker @("compose", "--project-name", "english-learning-app", "-f", $Compose, "up", "-d", "--build", "--force-recreate", "--remove-orphans")
    }
    finally { Pop-Location }

    $WebPort = [int](Get-EnvValue $EnvFile "ELA_WEB_PORT" "3000")
    $ApiPort = [int](Get-EnvValue $EnvFile "ELA_API_PORT" "4000")
    $ApiHealth = "http://localhost:$ApiPort/api/v1/health/ready"
    $WebHealth = "http://localhost:$WebPort/__ela/health"
    $LoginUrl = "http://localhost:$WebPort/login?accountType=student&next=%2Fstudent%2Ftoday&ela_build=0.4.9.4&cache_bust=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

    if (-not (Wait-Http $ApiHealth 300)) { throw "API readiness khong dat." }
    Write-Log "API da san sang." "OK"
    if (-not (Wait-Http $WebHealth 300 "0.4.9.3-m4-auth-role-ui")) { throw "Web auth role UI khong dat." }
    Write-Log "Web auth role UI da san sang." "OK"
    if (-not (Wait-Http "http://localhost:$WebPort/login?accountType=parent" 60 'id="accountType"')) { throw "Trang dang nhap thieu bo chon loai tai khoan." }
    if (-not (Wait-Http "http://localhost:$WebPort/" 60 'id="topLoginButton"')) { throw "Trang chu thieu nut Dang nhap goc phai." }

    $ProjectLogs = Join-Path $Root "logs"
    New-Item -ItemType Directory -Force -Path $ProjectLogs | Out-Null
    Copy-Item -LiteralPath $LogFile -Destination (Join-Path $ProjectLogs (Split-Path -Leaf $LogFile)) -Force
    & docker compose --project-name english-learning-app -f $Compose ps -a 2>&1 | Out-File (Join-Path $ProjectLogs "v0494_docker_$Timestamp.log") -Encoding UTF8

    Start-Process $LoginUrl
    Write-Log "Mo trinh duyet: $LoginUrl" "OK"
    Write-Host ""
    Write-Host "HOAN TAT - v0.4.9.4 DANG CHAY" -ForegroundColor Green
    exit 0
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    if ($Root -and (Test-ProjectRoot $Root)) {
        try {
            $projectLogs = Join-Path $Root "logs"
            New-Item -ItemType Directory -Force -Path $projectLogs | Out-Null
            Copy-Item -LiteralPath $LogFile -Destination (Join-Path $projectLogs (Split-Path -Leaf $LogFile)) -Force
        }
        catch { }
    }
    Write-Host ""
    Write-Host "Khong the ap dung v0.4.9.4. Xem log: $LogFile" -ForegroundColor Red
    exit 1
}
finally {
    $env:PATH = $OldPath
    Remove-Item -LiteralPath $ShimDir -Recurse -Force -ErrorAction SilentlyContinue
}
