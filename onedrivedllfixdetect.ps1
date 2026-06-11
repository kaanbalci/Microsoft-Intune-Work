<#  
Detects OneDrive binary/DLL mismatch or missing install.
Exit 0 = compliant (no action)
Exit 1 = non-compliant (run remediation)
#>

$ErrorActionPreference = 'Stop'

function Get-FileVer($path) {
    if (Test-Path $path) { (Get-Item $path).VersionInfo.FileVersion } else { $null }
}

# Common paths
$pf = ${env:ProgramFiles}
$pf86 = ${env:ProgramFiles(x86)}
$odRoot = Join-Path $pf 'Microsoft OneDrive'
$exePath = Join-Path $odRoot 'OneDrive.exe'
$dllPath = Join-Path $odRoot 'OneDrive.Sync.Service.dll'

# Quick checks: files must exist
if (-not (Test-Path $exePath) -or -not (Test-Path $dllPath)) { exit 1 }

# Compare versions (mismatch implies broken update)
$exeVer = Get-FileVer $exePath
$dllVer = Get-FileVer $dllPath

if (($null -eq $exeVer) -or ($null -eq $dllVer)) { exit 1 }
if ($exeVer -ne $dllVer) { exit 1 }

# Optional: ensure service exe exists in same build folder
$svcExe = Join-Path $odRoot 'OneDrive.Sync.Service.exe'
if (-not (Test-Path $svcExe)) { exit 1 }

# Looks good
exit 0
