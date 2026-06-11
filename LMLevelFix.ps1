<#
Sets LAN Manager authentication level to 5 at the classic LSA registry path.
Notes:
- If a domain GPO or Security Baseline configures this setting, that higher-precedence policy may overwrite this value at refresh.
- Script logs to C:\ProgramData\IntuneRemediations\LmCompat\remediation.log
#>

$ErrorActionPreference = 'Stop'
$expected = 5
$logDir = "C:\ProgramData\IntuneRemediations\LmCompat"
$log = Join-Path $logDir "remediation.log"
New-Item -Path $logDir -ItemType Directory -Force | Out-Null

function Write-Log($msg) {
    $timestamp = (Get-Date).ToString("s")
    "$timestamp`t$msg" | Out-File -FilePath $log -Encoding UTF8 -Append
}

try {
    Write-Log "Starting remediation…"
    $lsaPath = "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa"
    if (-not (Test-Path $lsaPath)) {
        New-Item -Path $lsaPath -Force | Out-Null
        Write-Log "Created $lsaPath"
    }

    $current = $null
    try { $current = (Get-ItemProperty -Path $lsaPath -Name "LmCompatibilityLevel" -ErrorAction Stop).LmCompatibilityLevel } catch {}

    if ($current -ne $expected) {
        New-ItemProperty -Path $lsaPath -Name "LmCompatibilityLevel" -PropertyType DWord -Value $expected -Force | Out-Null
        Write-Log "Set LmCompatibilityLevel from '$current' to '$expected'"
    } else {
        Write-Log "Already at expected value: $expected"
    }

    # OPTIONAL: Nudge policy consumers (no reboot required)
    try {
        # Refresh local security policy cache
        secedit /refreshpolicy machine_policy /enforce | Out-Null
        Write-Log "Called: secedit /refreshpolicy machine_policy /enforce"
    } catch {
        Write-Log "Warning: secedit refresh failed: $($_.Exception.Message)"
    }

    Write-Log "Remediation complete."
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    throw
}
