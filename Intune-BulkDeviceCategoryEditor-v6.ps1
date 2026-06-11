<#
.SYNOPSIS
    Intune Bulk Device Category Editor GUI - v3 Fixed Layout

.DESCRIPTION
    Bulk assign Intune device categories using Microsoft Graph.

    Inputs:
      - Manual entry: one or many laptop names/service tags
      - CSV import: DeviceName, ComputerName, Hostname, SerialNumber, ServiceTag, or one-per-line

    v6 fixes:
      - Removed problematic tab/split layout.
      - Manual input text box is always visible and typeable.
      - CSV import button is always visible.
      - Better resizing behavior.
      - Larger staged input and results areas.
      - Simpler workflow.
      - Fixed Apply Category button staying disabled when Graph response uses dictionary-style properties.
      - Fixed manual comma-separated input creating a literal comma row.
      - Suppressed harmless numeric console output from WinForms layout .Add() calls.

.REQUIREMENTS
    - Windows PowerShell 5.1 or PowerShell 7 on Windows
    - Microsoft.Graph.Authentication
    - Delegated Graph scope: DeviceManagementManagedDevices.ReadWrite.All

.NOTES
    Dell Service Tag usually maps to Intune managedDevice serialNumber.
#>

# -----------------------------
# PowerShell STA / Assembly setup
# -----------------------------
try {
    if ([System.Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
        Write-Warning "For best GUI behavior, launch with: powershell.exe -STA -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    }
} catch {}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# -----------------------------
# Graph module setup
# -----------------------------
function Ensure-GraphAuthModule {
    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        $answer = [System.Windows.Forms.MessageBox]::Show(
            "Microsoft.Graph.Authentication is not installed.`r`n`r`nInstall it for the current user now?",
            "Missing Graph Module",
            "YesNo",
            "Question"
        )

        if ($answer -ne [System.Windows.Forms.DialogResult]::Yes) {
            throw "Microsoft.Graph.Authentication module is required."
        }

        Install-Module Microsoft.Graph.Authentication -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
}

# -----------------------------
# State
# -----------------------------
$script:IsConnected = $false
$script:Categories = @()
$script:InputRows = New-Object System.Collections.Generic.List[object]
$script:ResolvedRows = New-Object System.Collections.Generic.List[object]

# -----------------------------
# Graph helpers
# -----------------------------
function Escape-ODataString {
    param([Parameter(Mandatory)][string]$Value)
    return $Value.Replace("'", "''").Trim()
}

function Get-GraphObjectValue {
    param(
        [Parameter(Mandatory)]$Object,
        [Parameter(Mandatory)][string]$PropertyName
    )

    if ($null -eq $Object) {
        return $null
    }

    # Works for PSCustomObject
    $prop = $Object.PSObject.Properties[$PropertyName]
    if ($prop) {
        return $prop.Value
    }

    # Works for dictionary/hashtable-style objects
    try {
        if ($Object.ContainsKey($PropertyName)) {
            return $Object[$PropertyName]
        }
    } catch {}

    return $null
}


function Invoke-GraphGetAll {
    param([Parameter(Mandatory)][string]$Uri)

    $items = @()
    $next = $Uri

    while ($next) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $next -ErrorAction Stop
        if ($response.value) {
            $items += $response.value
        }
        $next = $response.'@odata.nextLink'
    }

    return $items
}

function Connect-GraphForIntune {
    Ensure-GraphAuthModule

    Connect-MgGraph -Scopes "DeviceManagementManagedDevices.ReadWrite.All" -NoWelcome -ErrorAction Stop | Out-Null

    $context = Get-MgContext
    if (-not $context) {
        throw "Graph connection failed."
    }

    $script:IsConnected = $true
    return $context
}

function Get-IntuneDeviceCategories {
    $uri = "https://graph.microsoft.com/v1.0/deviceManagement/deviceCategories"

    return @(
        Invoke-GraphGetAll -Uri $uri |
        Sort-Object displayName |
        ForEach-Object {
            [PSCustomObject]@{
                Id          = $_.id
                DisplayName = $_.displayName
                Description = $_.description
            }
        }
    )
}

function Find-ManagedDevices {
    param(
        [Parameter(Mandatory)]
        [ValidateSet("DeviceName","SerialNumber")]
        [string]$LookupType,

        [Parameter(Mandatory)]
        [string]$Value,

        [switch]$UseContains
    )

    $cleanValue = $Value.Trim()
    if ([string]::IsNullOrWhiteSpace($cleanValue)) {
        return @()
    }

    $escapedValue = Escape-ODataString -Value $cleanValue

    if ($LookupType -eq "DeviceName") {
        if ($UseContains) {
            $filter = "contains(deviceName,'$escapedValue')"
        } else {
            $filter = "deviceName eq '$escapedValue'"
        }
    } else {
        if ($UseContains) {
            $filter = "contains(serialNumber,'$escapedValue')"
        } else {
            $filter = "serialNumber eq '$escapedValue'"
        }
    }

    $select = "id,deviceName,serialNumber,userPrincipalName,deviceCategoryDisplayName,operatingSystem,lastSyncDateTime,manufacturer,model"
    $encodedFilter = [System.Uri]::EscapeDataString($filter)
    $encodedSelect = [System.Uri]::EscapeDataString($select)

    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices?`$filter=$encodedFilter&`$select=$encodedSelect"

    return @(Invoke-GraphGetAll -Uri $uri)
}

function Set-ManagedDeviceCategory {
    param(
        [Parameter(Mandatory)][string]$ManagedDeviceId,
        [Parameter(Mandatory)][string]$CategoryId
    )

    $uri = "https://graph.microsoft.com/beta/deviceManagement/managedDevices('$ManagedDeviceId')/deviceCategory/`$ref"

    $body = @{
        "@odata.id" = "https://graph.microsoft.com/beta/deviceManagement/deviceCategories/$CategoryId"
    }

    Invoke-MgGraphRequest -Method PUT -Uri $uri -Body $body -ContentType "application/json" -ErrorAction Stop | Out-Null
}

# -----------------------------
# Input helpers
# -----------------------------
function Get-ItemsFromText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return @()
    }

    # Important:
    # Do NOT use a capturing regex group here, or PowerShell will include the delimiter itself
    # as an output item. That is what caused a literal "," row to appear in the staged list.
    return @(
        $Text -split '[,\r\n;]+' |
        ForEach-Object { $_.Trim() } |
        Where-Object {
            -not [string]::IsNullOrWhiteSpace($_) -and
            $_ -ne "," -and
            $_ -ne ";" -and
            $_ -notmatch '^[,;\s]+$'
        } |
        Select-Object -Unique
    )
}

