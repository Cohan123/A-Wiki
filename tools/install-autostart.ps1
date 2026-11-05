param(
  [int]$Port = 8765,
  [string]$BindAddress = "0.0.0.0",
  [string]$TaskName = "Firmen-Wiki Editor-Server"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot
$server = Join-Path $PSScriptRoot "editor-server.ps1"
$arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$server`" -Port $Port -BindAddress `"$BindAddress`""
$taskInstalled = $false
try {
  $action = New-ScheduledTaskAction -Execute "powershell.exe" -Argument $arguments -WorkingDirectory $root
  $triggerStartup = New-ScheduledTaskTrigger -AtStartup
  $triggerLogin = New-ScheduledTaskTrigger -AtLogOn
  $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit ([TimeSpan]::Zero) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -StartWhenAvailable
  $userId = "$env:USERDOMAIN\$env:USERNAME"
  $principal = New-ScheduledTaskPrincipal -UserId $userId -LogonType S4U -RunLevel Highest
  Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger @($triggerStartup, $triggerLogin) -Settings $settings -Principal $principal -Description "Startet die interne Firmen-Wissensdatenbank automatisch." -Force -ErrorAction Stop | Out-Null
  $taskInstalled = $true
  Write-Host "Autostart mit Systemstart und Benutzeranmeldung eingerichtet."
} catch {
  Write-Warning "Aufgabenplanung ist nicht zugaenglich. Richte den Benutzer-Autostart als Rueckfall ein."
  $startupDir = [Environment]::GetFolderPath("Startup")
  $shortcutPath = Join-Path $startupDir "Firmen-Wiki Editor-Server.lnk"
  $shell = New-Object -ComObject WScript.Shell
  $shortcut = $shell.CreateShortcut($shortcutPath)
  $shortcut.TargetPath = "powershell.exe"
  $shortcut.Arguments = $arguments
  $shortcut.WorkingDirectory = $root
  $shortcut.WindowStyle = 7
  $shortcut.Description = "Startet die interne Firmen-Wissensdatenbank bei der Anmeldung."
  $shortcut.Save()
  Write-Host "Benutzer-Autostart eingerichtet: $shortcutPath"
}
$firewallName = "Firmen-Wiki TCP $Port"
if (Get-Command Get-NetFirewallRule -ErrorAction SilentlyContinue) {
  if (-not (Get-NetFirewallRule -DisplayName $firewallName -ErrorAction SilentlyContinue)) {
    try { New-NetFirewallRule -DisplayName $firewallName -Direction Inbound -Action Allow -Protocol TCP -LocalPort $Port -Profile Domain,Private -ErrorAction Stop | Out-Null }
    catch { Write-Warning "Die Firewallregel benoetigt Administratorrechte und muss spaeter ergaenzt werden: $($_.Exception.Message)" }
  }
}
if ($taskInstalled) { Start-ScheduledTask -TaskName $TaskName }
else { Start-Process -FilePath "powershell.exe" -ArgumentList $arguments -WorkingDirectory $root -WindowStyle Hidden }
Write-Host "Autostart eingerichtet: $TaskName"
