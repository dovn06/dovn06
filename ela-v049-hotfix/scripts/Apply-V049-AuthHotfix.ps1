[CmdletBinding()]
param(
    [string]$ProjectRoot = "",
    [switch]$DiscoveryOnly
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$BundleRoot = Split-Path -Parent $ScriptDir
$PatchServer = Join-Path $BundleRoot "patch\apps\web\server.mjs"
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$BootstrapLogsDir = Join-Path $BundleRoot "logs"
New-Item -ItemType Directory -Force -Path $BootstrapLogsDir | Out-Null
$script:LogFile = Join-Path $BootstrapLogsDir "v0491_auth_hotfix_$Timestamp.log"
$script:ResolvedProjectRoot = $null

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $entry = "[{0}] [{1}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message
    Write-Host $entry
    Add-Content -Path $script:LogFile -Value $entry -Encoding UTF8
}

function Normalize-PathInput {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    $clean = [Environment]::ExpandEnvironmentVariables($Path.Trim().Trim('"'))
    try { return (Resolve-Path -LiteralPath $clean -ErrorAction Stop).Path } catch { return $null }
}

function Test-ProjectRoot {
    param([string]$Path)
    $resolved = Normalize-PathInput $Path
    if ([string]::IsNullOrWhiteSpace($resolved)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $resolved "docker-compose.yml")) -and
           (Test-Path -LiteralPath (Join-Path $resolved "apps\web\server.mjs")) -and
           (Test-Path -LiteralPath (Join-Path $resolved "package.json"))
}

function Add-UniquePath {
    param(
        [System.Collections.Generic.List[string]]$List,
        [hashtable]$Seen,
        [string]$Path
    )
    $resolved = Normalize-PathInput $Path
    if ([string]::IsNullOrWhiteSpace($resolved)) { return }
    $key = $resolved.ToLowerInvariant()
    if (-not $Seen.ContainsKey($key)) {
        $Seen[$key] = $true
        $List.Add($resolved)
    }
}

function Get-DockerComposeWorkingDirectories {
    $paths = New-Object System.Collections.Generic.List[string]
    if (-not (Get-Command docker -ErrorAction SilentlyContinue)) { return $paths }
    try {
        $ids = @(& docker ps -aq --filter "label=com.docker.compose.project=english-learning-app" 2>$null)
        foreach ($id in $ids) {
            if ([string]::IsNullOrWhiteSpace([string]$id)) { continue }
            $workingDir = (& docker inspect --format '{{ index .Config.Labels "com.docker.compose.project.working_dir" }}' $id 2>$null | Select-Object -First 1)
            if (-not [string]::IsNullOrWhiteSpace([string]$workingDir)) {
                $paths.Add(([string]$workingDir).Trim())
            }
        }
    } catch {
        Write-Log "Khong doc duoc working directory tu Docker; tiep tuc quet thu muc. $($_.Exception.Message)" "WARN"
    }
    return $paths
}

function Find-ProjectsUnder {
    param(
        [string]$BasePath,
        [int]$MaxDepth = 4
    )

    $matches = New-Object System.Collections.Generic.List[string]
    $base = Normalize-PathInput $BasePath
    if ([string]::IsNullOrWhiteSpace($base)) { return $matches }

    # Khong quet de quy toan bo goc dia vi co the rat cham.
    if ($base -match '^[A-Za-z]:\\$') { return $matches }

    $queue = New-Object System.Collections.Queue
    $queue.Enqueue([pscustomobject]@{ Path = $base; Depth = 0 })
    $visited = @{}
    $skipNames = @('.git', 'node_modules', '.next', 'out', 'dist', '.turbo', 'logs', 'System Volume Information', '$RECYCLE.BIN')

    while ($queue.Count -gt 0) {
        $item = $queue.Dequeue()
        $current = [string]$item.Path
        $depth = [int]$item.Depth
        $key = $current.ToLowerInvariant()
        if ($visited.ContainsKey($key)) { continue }
        $visited[$key] = $true

        if (Test-ProjectRoot $current) {
            $matches.Add((Normalize-PathInput $current))
            continue
        }
        if ($depth -ge $MaxDepth) { continue }

        try {
            Get-ChildItem -LiteralPath $current -Directory -ErrorAction SilentlyContinue | ForEach-Object {
                if ($skipNames -contains $_.Name) { return }
                if ($_.Attributes -band [IO.FileAttributes]::ReparsePoint) { return }
                $queue.Enqueue([pscustomobject]@{ Path = $_.FullName; Depth = ($depth + 1) })
            }
        } catch { }
    }

    return $matches
}

