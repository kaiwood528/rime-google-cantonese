# Install Google Cantonese cloud candidates into Weasel (Rime).
# Keep this file ASCII-only: Windows PowerShell 5.1 reads BOM-less scripts as ANSI.
# User-facing Chinese text lives in setup\messages.txt (read as UTF-8).
#
#   setup.cmd                                 double-click: asks a few questions, then installs
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Interactive    same as setup.cmd
#   powershell -ExecutionPolicy Bypass -File install.ps1 -Mode rime_first -Autostart
#     -Mode rime_first | rime_slot | cloud_first | cloud_only (applies to every schema installed
#           in this run). Without -Mode an existing install keeps its mode; a new install uses
#           rime\schema.custom.yaml. rime_slot also sets menu/page_size to 6.
#     -Yale             also install the Yale schema (jyut6ping3_yale)
#     -AddToSchemaList  put the schema(s) at the top of schema_list in default.custom.yaml
#     -Autostart        start the background program at login
#     -NoDeploy         do not redeploy Weasel
#
# jyut6ping3_ipa does "__include: jyut6ping3.schema:/" and Rime auto-patches the included
# resource, so jyut6ping3.custom.yaml already covers it. Do NOT add jyut6ping3_ipa here,
# or the Lua components would be inserted twice.
param(
    [string[]]$Schemas = @("jyut6ping3"),
    [switch]$Interactive,
    [switch]$Autostart,
    [switch]$Yale,
    [ValidateSet("", "rime_first", "rime_slot", "cloud_first", "cloud_only")]
    [string]$Mode = "",
    [switch]$AddToSchemaList,
    [switch]$NoDeploy
)
$ErrorActionPreference = "Stop"
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$rime = Join-Path $env:APPDATA "Rime"
$utf8 = New-Object System.Text.UTF8Encoding $false
$marker = "rime-google-cantonese"
$programDir = Join-Path $env:LOCALAPPDATA "Programs\rime-google-cantonese"
$exe = Join-Path $programDir "rime-gcloud.exe"
$startupLnk = Join-Path ([Environment]::GetFolderPath("Startup")) "Rime Google Cantonese.lnk"

# ------------------------------------------------------------------ helpers

$msg = @{}
$msgFile = Join-Path $here "setup\messages.txt"
if (Test-Path $msgFile) {
    foreach ($line in [System.IO.File]::ReadAllLines($msgFile, $utf8)) {
        if ($line -match '^([a-z0-9_]+)=(.*)$') { $msg[$Matches[1]] = $Matches[2] }
    }
}
function T([string]$key) { if ($msg.ContainsKey($key)) { return $msg[$key] } return $key }

function Ask-YesNo([string]$key) {
    $a = Read-Host (T $key)
    return ($a -eq "" -or $a -match '^[Yy]')
}

function Ask-Choice([string]$question, [string[]]$options) {
    Write-Host ""
    Write-Host (T $question)
    foreach ($o in $options) { Write-Host (T $o) }
    while ($true) {
        $a = Read-Host (T "choice")
        $n = 0
        if ([int]::TryParse($a, [ref]$n) -and $n -ge 1 -and $n -le $options.Count) { return $n }
    }
}

function Get-WeaselRoot {
    foreach ($k in @("HKLM:\SOFTWARE\WOW6432Node\Rime\Weasel", "HKLM:\SOFTWARE\Rime\Weasel")) {
        if (Test-Path $k) {
            $r = (Get-ItemProperty $k).WeaselRoot
            if ($r -and (Test-Path $r)) { return $r }
        }
    }
    return $null
}

function Test-Schema([string]$id) {
    return (Test-Path (Join-Path $rime "$id.schema.yaml")) -or
           (Test-Path (Join-Path $script:root "data\$id.schema.yaml"))
}

# Weasel's own default schema list, so a new default.custom.yaml does not hide the others.
function Get-DefaultSchemaIds {
    $ids = @()
    $d = Join-Path $script:root "data\default.yaml"
    if (-not (Test-Path $d)) { return $ids }
    $t = [System.IO.File]::ReadAllText($d, $utf8)
    $m = [regex]::Match($t, '(?ms)^schema_list:[ \t]*\r?\n(.*?)(?=^\S|\z)')
    if ($m.Success) {
        foreach ($x in [regex]::Matches($m.Groups[1].Value, '-\s*\{?\s*schema:\s*([A-Za-z0-9_]+)')) { $ids += $x.Groups[1].Value }
    }
    return $ids
}

