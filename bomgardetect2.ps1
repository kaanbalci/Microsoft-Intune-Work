$installFolder = "$env:ProgramData\bomgar-scc-*"
if(
    (Test-Path -Path $installFolder) -and
    (Test-Path -Path "$installFolder\bomgar-scc.exe") -and
    (Test-Path -Path "$installFolder\server.lic")
){
    Get-ChildItem -Path $installFolder | ForEach-Object {
        "Installed"
        Write-output "Poop"
        Exit 0
    }
}else{ 
        Write-output "Not Installed"
        Exit 1
    }