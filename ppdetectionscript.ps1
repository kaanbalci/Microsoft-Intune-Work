$targetPath = "C:\Program Files\PolicyPak\Cloud"
$exeName = "PPCloud.exe"  # Adjust if file is just named PPCloud without .exe
$minVersion = [version]"25.10.4424.630"

$exeFullPath = Join-Path $targetPath $exeName

# Check if directory exists
if (-not (Test-Path $targetPath)) {
    Write-Host "Directory not found: $targetPath"
    exit 1
}

# Check if the executable exists
if (-not (Test-Path $exeFullPath)) {
    Write-Host "Executable not found: $exeFullPath"
    exit 1
}

try {
    $fileVersion = (Get-Item $exeFullPath).VersionInfo.FileVersion
    $currentVersion = [version]$fileVersion
}
catch {
    Write-Host "Failed to retrieve file version."
    exit 1
}

# Compare versions
if ($currentVersion -ge $minVersion) {
    Write-Host "PPCloud version $currentVersion meets requirement."
    exit 0
} else {
    Write-Host "PPCloud version $currentVersion is lower than required $minVersion."
    exit 1
}
