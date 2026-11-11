# Install Google Cantonese cloud candidates into Weasel (Rime).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
#   powershell -ExecutionPolicy Bypass -File install.ps1              install/update and redeploy
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Autostart   also start the daemon at login
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Yale        also install the Yale schema
#     (jyut6ping3_yale; add {schema: jyut6ping3_yale} to schema_list in default.custom.yaml)
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Mode rime_first
#     rime_first | rime_slot | cloud_first | cloud_only; applies to every schema installed in this run.
#     Without -Mode an existing install keeps its current mode; a new install uses rime\*.yaml.
#     rime_slot also sets menu/page_size to 6 (slot 6 = Google's first candidate).
# jyut6ping3_ipa does "__include: jyut6ping3.schema:/" and Rime auto-patches the included
# resource, so jyut6ping3.custom.yaml already covers it. Do NOT add jyut6ping3_ipa here,
# or the Lua components would be inserted twice.
param(
    [string[]]$Schemas = @("jyut6ping3"),
    [switch]$Autostart,
    [switch]$Yale,
    [ValidateSet("", "rime_first", "rime_slot", "cloud_first", "cloud_only")]
    [string]$Mode = "",
    [switch]$NoDeploy
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rime = Join-Path $env:APPDATA "Rime"
$utf8 = New-Object System.Text.UTF8Encoding $false
$marker = "rime-google-cantonese"
if (-not (Test-Path $rime)) { throw "Rime user folder not found: $rime" }

$root = $null
foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel", "HKLM:\SOFTWARE\Rime\Weasel")) {
    if (Test-Path $k) { $root = (Get-ItemProperty $k).WeaselRoot; if ($root) { break } }
}
if (-not $root) { throw "Weasel install folder not found in registry; install Weasel first." }

# The plugin patches the Cantonese schema from rime-cantonese, which Weasel does not bundle.
$haveSchema = (Test-Path (Join-Path $rime "jyut6ping3.schema.yaml")) -or
              (Test-Path (Join-Path $root "data\jyut6ping3.schema.yaml"))
if (-not $haveSchema) {
    throw "jyut6ping3.schema.yaml not found. Install rime-cantonese first (Weasel settings > get more schemas > rime/rime-cantonese)."
}

# 1. Lua module
New-Item -ItemType Directory -Force (Join-Path $rime "lua") | Out-Null
Copy-Item (Join-Path $here "rime\lua\gcloud.lua") (Join-Path $rime "lua\gcloud.lua") -Force
Write-Host "lua\gcloud.lua copied"

# 2. rime.lua registers the components
$rimeLua = Join-Path $rime "rime.lua"
$snippet = [System.IO.File]::ReadAllText((Join-Path $here "rime\rime.lua.snippet"), $utf8)
if (Test-Path $rimeLua) {
    $current = [System.IO.File]::ReadAllText($rimeLua, $utf8)
    $block = "(?s)-- rime-google-cantonese \(begin\).*?-- rime-google-cantonese \(end\)\r?\n?"
    if ($current -notmatch $marker) {
        [System.IO.File]::AppendAllText($rimeLua, "`n" + $snippet, $utf8)
        Write-Host "rime.lua: snippet appended"
    } elseif ($current -match $block) {
        # Refresh our block so newly added components get registered.
        $eval = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $snippet }
        $updated = [regex]::Replace($current, $block, $eval)
        if ($updated -ne $current) {
            [System.IO.File]::WriteAllText($rimeLua, $updated, $utf8)
            Write-Host "rime.lua: block updated"
        } else { Write-Host "rime.lua: already up to date" }
    } else { Write-Warning "rime.lua mentions $marker but has no begin/end block; check it by hand." }
} else {
    [System.IO.File]::WriteAllText($rimeLua, $snippet, $utf8)
    Write-Host "rime.lua created"
}

# 3. Schema patches
$template = [System.IO.File]::ReadAllText((Join-Path $here "rime\schema.custom.yaml"), $utf8)
$modeLine = "(?m)^(\s+mode:\s*)(\S+)"
foreach ($s in $Schemas) {
    $dst = Join-Path $rime "$s.custom.yaml"
    $existing = $null
    if (Test-Path $dst) {
        $existing = [System.IO.File]::ReadAllText($dst, $utf8)
        if ($existing -notmatch $marker) {
            Write-Warning "$dst exists and is not ours; merge rime\schema.custom.yaml into it by hand."
            continue
        }
    }
    # -Mode wins; otherwise keep the mode already installed; otherwise the template default.
    $text = $template
    $useMode = $Mode
    if (-not $useMode -and $existing) {
        $m = [regex]::Match($existing, $modeLine)
        if ($m.Success) { $useMode = $m.Groups[2].Value }
    }
    if ($useMode) { $text = [regex]::Replace($text, $modeLine, "`${1}$useMode") }
    $effective = [regex]::Match($text, $modeLine).Groups[2].Value
    if ($effective -eq "rime_slot") {
        # Enable the commented-out page size line: 6 candidates, the 6th is Google's.
        $text = [regex]::Replace($text, '(?m)^(\s*)#\s*("menu/page_size":)', '$1$2')
    }
    [System.IO.File]::WriteAllText($dst, $text, $utf8)
    Write-Host "$s.custom.yaml written (mode $effective)"
}

# 3b. Optional Yale schema (includes jyut6ping3, so it inherits the patch above)
$yaleDst = Join-Path $rime "jyut6ping3_yale.schema.yaml"
if ($Yale -or ((Test-Path $yaleDst) -and ([System.IO.File]::ReadAllText($yaleDst, $utf8) -match $marker))) {
    $yaleText = [System.IO.File]::ReadAllText((Join-Path $here "rime\jyut6ping3_yale.schema.yaml"), $utf8)
    if ($Mode) { $yaleText = [regex]::Replace($yaleText, "(?m)^(\s+gcloud/mode:\s*)\S+", "`${1}$Mode") }
    [System.IO.File]::WriteAllText($yaleDst, $yaleText, $utf8)
    Write-Host "jyut6ping3_yale.schema.yaml written"
}

# 4. (Re)start the background daemon
$daemon = Join-Path $here "daemon\gcloud_daemon.py"
$pythonw = (Get-Command pythonw -ErrorAction SilentlyContinue).Source
if (-not $pythonw) { throw "pythonw.exe not found; install Python 3 first." }
Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
    Where-Object { $_.CommandLine -match "gcloud_daemon\.py" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "stopped old daemon $($_.ProcessId)" }
Start-Process -FilePath $pythonw -ArgumentList "`"$daemon`"" -WindowStyle Hidden
Write-Host "daemon started"

# 5. Optional: start the daemon at login
if ($Autostart) {
    $startup = [Environment]::GetFolderPath("Startup")
    $lnk = Join-Path $startup "Rime Google Cantonese.lnk"
    $shell = New-Object -ComObject WScript.Shell
    $sc = $shell.CreateShortcut($lnk)
    $sc.TargetPath = $pythonw
    $sc.Arguments = "`"$daemon`""
    $sc.WorkingDirectory = Split-Path $daemon
    $sc.WindowStyle = 7
    $sc.Save()
    Write-Host "autostart shortcut: $lnk"
}

# 6. Redeploy Weasel
if (-not $NoDeploy) {
    # Start-Process (ShellExecute) opens the settings dialog instead of deploying on this
    # Weasel build, so launch it directly with UseShellExecute = false.
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
    if ($proc.ExitCode -ne 0) { throw "WeaselDeployer /deploy failed with exit code $($proc.ExitCode)" }
    Write-Host "Weasel redeployed"
}
