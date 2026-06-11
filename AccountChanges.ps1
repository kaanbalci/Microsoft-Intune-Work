# Function to check and install PowerShell modules
function Install-ModuleIfMissing {
    param (
        [string]$ModuleName
    )
    if (!(Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Host "$ModuleName module not found. Installing..."
        try {
            Install-Module -Name $ModuleName -Force -Scope CurrentUser
            Write-Host "$ModuleName module installed successfully"
        } catch {
            Write-Host "Failed to install $ModuleName module - $_"
            exit 1
        }
    } else {
        Write-Host "$ModuleName module is already installed"
    }
}

# Ensure required modules are installed
Install-ModuleIfMissing -ModuleName "ActiveDirectory"
Install-ModuleIfMissing -ModuleName "Microsoft.Graph"
Install-ModuleIfMissing -ModuleName "Microsoft.Graph.Users.Actions"  # New module for password change

# Import Modules
Import-Module ActiveDirectory
Import-Module Microsoft.Graph.Users
Import-Module Microsoft.Graph.Identity.SignIns
Import-Module Microsoft.Graph.Users.Actions  # Import for password change handling

# Connect to Microsoft Graph (Interactive Login)
Write-Host "Connecting to Microsoft Graph..."
Connect-MgGraph -Scopes "User.ReadWrite.All", "Group.ReadWrite.All", "UserAuthenticationMethod.ReadWrite.All"

# Get list of user emails
$emails = Read-Host "Enter user email addresses (comma-separated)" | ForEach-Object { $_ -split "," }

# Define Azure AD Group to move users to
$targetAzureGroup = "Employee Lockout Group"

# Define the target OU for disabled accounts
$targetOU = "OU=Sync with 0365,OU=Disabled Accounts,DC=chpc2,DC=org"

# Process each email
foreach ($email in $emails) {
    $email = $email.Trim()
    if (-not $email) { continue }

    # Get AD user
    $adUser = Get-ADUser -Filter {EmailAddress -eq $email} -Properties EmailAddress, DistinguishedName
    if ($adUser) {
        Write-Host "Processing user: $email ($($adUser.SamAccountName))"

        # Disable AD Account
        try {
            Disable-ADAccount -Identity $adUser.SamAccountName
            Write-Host "Disabled AD Account for $email"
        } catch {
            Write-Host "Failed to disable AD account for $email - $_"
            continue
        }

        # Move user to the specified OU
        try {
            Move-ADObject -Identity $adUser.DistinguishedName -TargetPath $targetOU
            Write-Host "Moved $email to OU: $targetOU"
        } catch {
            Write-Host "Failed to move $email to OU: $targetOU - $_"
            continue
        }

        # Get Azure AD user
        $azureUser = Get-MgUser -Filter "UserPrincipalName eq '$email'"
        if ($azureUser) {
            # Move user to Azure AD Group
            $group = Get-MgGroup -Filter "DisplayName eq '$targetAzureGroup'"
            if ($group) {
                try {
                    New-MgGroupMember -GroupId $group.Id -DirectoryObjectId $azureUser.Id
                    Write-Host "Added $email to Azure AD Group: $targetAzureGroup"
                } catch {
                    Write-Host "Failed to add $email to Azure AD Group - $_"
                }
            } else {
                Write-Host "Azure AD Group '$targetAzureGroup' not found"
            }

            # Revoke MFA & force re-registration
            try {
                # Search for Authenticator App methods and remove any found
                $App = Get-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $azureUser.UserPrincipalName
                if ($App) {
                    # Ensure default method is changed before removing the old one
                    $phoneMethod = Get-MgUserAuthenticationPhoneMethod -UserId $azureUser.UserPrincipalName | Select-Object -First 1
                    if ($phoneMethod) {
                        # Set the phone method as default if available
                        Set-MgUserAuthenticationMethod -UserId $azureUser.UserPrincipalName -AuthenticationMethodId $phoneMethod.Id
                        Write-Host "Changed default method to phone number $($phoneMethod.PhoneNumber)" -ForegroundColor Green
                    }

                    $App | ForEach-Object {
                        Remove-MgUserAuthenticationMicrosoftAuthenticatorMethod -UserId $azureUser.UserPrincipalName -MicrosoftAuthenticatorAuthenticationMethodId $_.Id
                        Write-Host "Authenticator App '$($_.DisplayName)' removed" -ForegroundColor Green
                    }
                } else {
                    Write-Host "No Authenticator App methods found" -ForegroundColor Green
                }

                # Search for Email methods and remove any found
                $Email = Get-MgUserAuthenticationEmailMethod -UserId $azureUser.UserPrincipalName
                if ($Email) {
                    $Email | ForEach-Object {
                        Remove-MgUserAuthenticationEmailMethod -UserId $azureUser.UserPrincipalName -EmailAuthenticationMethodId $_.Id
                        Write-Host "Email address '$($_.EmailAddress)' removed" -ForegroundColor Green
                    }
                } else {
                    Write-Host "No Email methods found" -ForegroundColor Green
                }

                # Search for Phone methods and remove any found
                $Phone = Get-MgUserAuthenticationPhoneMethod -UserId $azureUser.UserPrincipalName
                if ($Phone) {
                    $Phone | ForEach-Object {
                        Remove-MgUserAuthenticationPhoneMethod -UserId $azureUser.UserPrincipalName -PhoneAuthenticationMethodId $_.Id
                        Write-Host "Phone number '$($_.PhoneNumber)' removed" -ForegroundColor Green
                    }
                } else {
                    Write-Host "No Phone/Text methods found" -ForegroundColor Green
                }

                # Reset password to a random string of 14 characters
                $newPassword = [System.Web.Security.Membership]::GeneratePassword(14, 4)
                Update-MgUser -UserId $azureUser.Id -PasswordProfile @{ ForceChangePasswordNextSignIn = $true; Password = $newPassword }
                Write-Host "Password for $email reset to a new random password" -ForegroundColor Green

            } catch {
                Write-Host "Failed to reset MFA for $email - $_"
            }
        } else {
            Write-Host "Azure AD user $email not found"
        }
    } else {
        Write-Host "No Active Directory user found for $email"
    }
}

Write-Host "Process Completed"
