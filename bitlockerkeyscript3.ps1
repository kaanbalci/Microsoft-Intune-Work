$BLV = Get-BitLockerVolume -MountPoint "C:"

$keyID = $BLV.KeyProtector[1].KeyProtectorId

manage-bde.exe -protectors -adbackup c: -id $keyID
manage-bde.exe -protectors -aadbackup c: -id $keyID
Write-Host ("True")
return 0
exit 0