function Get-InputItemsFromCsv {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][ValidateSet("DeviceName","SerialNumber")]
        [string]$LookupType
    )

    if (-not (Test-Path $Path)) {
        throw "CSV path not found: $Path"
    }

    $raw = Get-Content -Path $Path -ErrorAction Stop
    if (-not $raw -or $raw.Count -eq 0) {
        throw "CSV is empty."
    }

    try {
        $csv = Import-Csv -Path $Path -ErrorAction Stop
        $headers = @($csv | Get-Member -MemberType NoteProperty | Select-Object -ExpandProperty Name)

        $candidateColumns = if ($LookupType -eq "DeviceName") {
            @("DeviceName","Device Name","Name","LaptopName","Laptop Name","ComputerName","Computer Name","Hostname","Host Name")
        } else {
            @("SerialNumber","Serial Number","ServiceTag","Service Tag","Serial","Tag","AssetTag","Asset Tag")
        }

        $column = $candidateColumns | Where-Object { $headers -contains $_ } | Select-Object -First 1

        if ($column) {
            return @(
                $csv |
                ForEach-Object { $_.$column } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
                ForEach-Object { $_.Trim() } |
                Select-Object -Unique
            )
        }
    } catch {
        # Use fallback below.
    }

    # Fallback for headerless one-per-line files.
    return @(
        $raw |
        ForEach-Object { $_.Trim() } |
        Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
        Where-Object { $_ -notmatch '^(DeviceName|SerialNumber|ServiceTag|ComputerName|Hostname|Name)\s*$' } |
        Select-Object -Unique
    )
}

function Add-InputItems {
    param(
        [Parameter(Mandatory)][string[]]$Items,
        [Parameter(Mandatory)][ValidateSet("DeviceName","SerialNumber")]
        [string]$LookupType,
        [Parameter(Mandatory)][string]$Source
    )

    $added = 0

    foreach ($item in $Items) {
        $clean = $item.Trim()
        if ([string]::IsNullOrWhiteSpace($clean)) {
            continue
        }

        $exists = $script:InputRows | Where-Object {
            $_.InputValue -eq $clean -and $_.LookupType -eq $LookupType
        } | Select-Object -First 1

        if (-not $exists) {
            $script:InputRows.Add([PSCustomObject]@{
                InputValue = $clean
                LookupType = $LookupType
                Source     = $Source
            })
            $added++
        }
    }

    return $added
}

