[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$RootDir,
    [string]$LogFile = '',
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Write-Stage {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
}

function Write-Utf8NoBom {
    param([string]$Path, [string]$Content)
    $encoding = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($Path, $Content, $encoding)
}

function Read-EnvironmentMap {
    param([string]$Path)
    $map = @{}
    if (-not (Test-Path -LiteralPath $Path)) { return $map }
    foreach ($line in Get-Content -LiteralPath $Path) {
        $trimmed = ([string]$line).Trim()
        if (-not $trimmed -or $trimmed.StartsWith('#') -or $trimmed.IndexOf('=') -lt 1) { continue }
        $parts = $trimmed.Split(@('='), 2)
        $map[$parts[0].Trim()] = $parts[1].Trim()
    }
    return $map
}

function Set-EnvironmentValue {
    param([string]$Path, [string]$Name, [string]$Value)
    $content = if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw } else { '' }
    if ($null -eq $content) { $content = '' }
    $escapedName = [regex]::Escape($Name)
    if ($content -match "(?m)^$escapedName=") {
        $content = [regex]::Replace($content, "(?m)^$escapedName=.*$", "$Name=$Value")
    }
    else {
        if ($content.Length -gt 0 -and -not $content.EndsWith("`n")) { $content += "`r`n" }
        $content += "$Name=$Value`r`n"
    }
    Write-Utf8NoBom -Path $Path -Content $content
}

function New-SecureSecret {
    $bytes = New-Object byte[] 48
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) }
    finally { $rng.Dispose() }
    return [Convert]::ToBase64String($bytes)
}

function Test-PortAvailable {
    param([int]$Port)
    $listener = $null
    try {
        $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $Port)
        $listener.Start()
        return $true
    }
    catch { return $false }
    finally {
        if ($null -ne $listener) {
            try { $listener.Stop() } catch { }
        }
    }
}

function Select-Port {
    param([int]$Preferred, [int[]]$Reserved, [switch]$SkipProbe)
    for ($candidate = $Preferred; $candidate -le ($Preferred + 200); $candidate++) {
        if ($Reserved -contains $candidate) { continue }
        if ($SkipProbe -or (Test-PortAvailable -Port $candidate)) { return $candidate }
    }
    throw "Khong tim thay cong trong tu $Preferred den $($Preferred + 200)."
}

