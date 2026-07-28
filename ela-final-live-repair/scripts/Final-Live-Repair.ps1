[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$PackageRoot,
    [string]$LogFile = '',
    [switch]$SkipBrowser,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

$ExpectedVersion = '0.4.10.0-final-live-repair'
$WebContainerName = 'english-learning-app-web-1'
$script:DockerExe = ''
$script:PatchedContainer = ''
$script:ContainerBackup = '/app/apps/web/server.mjs.pre_v04100_final_backup'
$script:HostSource = ''
$script:HostBackup = ''

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    Write-Host $line
    if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
        Add-Content -LiteralPath $LogFile -Value $line -Encoding UTF8
    }
}

function Resolve-DockerExe {
    $candidates = @(
        (Get-Command docker.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        (Get-Command docker -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -ErrorAction SilentlyContinue),
        'C:\Program Files\Docker\Docker\resources\bin\docker.exe',
        (Join-Path $env:LOCALAPPDATA 'Programs\DockerDesktop\resources\bin\docker.exe')
    )
    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace([string]$candidate) -and (Test-Path -LiteralPath ([string]$candidate))) {
            return (Resolve-Path -LiteralPath ([string]$candidate)).Path
        }
    }
    throw 'Khong tim thay docker.exe.'
}

function Invoke-Docker {
    param([string[]]$Arguments, [switch]$AllowFailure)

    if ([string]::IsNullOrWhiteSpace($script:DockerExe)) { $script:DockerExe = Resolve-DockerExe }
    Write-Log ('Docker: {0}' -f ($Arguments -join ' '))

    $oldPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = @(& $script:DockerExe @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        $ErrorActionPreference = $oldPreference
    }

    $lines = @()
    foreach ($item in $output) {
        $text = [string]$item
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            $lines += $text
            Write-Host $text
            if (-not [string]::IsNullOrWhiteSpace($LogFile)) {
                Add-Content -LiteralPath $LogFile -Value $text -Encoding UTF8
            }
        }
    }

    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw ('Docker that bai, exit code {0}: docker {1}' -f $exitCode, ($Arguments -join ' '))
    }

    return [pscustomobject]@{
        ExitCode = [int]$exitCode
        Output = (($lines -join "`n").Trim())
    }
}

function Get-WebContainerId {
    $byLabel = Invoke-Docker @(
        'ps', '-q',
        '--filter', 'label=com.docker.compose.project=english-learning-app',
        '--filter', 'label=com.docker.compose.service=web'
    ) -AllowFailure
    if ($byLabel.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($byLabel.Output)) {
        return (($byLabel.Output -split "`r?`n")[0]).Trim()
    }

    $byName = Invoke-Docker @('ps', '-q', '--filter', ('name=^/{0}$' -f $WebContainerName)) -AllowFailure
    if ($byName.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($byName.Output)) {
        return (($byName.Output -split "`r?`n")[0]).Trim()
    }

    $stopped = Invoke-Docker @(
        'ps', '-aq',
        '--filter', 'label=com.docker.compose.project=english-learning-app',
        '--filter', 'label=com.docker.compose.service=web'
    ) -AllowFailure
    if ($stopped.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace($stopped.Output)) {
        $id = (($stopped.Output -split "`r?`n")[0]).Trim()
        Write-Log 'Web container dang dung; dang khoi dong lai.' 'WARN'
        Invoke-Docker @('start', $id) | Out-Null
        return $id
    }

    throw 'Khong tim thay Web container english-learning-app. Hay mo Docker Desktop roi chay lai.'
}

function Get-ContainerInspect {
    param([string]$ContainerId)
    $result = Invoke-Docker @('inspect', $ContainerId)
    $objects = $result.Output | ConvertFrom-Json
    if ($null -eq $objects -or $objects.Count -lt 1) { throw 'Khong doc duoc docker inspect.' }
    return $objects[0]
}

function Get-WebPort {
    param([object]$Container)
    $ports = $Container.NetworkSettings.Ports
    if ($null -ne $ports) {
        $property = $ports.PSObject.Properties['3000/tcp']
        if ($null -ne $property -and $null -ne $property.Value -and $property.Value.Count -gt 0) {
            $value = [string]$property.Value[0].HostPort
            if ($value -match '^\d+$') { return [int]$value }
        }
    }
    return 3000
}

function Get-ProjectRoot {
    param([object]$Container)
    $labels = $Container.Config.Labels
    if ($null -eq $labels) { return '' }
    $working = [string]$labels.'com.docker.compose.project.working_dir'
    if (-not [string]::IsNullOrWhiteSpace($working) -and (Test-Path -LiteralPath $working)) {
        return (Resolve-Path -LiteralPath $working).Path
    }
    $files = [string]$labels.'com.docker.compose.project.config_files'
    if (-not [string]::IsNullOrWhiteSpace($files)) {
        $first = ($files -split '[,;]')[0].Trim()
        if (Test-Path -LiteralPath $first) {
            return (Split-Path -Parent (Resolve-Path -LiteralPath $first).Path)
        }
    }
    return ''
}