# -----------------------------
# UI helper functions
# -----------------------------
function Add-Log {
    param([string]$Message)

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $txtLog.AppendText("[$timestamp] $Message`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

function Set-Status {
    param([string]$Message)
    $lblStatus.Text = $Message
    [System.Windows.Forms.Application]::DoEvents()
}

function Get-SelectedLookupType {
    if ($rbSerial.Checked) {
        return "SerialNumber"
    }

    return "DeviceName"
}

function Get-SelectedCategory {
    if (-not $cmbCategory.SelectedItem) {
        throw "Select a target category."
    }

    $selectedName = [string]$cmbCategory.SelectedItem
    $category = $script:Categories | Where-Object { $_.DisplayName -eq $selectedName } | Select-Object -First 1

    if (-not $category) {
        throw "Selected category was not found."
    }

    return $category
}

function Refresh-CategoryCombo {
    $cmbCategory.Items.Clear()

    foreach ($category in $script:Categories) {
        [void]$cmbCategory.Items.Add($category.DisplayName)
    }

    if ($cmbCategory.Items.Count -gt 0) {
        $cmbCategory.SelectedIndex = 0
    }
}

function Refresh-InputGrid {
    $gridInputs.Rows.Clear()

    foreach ($row in $script:InputRows) {
        $i = $gridInputs.Rows.Add()
        $gridInputs.Rows[$i].Cells["InputValue"].Value = $row.InputValue
        $gridInputs.Rows[$i].Cells["InputLookupType"].Value = $row.LookupType
        $gridInputs.Rows[$i].Cells["InputSource"].Value = $row.Source
    }

    $lblInputCount.Text = "Input items: $($script:InputRows.Count)"
}

function Refresh-ResultsGrid {
    $gridResults.Rows.Clear()

    foreach ($row in $script:ResolvedRows) {
        $i = $gridResults.Rows.Add()
        $gridResults.Rows[$i].Cells["Apply"].Value = $row.Apply
        $gridResults.Rows[$i].Cells["InputValueResult"].Value = $row.InputValue
        $gridResults.Rows[$i].Cells["LookupTypeResult"].Value = $row.LookupType
        $gridResults.Rows[$i].Cells["Status"].Value = $row.Status
        $gridResults.Rows[$i].Cells["DeviceName"].Value = $row.DeviceName
        $gridResults.Rows[$i].Cells["SerialNumber"].Value = $row.SerialNumber
        $gridResults.Rows[$i].Cells["CurrentCategory"].Value = $row.CurrentCategory
        $gridResults.Rows[$i].Cells["UPN"].Value = $row.UserPrincipalName
        $gridResults.Rows[$i].Cells["LastSync"].Value = $row.LastSyncDateTime
        $gridResults.Rows[$i].Cells["ManagedDeviceId"].Value = $row.ManagedDeviceId
        $gridResults.Rows[$i].Cells["Message"].Value = $row.Message
    }

    $lblResultCount.Text = "Resolved rows: $($script:ResolvedRows.Count)"
}

function Update-ApplyButtonState {
    $eligibleCount = @(
        $script:ResolvedRows |
        Where-Object {
            $_.Apply -eq $true -and
            -not [string]::IsNullOrWhiteSpace([string]$_.ManagedDeviceId) -and
            ($_.Status -eq "Ready" -or $_.Status -eq "Multiple Match" -or $_.Status -eq "Updated")
        }
    ).Count

    $btnApply.Enabled = ($eligibleCount -gt 0)

    if ($eligibleCount -gt 0) {
        Set-Status "Ready to apply category to $eligibleCount checked device(s)"
    }
}


# -----------------------------
# Build GUI
# -----------------------------
$form = New-Object System.Windows.Forms.Form
$form.Text = "Intune Bulk Device Category Editor v6"
$form.StartPosition = "CenterScreen"
$form.Size = New-Object System.Drawing.Size(1250, 850)
$form.MinimumSize = New-Object System.Drawing.Size(1000, 700)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Main layout
$main = New-Object System.Windows.Forms.TableLayoutPanel
$main.Dock = "Fill"
$main.ColumnCount = 1
$main.RowCount = 4
$main.Padding = New-Object System.Windows.Forms.Padding(10)
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 145)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 38)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 42)))
[void]$main.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 20)))
[void]$form.Controls.Add($main)

# -----------------------------
# Top controls
# -----------------------------
$top = New-Object System.Windows.Forms.Panel
$top.Dock = "Fill"
[void]$main.Controls.Add($top, 0, 0)

$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = "1. Connect to Graph"
$btnConnect.Location = New-Object System.Drawing.Point(0, 0)
$btnConnect.Size = New-Object System.Drawing.Size(150, 30)
[void]$top.Controls.Add($btnConnect)

$lblTenant = New-Object System.Windows.Forms.Label
$lblTenant.Text = "Not connected"
$lblTenant.Location = New-Object System.Drawing.Point(165, 7)
$lblTenant.Size = New-Object System.Drawing.Size(900, 22)
[void]$top.Controls.Add($lblTenant)

$lblLookup = New-Object System.Windows.Forms.Label
$lblLookup.Text = "Lookup type for new input:"
$lblLookup.Location = New-Object System.Drawing.Point(0, 42)
$lblLookup.Size = New-Object System.Drawing.Size(155, 22)
[void]$top.Controls.Add($lblLookup)

$rbName = New-Object System.Windows.Forms.RadioButton
$rbName.Text = "Laptop / Device Name"
$rbName.Checked = $true
$rbName.Location = New-Object System.Drawing.Point(160, 40)
$rbName.Size = New-Object System.Drawing.Size(165, 24)
[void]$top.Controls.Add($rbName)

