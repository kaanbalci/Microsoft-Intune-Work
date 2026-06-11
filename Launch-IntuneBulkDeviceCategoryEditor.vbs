Option Explicit

Dim shell, fso, scriptFolder, ps1Path, command

Set shell = CreateObject("WScript.Shell")
Set fso = CreateObject("Scripting.FileSystemObject")

scriptFolder = fso.GetParentFolderName(WScript.ScriptFullName)
ps1Path = scriptFolder & "\Intune-BulkDeviceCategoryEditor-v6.ps1"

If Not fso.FileExists(ps1Path) Then
    MsgBox "Could not find Intune-BulkDeviceCategoryEditor-v6.ps1 in the same folder as this launcher." & vbCrLf & vbCrLf & _
           "Expected path:" & vbCrLf & ps1Path, vbCritical, "Missing PowerShell Script"
    WScript.Quit 1
End If

command = "powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File """ & ps1Path & """"

' 0 = hidden window
' False = do not wait for PowerShell to exit
shell.Run command, 0, False