function Initialize-Environment {
    param([string]$Root, [switch]$SkipPortProbe)

    $resolvedRoot = (Resolve-Path -LiteralPath $Root).Path
    $envFile = Join-Path $resolvedRoot '.env'
    $exampleFile = Join-Path $resolvedRoot '.env.example'
    Write-Stage "Root environment: $resolvedRoot"

    if (-not (Test-Path -LiteralPath $exampleFile)) {
        throw "Thieu file .env.example: $exampleFile"
    }

    if (-not (Test-Path -LiteralPath $envFile)) {
        Copy-Item -LiteralPath $exampleFile -Destination $envFile -Force
        Write-Stage 'Da tao .env tu .env.example.' 'OK'
    }
    else {
        $backup = "$envFile.full_backup_$(Get-Date -Format yyyyMMdd_HHmmss)"
        Copy-Item -LiteralPath $envFile -Destination $backup -Force
        Write-Stage "Da backup .env: $backup"
    }

    $map = Read-EnvironmentMap -Path $envFile
    $jwt = if ($map.ContainsKey('JWT_SECRET')) { [string]$map['JWT_SECRET'] } else { '' }
    if ([string]::IsNullOrWhiteSpace($jwt) -or $jwt.Length -lt 32 -or $jwt -eq 'replace-with-at-least-32-characters') {
        Set-EnvironmentValue -Path $envFile -Name 'JWT_SECRET' -Value (New-SecureSecret)
        Write-Stage 'Da sinh JWT_SECRET an toan.' 'OK'
    }

    $definitions = @(
        @{ Key = 'ELA_WEB_PORT'; Default = 3000 },
        @{ Key = 'ELA_API_PORT'; Default = 4000 },
        @{ Key = 'ELA_MINIO_API_PORT'; Default = 9000 },
        @{ Key = 'ELA_MINIO_CONSOLE_PORT'; Default = 9001 },
        @{ Key = 'ELA_MAILPIT_SMTP_PORT'; Default = 1025 },
        @{ Key = 'ELA_MAILPIT_UI_PORT'; Default = 8025 }
    )

    $reserved = @()
    $chosen = @{}
    $map = Read-EnvironmentMap -Path $envFile
    foreach ($definition in $definitions) {
        $preferred = [int]$definition.Default
        if ($map.ContainsKey($definition.Key) -and ([string]$map[$definition.Key]) -match '^\d+$') {
            $preferred = [int]$map[$definition.Key]
        }
        $port = Select-Port -Preferred $preferred -Reserved $reserved -SkipProbe:$SkipPortProbe
        $chosen[$definition.Key] = [int]$port
        $reserved += [int]$port
        Set-EnvironmentValue -Path $envFile -Name $definition.Key -Value ([string]$port)
        if ($port -ne $preferred) { Write-Stage "Cong $preferred dang ban; $($definition.Key) dung cong $port." 'WARN' }
    }

    Set-EnvironmentValue -Path $envFile -Name 'NODE_ENV' -Value 'development'
    Set-EnvironmentValue -Path $envFile -Name 'WEB_PORT' -Value ([string]$chosen['ELA_WEB_PORT'])
    Set-EnvironmentValue -Path $envFile -Name 'API_PORT' -Value ([string]$chosen['ELA_API_PORT'])
    Set-EnvironmentValue -Path $envFile -Name 'NEXT_PUBLIC_API_URL' -Value ("http://localhost:{0}/api/v1" -f $chosen['ELA_API_PORT'])
    Set-EnvironmentValue -Path $envFile -Name 'CORS_ORIGINS' -Value ("http://localhost:{0},http://127.0.0.1:{0}" -f $chosen['ELA_WEB_PORT'])
    Set-EnvironmentValue -Path $envFile -Name 'WEB_CONNECT_ORIGINS' -Value ("http://localhost:{0},http://127.0.0.1:{0}" -f $chosen['ELA_API_PORT'])
    Set-EnvironmentValue -Path $envFile -Name 'OBJECT_STORAGE_ENDPOINT' -Value ("http://localhost:{0}" -f $chosen['ELA_MINIO_API_PORT'])
    Set-EnvironmentValue -Path $envFile -Name 'DATABASE_URL' -Value 'postgresql://ela:ela_dev_password@localhost:5432/ela'
    Set-EnvironmentValue -Path $envFile -Name 'REDIS_URL' -Value 'redis://localhost:6379'
    Set-EnvironmentValue -Path $envFile -Name 'SEED_DEMO_DATA' -Value 'true'
    Set-EnvironmentValue -Path $envFile -Name 'DEMO_PASSWORD' -Value 'Demo123!'

    Write-Stage ("ENV_READY Web={0} API={1} MinIO={2}/{3} Mailpit={4}/{5}" -f $chosen['ELA_WEB_PORT'], $chosen['ELA_API_PORT'], $chosen['ELA_MINIO_API_PORT'], $chosen['ELA_MINIO_CONSOLE_PORT'], $chosen['ELA_MAILPIT_SMTP_PORT'], $chosen['ELA_MAILPIT_UI_PORT']) 'OK'
    return $envFile
}

try {
    if ($SelfTest) {
        $testRoot = Join-Path $env:TEMP ("ela-full-env-test-{0}-{1}" -f $PID, (Get-Date -Format yyyyMMddHHmmss))
        try {
            New-Item -ItemType Directory -Force -Path $testRoot | Out-Null
            @"
NODE_ENV=development
ELA_WEB_PORT=3000
ELA_API_PORT=4000
ELA_MINIO_API_PORT=9000
ELA_MINIO_CONSOLE_PORT=9001
ELA_MAILPIT_SMTP_PORT=1025
ELA_MAILPIT_UI_PORT=8025
JWT_SECRET=replace-with-at-least-32-characters
"@ | Set-Content -LiteralPath (Join-Path $testRoot '.env.example') -Encoding UTF8
            $result = Initialize-Environment -Root $testRoot -SkipPortProbe
            $testMap = Read-EnvironmentMap -Path $result
            if (-not (Test-Path -LiteralPath $result)) { throw 'Self-test khong tao .env.' }
            if (-not $testMap.ContainsKey('JWT_SECRET') -or ([string]$testMap['JWT_SECRET']).Length -lt 32) { throw 'Self-test JWT that bai.' }
            if ($testMap['NEXT_PUBLIC_API_URL'] -ne 'http://localhost:4000/api/v1') { throw 'Self-test API URL that bai.' }
            Write-Output 'SELF_TEST_FULL_ENV=PASS'
            exit 0
        }
        finally { Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue }
    }

    Initialize-Environment -Root $RootDir | Out-Null
    exit 0
}
catch {
    Write-Stage $_.Exception.Message 'ERROR'
    if ($_.ScriptStackTrace) { Write-Stage $_.ScriptStackTrace 'ERROR' }
    exit 1
}