$rbSerial = New-Object System.Windows.Forms.RadioButton
$rbSerial.Text = "Service Tag / Serial"
$rbSerial.Location = New-Object System.Drawing.Point(330, 40)
$rbSerial.Size = New-Object System.Drawing.Size(150, 24)
[void]$top.Controls.Add($rbSerial)

$chkContains = New-Object System.Windows.Forms.CheckBox
$chkContains.Text = "Use contains search instead of exact match"
$chkContains.Location = New-Object System.Drawing.Point(500, 41)
$chkContains.Size = New-Object System.Drawing.Size(285, 24)
[void]$top.Controls.Add($chkContains)

$lblCategory = New-Object System.Windows.Forms.Label
$lblCategory.Text = "Target category:"
$lblCategory.Location = New-Object System.Drawing.Point(0, 80)
$lblCategory.Size = New-Object System.Drawing.Size(110, 22)
[void]$top.Controls.Add($lblCategory)

$cmbCategory = New-Object System.Windows.Forms.ComboBox
$cmbCategory.DropDownStyle = "DropDownList"
$cmbCategory.Location = New-Object System.Drawing.Point(110, 76)
$cmbCategory.Size = New-Object System.Drawing.Size(365, 25)
[void]$top.Controls.Add($cmbCategory)

$btnReloadCategories = New-Object System.Windows.Forms.Button
$btnReloadCategories.Text = "Reload Categories"
$btnReloadCategories.Location = New-Object System.Drawing.Point(490, 74)
$btnReloadCategories.Size = New-Object System.Drawing.Size(130, 30)
[void]$top.Controls.Add($btnReloadCategories)

$btnPreview = New-Object System.Windows.Forms.Button
$btnPreview.Text = "3. Preview / Resolve"
$btnPreview.Location = New-Object System.Drawing.Point(640, 74)
$btnPreview.Size = New-Object System.Drawing.Size(135, 30)
[void]$top.Controls.Add($btnPreview)

$btnApply = New-Object System.Windows.Forms.Button
$btnApply.Text = "4. Apply Category"
$btnApply.Enabled = $false
$btnApply.Location = New-Object System.Drawing.Point(785, 74)
$btnApply.Size = New-Object System.Drawing.Size(135, 30)
[void]$top.Controls.Add($btnApply)

$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Export Results"
$btnExport.Location = New-Object System.Drawing.Point(930, 74)
$btnExport.Size = New-Object System.Drawing.Size(115, 30)
[void]$top.Controls.Add($btnExport)

$btnClearAll = New-Object System.Windows.Forms.Button
$btnClearAll.Text = "Clear All"
$btnClearAll.Location = New-Object System.Drawing.Point(1055, 74)
$btnClearAll.Size = New-Object System.Drawing.Size(85, 30)
[void]$top.Controls.Add($btnClearAll)

$lblCsvHeader = New-Object System.Windows.Forms.Label
$lblCsvHeader.Text = "CSV import:"
$lblCsvHeader.Location = New-Object System.Drawing.Point(0, 116)
$lblCsvHeader.Size = New-Object System.Drawing.Size(80, 22)
[void]$top.Controls.Add($lblCsvHeader)

$btnImportCsv = New-Object System.Windows.Forms.Button
$btnImportCsv.Text = "Import CSV to List"
$btnImportCsv.Location = New-Object System.Drawing.Point(85, 111)
$btnImportCsv.Size = New-Object System.Drawing.Size(130, 30)
[void]$top.Controls.Add($btnImportCsv)

$txtCsvPath = New-Object System.Windows.Forms.TextBox
$txtCsvPath.ReadOnly = $true
$txtCsvPath.Location = New-Object System.Drawing.Point(225, 116)
$txtCsvPath.Size = New-Object System.Drawing.Size(915, 23)
$txtCsvPath.Anchor = "Left,Right,Top"
[void]$top.Controls.Add($txtCsvPath)

# -----------------------------
# Input area
# -----------------------------
$inputLayout = New-Object System.Windows.Forms.TableLayoutPanel
$inputLayout.Dock = "Fill"
$inputLayout.ColumnCount = 2
$inputLayout.RowCount = 1
[void]$inputLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$inputLayout.ColumnStyles.Add((New-Object System.Windows.Forms.ColumnStyle([System.Windows.Forms.SizeType]::Percent, 50)))
[void]$main.Controls.Add($inputLayout, 0, 1)

# Manual group
$grpManual = New-Object System.Windows.Forms.GroupBox
$grpManual.Text = "Manual Entry - one per line, comma, or semicolon separated"
$grpManual.Dock = "Fill"
[void]$inputLayout.Controls.Add($grpManual, 0, 0)

$manualInner = New-Object System.Windows.Forms.TableLayoutPanel
$manualInner.Dock = "Fill"
$manualInner.ColumnCount = 1
$manualInner.RowCount = 3
$manualInner.Padding = New-Object System.Windows.Forms.Padding(8)
[void]$manualInner.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
[void]$manualInner.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$manualInner.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 42)))
[void]$grpManual.Controls.Add($manualInner)

