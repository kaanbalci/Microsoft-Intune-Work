<#
Detects LAN Manager authentication level = 5 (Send NTLMv2 only; refuse LM & NTLM)
Checks classic LSA reg path, then MDM Policy CSP path, then falls back to secedit export.
#>

$expected = 5
$actual = $null

# 1) Classic GPO/local reg path
try {
    $val1 = (Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Control\Lsa" -Name "LmCompatibilityLevel" -ErrorAction Stop).LmCompatibilityLevel
} catch { $val1 = $null }

# 2) MDM Policy CSP (what Intune writes when using the Policy CSP)
try {
    $val2 = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Microsoft\PolicyManager\current\device\LocalPoliciesSecurityOptions\LANManagerAuthenticationLevel" -Name "value" -ErrorAction Stop).value
} catch { $val2 = $null }

# 3) Effective security policy database
$seceditVal = $null
try {
    $tmp = Join-Path $env:TEMP "secpol.cfg"
    secedit /export /cfg $tmp | Out-Null
    $line = Select-String -Path $tmp -Pattern '^LmCompatibilityLevel'
    if ($line) {
        $seceditVal = ($line -split '=')[1].Trim()
        if ($seceditVal -match '^\d+$') { $seceditVal = [int]$seceditVal } else { $seceditVal = $null }
    }
} catch { }

$actual = $val1, $val2, $seceditVal | Where-Object { $_ -ne $null } | Select-Object -First 1

Write-Output "LmCompatibilityLevel (detected): $actual"
Write-Output "Expected: $expected"

if ($actual -eq $expected) {
    Write-Output "Compliance State: Compliant"
    exit 0
} else {
    Write-Output "Compliance State: Not Compliant"
    exit 1
}