function Select-ProjectFolder {
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = "Chon thu muc English Learning App dang chua docker-compose.yml"
        $dialog.ShowNewFolderButton = $false
        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            return $dialog.SelectedPath
        }
    } catch {
        Write-Log "Khong mo duoc cua so chon thu muc; chuyen sang nhap duong dan. $($_.Exception.Message)" "WARN"
    }
    return $null
}

function Choose-ProjectFromList {
    param([string[]]$Projects)
    if (-not $Projects -or $Projects.Count -eq 0) { return $null }
    if ($Projects.Count -eq 1) { return $Projects[0] }

    $ordered = @($Projects | Sort-Object -Property @{ Expression = {
        try { (Get-Item -LiteralPath (Join-Path $_ 'docker-compose.yml')).LastWriteTimeUtc } catch { [datetime]::MinValue }
    }; Descending = $true })

    Write-Host ""
    Write-Host "Tim thay nhieu phien ban English Learning App:" -ForegroundColor Cyan
    for ($i = 0; $i -lt $ordered.Count; $i++) {
        Write-Host ("  [{0}] {1}" -f ($i + 1), $ordered[$i])
    }
    Write-Host "Nhan Enter de dung muc [1] (phien ban cap nhat gan nhat)." -ForegroundColor Yellow

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $choice = Read-Host "Chon so 1-$($ordered.Count)"
        if ([string]::IsNullOrWhiteSpace($choice)) { return $ordered[0] }
        $number = 0
        if ([int]::TryParse($choice, [ref]$number) -and $number -ge 1 -and $number -le $ordered.Count) {
            return $ordered[$number - 1]
        }
        Write-Host "Lua chon khong hop le. Vui long nhap mot so trong danh sach." -ForegroundColor Yellow
    }
    return $ordered[0]
}