$lblManualHelp = New-Object System.Windows.Forms.Label
$lblManualHelp.Text = "Example: CHP-LAPTOP01 or ABC1234. Choose name vs serial above before adding."
$lblManualHelp.Dock = "Fill"
[void]$manualInner.Controls.Add($lblManualHelp, 0, 0)

$txtManual = New-Object System.Windows.Forms.TextBox
$txtManual.Multiline = $true
$txtManual.ScrollBars = "Both"
$txtManual.AcceptsReturn = $true
$txtManual.AcceptsTab = $false
$txtManual.WordWrap = $false
$txtManual.ReadOnly = $false
$txtManual.Enabled = $true
$txtManual.BackColor = [System.Drawing.Color]::White
$txtManual.ForeColor = [System.Drawing.Color]::Black
$txtManual.BorderStyle = "FixedSingle"
$txtManual.Dock = "Fill"
[void]$manualInner.Controls.Add($txtManual, 0, 1)

$manualButtonPanel = New-Object System.Windows.Forms.Panel
$manualButtonPanel.Dock = "Fill"
[void]$manualInner.Controls.Add($manualButtonPanel, 0, 2)

$btnAddManual = New-Object System.Windows.Forms.Button
$btnAddManual.Text = "2. Add Manual Input to List"
$btnAddManual.Location = New-Object System.Drawing.Point(0, 7)
$btnAddManual.Size = New-Object System.Drawing.Size(190, 28)
[void]$manualButtonPanel.Controls.Add($btnAddManual)

$btnClearManualText = New-Object System.Windows.Forms.Button
$btnClearManualText.Text = "Clear Text Box"
$btnClearManualText.Location = New-Object System.Drawing.Point(200, 7)
$btnClearManualText.Size = New-Object System.Drawing.Size(115, 28)
[void]$manualButtonPanel.Controls.Add($btnClearManualText)

# Staged input group
$grpInputs = New-Object System.Windows.Forms.GroupBox
$grpInputs.Text = "Staged Input List"
$grpInputs.Dock = "Fill"
[void]$inputLayout.Controls.Add($grpInputs, 1, 0)

$inputInner = New-Object System.Windows.Forms.TableLayoutPanel
$inputInner.Dock = "Fill"
$inputInner.ColumnCount = 1
$inputInner.RowCount = 2
$inputInner.Padding = New-Object System.Windows.Forms.Padding(8)
[void]$inputInner.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 38)))
[void]$inputInner.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$grpInputs.Controls.Add($inputInner)

$inputButtons = New-Object System.Windows.Forms.Panel
$inputButtons.Dock = "Fill"
[void]$inputInner.Controls.Add($inputButtons, 0, 0)

$lblInputCount = New-Object System.Windows.Forms.Label
$lblInputCount.Text = "Input items: 0"
$lblInputCount.Location = New-Object System.Drawing.Point(0, 9)
$lblInputCount.Size = New-Object System.Drawing.Size(130, 22)
[void]$inputButtons.Controls.Add($lblInputCount)

$btnRemoveSelectedInputs = New-Object System.Windows.Forms.Button
$btnRemoveSelectedInputs.Text = "Remove Selected"
$btnRemoveSelectedInputs.Location = New-Object System.Drawing.Point(140, 5)
$btnRemoveSelectedInputs.Size = New-Object System.Drawing.Size(125, 28)
[void]$inputButtons.Controls.Add($btnRemoveSelectedInputs)

$btnClearInputs = New-Object System.Windows.Forms.Button
$btnClearInputs.Text = "Clear Input List"
$btnClearInputs.Location = New-Object System.Drawing.Point(275, 5)
$btnClearInputs.Size = New-Object System.Drawing.Size(115, 28)
[void]$inputButtons.Controls.Add($btnClearInputs)

$gridInputs = New-Object System.Windows.Forms.DataGridView
$gridInputs.Dock = "Fill"
$gridInputs.AllowUserToAddRows = $false
$gridInputs.AllowUserToDeleteRows = $false
$gridInputs.ReadOnly = $true
$gridInputs.SelectionMode = "FullRowSelect"
$gridInputs.MultiSelect = $true
$gridInputs.AutoSizeColumnsMode = "Fill"
[void]$inputInner.Controls.Add($gridInputs, 0, 1)

$c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$c.Name = "InputValue"
$c.HeaderText = "Input Value"
$c.FillWeight = 55
[void]$gridInputs.Columns.Add($c)

$c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$c.Name = "InputLookupType"
$c.HeaderText = "Lookup Type"
$c.FillWeight = 25
[void]$gridInputs.Columns.Add($c)

$c = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$c.Name = "InputSource"
$c.HeaderText = "Source"
$c.FillWeight = 20
[void]$gridInputs.Columns.Add($c)

# -----------------------------
# Results area
# -----------------------------
$grpResults = New-Object System.Windows.Forms.GroupBox
$grpResults.Text = "Preview / Results"
$grpResults.Dock = "Fill"
[void]$main.Controls.Add($grpResults, 0, 2)

