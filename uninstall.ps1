# Remove Google Cantonese cloud candidates; Weasel goes back to its original setup.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1             remove and redeploy
#   powershell -ExecutionPolicy Bypass -File uninstall.ps1 -PurgeCache also delete the cloud cache
#   uninstall.cmd                                                     double-click version
# Weasel and the rime-cantonese schema are left installed.
param([switch]$PurgeCache, [switch]$Interactive)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rime = Join-Path $env:APPDATA "Rime"
$customDir = (Get-ItemProperty "HKCU:\Software\Rime\Weasel" -ErrorAction SilentlyContinue).RimeUserDir
if ($customDir) { $rime = [Environment]::ExpandEnvironmentVariables($customDir) }
$utf8 = New-Object System.Text.UTF8Encoding $false
$marker = "rime-google-cantonese"
$programDir = Join-Path $env:LOCALAPPDATA "Programs\rime-google-cantonese"

$msg = @{}
$msgFile = Join-Path $here "setup\messages.txt"
if (Test-Path $msgFile) {
    foreach ($line in [System.IO.File]::ReadAllLines($msgFile, $utf8)) {
        if ($line -match '^([a-z0-9_]+)=(.*)$') { $msg[$Matches[1]] = $Matches[2] }
    }
}
if ($Interactive -and $msg.ContainsKey("uninstall_title")) { Write-Host ""; Write-Host $msg["uninstall_title"]; if ($msg.ContainsKey("uninstall_title_en")) { Write-Host $msg["uninstall_title_en"] -ForegroundColor DarkGray }; Write-Host "" }

Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
    Where-Object { $_.CommandLine -match "gcloud_daemon\.py" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "stopped old Python daemon $($_.ProcessId)" }
Get-Process rime-gcloud -ErrorAction SilentlyContinue |
    ForEach-Object { Stop-Process -Id $_.Id -Force; Write-Host "stopped daemon $($_.Id)" }
Start-Sleep -Milliseconds 300
if (Test-Path $programDir) { Remove-Item $programDir -Recurse -Force; Write-Host "removed $programDir" }

$lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Rime Google Cantonese.lnk"
if (Test-Path $lnk) { Remove-Item $lnk; Write-Host "autostart removed" }

Get-ChildItem $rime -Filter "*.custom.yaml" | ForEach-Object {
    if ([System.IO.File]::ReadAllText($_.FullName, $utf8) -match $marker) { Remove-Item $_.FullName; Write-Host "removed $($_.Name)" }
}

$yale = Join-Path $rime "jyut6ping3_yale.schema.yaml"
if ((Test-Path $yale) -and ([System.IO.File]::ReadAllText($yale, $utf8) -match $marker)) {
    Remove-Item $yale
    Write-Host "removed jyut6ping3_yale.schema.yaml"
    $dc = Join-Path $rime "default.custom.yaml"
    if (Test-Path $dc) {
        $text = [System.IO.File]::ReadAllText($dc, $utf8)
        $clean = [regex]::Replace($text, '(?m)^[ \t]*-[ \t]*\{?[ \t]*schema:[ \t]*jyut6ping3_yale[ \t]*\}?[ \t]*\r?\n', '')
        if ($clean -ne $text) {
            Copy-Item $dc ("$dc.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
            [System.IO.File]::WriteAllText($dc, $clean, $utf8)
            Write-Host "default.custom.yaml: removed jyut6ping3_yale from schema_list"
        }
    }
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
if ($Interactive -and $msg.ContainsKey("uninstall_done")) { Write-Host ""; Write-Host $msg["uninstall_done"]; if ($msg.ContainsKey("uninstall_done_en")) { Write-Host $msg["uninstall_done_en"] -ForegroundColor DarkGray } }
