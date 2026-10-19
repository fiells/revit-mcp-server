#Requires -Version 5.1
<#
.SYNOPSIS
    Check and auto-fix all prerequisites for mcp-servers-for-revit + Claude Desktop.

.DESCRIPTION
    Run this once on any machine where "Revit MCP" does not appear in Claude.
    The script checks every component and fixes what it can automatically.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File .\fix-mcp.ps1

.EXAMPLE
    powershell -ExecutionPolicy Bypass -Command "irm https://raw.githubusercontent.com/fiells/revit-mcp-server/main/scripts/fix-mcp.ps1 | iex"
#>

$ErrorActionPreference = 'Continue'
$ProgressPreference    = 'SilentlyContinue'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# -- Load shared module --------------------------------------------------------
$_commonPath = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'common.ps1' } else { $null }
if ($_commonPath -and (Test-Path $_commonPath)) {
    . $_commonPath
} else {
    # Inline fallback for irm | iex usage
    $REPO          = 'fiells/revit-mcp-server'
    $PLUGIN_NAME   = 'mcp-servers-for-revit'
    $PLUGIN_FOLDER = 'revit_mcp_plugin'
    $NPM_PACKAGE   = 'mcp-server-for-revit'
    $ADDIN_FILE    = "$PLUGIN_NAME.addin"
    $MIN_NODE      = 18
    $REVIT_YEARS   = 2019..2027
    $MCP_HOST      = '127.0.0.1'
    $MCP_PORT      = 8080
    function Get-NodePath {
        $sysNode = Get-Command node -ErrorAction SilentlyContinue
        if ($sysNode) { return $sysNode.Source }
        foreach ($year in ($REVIT_YEARS | Sort-Object -Descending)) {
            $p = "$env:APPDATA\Autodesk\Revit\Addins\$year\$PLUGIN_FOLDER\Commands\RevitMCPCommandSet\server\runtime\node.exe"
            if (Test-Path $p) { return $p }
        }
        return $null
    }
    function Get-NodeStatus {
        $result = [PSCustomObject]@{
            Available = $false; Version = $null; Major = 0
            Path = $null; MeetsMinimum = $false; IsBundled = $false
        }
        $nodePath = Get-NodePath
        if ($nodePath) {
            $result.Available = $true
            $result.Path      = $nodePath
            $result.IsBundled = -not [bool](Get-Command node -ErrorAction SilentlyContinue)
            $result.Version   = (& "$nodePath" --version 2>$null).TrimStart('v')
            $result.Major     = [int](($result.Version -split '\.')[0])
            $result.MeetsMinimum = $result.Major -ge $MIN_NODE
        }
        return $result
    }
    function Get-McpServerPath {
        # Prefer the newest Revit that is actually installed: when it starts, the plugin
        # writes its own server path, so using the same one avoids rewriting the config.
        $years     = @($REVIT_YEARS | Sort-Object -Descending)
        $installed = @($years | Where-Object {
            (Test-Path "C:\Program Files\Autodesk\Revit $_\Revit.exe") -or
            (Test-Path "HKLM:\SOFTWARE\Autodesk\Revit\Autodesk Revit $_") -or
            (Test-Path "HKLM:\SOFTWARE\WOW6432Node\Autodesk\Revit\Autodesk Revit $_")
        })
        foreach ($year in ($installed + $years)) {
            $serverJs = "$env:APPDATA\Autodesk\Revit\Addins\$year\$PLUGIN_FOLDER\Commands\RevitMCPCommandSet\server\build\index.js"
            if (Test-Path $serverJs) { return $serverJs }
        }
        return $null
    }
    function New-RevitMcpEntry {
        param([string]$ServerPath)
        # Prefer the portable node.exe shipped next to the server, as the plugin does,
        # so the scripts and the plugin write the same entry.
        $bundledNode = Join-Path (Split-Path (Split-Path $ServerPath)) 'runtime\node.exe'
        $nodePath = if (Test-Path $bundledNode) { $bundledNode } else { Get-NodePath }
        if ($nodePath) {
            return [PSCustomObject]@{ command = $nodePath; args = @($ServerPath) }
        }
        # Last resort: rely on node in PATH via cmd shell
        return [PSCustomObject]@{ command = 'cmd'; args = @('/c', 'node', $ServerPath) }
    }
    function Get-ClaudeDesktopCandidates {
        $candidates = @()
        $candidates += @(Get-ChildItem "$env:LOCALAPPDATA\Claude-Data" -Directory -Filter 'claude_*' -ErrorAction SilentlyContinue |
            ForEach-Object { $_.FullName })
        $candidates += @(Get-ChildItem "$env:LOCALAPPDATA\Packages" -Directory -Filter 'Claude_*' -ErrorAction SilentlyContinue |
            ForEach-Object { "$($_.FullName)\LocalCache\Roaming\Claude" })
        $candidates += "$env:APPDATA\Claude"
        return $candidates
    }
    function Get-ClaudeDesktopDirs {
        return @(Get-ClaudeDesktopCandidates | Where-Object { $_ -and (Test-Path $_) })
    }
    function Get-ClaudeDesktopDir {
        $dirs = @(Get-ClaudeDesktopDirs)
        if ($dirs.Count -gt 0) { return $dirs[0] }
        return $null
    }
    function Get-ClaudeDesktopConfig {
        param([string]$ClaudeDir)
        $configPath = "$ClaudeDir\claude_desktop_config.json"
        $result = [PSCustomObject]@{
            Exists = $false; Path = $configPath; Config = $null
            HasRevitMcp = $false; RevitMcpEntry = $null
        }
        if (Test-Path $configPath) {
            $result.Exists = $true
            try {
                $result.Config = Get-Content $configPath -Raw | ConvertFrom-Json
                if ($result.Config.mcpServers -and $result.Config.mcpServers.'revit-mcp') {
                    $result.HasRevitMcp   = $true
                    $result.RevitMcpEntry = $result.Config.mcpServers.'revit-mcp'
                }
            } catch {}
        }
        return $result
    }
    function Set-ClaudeDesktopMcpEntry {
        param([string]$ClaudeDir, [object]$Entry)
        $cfgInfo = Get-ClaudeDesktopConfig $ClaudeDir
        if ($cfgInfo.HasRevitMcp -and
            $cfgInfo.RevitMcpEntry.command -eq $Entry.command -and
            (@($cfgInfo.RevitMcpEntry.args) -join ' ') -eq (@($Entry.args) -join ' ')) {
            return 'unchanged'
        }
        if ($cfgInfo.Exists) {
            Copy-Item $cfgInfo.Path "$($cfgInfo.Path).$(Get-Date -Format 'yyyyMMdd_HHmmss').bak" -Force
        }
        $config = if ($null -ne $cfgInfo.Config) { $cfgInfo.Config } else { [PSCustomObject]@{} }
        if ($null -eq $config.mcpServers) {
            $config | Add-Member -NotePropertyName 'mcpServers' -NotePropertyValue ([PSCustomObject]@{}) -Force
        }
        $config.mcpServers | Add-Member -NotePropertyName 'revit-mcp' -NotePropertyValue $Entry -Force
        New-Item -ItemType Directory -Path $ClaudeDir -Force | Out-Null
        # UTF-8 without BOM: Set-Content -Encoding UTF8 in Windows PowerShell 5.1 adds a BOM,
        # which Node-based readers such as Claude Desktop can fail to parse.
        $json = $config | ConvertTo-Json -Depth 10
        $filePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($cfgInfo.Path)
        [System.IO.File]::WriteAllText($filePath, $json, (New-Object System.Text.UTF8Encoding $false))
        if (-not $cfgInfo.Exists) { return 'created' }
        if ($null -eq $cfgInfo.Config) { return 'recreated' }
        return 'updated'
    }
    function Test-RevitInstalled {
        param([int]$Year)
        $addinsDir = "$env:APPDATA\Autodesk\Revit\Addins\$Year"
        $regPaths  = @(
            "HKLM:\SOFTWARE\Autodesk\Revit\Autodesk Revit $Year",
            "HKLM:\SOFTWARE\WOW6432Node\Autodesk\Revit\Autodesk Revit $Year"
        )
        $exePath   = "C:\Program Files\Autodesk\Revit $Year\Revit.exe"
        $inReg     = ($regPaths | Where-Object { Test-Path $_ }).Count -gt 0
        $inExe     = Test-Path $exePath
        $inAddins  = Test-Path $addinsDir
        return ($inReg -or $inExe -or $inAddins)
    }
}

