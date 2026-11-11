# Collect a diagnostics report for rime-google-cantonese testers.
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#   diagnose.cmd   double-click: writes rime-google-cantonese-report.txt to the Desktop
# The report contains versions, settings, file checks and recent log lines. It does not
# include anything you typed; your Windows user name and PC name are replaced by placeholders.
param([switch]$Interactive)
$ErrorActionPreference = "Continue"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$utf8 = New-Object System.Text.UTF8Encoding $false
$rime = Join-Path $env:APPDATA "Rime"
$customDir = (Get-ItemProperty "HKCU:\Software\Rime\Weasel" -ErrorAction SilentlyContinue).RimeUserDir
if ($customDir) { $rime = [Environment]::ExpandEnvironmentVariables($customDir) }
$programDir = Join-Path $env:LOCALAPPDATA "Programs\rime-google-cantonese"
$exe = Join-Path $programDir "rime-gcloud.exe"
$app = Join-Path $rime "gcloud"
$out = New-Object System.Collections.Generic.List[string]

function Add([string]$s) { $out.Add($s) }
function Section([string]$s) { $out.Add(""); $out.Add("== " + $s) }
function Tail([string]$path, [int]$n) {
    if (Test-Path $path) { Get-Content $path -Encoding UTF8 -Tail $n | ForEach-Object { Add ("  " + $_) } }
    else { Add "  (missing) $path" }
}

Section "System"
$os = Get-CimInstance Win32_OperatingSystem
Add ("Windows: " + $os.Caption + " " + $os.Version + " (" + $os.OSArchitecture + ")")
$net = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full" -ErrorAction SilentlyContinue).Release
Add (".NET Framework release: " + $net)
Add ("csc.exe: " + (Test-Path (Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319\csc.exe")))
Add ("Report time: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss zzz"))

Section "Weasel"
$root = $null
foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel", "HKLM:\SOFTWARE\Rime\Weasel")) {
    if (Test-Path $k) { $r = (Get-ItemProperty $k).WeaselRoot; if ($r) { $root = $r; Add ("registry: " + $k); break } }
}
if ($root) {
    Add ("root: " + $root)
    $server = Join-Path $root "WeaselServer.exe"
    if (Test-Path $server) { Add ("version: " + (Get-Item $server).VersionInfo.ProductVersion) }
    Add ("WeaselServer running: " + [bool](Get-Process WeaselServer -ErrorAction SilentlyContinue))
} else { Add "Weasel not found in registry" }
Add ("user folder: " + $rime + $(if ($customDir) { " (custom)" } else { "" }))

Section "Schemas"
foreach ($id in @("jyut6ping3", "jyut6ping3_yale", "loengfan", "luna_pinyin", "stroke", "cangjie5")) {
    $u = Test-Path (Join-Path $rime "$id.schema.yaml")
    $s = $root -and (Test-Path (Join-Path $root "data\$id.schema.yaml"))
    $b = Test-Path (Join-Path $rime "build\$id.schema.yaml")
    Add ("{0,-16} user={1,-5} shared={2,-5} built={3}" -f $id, $u, $s, $b)
}
$dc = Join-Path $rime "default.custom.yaml"
if (Test-Path $dc) {
    Add "default.custom.yaml schema_list:"
    Get-Content $dc -Encoding UTF8 | Where-Object { $_ -match "schema" } | ForEach-Object { Add ("  " + $_.Trim()) }
} else { Add "default.custom.yaml: (none)" }

Section "Plugin files"
Add ("lua\gcloud.lua: " + (Test-Path (Join-Path $rime "lua\gcloud.lua")))
$rl = Join-Path $rime "rime.lua"
Add ("rime.lua registers plugin: " + ((Test-Path $rl) -and ((Get-Content $rl -Raw -Encoding UTF8) -match "gcloud_slot_filter")))
$cy = Join-Path $rime "jyut6ping3.custom.yaml"
if (Test-Path $cy) {
    Get-Content $cy -Encoding UTF8 | Where-Object { $_ -match "^\s+(mode|prefetch|engine):|menu/page_size" } |
        ForEach-Object { Add ("  " + ($_ -replace "\s+#.*$", "").Trim()) }
} else { Add "jyut6ping3.custom.yaml: (missing)" }
$built = Join-Path $rime "build\jyut6ping3.schema.yaml"
if (Test-Path $built) {
    $bt = Get-Content $built -Raw -Encoding UTF8
    Add ("built schema has lua components: translator=" + ($bt -match "gcloud_translator") + " processor=" + ($bt -match "gcloud_processor") +
         " filter=" + ($bt -match "gcloud_filter") + " slot_filter=" + ($bt -match "gcloud_slot_filter"))
}

Section "Background program"
Add ("exe: " + (Test-Path $exe))
$p = Get-Process rime-gcloud -ErrorAction SilentlyContinue
Add ("running: " + [bool]$p + $(if ($p) { " (since " + $p[0].StartTime + ", " + [math]::Round($p[0].WorkingSet64 / 1MB, 1) + " MB)" } else { "" }))
$hb = Join-Path $app "heartbeat.txt"
if (Test-Path $hb) {
    $t = [long](Get-Content $hb -TotalCount 1)
    Add ("heartbeat age: " + ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - $t) + " s (under 8 s is healthy)")
}
$lnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Rime Google Cantonese.lnk"
if (Test-Path $lnk) { Add ("autostart -> " + (New-Object -ComObject WScript.Shell).CreateShortcut($lnk).TargetPath) } else { Add "autostart: (none)" }
if (Test-Path $exe) {
    $tmp = Join-Path $env:TEMP "rgc-diagnose.txt"
    Start-Process -FilePath $exe -ArgumentList "--once", "nei", "--out", "`"$tmp`"" -Wait -WindowStyle Hidden
    if (Test-Path $tmp) {
        $lines = Get-Content $tmp -Encoding UTF8
        Add ("Google test (nei): " + $lines[0] + ", " + ($lines.Count - 1) + " candidates" + $(if ($lines.Count -gt 1) { ", first: " + ($lines[1] -split "`t")[1] } else { "" }))
        Remove-Item $tmp -Force
    }
}
Add "daemon.log (last 15 lines):"
Tail (Join-Path $app "daemon.log") 15