function Find-ProjectRoot {
    # 1. Duong dan truyen vao/keo tha co uu tien cao nhat.
    foreach ($explicit in @($ProjectRoot, $env:ELA_PROJECT_ROOT)) {
        if (Test-ProjectRoot $explicit) {
            $resolved = Normalize-PathInput $explicit
            Write-Log "Tim thay project tu duong dan duoc cung cap: $resolved" "OK"
            return $resolved
        }
    }

    # 2. Neu container cu dang ton tai, lay chinh working directory cua Docker Compose.
    foreach ($dockerPath in (Get-DockerComposeWorkingDirectories)) {
        if (Test-ProjectRoot $dockerPath) {
            $resolved = Normalize-PathInput $dockerPath
            Write-Log "Tim thay project tu Docker Compose dang/da chay: $resolved" "OK"
            return $resolved
        }
    }

    $projects = New-Object System.Collections.Generic.List[string]
    $seenProjects = @{}
    $directCandidates = New-Object System.Collections.Generic.List[string]
    $seenDirect = @{}

    Add-UniquePath $directCandidates $seenDirect $BundleRoot
    Add-UniquePath $directCandidates $seenDirect (Split-Path -Parent $BundleRoot)
    Add-UniquePath $directCandidates $seenDirect (Get-Location).Path

    $cursor = $BundleRoot
    for ($level = 0; $level -lt 4; $level++) {
        Add-UniquePath $directCandidates $seenDirect $cursor
        $parent = Split-Path -Parent $cursor
        if ([string]::IsNullOrWhiteSpace($parent) -or $parent -eq $cursor) { break }
        $cursor = $parent
    }

    foreach ($candidate in $directCandidates) {
        if (Test-ProjectRoot $candidate) {
            Add-UniquePath $projects $seenProjects $candidate
        }
    }

    # 3. Quet cac thu muc cha. Truong hop thuc te: hotfix o E:\English\R10,
    # project o E:\English\R9 se duoc tim tu dong tai day.
    foreach ($base in $directCandidates) {
        foreach ($found in (Find-ProjectsUnder $base 4)) {
            Add-UniquePath $projects $seenProjects $found
        }
    }

    # 4. Quet cac thu muc nguoi dung pho bien neu van chua tim thay.
    if ($projects.Count -eq 0 -and -not [string]::IsNullOrWhiteSpace($env:USERPROFILE)) {
        foreach ($common in @(
            (Join-Path $env:USERPROFILE 'Desktop'),
            (Join-Path $env:USERPROFILE 'Downloads'),
            (Join-Path $env:USERPROFILE 'Documents')
        )) {
            foreach ($found in (Find-ProjectsUnder $common 3)) {
                Add-UniquePath $projects $seenProjects $found
            }
        }
    }

    if ($projects.Count -gt 0) {
        $selected = Choose-ProjectFromList @($projects)
        if (Test-ProjectRoot $selected) {
            $resolved = Normalize-PathInput $selected
            Write-Log "Da chon project: $resolved" "OK"
            return $resolved
        }
    }

    # 5. Mo cua so chon thu muc. Neu nguoi dung huy/bo trong, khong throw ngay.
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        Write-Host ""
        Write-Host "Chua tu dong tim thay thu muc English Learning App." -ForegroundColor Yellow
        Write-Host "Hay chon thu muc dang chua docker-compose.yml, apps\web\server.mjs va package.json." -ForegroundColor Yellow

        $picked = Select-ProjectFolder
        if (Test-ProjectRoot $picked) {
            $resolved = Normalize-PathInput $picked
            Write-Log "Da chon project bang cua so Folder Browser: $resolved" "OK"
            return $resolved
        }

        $manual = Read-Host "Nhap duong dan project hoac nhan Enter de thu lai"
        if ([string]::IsNullOrWhiteSpace($manual)) {
            Write-Host "Chua nhap duong dan; script se thu lai, khong dung dot ngot." -ForegroundColor Yellow
            continue
        }
        if (Test-ProjectRoot $manual) {
            $resolved = Normalize-PathInput $manual
            Write-Log "Da nhap project: $resolved" "OK"
            return $resolved
        }
        Write-Host "Thu muc khong hop le: $manual" -ForegroundColor Red
    }

    throw "Khong xac dinh duoc thu muc project. Co the keo-tha thu muc project vao file BAT, hoac dat hotfix ben trong thu muc project va chay lai."
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

Write-Log "======================================================================="
Write-Log "ENGLISH LEARNING APP v0.4.9.1 - AUTH UX HOTFIX PATH FIX"
Write-Log "======================================================================="
Write-Log "Thu muc hotfix: $BundleRoot"
Write-Log "Log khoi dong: $script:LogFile"

