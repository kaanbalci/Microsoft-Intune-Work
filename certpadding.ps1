$paths = @(
  'HKLM:\SOFTWARE\Microsoft\Cryptography\Wintrust\Config',
  'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Cryptography\Wintrust\Config'
)
$wantName  = 'EnableCertPaddingCheck'
$wantValue = '1'

foreach ($p in $paths) {
  try {
    $v = (Get-ItemProperty -LiteralPath $p -Name $wantName -ErrorAction Stop).$wantName
    if ($v -ne $wantValue) { exit 1 }
  } catch { exit 1 }
}
exit 0
