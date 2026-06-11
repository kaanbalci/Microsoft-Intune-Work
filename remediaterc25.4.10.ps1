<#
Remediate RingCentral to >= MinVersion by running the Deployment Tool from:
  C:\Program Files\RingCentral Deployment\RingCentralDeploymentTool.exe
- Uses same validity rules as the detector
- Waits for completion and polls until compliant (or timeout)

Run in Intune PR as SYSTEM, 64-bit PowerShell.
#>

param(
  [string]$MinVersion = '26.1.10',
  [int]$MaxWaitMinutes = 25,
  [int]$PollSeconds = 10
)

$ErrorActionPreference = 'SilentlyContinue'

$ToolPath = "C:\Program Files\RingCentral Deployment\RingCentralDeploymentTool.exe"
$LogRoot  = "C:\ProgramData\RingCentral\SelfHeal"
$Log      = Join-Path $LogRoot "Remediate-Ensure-25410-Wait.log"
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Write-Log($msg) {
  $ts = (Get-Date).ToString('s')
  Add-Content -Path $Log -Value "[$ts] $msg"
  Write-Output $msg
}

function Get-VersionObject {
  param([string]$FileVersionString)
  if ([string]::IsNullOrWhiteSpace($FileVersionString)) { return $null }
  $m = [regex]::Match($FileVersionString, '\d+(\.\d+){1,3}')
  if (-not $m.Success) { return $null }
  try { return [version]$m.Value } catch { return $null }
}

$MinV = [version]$MinVersion

function Is-ValidDesktopApp([string]$base){
  if (-not (Test-Path $base)) { return $false }
  $upd = Join-Path $base 'Update.exe'
  $cur = Join-Path $base 'current\RingCentral.exe'
  $hasUpdate = Test-Path $upd
  $appDirs   = @(Get-ChildItem -Path $base -Filter 'app-*' -Directory -ErrorAction SilentlyContinue)
  $hasAppDir = ($appDirs.Count -gt 0)
  $verOK = $false
  foreach ($d in $appDirs) {
    $appExe = Join-Path $d.FullName 'RingCentral.exe'
    if (Test-Path $appExe) {
      $vo = Get-VersionObject (Get-Item $appExe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
      if ($vo -and ($vo -ge $MinV)) { $verOK = $true }
    }
  }
  if (Test-Path $cur) {
    $vo = Get-VersionObject (Get-Item $cur -ErrorAction SilentlyContinue).VersionInfo.FileVersion
    if ($vo -and ($vo -ge $MinV)) { $verOK = $true }
  }
  return ($hasUpdate -and $hasAppDir -and $verOK)
}

function Is-ValidPrograms([string]$base){
  if (-not (Test-Path $base)) { return $false }
  $exe = Join-Path $base 'RingCentral.exe'
  $upd = Join-Path $base 'Update.exe'
  if (-not (Test-Path $exe)) { return $false }
  $vo  = Get-VersionObject (Get-Item $exe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
  return ((Test-Path $upd) -and $vo -and ($vo -ge $MinV))
}

function Test-ValidInstall {
  try {
    $profiles = Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -and (Test-Path $_.LocalPath) -and -not $_.Special }
  } catch { $profiles=@() }

  foreach ($p in $profiles){
    $u = $p.LocalPath
    $d = Join-Path $u 'AppData\Local\RingCentral\DesktopApp'
    if (Is-ValidDesktopApp -base $d) { return $true }
    $pr = Join-Path $u 'AppData\Local\Programs\RingCentral'
    if (Is-ValidPrograms -base $pr)  { return $true }
  }

  # Optional Program Files defensive check
  $roots=@()
  if ($env:ProgramFiles)         { $roots+= (Join-Path $env:ProgramFiles 'RingCentral') }
  if (${env:ProgramFiles(x86)})  { $roots+= (Join-Path ${env:ProgramFiles(x86)} 'RingCentral') }
  foreach ($root in $roots){
    if (-not (Test-Path $root)) { continue }
    $exe = Get-ChildItem -Path $root -Recurse -Filter 'RingCentral.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
    $upd = Get-ChildItem -Path $root -Recurse -Filter 'Update.exe'     -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($exe -and $upd){
      $vo = Get-VersionObject (Get-Item $exe.FullName -ErrorAction SilentlyContinue).VersionInfo.FileVersion
      if ($vo -and ($vo -ge $MinV)) { return $true }
    }
  }
  return $false
}

function Any-InstallerProcessRunning {
  $names = @('RingCentralDeploymentTool','Update','RingCentralUpdater','msiexec')
  foreach ($n in $names) { if (Get-Process -Name $n -ErrorAction SilentlyContinue) { return $true } }
  return $false
}

try {
  if (Test-ValidInstall){
    Write-Log "Compliant: Valid RingCentral install >= $MinVersion already present. No action needed."
    exit 0
  }

  if (-not (Test-Path $ToolPath)){
    Write-Log "ERROR: Deployment Tool not found at $ToolPath"
    exit 3
  }

  $wd = Split-Path -Path $ToolPath -Parent
  Write-Log "Starting Deployment Tool and waiting for completion ..."
  Write-Log "Command: `"$ToolPath`""

  try {
    $proc = Start-Process -FilePath $ToolPath -WorkingDirectory $wd -WindowStyle Hidden -Wait -PassThru -ErrorAction Continue
    if ($proc) { Write-Log ("Deployment Tool exit code: {0}" -f $proc.ExitCode) } else { Write-Log "Start-Process returned null process object." }
  } catch {
    Write-Log ("Start-Process error: {0}" -f $_.Exception.Message)
  }

  $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
  while ((Get-Date) -lt $deadline){
    if (Test-ValidInstall) {
      Write-Log "SUCCESS: Valid RingCentral install >= $MinVersion detected."
      exit 0
    }
    if (Any-InstallerProcessRunning) {
      Write-Log "Installer processes still running; waiting ..."
      Start-Sleep -Seconds $PollSeconds
      continue
    }
    Write-Log "No installer processes seen; short grace wait before final check ..."
    Start-Sleep -Seconds $PollSeconds
    if (Test-ValidInstall) {
      Write-Log "SUCCESS (post-grace): Valid RingCentral install >= $MinVersion detected."
      exit 0
    } else {
      break
    }
  }

  Write-Log "FAIL: Still not compliant after waiting."
  exit 1
}
catch {
  Write-Log ("FATAL: {0}" -f $_.Exception.Message)
  exit 2
}