function Backup-And-Patch {
    param([string]$ContainerId, [object]$Container, [string]$PayloadFile)

    Invoke-Docker @('exec', $ContainerId, 'cp', '-f', '/app/apps/web/server.mjs', $script:ContainerBackup) | Out-Null
    Write-Log "Da backup runtime trong container: $script:ContainerBackup" 'OK'

    $mount = $null
    foreach ($item in @($Container.Mounts)) {
        if ([string]$item.Destination -eq '/app/apps/web/server.mjs') {
            $mount = $item
            break
        }
    }

    $projectRoot = Get-ProjectRoot -Container $Container
    if (-not [string]::IsNullOrWhiteSpace($projectRoot)) {
        $hostServer = Join-Path $projectRoot 'apps\web\server.mjs'
        if (Test-Path -LiteralPath $hostServer) {
            $hostBackup = "$hostServer.pre_v04100_backup_$(Get-Date -Format yyyyMMdd_HHmmss)"
            Copy-Item -LiteralPath $hostServer -Destination $hostBackup -Force
            Copy-Item -LiteralPath $PayloadFile -Destination $hostServer -Force
            $script:HostSource = $hostServer
            $script:HostBackup = $hostBackup
            Write-Log "Da cap nhat ma nguon dang chay tai: $hostServer" 'OK'
        }
    }

    $tempTarget = $ContainerId + ':/tmp/ela-server-v04100.mjs'
    Invoke-Docker @('cp', $PayloadFile, $tempTarget) | Out-Null
    Invoke-Docker @('exec', $ContainerId, 'node', '--check', '/tmp/ela-server-v04100.mjs') | Out-Null

    if ($null -ne $mount -and -not [string]::IsNullOrWhiteSpace([string]$mount.Source)) {
        $mountSource = [string]$mount.Source
        if (Test-Path -LiteralPath $mountSource) {
            if ($script:HostSource -ne $mountSource) {
                $backup = "$mountSource.pre_v04100_backup_$(Get-Date -Format yyyyMMdd_HHmmss)"
                Copy-Item -LiteralPath $mountSource -Destination $backup -Force
                Copy-Item -LiteralPath $PayloadFile -Destination $mountSource -Force
                if ([string]::IsNullOrWhiteSpace($script:HostBackup)) {
                    $script:HostSource = $mountSource
                    $script:HostBackup = $backup
                }
            }
            Write-Log "Da cap nhat bind mount: $mountSource" 'OK'
        }
        else {
            throw "Web runtime dang bind mount nhung Windows khong truy cap duoc source: $mountSource"
        }
    }
    else {
        Invoke-Docker @('exec', $ContainerId, 'cp', '-f', '/tmp/ela-server-v04100.mjs', '/app/apps/web/server.mjs') | Out-Null
        Write-Log 'Da cap nhat runtime truc tiep trong Web container.' 'OK'
    }

    $script:PatchedContainer = $ContainerId
}

function Wait-Ready {
    param([int]$Port, [int]$TimeoutSeconds = 120)
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $healthUrl = "http://localhost:$Port/__ela/health?final_fix=$([DateTime]::UtcNow.Ticks)"
    $last = ''
    while ((Get-Date) -lt $deadline) {
        try {
            $response = Invoke-WebRequest -Uri $healthUrl -UseBasicParsing -TimeoutSec 6 -Headers @{ 'Cache-Control' = 'no-cache' }
            $last = [string]$response.Content
            if ($response.StatusCode -eq 200 -and $last -match [regex]::Escape($ExpectedVersion)) {
                return $true
            }
        }
        catch { $last = $_.Exception.Message }
        Start-Sleep -Seconds 2
    }
    Write-Log "Health khong dat. Phan hoi cuoi: $last" 'ERROR'
    return $false
}

function Verify-UserInterface {
    param([int]$Port)
    $login = Invoke-WebRequest -Uri "http://localhost:$Port/login?accountType=student" -UseBasicParsing -TimeoutSec 10 -Headers @{ 'Cache-Control' = 'no-cache' }
    if ($login.StatusCode -ne 200) { throw 'Trang login khong tra HTTP 200.' }
    foreach ($marker in @('id="accountType"', 'value="student"', 'value="parent"', 'value="teacher"', 'value="admin"')) {
        if ([string]$login.Content -notlike "*$marker*") { throw "Trang login thieu marker: $marker" }
    }
    $home = Invoke-WebRequest -Uri "http://localhost:$Port/" -UseBasicParsing -TimeoutSec 10 -Headers @{ 'Cache-Control' = 'no-cache' }
    if ([string]$home.Content -notlike '*id="topLoginButton"*') { throw 'Trang chu thieu nut Dang nhap goc phai.' }
    Write-Log 'Da xac nhan nut Dang nhap va 4 loai tai khoan.' 'OK'
}

