<#
.SYNOPSIS
  If RingCentral EXE is missing OR not at 25.3.20*, run the Deployment Tool (no args) and WAIT
  until the install completes or a timeout elapses.

.DESCRIPTION
  - Detects RingCentral.exe version 25.3.20* for any user or Program Files.
  - If not compliant, runs:
      Start-Process -FilePath "C:\Program Files\RingCentral Deployment\RingCentralDeploymentTool.exe"
    (no arguments; hidden window).
  - Then polls for up to MaxWaitMinutes, watching:
      * The EXE version (target 25.3.20*), and
      * Installer processes: RingCentralDeploymentTool, Update (Squirrel), msiexec, RingCentralUpdater.
    The loop only exits SUCCESS when the target EXE appears; otherwise it waits while any installer
    process is still active, plus a small grace period.
  - Logs to C:\ProgramData\RingCentral\SelfHeal\SelfHeal-RunDeploymentTool-25320-NoArgs-LongWait.log

.NOTES
  Run as SYSTEM, 64-bit PowerShell in Intune Proactive Remediations.
#>

param(
  [string]$TargetVersion = '25.3.20',
  [string]$ToolPath = "C:\Program Files\RingCentral Deployment\RingCentralDeploymentTool.exe",
  [int]$MaxWaitMinutes = 10,
  [int]$PollSeconds = 10
)

$ErrorActionPreference = 'SilentlyContinue'
$LogRoot = "C:\ProgramData\RingCentral\SelfHeal"
$Log = Join-Path $LogRoot "SelfHeal-RunDeploymentTool-25320-NoArgs-LongWait.log"
New-Item -ItemType Directory -Force -Path $LogRoot | Out-Null

function Write-Log($msg) {
  $stamp = (Get-Date).ToString("s")
  Add-Content -Path $Log -Value "[$stamp] $msg"
  Write-Output $msg
}

function Get-RCExeFindings {
  $results = @()

  # Machine-wide under Program Files
  $pfRoots = @()
  if ($env:ProgramFiles) { $pfRoots += (Join-Path $env:ProgramFiles 'RingCentral') }
  if (${env:ProgramFiles(x86)}) { $pfRoots += (Join-Path ${env:ProgramFiles(x86)} 'RingCentral') }
  foreach ($root in $pfRoots) {
    if (Test-Path $root) {
      Get-ChildItem -Path $root -Recurse -Filter 'RingCentral.exe' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
          $ver = (Get-Item $_.FullName -ErrorAction SilentlyContinue).VersionInfo.FileVersion
          $results += [pscustomobject]@{ Scope='Machine'; Path=$_.FullName; Version=$ver }
        } catch {}
      }
    }
  }

  # Per-user Squirrel locations
  try {
    $profiles = Get-CimInstance Win32_UserProfile | Where-Object { $_.LocalPath -and (Test-Path $_.LocalPath) -and -not $_.Special }
  } catch { $profiles = @() }

  foreach ($p in $profiles) {
    $u = $p.LocalPath
    $paths = @(
      (Join-Path $u 'AppData\Local\RingCentral\DesktopApp\current\RingCentral.exe'),
      (Join-Path $u 'AppData\Local\Programs\RingCentral\RingCentral.exe')
    )
    foreach ($exe in $paths) {
      if (Test-Path $exe) {
        try {
          $ver = (Get-Item $exe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
          $results += [pscustomobject]@{ Scope='User'; Path=$exe; Version=$ver; User=$u }
        } catch {}
      }
    }
    $desktopAppRoot = Join-Path $u 'AppData\Local\RingCentral\DesktopApp'
    if (Test-Path $desktopAppRoot) {
      Get-ChildItem -Path $desktopAppRoot -Filter 'app-*' -Directory -ErrorAction SilentlyContinue | ForEach-Object {
        $appExe = Join-Path $_.FullName 'RingCentral.exe'
        if (Test-Path $appExe) {
          try {
            $ver = (Get-Item $appExe -ErrorAction SilentlyContinue).VersionInfo.FileVersion
            $results += [pscustomobject]@{ Scope='User'; Path=$appExe; Version=$ver; User=$u }
          } catch {}
        }
      }
    }
  }
  return $results
}

function Test-Compliant {
  param([string]$Desired)
  $findings = Get-RCExeFindings
  if ($findings.Count -eq 0) { return $false }
  return ($findings | Where-Object { $_.Version -like "$Desired*" } | Select-Object -First 1) -ne $null
}

function Any-InstallerProcessRunning {
  $names = @('RingCentralDeploymentTool','Update','RingCentralUpdater','msiexec')
  foreach ($n in $names) {
    $p = Get-Process -Name $n -ErrorAction SilentlyContinue
    if ($p) { return $true }
  }
  return $false
}

try {
  if (Test-Compliant -Desired $TargetVersion) {
    Write-Log "Compliant: RingCentral.exe at version $TargetVersion* already present. No action taken."
    exit 0
  }

  if (-not (Test-Path $ToolPath)) {
    Write-Log "ERROR: Deployment Tool not found at $ToolPath"
    exit 3
  }

  $wd = Split-Path -Path $ToolPath -Parent
  Write-Log "Non-compliant: Starting Deployment Tool (no arguments) and entering wait loop ..."
  Write-Log ("Command: `"{0}`"" -f $ToolPath)

  # Fire the tool (hidden) and do not rely solely on the parent exit; it may spawn children.
  try {
    $proc = Start-Process -FilePath $ToolPath -WorkingDirectory $wd -WindowStyle Hidden -PassThru -ErrorAction Continue
    if ($null -ne $proc) {
      Write-Log ("Deployment Tool started (PID={0})." -f $proc.Id)
    } else {
      Write-Log "Start-Process returned null process object (direct)."
    }
  } catch {
    Write-Log ("Direct Start-Process error: {0}" -f $_.Exception.Message)
  }

  # Poll for completion / compliance
  $deadline = (Get-Date).AddMinutes($MaxWaitMinutes)
  $grace = 3  # a few extra polls after processes disappear
  while ((Get-Date) -lt $deadline) {
    if (Test-Compliant -Desired $TargetVersion) {
      Write-Log "SUCCESS: Found RingCentral.exe at $TargetVersion* during wait loop."
      exit 0
    }

    if (Any-InstallerProcessRunning) {
      Write-Log "Install still in progress (installer process running). Waiting..."
      Start-Sleep -Seconds $PollSeconds
      continue
    } else {
      if ($grace -gt 0) {
        Write-Log ("No installer processes running; grace waits remaining: {0}" -f $grace)
        $grace -= 1
        Start-Sleep -Seconds $PollSeconds
        continue
      } else {
        break
      }
    }
  }

  if (Test-Compliant -Desired $TargetVersion) {
    Write-Log "SUCCESS: Found RingCentral.exe at $TargetVersion* after wait loop."
    exit 0
  } else {
    Write-Log "FAIL: Still no RingCentral.exe at $TargetVersion* after wait loop/timeout."
    exit 1
  }
}
catch {
  Write-Log ("FATAL: {0}" -f $_.Exception.Message)
  exit 2
}
