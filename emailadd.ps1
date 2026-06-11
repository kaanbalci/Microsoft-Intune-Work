
# Import Exchange Online module (if not already installed)
if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
    Install-Module ExchangeOnlineManagement -Force -AllowClobber
}

# Prompt for Exchange Online credentials (admin account for the domain)
$adminCredential = Get-Credential -Message "Enter Exchange Online admin credentials"

# Connect to Exchange Online with basic authentication (no MFA)
Write-Host "Connecting to Exchange Online with admin credentials..."
Connect-ExchangeOnline -UserPrincipalName $adminCredential.UserName -Password $adminCredential.GetNetworkCredential().Password -ShowProgress $true


# Get the FQDN of your on-prem Exchange server (you will enter it here)
$exchangeServer = Read-Host "Enter the FQDN of your on-prem Exchange server"

# Prompt for credentials to establish a session with the on-prem Exchange server
$creds = Get-Credential

# Set up remote session for on-prem Exchange
try {
    $session = New-PSSession -ConfigurationName Microsoft.Exchange `
                             -ConnectionUri "http://$exchangeServer/PowerShell/" `
                             -Authentication Kerberos `
                             -Credential $creds -ErrorAction Stop
    Import-PSSession $session -DisableNameChecking -ErrorAction Stop
    Write-Host "Connected to Exchange server at $exchangeServer"
} catch {
    Write-Error "Failed to connect to Exchange server: $($_)"
    exit
}

# Prompt for action (add or remove)
$action = Read-Host "Do you want to 'add' or 'remove' external contacts from a distribution group? (add/remove)"

if ($action -ne "add" -and $action -ne "remove") {
    Write-Error "Invalid action. Please enter 'add' or 'remove'."
    exit
}

# Prompt for comma-separated emails
$emailsInput = Read-Host "Enter one or more external email addresses, separated by commas"
$emailList = $emailsInput.Split(",") | ForEach-Object { $_.Trim() }

# Prompt for distribution group
$distributionGroup = Read-Host "Enter the distribution group name (name or alias)"

# Add or remove logic
if ($action -eq "add") {
    $ou = Read-Host "Enter the OU path (e.g., OU=Contacts,DC=yourdomain,DC=com)"
    
    foreach ($email in $emailList) {
        $alias = ($email.Split("@")[0]) -replace "[^a-zA-Z0-9]", ""
        $displayName = $email

        # Check if contact exists
        $existingContact = Get-MailContact -Filter "ExternalEmailAddress -eq '$email'" -ErrorAction SilentlyContinue

        if ($existingContact) {
            Write-Host "Contact for $email already exists. Using existing contact."
            $contactIdentity = $existingContact.Alias
        } else {
            try {
                $newContact = New-MailContact -Name $displayName `
                                              -ExternalEmailAddress $email `
                                              -Alias $alias `
                                              -OrganizationalUnit $ou `
                                              -DisplayName $displayName `
                                              -HiddenFromAddressListsEnabled $false `
                                              -ErrorAction Stop
                $contactIdentity = $newContact.Alias
                Write-Host "Created contact for $email"
            } catch {
                Write-Error "Failed to create contact for ${email}: $($_)"
                continue
            }
        }

        # Add contact to the distribution group
        try {
            Add-DistributionGroupMember -Identity $distributionGroup -Member $contactIdentity -ErrorAction Stop
            Write-Host "Added $email to $distributionGroup"
        } catch {
            Write-Error "Failed to add ${email} to group: $($_)"
        }
    }

} elseif ($action -eq "remove") {
    $deleteContacts = Read-Host "Do you also want to delete the mail contacts after removing from the group? (yes/no)"
    
    foreach ($email in $emailList) {
        $contact = Get-MailContact -Filter "ExternalEmailAddress -eq '$email'" -ErrorAction SilentlyContinue

        if (-not $contact) {
            Write-Warning "No contact found for $email"
            continue
        }

        try {
            Remove-DistributionGroupMember -Identity $distributionGroup -Member $contact.Alias -Confirm:$false -ErrorAction Stop
            Write-Host "Removed $email from $distributionGroup"
        } catch {
            Write-Error "Failed to remove ${email} from group: $($_)"
        }

        if ($deleteContacts -eq "yes") {
            try {
                Remove-MailContact -Identity $contact.Alias -Confirm:$false -ErrorAction Stop
                Write-Host "Deleted mail contact for $email"
            } catch {
                Write-Error "Failed to delete contact ${email}: $($_)"
            }
        }
    }
}

# Clean up the session after script completion
Remove-PSSession $session
Write-Host "Session closed and script completed."