$resultsInner = New-Object System.Windows.Forms.TableLayoutPanel
$resultsInner.Dock = "Fill"
$resultsInner.ColumnCount = 1
$resultsInner.RowCount = 2
$resultsInner.Padding = New-Object System.Windows.Forms.Padding(8)
[void]$resultsInner.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Absolute, 28)))
[void]$resultsInner.RowStyles.Add((New-Object System.Windows.Forms.RowStyle([System.Windows.Forms.SizeType]::Percent, 100)))
[void]$grpResults.Controls.Add($resultsInner)

$lblResultCount = New-Object System.Windows.Forms.Label
$lblResultCount.Text = "Resolved rows: 0"
$lblResultCount.Dock = "Fill"
[void]$resultsInner.Controls.Add($lblResultCount, 0, 0)

$gridResults = New-Object System.Windows.Forms.DataGridView
$gridResults.Dock = "Fill"
$gridResults.AllowUserToAddRows = $false
$gridResults.AllowUserToDeleteRows = $false
$gridResults.SelectionMode = "FullRowSelect"
$gridResults.MultiSelect = $true
$gridResults.AutoSizeColumnsMode = "DisplayedCells"
[void]$resultsInner.Controls.Add($gridResults, 0, 1)

$colApply = New-Object System.Windows.Forms.DataGridViewCheckBoxColumn
$colApply.Name = "Apply"
$colApply.HeaderText = "Apply"
$colApply.Width = 55
[void]$gridResults.Columns.Add($colApply)

$columns = @(
    @("InputValueResult", "Input"),
    @("LookupTypeResult", "Lookup"),
    @("Status", "Status"),
    @("DeviceName", "Device Name"),
    @("SerialNumber", "Serial / Service Tag"),
    @("CurrentCategory", "Current Category"),
    @("UPN", "Primary User"),
    @("LastSync", "Last Sync"),
    @("ManagedDeviceId", "Managed Device ID"),
    @("Message", "Message")
)

foreach ($col in $columns) {
    $dc = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $dc.Name = $col[0]
    $dc.HeaderText = $col[1]
    $dc.ReadOnly = $true
    [void]$gridResults.Columns.Add($dc)
}

$gridResults.Columns["ManagedDeviceId"].Visible = $false
$gridResults.Columns["Message"].AutoSizeMode = "Fill"

# -----------------------------
# Log area
# -----------------------------
$grpLog = New-Object System.Windows.Forms.GroupBox
$grpLog.Text = "Log"
$grpLog.Dock = "Fill"
[void]$main.Controls.Add($grpLog, 0, 3)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Multiline = $true
$txtLog.ScrollBars = "Vertical"
$txtLog.ReadOnly = $true
$txtLog.Dock = "Fill"
[void]$grpLog.Controls.Add($txtLog)

# Status strip
$statusStrip = New-Object System.Windows.Forms.StatusStrip
$lblStatus = New-Object System.Windows.Forms.ToolStripStatusLabel
$lblStatus.Text = "Ready"
[void]$statusStrip.Items.Add($lblStatus)
[void]$form.Controls.Add($statusStrip)
$statusStrip.BringToFront()

# -----------------------------
# Event handlers
# -----------------------------
$btnConnect.Add_Click({
    try {
        Set-Status "Connecting..."
        Add-Log "Connecting to Microsoft Graph..."
        $context = Connect-GraphForIntune
        $lblTenant.Text = "Connected: $($context.Account) | Tenant: $($context.TenantId)"

        Add-Log "Loading device categories..."
        $script:Categories = @(Get-IntuneDeviceCategories)
        Refresh-CategoryCombo

        Add-Log "Loaded $($script:Categories.Count) device categories."
        Set-Status "Connected"
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Connection Error", "OK", "Error") | Out-Null
        Set-Status "Connection failed"
    }
})

$btnReloadCategories.Add_Click({
    try {
        if (-not $script:IsConnected) {
            throw "Connect to Graph first."
        }

        Add-Log "Reloading device categories..."
        $script:Categories = @(Get-IntuneDeviceCategories)
        Refresh-CategoryCombo
        Add-Log "Reloaded $($script:Categories.Count) device categories."
        Set-Status "Categories reloaded"
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Category Error", "OK", "Error") | Out-Null
        Set-Status "Category reload failed"
    }
})

$btnAddManual.Add_Click({
    try {
        $lookupType = Get-SelectedLookupType
        $items = @(Get-ItemsFromText -Text $txtManual.Text)

        if ($items.Count -eq 0) {
            throw "Enter at least one laptop/device name or service tag first."
        }

        $added = Add-InputItems -Items $items -LookupType $lookupType -Source "Manual"
        Refresh-InputGrid

        Add-Log "Added $added manual input item(s) as $lookupType."
        Set-Status "Manual input added"
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Manual Input Error", "OK", "Error") | Out-Null
        Set-Status "Manual input failed"
    }
})