$pass = 0; $fail = 0; $fixed = 0

function OK    { param([string]$m) Write-Host "  [OK]    $m" -ForegroundColor Green;  $script:pass++ }
function FAIL  { param([string]$m) Write-Host "  [FAIL]  $m" -ForegroundColor Red;    $script:fail++ }
function FIXED { param([string]$m) Write-Host "  [FIXED] $m" -ForegroundColor Cyan;   $script:fixed++ }
function WARN  { param([string]$m) Write-Host "  [WARN]  $m" -ForegroundColor Yellow }
function INFO  { param([string]$m) Write-Host "          $m" -ForegroundColor Gray }
function HEAD  { param([string]$m) Write-Host "`n  -- $m" -ForegroundColor White }

Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   revit-mcp  --  Check & Fix"                                   -ForegroundColor Cyan
Write-Host "   $env:COMPUTERNAME  /  $env:USERNAME  /  $(Get-Date -f 'yyyy-MM-dd HH:mm')" -ForegroundColor DarkCyan
Write-Host "  ============================================================" -ForegroundColor Cyan


# ── 1. Node.js ───────────────────────────────────────────────────────────────
HEAD "1. Node.js"
$nodeStatus = Get-NodeStatus
if ($nodeStatus.Available) {
    if ($nodeStatus.MeetsMinimum) {
        if ($nodeStatus.IsBundled) {
            OK "Node.js $($nodeStatus.Version)  (bundled portable runtime — $($nodeStatus.Path))"
        } else {
            OK "Node.js $($nodeStatus.Version)  ($($nodeStatus.Path))"
        }
        $nodeOk = $true
    } else {
        FAIL "Node.js $($nodeStatus.Version) found but v18+ required -- install from https://nodejs.org"
        $nodeOk = $false
    }
} else {
    FAIL "Node.js not found (system or bundled) -- install from https://nodejs.org"
    $nodeOk = $false
}


