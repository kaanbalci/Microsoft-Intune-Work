# Install.ps1
$ErrorActionPreference = 'Stop'

# ----- Config -----
$InstallerName = 'windowsdesktop-runtime-8.0.12-win-x64.exe'   # update if needed
$InstallerPath = Join-Path $PSScriptRoot $InstallerName
$LogDir = 'C:\ProgramData\Microsoft\IntuneManagementExtension\Logs'
$LogFile = Join-Path $LogDir 'DotNetDesktopRuntime8-Install.log'

# Ensure log folder
if (!(Test-Path $LogDir)) { New-Item -Path $LogDir -ItemType Directory -Force | Out-Null }

"[$(Get-Date -Format s)] Starting install" | Out-File -FilePath $LogFile -Encoding utf8 -Append
"InstallerPath: $InstallerPath" | Out-File -FilePath $LogFile -Encoding utf8 -Append

if (!(Test-Path $InstallerPath)) {
    "Installer not found." | Out-File -FilePath $LogFile -Encoding utf8 -Append
    exit 1
}

# Try primary switch set first; if that fails, fallback to alternate silent switches.
$argumentsPrimary  = '/install /quiet /norestart'
$argumentsFallback = '/quiet /norestart'

# Start installer (PRIMARY)
$proc = Start-Process -FilePath $InstallerPath -ArgumentList $argumentsPrimary -Wait -PassThru -WindowStyle Hidden
"Primary exit code: $($proc.ExitCode)" | Out-File -FilePath $LogFile -Encoding utf8 -Append

if ($proc.ExitCode -ne 0) {
    "Primary failed; trying fallback switches..." | Out-File -FilePath $LogFile -Encoding utf8 -Append
    $proc2 = Start-Process -FilePath $InstallerPath -ArgumentList $argumentsFallback -Wait -PassThru -WindowStyle Hidden
    "Fallback exit code: $($proc2.ExitCode)" | Out-File -FilePath $LogFile -Encoding utf8 -Append

    # Treat 0 and 3010 as success for Intune
    if ($proc2.ExitCode -in 0, 3010) { exit 0 }
    exit $proc2.ExitCode
}

# Treat 0 and 3010 as success for Intune
if ($proc.ExitCode -in 0, 3010) { exit 0 }
exit $proc.ExitCode