$btnClearManualText.Add_Click({
    $txtManual.Clear()
    $txtManual.Focus()
    Set-Status "Manual text cleared"
})

$btnImportCsv.Add_Click({
    try {
        $dialog = New-Object System.Windows.Forms.OpenFileDialog
        $dialog.Filter = "CSV files (*.csv)|*.csv|Text files (*.txt)|*.txt|All files (*.*)|*.*"
        $dialog.Title = "Select input CSV or text file"

        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $txtCsvPath.Text = $dialog.FileName

            $lookupType = Get-SelectedLookupType
            $items = @(Get-InputItemsFromCsv -Path $dialog.FileName -LookupType $lookupType)

            if ($items.Count -eq 0) {
                throw "No usable values found in selected file."
            }

            $added = Add-InputItems -Items $items -LookupType $lookupType -Source "CSV"
            Refresh-InputGrid

            Add-Log "Imported file: $($dialog.FileName)"
            Add-Log "Added $added CSV/file input item(s) as $lookupType."
            Set-Status "CSV imported"
        }
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "CSV Import Error", "OK", "Error") | Out-Null
        Set-Status "CSV import failed"
    }
})

$btnRemoveSelectedInputs.Add_Click({
    try {
        if ($gridInputs.SelectedRows.Count -eq 0) {
            throw "Select one or more staged input rows to remove."
        }

        $indexes = @()
        foreach ($selectedRow in $gridInputs.SelectedRows) {
            if ($selectedRow.Index -ge 0) {
                $indexes += $selectedRow.Index
            }
        }

        foreach ($idx in ($indexes | Sort-Object -Descending)) {
            $script:InputRows.RemoveAt($idx)
        }

        Refresh-InputGrid
        Add-Log "Removed $($indexes.Count) staged input item(s)."
        Set-Status "Selected inputs removed"
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Remove Input Error", "OK", "Error") | Out-Null
    }
})

$btnClearInputs.Add_Click({
    $script:InputRows.Clear()
    Refresh-InputGrid
    Add-Log "Cleared staged input list."
    Set-Status "Input list cleared"
})

$btnPreview.Add_Click({
    try {
        if (-not $script:IsConnected) {
            throw "Connect to Graph first."
        }

        if ($script:InputRows.Count -eq 0) {
            throw "No staged inputs. Add manual entries or import a CSV first."
        }

        $script:ResolvedRows.Clear()

        $useContains = $chkContains.Checked
        $total = $script:InputRows.Count
        $count = 0

        Add-Log "Resolving $total staged input item(s)..."

        foreach ($inputRow in $script:InputRows) {
            $count++
            $item = $inputRow.InputValue
            $lookupType = $inputRow.LookupType

            Set-Status "Resolving $count of $total`: $item"

            try {
                $matches = @(Find-ManagedDevices -LookupType $lookupType -Value $item -UseContains:$useContains)

                if ($matches.Count -eq 0) {
                    $script:ResolvedRows.Add([PSCustomObject]@{
                        Apply             = $false
                        InputValue        = $item
                        LookupType        = $lookupType
                        Status            = "Not Found"
                        DeviceName        = ""
                        SerialNumber      = ""
                        CurrentCategory   = ""
                        UserPrincipalName = ""
                        LastSyncDateTime  = ""
                        ManagedDeviceId   = ""
                        Message           = "No Intune managed device matched this input."
                    })
                    continue
                }

                foreach ($device in $matches) {
                    $managedDeviceId = Get-GraphObjectValue -Object $device -PropertyName "id"
                    $deviceName = Get-GraphObjectValue -Object $device -PropertyName "deviceName"
                    $serialNumber = Get-GraphObjectValue -Object $device -PropertyName "serialNumber"
                    $userPrincipalName = Get-GraphObjectValue -Object $device -PropertyName "userPrincipalName"
                    $lastSyncDateTime = Get-GraphObjectValue -Object $device -PropertyName "lastSyncDateTime"
                    $cat = Get-GraphObjectValue -Object $device -PropertyName "deviceCategoryDisplayName"

                    if ([string]::IsNullOrWhiteSpace($cat)) {
                        $cat = "Unknown / Unassigned"
                    }

                    $rowStatus = if ($matches.Count -gt 1) { "Multiple Match" } else { "Ready" }
                    $rowMessage = if ($matches.Count -gt 1) { "Review multiple matches before applying." } else { "Resolved." }

                    if ([string]::IsNullOrWhiteSpace($managedDeviceId)) {
                        $rowStatus = "Error"
                        $rowMessage = "Device resolved, but managedDeviceId was not returned by Graph. Cannot apply category."
                    }

                    $script:ResolvedRows.Add([PSCustomObject]@{
                        Apply             = -not [string]::IsNullOrWhiteSpace($managedDeviceId)
                        InputValue        = $item
                        LookupType        = $lookupType
                        Status            = $rowStatus
                        DeviceName        = $deviceName
                        SerialNumber      = $serialNumber
                        CurrentCategory   = $cat
                        UserPrincipalName = $userPrincipalName
                        LastSyncDateTime  = $lastSyncDateTime
                        ManagedDeviceId   = $managedDeviceId
                        Message           = $rowMessage
                    })
                }
            } catch {
                $script:ResolvedRows.Add([PSCustomObject]@{
                    Apply             = $false
                    InputValue        = $item
                    LookupType        = $lookupType
                    Status            = "Error"
                    DeviceName        = ""
                    SerialNumber      = ""
                    CurrentCategory   = ""
                    UserPrincipalName = ""
                    LastSyncDateTime  = ""
                    ManagedDeviceId   = ""
                    Message           = $_.Exception.Message
                })
            }
        }

        Refresh-ResultsGrid

        Update-ApplyButtonState

        $eligibleCount = @($script:ResolvedRows | Where-Object { $_.Apply -and -not [string]::IsNullOrWhiteSpace([string]$_.ManagedDeviceId) }).Count
        Add-Log "Preview complete. Resolved rows: $($script:ResolvedRows.Count). Eligible to update: $eligibleCount"
        Set-Status "Preview complete"
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Preview Error", "OK", "Error") | Out-Null
        Set-Status "Preview failed"
    }
})

