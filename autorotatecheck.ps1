try {
	if(-NOT (Test-Path -LiteralPath "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AutoRotation")){ return $false };
	if((Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AutoRotation' -Name 'Enable' -ea SilentlyContinue) -eq 0) {  } else { return $false };
	if((Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AutoRotation' -Name 'LastOrientation' -ea SilentlyContinue) -eq 0) {  } else { return $false };
	if((Get-ItemPropertyValue -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AutoRotation' -Name 'SlateEnable' -ea SilentlyContinue) -eq 1) {  } else { return $false };
}
catch { return $false
	exit 1 
       }
return $true
exit 1