try {
    $Root = Find-ProjectRoot
    $script:ResolvedProjectRoot = $Root
    Write-Log "Thu muc du an: $Root" "OK"

    if ($DiscoveryOnly) {
        Write-Output "DISCOVERED_PROJECT_ROOT=$Root"
        exit 0
    }

    if (-not (Test-Path -LiteralPath $PatchServer)) {
        throw "Thieu file patch: $PatchServer"
    }

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
    Write-Log "Da cai Web auth gateway v0.4.9.1: $TargetServer"

    $Marker = @"
English Learning App v0.4.9.1 Authentication UX Hotfix
Applied at: $(Get-Date -Format "yyyy-MM-dd HH:mm:ss")
Previous web runtime backup: $BackupServer
Data volumes were preserved. No destructive Docker volume command was executed.
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
    $LoginUrl = "http://localhost:$WebPort/login?next=%2Fstudent%2Ftoday&ela_build=0.4.9.1&cache_bust=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"

    Write-Log "Cho API tai: $ApiHealth"
    if (-not (Wait-Http $ApiHealth 300)) { throw "API readiness khong dat." }
    Write-Log "API da san sang." "OK"

    Write-Log "Cho Web auth gateway tai: $WebHealth"
    if (-not (Wait-Http $WebHealth 300 '0.4.9-m4-auth-ux')) { throw "Web auth gateway khong dat." }
    Write-Log "Web auth gateway v0.4.9.1 da san sang." "OK"

    $LoginCheck = "http://localhost:$WebPort/login?next=%2Fstudent%2Ftoday"
    if (-not (Wait-Http $LoginCheck 60 'id="loginForm"')) { throw "Trang dang nhap khong tra ve noi dung mong doi." }
    Write-Log "Trang dang nhap da duoc kiem tra." "OK"

    $ProjectLogsDir = Join-Path $Root "logs"
    New-Item -ItemType Directory -Force -Path $ProjectLogsDir | Out-Null
    $SnapshotLog = Join-Path $ProjectLogsDir "v0491_docker_$Timestamp.log"
    & docker compose --project-name english-learning-app -f (Join-Path $Root "docker-compose.yml") ps -a 2>&1 | Out-File $SnapshotLog -Encoding UTF8
    & docker compose --project-name english-learning-app -f (Join-Path $Root "docker-compose.yml") logs --no-color --timestamps --tail 500 2>&1 | Out-File $SnapshotLog -Append -Encoding UTF8
    Copy-Item $script:LogFile (Join-Path $ProjectLogsDir (Split-Path -Leaf $script:LogFile)) -Force

    Start-Process $LoginUrl
    Write-Log "Mo trinh duyet: $LoginUrl" "OK"
    Write-Log "======================================================================="
    Write-Log "HOAN TAT - v0.4.9.1 DANG CHAY"
    Write-Log "======================================================================="
    Write-Host ""
    Write-Host "Da cai thanh cong v0.4.9.1. Trinh duyet se mo trang dang nhap." -ForegroundColor Green
    Write-Host "Log: $script:LogFile" -ForegroundColor Cyan
}
catch {
    Write-Log $_.Exception.Message "ERROR"
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ResolvedProjectRoot) -and (Test-ProjectRoot $script:ResolvedProjectRoot)) {
        try {
            $failureDir = Join-Path $script:ResolvedProjectRoot "logs"
            New-Item -ItemType Directory -Force -Path $failureDir | Out-Null
            $FailureLog = Join-Path $failureDir "v0491_failure_$Timestamp.log"
            & docker compose --project-name english-learning-app -f (Join-Path $script:ResolvedProjectRoot "docker-compose.yml") ps -a 2>&1 | Out-File $FailureLog -Encoding UTF8
            & docker compose --project-name english-learning-app -f (Join-Path $script:ResolvedProjectRoot "docker-compose.yml") logs --no-color --timestamps --tail 1200 2>&1 | Out-File $FailureLog -Append -Encoding UTF8
            Copy-Item $script:LogFile (Join-Path $failureDir (Split-Path -Leaf $script:LogFile)) -Force
            Write-Log "Da luu Docker diagnostic: $FailureLog" "WARN"
        } catch { }
    }
    Write-Host ""
    Write-Host "Ap dung v0.4.9.1 that bai. Xem log ngay trong thu muc hotfix\logs." -ForegroundColor Red
    exit 1
}
