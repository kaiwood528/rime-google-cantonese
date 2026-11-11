# Remove Google Cantonese cloud candidates; Weasel goes back to its original setup.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1             remove and redeploy
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 -PurgeCache also delete the cloud cache
param([switch]$PurgeCache)
$ErrorActionPreference = "Stop"
$rime = Join-Path $env:APPDATA "Rime"
$utf8 = New-Object System.Text.UTF8Encoding $false
$marker = "rime-google-cantonese"

Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
    Where-Object { $_.CommandLine -match "gcloud_daemon\.py" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "stopped daemon $($_.ProcessId)" }

$lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Rime Google Cantonese.lnk"
if (Test-Path $lnk) { Remove-Item $lnk; Write-Host "autostart removed" }

Get-ChildItem $rime -Filter "*.custom.yaml" | ForEach-Object {
    if ([System.IO.File]::ReadAllText($_.FullName, $utf8) -match $marker) { Remove-Item $_.FullName; Write-Host "removed $($_.Name)" }
}

$yale = Join-Path $rime "jyut6ping3_yale.schema.yaml"
if ((Test-Path $yale) -and ([System.IO.File]::ReadAllText($yale, $utf8) -match $marker)) {
    Remove-Item $yale
    Write-Host "removed jyut6ping3_yale.schema.yaml (also remove it from schema_list in default.custom.yaml)"
}

$rimeLua = Join-Path $rime "rime.lua"
if (Test-Path $rimeLua) {
    $text = [System.IO.File]::ReadAllText($rimeLua, $utf8)
    $clean = [regex]::Replace($text, "(?s)\r?\n?-- rime-google-cantonese \(begin\).*?-- rime-google-cantonese \(end\)\r?\n?", "")
    if ($clean.Trim() -eq "") { Remove-Item $rimeLua; Write-Host "rime.lua removed" }
    elseif ($clean -ne $text) { [System.IO.File]::WriteAllText($rimeLua, $clean, $utf8); Write-Host "rime.lua cleaned" }
}

$lua = Join-Path $rime "lua\gcloud.lua"
if (Test-Path $lua) { Remove-Item $lua; Write-Host "lua\gcloud.lua removed" }
if ($PurgeCache -and (Test-Path (Join-Path $rime "gcloud"))) { Remove-Item (Join-Path $rime "gcloud") -Recurse; Write-Host "cache removed" }

foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel", "HKLM:\SOFTWARE\Rime\Weasel")) {
    if (Test-Path $k) { $root = (Get-ItemProperty $k).WeaselRoot; if ($root) { break } }
}
if ($root) {
    # ShellExecute opens the settings dialog on this Weasel build; launch directly instead.
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = Join-Path $root "WeaselDeployer.exe"
    $psi.Arguments = "/deploy"
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $proc = [System.Diagnostics.Process]::Start($psi)
    $null = $proc.StandardError.ReadToEndAsync()
    $null = $proc.StandardOutput.ReadToEnd()
    $proc.WaitForExit()
    Write-Host "Weasel redeployed (exit $($proc.ExitCode))"
}
