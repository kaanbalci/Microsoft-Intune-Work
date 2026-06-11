$BitLockerOSVolume = Get-BitLockerVolume -MountPoint $env:SystemRoot
if (($BitLockerOSVolume.VolumeStatus -like "FullyEncrypted") -and ($BitLockerOSVolume.KeyProtector.Count -eq 2)) {
    Write-Host ("True")
    return 0
    exit 1
}