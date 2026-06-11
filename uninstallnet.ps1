# Uninstall.ps1
$ErrorActionPreference = 'Stop'
$displayName = 'Microsoft Windows Desktop Runtime - 8 (x64)'

$roots = @(
  'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)

$apps = foreach ($r in $roots) {
    Get-ItemProperty -Path $r -ErrorAction SilentlyContinue |
      Where-Object { $_.DisplayName -eq $displayName }
}

if (-not $apps) { exit 0 }

foreach ($app in $apps) {
    $quiet = $app.QuietUninstallString
    $normal = $app.UninstallString

    if ($quiet) {
        # Execute exact quiet uninstall string
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c $quiet" -Wait -WindowStyle Hidden
    }
    elseif ($normal) {
        # Attempt silent append for msiexec-based strings
        $cmd = $normal
        if ($cmd -match 'msiexec') {
            if ($cmd -notmatch '/quiet|/qn') { $cmd += ' /qn /norestart' }
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -Wait -WindowStyle Hidden
        } else {
            Start-Process -FilePath "cmd.exe" -ArgumentList "/c $cmd" -Wait -WindowStyle Hidden
        }
    }
}

exit 0