function Restore-Backup {
    Write-Log 'Dang rollback runtime cu do kiem tra sau cap nhat khong dat.' 'WARN'
    try {
        if (-not [string]::IsNullOrWhiteSpace($script:HostSource) -and
            -not [string]::IsNullOrWhiteSpace($script:HostBackup) -and
            (Test-Path -LiteralPath $script:HostBackup)) {
            Copy-Item -LiteralPath $script:HostBackup -Destination $script:HostSource -Force
        }
        elseif (-not [string]::IsNullOrWhiteSpace($script:PatchedContainer)) {
            Invoke-Docker @('exec', $script:PatchedContainer, 'cp', '-f', $script:ContainerBackup, '/app/apps/web/server.mjs') -AllowFailure | Out-Null
        }
        if (-not [string]::IsNullOrWhiteSpace($script:PatchedContainer)) {
            Invoke-Docker @('restart', $script:PatchedContainer) -AllowFailure | Out-Null
        }
        Write-Log 'Rollback da hoan tat.' 'OK'
    }
    catch { Write-Log "Rollback gap loi: $($_.Exception.Message)" 'ERROR' }
}

function Run-SelfTest {
    $root = (Resolve-Path -LiteralPath $PackageRoot).Path
    $payload = Join-Path $root 'payload\server.mjs'
    if (-not (Test-Path -LiteralPath $payload)) { throw 'Self-test thieu payload/server.mjs.' }
    if (-not (Select-String -LiteralPath $payload -Pattern $ExpectedVersion -SimpleMatch -Quiet)) { throw 'Self-test payload sai version.' }

    $fake = Join-Path $env:TEMP ("ela-fake-docker-{0}.cmd" -f $PID)
    try {
        @"
@echo off
echo fake stdout
echo Network english-learning-app_default Creating 1>&2
exit /b 0
"@ | Set-Content -LiteralPath $fake -Encoding ASCII
        $script:DockerExe = $fake
        $result = Invoke-Docker @('compose', 'up')
        if ($result.ExitCode -ne 0) { throw 'Self-test exit code sai.' }
        if ($result.Output -notmatch 'Network english-learning-app_default Creating') { throw 'Self-test stderr bi mat.' }
    }
    finally { Remove-Item -LiteralPath $fake -Force -ErrorAction SilentlyContinue }

    Write-Output 'SELF_TEST_FINAL_LIVE_REPAIR=PASS'
}

if ($SelfTest) {
    Run-SelfTest
    exit 0
}

try {
    $root = (Resolve-Path -LiteralPath $PackageRoot).Path
    $payload = Join-Path $root 'payload\server.mjs'
    if (-not (Test-Path -LiteralPath $payload)) { throw "Goi ZIP thieu payload: $payload" }

    Write-Log 'ENGLISH LEARNING APP v0.4.10.0 - FINAL LIVE REPAIR'
    $script:DockerExe = Resolve-DockerExe
    Invoke-Docker @('info') | Out-Null

    $containerId = Get-WebContainerId
    $container = Get-ContainerInspect -ContainerId $containerId
    $webPort = Get-WebPort -Container $container
    Write-Log "Web container=$containerId, Web port=$webPort" 'OK'

    Backup-And-Patch -ContainerId $containerId -Container $container -PayloadFile $payload
    Invoke-Docker @('restart', $containerId) | Out-Null
    Write-Log 'Da restart rieng Web; API va database khong bi dung.' 'OK'

    if (-not (Wait-Ready -Port $webPort -TimeoutSeconds 120)) {
        Restore-Backup
        throw 'Web moi khong dat health; he thong da rollback runtime cu.'
    }

    Verify-UserInterface -Port $webPort

    $imageId = [string]$container.Image
    if (-not [string]::IsNullOrWhiteSpace($imageId)) {
        Invoke-Docker @('tag', $imageId, 'english-learning-app-web:pre-v04100-backup') -AllowFailure | Out-Null
    }
    Invoke-Docker @('commit', $containerId, 'english-learning-app-web:latest') -AllowFailure | Out-Null
    Write-Log 'Da luu runtime moi vao image local de giu sau khi Docker restart.' 'OK'

    $loginUrl = "http://localhost:$webPort/login?accountType=student&next=%2Fstudent%2Ftoday&final_fix=0.4.10.0"
    Write-Log "FINAL_REPAIR_OK Web=$webPort Version=$ExpectedVersion" 'OK'
    if (-not $SkipBrowser) { Start-Process $loginUrl }

    Write-Host ''
    Write-Host 'HOAN TAT - PHAN MEM DA SAN SANG' -ForegroundColor Green
    Write-Host $loginUrl
    exit 0
}
catch {
    Write-Log $_.Exception.Message 'ERROR'
    if ($_.ScriptStackTrace) { Write-Log $_.ScriptStackTrace 'ERROR' }
    if (-not [string]::IsNullOrWhiteSpace($script:PatchedContainer)) {
        $dockerLog = Invoke-Docker @('logs', '--tail', '200', $script:PatchedContainer) -AllowFailure
        if (-not [string]::IsNullOrWhiteSpace($LogFile) -and -not [string]::IsNullOrWhiteSpace($dockerLog.Output)) {
            Add-Content -LiteralPath $LogFile -Value "`r`n--- WEB CONTAINER LOG ---`r`n$($dockerLog.Output)" -Encoding UTF8
        }
    }
    exit 1
}