function Add-SchemaToList([string]$id) {
    $dc = Join-Path $rime "default.custom.yaml"
    $entry = "- {schema: $id}"
    if (-not (Test-Path $dc)) {
        $ids = @($id) + @(Get-DefaultSchemaIds | Where-Object { $_ -ne $id })
        $text = "patch:`n  schema_list:`n" + (($ids | ForEach-Object { "    - {schema: $_}`n" }) -join "")
        [System.IO.File]::WriteAllText($dc, $text, $utf8)
        Write-Host "default.custom.yaml created ($id first)"
        return
    }
    $text = [System.IO.File]::ReadAllText($dc, $utf8)
    if ($text -match ('(?m)^\s*-\s*\{?\s*schema:\s*' + [regex]::Escape($id) + '\s*\}?\s*$')) {
        Write-Host "schema_list already contains $id"
        return
    }
    $backup = "$dc.bak-" + (Get-Date -Format "yyyyMMdd-HHmmss")
    $re = New-Object System.Text.RegularExpressions.Regex('(?m)^([ \t]*schema_list:[ \t]*)(\r?\n)([ \t]*)-')
    if ($re.IsMatch($text)) {
        $eval = [System.Text.RegularExpressions.MatchEvaluator] {
            param($mm)
            $mm.Groups[1].Value + $mm.Groups[2].Value + $mm.Groups[3].Value + $entry + $mm.Groups[2].Value + $mm.Groups[3].Value + "-"
        }
        Copy-Item $dc $backup
        [System.IO.File]::WriteAllText($dc, $re.Replace($text, $eval, 1), $utf8)
        Write-Host "schema_list: added $id at the top (backup $(Split-Path -Leaf $backup))"
    } elseif ($text -match '(?m)^patch:[ \t]*$' -and $text -notmatch 'schema_list') {
        $ids = @($id) + @(Get-DefaultSchemaIds | Where-Object { $_ -ne $id })
        $block = "patch:`n  schema_list:`n" + (($ids | ForEach-Object { "    - {schema: $_}`n" }) -join "")
        Copy-Item $dc $backup
        [System.IO.File]::WriteAllText($dc, ([regex]'(?m)^patch:[ \t]*\r?\n').Replace($text, $block, 1), $utf8)
        Write-Host "schema_list: created with $id first (backup $(Split-Path -Leaf $backup))"
    } else {
        Write-Warning "Could not add $id to schema_list automatically; tick it in Weasel settings."
    }
}

function Stop-Daemons {
    Get-CimInstance Win32_Process -Filter "Name like 'python%'" |
        Where-Object { $_.CommandLine -match "gcloud_daemon\.py" } |
        ForEach-Object { Stop-Process -Id $_.ProcessId -Force; Write-Host "stopped old Python daemon $($_.ProcessId)" }
    Get-Process rime-gcloud -ErrorAction SilentlyContinue |
        ForEach-Object { Stop-Process -Id $_.Id -Force; Write-Host "stopped daemon $($_.Id)" }
    Start-Sleep -Milliseconds 300
}

# ------------------------------------------------------------------ main

