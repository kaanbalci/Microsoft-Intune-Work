<#
.SYNOPSIS
  Detect if RingCentral EXE exists at the exact required version (25.3.20*).
  Exit 0 (compliant)  = at least one RingCentral.exe found with version 25.3.20*
  Exit 1 (non-compliant) = none found at required version (includes "not installed")
.NOTES
  Run as SYSTEM, 64-bit PowerShell in Intune.
#>

param(
  [string]$TargetVersion = '25.3.20'
)

$ErrorActionPreference = 'SilentlyContinue'

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

$findings = Get-RCExeFindings
if ($findings.Count -eq 0) {
  Write-Output "Non-compliant: RingCentral EXE not installed."
  exit 1
}

$match = $findings | Where-Object { $_.Version -like "$TargetVersion*" }
if ($match) {
  Write-Output ("Compliant: Found RingCentral.exe at required version {0} in {1}" -f $TargetVersion, ($match | Select-Object -First 1).Path)
  exit 0
} else {
  Write-Output "Non-compliant: RingCentral EXE present but not version $TargetVersion."
  $findings | Select-Object Scope,User,Version,Path | Format-Table -AutoSize | Out-String | Write-Output
  exit 1
}