$btnApply.Add_Click({
    try {
        if (-not $script:IsConnected) {
            throw "Connect to Graph first."
        }

        $category = Get-SelectedCategory

        # Sync checkbox values from grid into objects.
        for ($i = 0; $i -lt $gridResults.Rows.Count; $i++) {
            $script:ResolvedRows[$i].Apply = [bool]$gridResults.Rows[$i].Cells["Apply"].Value
        }

        $targets = @(
            $script:ResolvedRows |
            Where-Object { $_.Apply -and -not [string]::IsNullOrWhiteSpace($_.ManagedDeviceId) }
        )

        if ($targets.Count -eq 0) {
            throw "No checked resolved rows to update."
        }

        $confirm = [System.Windows.Forms.MessageBox]::Show(
            "Apply category '$($category.DisplayName)' to $($targets.Count) checked device(s)?",
            "Confirm Bulk Update",
            "YesNo",
            "Warning"
        )

        if ($confirm -ne [System.Windows.Forms.DialogResult]::Yes) {
            Add-Log "Apply cancelled."
            return
        }

        $count = 0
        foreach ($row in $targets) {
            $count++
            Set-Status "Updating $count of $($targets.Count): $($row.DeviceName)"

            try {
                Set-ManagedDeviceCategory -ManagedDeviceId $row.ManagedDeviceId -CategoryId $category.Id
                $row.Status = "Updated"
                $row.CurrentCategory = $category.DisplayName
                $row.Message = "Category updated successfully."
                Add-Log "Updated: $($row.DeviceName) [$($row.SerialNumber)] -> $($category.DisplayName)"
            } catch {
                $row.Status = "Failed"
                $row.Message = $_.Exception.Message
                Add-Log "FAILED: $($row.DeviceName) [$($row.SerialNumber)] - $($_.Exception.Message)"
            }

            Refresh-ResultsGrid
        }

        Add-Log "Bulk update complete."
        Set-Status "Apply complete"
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Apply Error", "OK", "Error") | Out-Null
        Set-Status "Apply failed"
    }
})

$btnExport.Add_Click({
    try {
        if ($script:ResolvedRows.Count -eq 0) {
            throw "No resolved rows to export."
        }

        $dialog = New-Object System.Windows.Forms.SaveFileDialog
        $dialog.Filter = "CSV files (*.csv)|*.csv"
        $dialog.Title = "Export results"
        $dialog.FileName = "Intune_Device_Category_Update_Results_$(Get-Date -Format yyyyMMdd_HHmmss).csv"

        if ($dialog.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            $script:ResolvedRows | Export-Csv -Path $dialog.FileName -NoTypeInformation -Encoding UTF8
            Add-Log "Exported results to: $($dialog.FileName)"
            Set-Status "Export complete"
        }
    } catch {
        Add-Log "ERROR: $($_.Exception.Message)"
        [System.Windows.Forms.MessageBox]::Show($_.Exception.Message, "Export Error", "OK", "Error") | Out-Null
        Set-Status "Export failed"
    }
})

$btnClearAll.Add_Click({
    $txtManual.Clear()
    $txtCsvPath.Clear()
    $script:InputRows.Clear()
    $script:ResolvedRows.Clear()
    Refresh-InputGrid
    Refresh-ResultsGrid
    $btnApply.Enabled = $false
    Add-Log "Cleared all input and results."
    Set-Status "Cleared"
})

# Initial focus and log
$form.Add_Shown({
    $txtManual.Focus()
})

Add-Log "Ready."
Add-Log "Manual input: type or paste one or more values, then click 'Add Manual Input to List'."
Add-Log "CSV input: click 'Import CSV to List'. CSV and manual entries can be mixed."
Add-Log "v6: Fixed comma-separated input and suppressed harmless console layout output."

[void]$form.ShowDialog()