try {
    if ($Interactive) { Write-Host ""; Write-Host (T "title"); Write-Host "" }

    # Files from a downloaded ZIP carry the "from the internet" mark; drop it for our own files.
    try { Get-ChildItem $here -Recurse -File | Unblock-File } catch { }

    # 0a. Weasel
    $script:root = Get-WeaselRoot
    if (-not $script:root) {
        if ($Interactive) {
            Write-Host (T "weasel_missing")
            if ((Get-Command winget -ErrorAction SilentlyContinue) -and (Ask-YesNo "weasel_ask")) {
                & winget install --id Rime.Weasel -e --source winget --accept-package-agreements --accept-source-agreements
                $script:root = Get-WeaselRoot
            }
        }
        if (-not $script:root) { throw (T "weasel_manual") }
    }
    $root = $script:root
    $weaselVersion = (Get-Item (Join-Path $root "WeaselServer.exe")).VersionInfo.ProductVersion
    Write-Host ((T "weasel_version") -f $weaselVersion)
    New-Item -ItemType Directory -Force $rime | Out-Null

    # 0b. The plugin patches the Cantonese schema from rime-cantonese, which Weasel does not bundle.
    if (-not (Test-Schema "jyut6ping3")) {
        if ($Interactive) {
            Write-Host (T "schema_missing")
            if (Ask-YesNo "schema_ask") {
                Write-Host (T "schema_installing")
                $pkgs = @("rime/rime-cantonese", "CanCLID/rime-loengfan")
                foreach ($dep in @(@("luna_pinyin", "rime/rime-luna-pinyin"), @("stroke", "rime/rime-stroke"), @("cangjie5", "rime/rime-cangjie"))) {
                    if (-not (Test-Schema $dep[0])) { $pkgs += $dep[1] }
                }
                # Weasel ships this downloader (curl + 7z); it copies the files into the Rime user folder.
                & (Join-Path $root "rime-install.bat") @pkgs
            }
        }
        if (-not (Test-Schema "jyut6ping3")) { throw (T "schema_manual") }
    }

    # 0c. Questions
    if ($Interactive) {
        $Yale = ((Ask-Choice "q_scheme" @("scheme_1", "scheme_2")) -eq 2)
        Write-Host ""
        Write-Host (T "privacy")
        $Mode = @("rime_first", "rime_slot", "cloud_only")[(Ask-Choice "q_mode" @("mode_1", "mode_2", "mode_3")) - 1]
        $Autostart = $true
        $AddToSchemaList = $true
        Write-Host ""
        Write-Host (T "installing")
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
            $evalLua = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $snippet }
            $updated = [regex]::Replace($current, $block, $evalLua)
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
    $effective = ""
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

    # 4. Build and (re)start the background program. It is compiled here with the C# compiler
    #    that ships with .NET Framework 4.x, so users need no Python and get no downloaded .exe.
    Stop-Daemons
    $fw = Join-Path $env:WINDIR "Microsoft.NET\Framework64\v4.0.30319"
    if (-not (Test-Path (Join-Path $fw "csc.exe"))) { $fw = Join-Path $env:WINDIR "Microsoft.NET\Framework\v4.0.30319" }
    $csc = Join-Path $fw "csc.exe"
    if (-not (Test-Path $csc)) { throw "csc.exe (.NET Framework 4.x) not found." }
    New-Item -ItemType Directory -Force $programDir | Out-Null
    $cscOut = & $csc /nologo /target:winexe /optimize+ /codepage:65001 "/out:$exe" `
        "/r:$fw\System.Net.Http.dll" "/r:$fw\System.Web.Extensions.dll" (Join-Path $here "daemon\RimeGcloud.cs")
    if ($LASTEXITCODE -ne 0) {
        $cscOut | ForEach-Object { Write-Host $_ }
        throw "Compiling the background program failed."
    }
    Write-Host "built $exe"
    Start-Process -FilePath $exe -WorkingDirectory $programDir
    Write-Host "background program started"

    # 5. Start at login. An existing shortcut is always refreshed: older versions pointed it at
    #    the Python daemon.
    if ($Autostart -or (Test-Path $startupLnk)) {
        $shell = New-Object -ComObject WScript.Shell
        $sc = $shell.CreateShortcut($startupLnk)
        $sc.TargetPath = $exe
        $sc.Arguments = ""
        $sc.WorkingDirectory = $programDir
        $sc.WindowStyle = 7
        $sc.Description = "rime-google-cantonese background program"
        $sc.Save()
        Write-Host "autostart shortcut: $startupLnk"
    }

    # 5b. Make the chosen schema the first one in the schema list
    if ($AddToSchemaList) {
        Add-SchemaToList "jyut6ping3"
        if ($Yale) { Add-SchemaToList "jyut6ping3_yale" }
    }

    # 6. Redeploy Weasel
    if (-not $NoDeploy) {
        # Start-Process (ShellExecute) opens the settings dialog instead of deploying on
        # Weasel 0.15, so launch it directly with UseShellExecute = false.
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

    if ($Interactive) {
        Write-Host ""
        Write-Host (T "done")
        Write-Host (T ("done_" + $Mode))
        $schemaKey = if ($Yale) { "name_yale" } else { "name_jyutping" }
        Write-Host ((T "done_switch") -f (T $schemaKey))
    }
} catch {
    if ($Interactive) {
        Write-Host ""
        Write-Host ((T "failed") + $_.Exception.Message) -ForegroundColor Red
        exit 1
    }
    throw
}
