<#
.SYNOPSIS
  Enable strict certificate padding check locally on this device.

.DESCRIPTION
  Sets (or creates) the following registry values to REG_SZ "1":
    - HKLM\SOFTWARE\Microsoft\Cryptography\Wintrust\Config\EnableCertPaddingCheck
    - HKLM\SOFTWARE\WOW6432Node\Microsoft\Cryptography\Wintrust\Config\EnableCertPaddingCheck

  Idempotent, with verification and clear exit codes:
    0 = success (both hives set correctly)
    1 = partial (one hive set, the other failed)
    2 = error (neither hive set)

.NOTES
  Run as SYSTEM (Intune) or an elevated admin PowerShell (x64 preferred).
#>

$ErrorActionPreference = 'Stop'

# --- Settings ---
$DesiredName  = 'EnableCertPaddingCheck'
$DesiredType  = 'String'      # REG_SZ
$DesiredValue = '1'
$Paths = @(
  'HKLM:\SOFTWARE\Microsoft\Cryptography\Wintrust\Config',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography\Wintrust\Config'
)

# --- Helpers ---
function Ensure-Path {
  param([string]$Path)
  if (-not (Test-Path -LiteralPath $Path)) {
    New-Item -Path $Path -Force | Out-Null
  }
}

function Set-Value {
  param([string]$Path, [string]$Name, [string]$Type, [string]$Value)
  if (-not (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction SilentlyContinue)) {
    New-ItemProperty -Path $Path -Name $Name -PropertyType $Type -Value $Value -Force | Out-Null
  } else {
    Set-ItemProperty -Path $Path -Name $Name -Value $Value -Force
  }
}

function Get-Value {
  param([string]$Path, [string]$Name)
  try {
    (Get-ItemProperty -LiteralPath $Path -Name $Name -ErrorAction Stop).$Name
  } catch {
    $null
  }
}

# --- Admin check (friendly; Intune runs as SYSTEM so this will pass there) ---
try {
  $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()
             ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
  if (-not $isAdmin) {
    Write-Host "[WARN] Not running elevated. Please run as admin or deploy via Intune (SYSTEM)." -ForegroundColor Yellow
  }
} catch { }

# --- Apply + Verify ---
$results = @()
foreach ($path in $Paths) {
  try {
    Ensure-Path -Path $path
    Set-Value -Path $path -Name $DesiredName -Type $DesiredType -Value $DesiredValue

    $actual = Get-Value -Path $path -Name $DesiredName
    if ($actual -ne $DesiredValue) {
      $results += [pscustomobject]@{ Path = $path; Status = 'FailedVerify'; Actual = $actual }
      Write-Host "[ERROR] Verify failed at $path (got '$actual', wanted '$DesiredValue')." -ForegroundColor Red
    } else {
      $results += [pscustomobject]@{ Path = $path; Status = 'OK'; Actual = $actual }
      Write-Host "[OK] $path\$DesiredName set to '$DesiredValue'." -ForegroundColor Green
    }
  } catch {
    $results += [pscustomobject]@{ Path = $path; Status = 'Error'; Actual = $null; Error = $_.Exception.Message }
    Write-Host "[ERROR] $path - $($_.Exception.Message)" -ForegroundColor Red
  }
}

# --- Summarize and exit code ---
$ok        = ($results | Where-Object { $_.Status -eq 'OK' }).Count
$failCount = $results.Count - $ok

if ($ok -eq $results.Count) {
  Write-Host "`n[SUMMARY] EnableCertPaddingCheck successfully enforced in both hives." -ForegroundColor Green
  exit 0
} elseif ($ok -gt 0) {
  Write-Host "`n[SUMMARY] Partially enforced. At least one hive failed verification." -ForegroundColor Yellow
  exit 1
} else {
  Write-Host "`n[SUMMARY] Failed to enforce in both hives." -ForegroundColor Red
  exit 2
}