Section "Rime logs"
$logs = Get-ChildItem $env:TEMP -Filter "rime.weasel.*" -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending
$err = $logs | Where-Object { $_.Name -match "\.log\.(ERROR|WARNING)\." } | Select-Object -First 1
if ($err) { Add ("latest " + $err.Name + " (last 20 lines):"); Tail $err.FullName 20 } else { Add "no ERROR/WARNING log" }
$info = $logs | Where-Object { $_.Name -match "\.log\.INFO\." } | Select-Object -First 1
if ($info) {
    Add ("lua / gcloud / deploy lines in " + $info.Name + ":")
    Get-Content $info.FullName -Encoding UTF8 | Where-Object { $_ -match "lua|gcloud|finished updating|error" } |
        Select-Object -Last 20 | ForEach-Object { Add ("  " + $_) }
}

# Privacy: hide the Windows user name, profile path and PC name.
$text = ($out -join "`r`n")
$text = $text.Replace($env:USERPROFILE, "%USERPROFILE%").Replace($env:USERNAME, "<user>").Replace($env:COMPUTERNAME, "<pc>")
$report = Join-Path ([Environment]::GetFolderPath("Desktop")) "rime-google-cantonese-report.txt"
[System.IO.File]::WriteAllText($report, "rime-google-cantonese diagnostics`r`n" + $text + "`r`n", $utf8)
Write-Host $text
Write-Host ""
Write-Host ("Report saved: " + $report)
if ($Interactive) {
    $msgFile = Join-Path $here "setup\messages.txt"
    if (Test-Path $msgFile) {
        foreach ($line in [System.IO.File]::ReadAllLines($msgFile, $utf8)) {
            if ($line -match '^diag_done(_en)?=(.*)$') { Write-Host ""; Write-Host $Matches[2] }
        }
    }
}