# ── 2. Local MCP server (installed with the plugin) ──────────────────────────
HEAD "2. Local MCP server"
$serverPath = Get-McpServerPath
if ($serverPath) {
    OK "Local server found"
    INFO $serverPath
} else {
    FAIL "Local server not found -- reinstall the plugin"
    INFO "Run: powershell -ExecutionPolicy Bypass -Command `"irm https://raw.githubusercontent.com/$REPO/main/scripts/install.ps1 | iex`""
}


# ── 3. Claude Desktop config ─────────────────────────────────────────────────
HEAD "3. Claude Desktop configuration"

# Claude Desktop keeps its config in different folders depending on how it was
# installed; configure every one that exists.
$claudeDirs = @(Get-ClaudeDesktopDirs)

if ($claudeDirs.Count -eq 0) {
    # Claude not installed yet -- create the standard path
    $claudeDirs = @("$env:APPDATA\Claude")
    New-Item -ItemType Directory -Path $claudeDirs[0] -Force | Out-Null
    WARN "Claude Desktop folder not found -- created $($claudeDirs[0])"
    INFO "Make sure Claude Desktop is installed: https://claude.ai/download"
} else {
    foreach ($claudeDir in $claudeDirs) { OK "Claude Desktop folder: $claudeDir" }
}

# Build the config entry using the local server
if ($serverPath) {
    $mcpEntry = New-RevitMcpEntry $serverPath
    INFO "Will configure: $($mcpEntry.command) $($mcpEntry.args -join ' ')"
} else {
    $mcpEntry = $null
    WARN "Cannot configure Claude Desktop -- local server not found"
}

if (-not $mcpEntry) {
    WARN "Skipping Claude Desktop configuration -- no server available"
} else {
    foreach ($claudeDir in $claudeDirs) {
        $before = Get-ClaudeDesktopConfig $claudeDir
        $state  = Set-ClaudeDesktopMcpEntry $claudeDir $mcpEntry
        switch ($state) {
            'unchanged' { OK "revit-mcp entry is already correct" }
            'created'   { FIXED "claude_desktop_config.json created" }
            'recreated' {
                WARN "Existing claude_desktop_config.json was invalid JSON -- backed up"
                FIXED "claude_desktop_config.json recreated"
            }
            default {
                if ($before.HasRevitMcp) {
                    WARN "revit-mcp entry pointed to: $($before.RevitMcpEntry.command) $(@($before.RevitMcpEntry.args) -join ' ')"
                } else {
                    WARN "revit-mcp entry missing from config"
                }
                FIXED "claude_desktop_config.json updated"
            }
        }
        INFO $before.Path
    }
}


# ── 4. Revit plugin ───────────────────────────────────────────────────────────
HEAD "4. Revit plugin"

$anyRevit = $false

