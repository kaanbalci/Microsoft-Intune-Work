# Intune Win32 Detection Script
# Detect RingCentral.exe in any user's profile path:
# C:\Users\<username>\AppData\Local\RingCentral\DesktopApp\RingCentral.exe

$found = $false

# Get all local user profile folders under C:\Users (skip common public/default folders)
$userFolders = Get-ChildItem -Path "C:\Users" -Directory -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notin @("Public", "Default", "Default User", "All Users") }

foreach ($user in $userFolders) {
    $exePath = Join-Path $user.FullName "AppData\Local\RingCentral\DesktopApp\RingCentral.exe"
    
    if (Test-Path $exePath) {
        $found = $true
        break
    }
}

if ($found) {
    Write-Output "RingCentral.exe detected in a user profile."
    exit 0
}
else {
    Write-Output "RingCentral.exe NOT detected in any user profile."
    exit 1
}
