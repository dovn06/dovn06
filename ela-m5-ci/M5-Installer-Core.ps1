[CmdletBinding()]
param([switch]$SelfTest)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0

function Quote-Argument {
  param([string]$Value)
  if ($Value -notmatch '[\s"]') { return $Value }
  return '"' + ($Value -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"'
}

function Invoke-Native {
  param(
    [Parameter(Mandatory = $true)][string]$FilePath,
    [string[]]$Arguments = @(),
    [switch]$AllowFailure
  )
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $FilePath
  $psi.Arguments = (($Arguments | ForEach-Object { Quote-Argument ([string]$_) }) -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError = $true
  $psi.CreateNoWindow = $true
  $process = New-Object System.Diagnostics.Process
  $process.StartInfo = $psi
  [void]$process.Start()
  $stdoutTask = $process.StandardOutput.ReadToEndAsync()
  $stderrTask = $process.StandardError.ReadToEndAsync()
  $process.WaitForExit()
  $stdout = $stdoutTask.Result
  $stderr = $stderrTask.Result
  $lines = @()
  if (-not [string]::IsNullOrWhiteSpace($stdout)) { $lines += $stdout.TrimEnd() }
  if (-not [string]::IsNullOrWhiteSpace($stderr)) { $lines += $stderr.TrimEnd() }
  if ($process.ExitCode -ne 0 -and -not $AllowFailure) {
    throw "Native command failed: $($process.ExitCode)"
  }
  return [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = ($lines -join "`n") }
}

if ($SelfTest) {
  $cmd = Join-Path $env:SystemRoot 'System32\cmd.exe'
  $result = Invoke-Native -FilePath $cmd -Arguments @(
    '/d', '/s', '/c', 'echo fake stdout & echo Network english-learning-app_default Creating 1>&2 & exit /b 0'
  )
  if ($result.ExitCode -ne 0) { throw 'Exit code regression failed.' }
  if ($result.Output -notmatch 'fake stdout') { throw 'Stdout regression failed.' }
  if ($result.Output -notmatch 'Network english-learning-app_default Creating') { throw 'Stderr regression failed.' }

  $quoted = Invoke-Native -FilePath $cmd -Arguments @('/d','/s','/c','echo "path with spaces"')
  if ($quoted.Output -notmatch 'path with spaces') { throw 'Argument quoting regression failed.' }
  Write-Output 'SELF_TEST_M5_INSTALLER_CORE=PASS'
}