foreach ($year in $REVIT_YEARS) {
    if (-not (Test-RevitInstalled $year)) { continue }

    $addinsDir  = "$env:APPDATA\Autodesk\Revit\Addins\$year"
    $addinFile  = "$addinsDir\$ADDIN_FILE"
    $pluginRoot = "$addinsDir\$PLUGIN_FOLDER"
    $cmdSetDll  = "$pluginRoot\Commands\RevitMCPCommandSet\$year\RevitMCPCommandSet.dll"
    $regFile    = "$pluginRoot\Commands\commandRegistry.json"
    $anyRevit = $true

    $addinOk  = Test-Path $addinFile
    $pluginOk = Test-Path $pluginRoot
    $cmdSetOk = Test-Path $cmdSetDll

    if ($addinOk -and $pluginOk -and $cmdSetOk) {
        # Check registry
        if (Test-Path $regFile) {
            try {
                $reg     = Get-Content $regFile -Raw | ConvertFrom-Json
                $total   = $reg.Commands.Count
                $enabled = ($reg.Commands | Where-Object { $_.Enabled }).Count
                if ($total -eq 0) {
                    OK "Revit $year plugin installed"
                    WARN "  commandRegistry.json is empty -- open Revit -> Add-Ins -> Settings -> Select All -> Save"
                } elseif ($enabled -eq 0) {
                    OK "Revit $year plugin installed"
                    WARN "  All $total commands DISABLED -- open Revit -> Add-Ins -> Settings -> Select All -> Save"
                } else {
                    OK "Revit $year plugin installed ($enabled/$total commands enabled)"
                }
            } catch {
                OK "Revit $year plugin installed (registry parse error: $_)"
            }
        } else {
            OK "Revit $year plugin installed"
            WARN "  commandRegistry.json missing -- start Revit once to generate it"
        }

        # Blocked DLLs check
        $blocked = Get-ChildItem $pluginRoot -Recurse -Filter '*.dll' -ErrorAction SilentlyContinue |
            Where-Object { (Get-Item $_.FullName -Stream 'Zone.Identifier' -ErrorAction SilentlyContinue) -ne $null }
        if ($blocked.Count -gt 0) {
            WARN "  $($blocked.Count) DLL(s) blocked by Windows -- unblocking..."
            Get-ChildItem $pluginRoot -Recurse -ErrorAction SilentlyContinue | Unblock-File -ErrorAction SilentlyContinue
            FIXED "  DLLs unblocked"
        }
    } else {
        FAIL "Revit $year plugin NOT fully installed"
        if (-not $addinOk)  { INFO "  Missing: $addinFile" }
        if (-not $pluginOk) { INFO "  Missing: $pluginRoot" }
        if (-not $cmdSetOk) { INFO "  Missing: $cmdSetDll" }
        INFO "  Run the full installer to fix this"
    }
}

if (-not $anyRevit) {
    WARN "No Revit installation detected (2019-2027)"
}


# ── 5. Revit process + TCP ────────────────────────────────────────────────────
HEAD "5. Revit process and MCP server"

$revitProcs = Get-Process -Name "Revit" -ErrorAction SilentlyContinue
if ($revitProcs) {
    foreach ($p in $revitProcs) {
        OK "Revit running  (PID $($p.Id))  $($p.MainWindowTitle)"
    }
} else {
    WARN "Revit is NOT running -- start Revit and click Add-Ins -> Revit MCP Switch"
}

try {
    $tcp = New-Object System.Net.Sockets.TcpClient
    $ar  = $tcp.BeginConnect($MCP_HOST, $MCP_PORT, $null, $null)
    $ok  = $ar.AsyncWaitHandle.WaitOne(2000, $false)
    if ($ok -and $tcp.Connected) {
        OK "Port $MCP_PORT is open -- Revit MCP server is listening"
        $tcp.Close()
    } else {
        $tcp.Close()
        FAIL "Port $MCP_PORT is CLOSED"
        if ($revitProcs) {
            INFO "  Revit is running but MCP server not started"
            INFO "  -> In Revit: Add-Ins tab -> click 'Revit MCP Switch'"
        } else {
            INFO "  -> Start Revit first, then click 'Revit MCP Switch'"
        }
    }
} catch {
    FAIL "Could not test port $MCP_PORT : $_"
}


# ── Summary ───────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "  ============================================================" -ForegroundColor Cyan
Write-Host "   Results:  $pass OK  /  $fixed fixed  /  $fail failed"       -ForegroundColor $(if ($fail -eq 0) { 'Green' } else { 'Yellow' })
Write-Host "  ============================================================" -ForegroundColor Cyan

if ($fail -eq 0) {
    Write-Host ""
    Write-Host "  All checks passed." -ForegroundColor Green
    Write-Host ""
    Write-Host "  NEXT STEP: Restart Claude Desktop completely" -ForegroundColor Yellow
    Write-Host "  (close from system tray, then reopen)"       -ForegroundColor Yellow
    Write-Host "  Then ask Claude: 'list the elements in the open Revit project'" -ForegroundColor Gray
} else {
    Write-Host ""
    Write-Host "  Fix the FAIL items above, then re-run this script." -ForegroundColor Yellow
}
Write-Host ""
