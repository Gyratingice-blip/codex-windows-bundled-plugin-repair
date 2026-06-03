<#
.SYNOPSIS
Safely diagnose and repair Codex Desktop openai-bundled chrome/computer-use plugins on Windows.

.DESCRIPTION
Default mode is inspect-only. Repair mode backs up user Codex config, copies the bundled
openai-bundled marketplace from the Codex MSIX package to a user-owned directory, registers
that marketplace, installs target plugins, and verifies cache-critical files.
#>

[CmdletBinding()]
param(
    [switch]$InspectOnly,
    [switch]$Repair,
    [switch]$SetRuntimeEnv,
    [switch]$CheckChromeNativeHost,
    [switch]$SkipChromeNativeHostCheck,
    [switch]$RepairChromeNativeHost,
    [switch]$RepairStaleConfigRefs,
    [string]$MarketplaceName = "openai-bundled",
    [string[]]$TargetPlugins = @("chrome", "computer-use"),
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE ".codex" }),
    [string]$FixedRoot,
    [string]$BackupRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

if (-not $InspectOnly -and -not $Repair) {
    $InspectOnly = $true
}
if ($RepairChromeNativeHost -and -not $Repair) {
    throw "-RepairChromeNativeHost requires -Repair."
}
if ($RepairStaleConfigRefs -and -not $Repair) {
    throw "-RepairStaleConfigRefs requires -Repair."
}
if (-not $CheckChromeNativeHost -and -not $SkipChromeNativeHostCheck) {
    $CheckChromeNativeHost = $true
}

if (-not $FixedRoot) {
    $FixedRoot = Join-Path $CodexHome "$MarketplaceName-fixed"
}
if (-not $BackupRoot) {
    $BackupRoot = Join-Path $CodexHome "backups"
}

function Write-Step {
    param([string]$Message)
    Write-Host ""
    Write-Host "==> $Message"
}

function Write-Info {
    param([string]$Message)
    Write-Host "    $Message"
}

function Test-IsProtectedPath {
    param([string]$Path)
    if (-not $Path) { return $false }
    return $Path -match "^[A-Za-z]:\\Program Files\\WindowsApps\\"
}

function Copy-FileByStream {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    $parent = Split-Path -Parent $Destination
    if ($parent) {
        New-Item -ItemType Directory -Force -Path $parent | Out-Null
    }
    if (Test-Path -LiteralPath $Destination) {
        try {
            $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Source).Hash
            $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $Destination).Hash
            if ($sourceHash -eq $destinationHash) {
                return
            }
        }
        catch {
            # Fall through to a normal copy attempt; the caller will receive any real copy error.
        }
    }
    $inputStream = [System.IO.File]::Open($Source, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $outputStream = [System.IO.File]::Open($Destination, [System.IO.FileMode]::Create, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            $inputStream.CopyTo($outputStream)
        }
        finally {
            $outputStream.Dispose()
        }
    }
    finally {
        $inputStream.Dispose()
    }
}

function Copy-DirectoryByStream {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        throw "Source directory does not exist: $Source"
    }
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null

    Get-ChildItem -LiteralPath $Source -Directory -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart("\")
        New-Item -ItemType Directory -Force -Path (Join-Path $Destination $relative) | Out-Null
    }

    Get-ChildItem -LiteralPath $Source -File -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
        $relative = $_.FullName.Substring($Source.Length).TrimStart("\")
        Copy-FileByStream -Source $_.FullName -Destination (Join-Path $Destination $relative)
    }
}

function Copy-DirectoryForBackup {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    New-Item -ItemType Directory -Force -Path $Destination | Out-Null
    $output = & robocopy.exe $Source $Destination /E /COPY:DAT /DCOPY:DAT /XJ /R:1 /W:1 /NFL /NDL /NJH /NJS /NP 2>&1
    $exit = $LASTEXITCODE
    if ($output) { $output | ForEach-Object { Write-Host $_ } }
    if ($exit -gt 7) {
        throw "robocopy backup failed with exit code ${exit}: $Source -> $Destination"
    }
}

function Test-ExistingMarketplaceCacheReady {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$MarketplaceName
    )

    $required = @(
        (Join-Path $Root ".agents\plugins\marketplace.json"),
        (Join-Path $Root "plugins\chrome\scripts\browser-client.mjs"),
        (Join-Path $Root "plugins\chrome\scripts\check-native-host-manifest.js"),
        (Join-Path $Root "plugins\chrome\scripts\installManifest.mjs"),
        (Join-Path $Root "plugins\chrome\extension-host\windows\x64\extension-host.exe"),
        (Join-Path $CodexHome "plugins\cache\$MarketplaceName\chrome\latest\scripts\browser-client.mjs"),
        (Join-Path $CodexHome "plugins\cache\$MarketplaceName\chrome\latest\scripts\check-native-host-manifest.js"),
        (Join-Path $CodexHome "plugins\cache\$MarketplaceName\chrome\latest\scripts\installManifest.mjs"),
        (Join-Path $CodexHome "plugins\cache\$MarketplaceName\chrome\latest\extension-host\windows\x64\extension-host.exe")
    )

    foreach ($path in $required) {
        if (-not (Test-Path -LiteralPath $path)) {
            return $false
        }
    }
    return $true
}

function Get-PluginVersion {
    param([Parameter(Mandatory)][string]$PluginRoot)
    $manifest = Join-Path $PluginRoot ".codex-plugin\plugin.json"
    if (-not (Test-Path -LiteralPath $manifest)) {
        return $null
    }
    try {
        $json = Get-Content -LiteralPath $manifest -Raw | ConvertFrom-Json
        if ($json.PSObject.Properties["version"] -and $json.version) {
            return [string]$json.version
        }
    }
    catch {
        Write-Info "Could not parse plugin version from ${manifest}: $($_.Exception.Message)"
    }
    return $null
}

function Get-PluginVersionMap {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string[]]$Plugins
    )
    $versions = @{}
    foreach ($plugin in $Plugins) {
        $version = Get-PluginVersion -PluginRoot (Join-Path $SourceRoot "plugins\$plugin")
        if ($version) {
            $versions[$plugin] = $version
        }
    }
    return $versions
}

function Assert-PathUnder {
    param(
        [Parameter(Mandatory)][string]$Path,
        [Parameter(Mandatory)][string]$Base
    )
    $baseFull = [System.IO.Path]::GetFullPath($Base).TrimEnd("\") + "\"
    $pathFull = [System.IO.Path]::GetFullPath($Path)
    if (-not $pathFull.StartsWith($baseFull, [System.StringComparison]::OrdinalIgnoreCase)) {
        throw "Refusing to modify path outside expected base. Path: $pathFull Base: $baseFull"
    }
}

function Repair-PluginLatestCache {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$MarketplaceName,
        [Parameter(Mandatory)][string]$Plugin
    )
    $source = Join-Path $SourceRoot "plugins\$Plugin"
    if (-not (Test-Path -LiteralPath $source)) {
        Write-Info "Latest repair skipped, plugin source missing: $source"
        return
    }

    $version = Get-PluginVersion -PluginRoot $source
    if (-not $version) {
        Write-Info "Latest repair skipped, plugin version missing: $source"
        return
    }

    $cacheBase = Join-Path $CodexHome "plugins\cache\$MarketplaceName\$Plugin"
    $versionDir = Join-Path $cacheBase $version
    $latest = Join-Path $cacheBase "latest"
    Assert-PathUnder -Path $versionDir -Base $cacheBase
    Assert-PathUnder -Path $latest -Base $cacheBase

    New-Item -ItemType Directory -Force -Path $cacheBase | Out-Null
    Copy-DirectoryByStream -Source $source -Destination $versionDir

    $latestItem = Get-Item -LiteralPath $latest -Force -ErrorAction SilentlyContinue
    if ($latestItem -and (($latestItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0)) {
        $target = @($latestItem.Target) | Select-Object -First 1
        if ($target -and (([System.IO.Path]::GetFullPath($target)) -ieq ([System.IO.Path]::GetFullPath($versionDir))) -and (Test-Path -LiteralPath $latest)) {
            Write-Info "OK: $Plugin latest junction already points to $version"
            return
        }
        Remove-Item -LiteralPath $latest -Force
        $latestItem = $null
    }

    if (-not $latestItem) {
        try {
            New-Item -ItemType Junction -Path $latest -Target $versionDir | Out-Null
            Write-Info "Rebuilt $Plugin latest junction: $latest -> $versionDir"
            return
        }
        catch {
            Write-Info "Could not create junction for $Plugin latest; copying directory instead: $($_.Exception.Message)"
        }
    }

    Copy-DirectoryByStream -Source $source -Destination $latest
    Write-Info "Synced $Plugin latest directory: $latest"
}

function Repair-PluginLatestCaches {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$MarketplaceName,
        [Parameter(Mandatory)][string[]]$Plugins
    )
    foreach ($plugin in $Plugins) {
        Repair-PluginLatestCache -SourceRoot $SourceRoot -CodexHome $CodexHome -MarketplaceName $MarketplaceName -Plugin $plugin
    }
}

function Test-PluginLatestCaches {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$MarketplaceName,
        [Parameter(Mandatory)][string[]]$Plugins
    )
    foreach ($plugin in $Plugins) {
        $version = Get-PluginVersion -PluginRoot (Join-Path $SourceRoot "plugins\$plugin")
        $cacheBase = Join-Path $CodexHome "plugins\cache\$MarketplaceName\$plugin"
        $versionDir = if ($version) { Join-Path $cacheBase $version } else { $null }
        $latest = Join-Path $cacheBase "latest"
        $latestItem = Get-Item -LiteralPath $latest -Force -ErrorAction SilentlyContinue

        if (-not $version) {
            Write-Info "UNKNOWN: $plugin plugin version could not be read."
        }
        elseif (-not (Test-Path -LiteralPath $versionDir)) {
            Write-Info "MISSING: $plugin version cache: $versionDir"
        }
        elseif (-not $latestItem) {
            Write-Info "MISSING: $plugin latest cache: $latest"
        }
        elseif (($latestItem.Attributes -band [System.IO.FileAttributes]::ReparsePoint) -ne 0) {
            $target = @($latestItem.Target) | Select-Object -First 1
            if ($target -and (([System.IO.Path]::GetFullPath($target)) -ieq ([System.IO.Path]::GetFullPath($versionDir)))) {
                Write-Info "OK: $plugin latest points to current version $version"
            }
            else {
                Write-Info "STALE: $plugin latest target is '$target', expected '$versionDir'"
            }
        }
        elseif (Test-Path -LiteralPath (Join-Path $latest ".codex-plugin\plugin.json")) {
            $latestVersion = Get-PluginVersion -PluginRoot $latest
            if ($latestVersion -eq $version) {
                Write-Info "OK: $plugin latest directory contains current version $version"
            }
            else {
                Write-Info "STALE: $plugin latest directory version is '$latestVersion', expected '$version'"
            }
        }
        else {
            Write-Info "MISSING: $plugin latest plugin manifest: $latest"
        }
    }
}

function Backup-Path {
    param(
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$BackupDir
    )
    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Info "Backup skipped, missing: $Source"
        return
    }
    $leaf = Split-Path -Leaf $Source
    $dest = Join-Path $BackupDir $leaf
    if ((Get-Item -LiteralPath $Source).PSIsContainer) {
        Copy-DirectoryForBackup -Source $Source -Destination $dest
    }
    else {
        Copy-FileByStream -Source $Source -Destination $dest
    }
    Write-Info "Backed up: $Source -> $dest"
}

function Get-CodexPackage {
    $packages = Get-AppxPackage -Name "OpenAI.Codex" -ErrorAction SilentlyContinue
    if (-not $packages) {
        return $null
    }
    return $packages | Sort-Object Version -Descending | Select-Object -First 1
}

function Find-CodexCli {
    $candidates = @()
    if ($env:CODEX_CLI_PATH) { $candidates += $env:CODEX_CLI_PATH }
    $candidates += Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\codex.exe"
    $cmd = Get-Command codex.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }

    foreach ($candidate in $candidates | Where-Object { $_ } | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Find-BundledExecutable {
    param(
        [Parameter(Mandatory)][string]$ResourcesRoot,
        [Parameter(Mandatory)][string]$FileName
    )
    $directCandidates = @(
        (Join-Path $ResourcesRoot $FileName),
        (Join-Path $ResourcesRoot "bin\$FileName"),
        (Join-Path $ResourcesRoot "app\resources\$FileName"),
        (Join-Path $ResourcesRoot "app\resources\bin\$FileName")
    )
    foreach ($candidate in $directCandidates) {
        if (Test-Path -LiteralPath $candidate) { return $candidate }
    }
    $found = Get-ChildItem -LiteralPath $ResourcesRoot -Filter $FileName -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found) { return $found.FullName }
    return $null
}

function Find-NodeExecutable {
    param([string]$ResourcesRoot)
    $candidates = @()
    if ($env:CODEX_BROWSER_USE_NODE_PATH) { $candidates += $env:CODEX_BROWSER_USE_NODE_PATH }
    if ($env:CODEX_NODE_PATH) { $candidates += $env:CODEX_NODE_PATH }
    $candidates += Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\node.exe"
    $cmd = Get-Command node.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    if ($ResourcesRoot) {
        $bundled = Find-BundledExecutable -ResourcesRoot $ResourcesRoot -FileName "node.exe"
        if ($bundled) { $candidates += $bundled }
    }

    foreach ($candidate in $candidates | Where-Object { $_ } | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Find-NodeReplExecutable {
    param([string]$ResourcesRoot)
    $candidates = @()
    if ($env:CODEX_NODE_REPL_PATH) { $candidates += $env:CODEX_NODE_REPL_PATH }
    $candidates += Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin\node_repl.exe"
    $cmd = Get-Command node_repl.exe -ErrorAction SilentlyContinue
    if ($cmd) { $candidates += $cmd.Source }
    if ($ResourcesRoot) {
        $bundled = Find-BundledExecutable -ResourcesRoot $ResourcesRoot -FileName "node_repl.exe"
        if ($bundled) { $candidates += $bundled }
    }

    foreach ($candidate in $candidates | Where-Object { $_ } | Select-Object -Unique) {
        if (Test-Path -LiteralPath $candidate) {
            return $candidate
        }
    }
    return $null
}

function Invoke-Codex {
    param(
        [Parameter(Mandatory)][string]$CodexCli,
        [Parameter(Mandatory)][string[]]$Args
    )
    Write-Info ("codex " + ($Args -join " "))
    $output = & $CodexCli @Args 2>&1
    $exit = $LASTEXITCODE
    if ($output) { $output | ForEach-Object { Write-Host $_ } }
    if ($exit -ne 0) {
        throw "codex command failed with exit code ${exit}: $($Args -join ' ')"
    }
    return $output
}

function Get-MarketplaceRoot {
    param(
        [Parameter(Mandatory)][string]$CodexCli,
        [Parameter(Mandatory)][string]$Name
    )
    $list = & $CodexCli plugin marketplace list 2>&1
    foreach ($line in $list) {
        if ($line -match "^\s*$([regex]::Escape($Name))\s+(.+?)\s*$") {
            return $Matches[1].Trim()
        }
    }
    return $null
}

function Register-Marketplace {
    param(
        [Parameter(Mandatory)][string]$CodexCli,
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Root
    )
    $existing = Get-MarketplaceRoot -CodexCli $CodexCli -Name $Name
    if ($existing -and ($existing -ieq $Root)) {
        Write-Info "Marketplace already registered: $Name -> $Root"
        return
    }
    if ($existing) {
        Write-Info "Marketplace currently points to: $existing"
        Invoke-Codex -CodexCli $CodexCli -Args @("plugin", "marketplace", "remove", $Name) | Out-Null
    }
    Invoke-Codex -CodexCli $CodexCli -Args @("plugin", "marketplace", "add", $Root) | Out-Null
}

function Test-CriticalFiles {
    param(
        [Parameter(Mandatory)][string]$Root,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$MarketplaceName
    )
    $paths = @(
        (Join-Path $Root ".agents\plugins\marketplace.json"),
        (Join-Path $Root "plugins\chrome\.codex-plugin\plugin.json"),
        (Join-Path $Root "plugins\computer-use\.codex-plugin\plugin.json"),
        (Join-Path $Root "plugins\chrome\scripts\browser-client.mjs"),
        (Join-Path $Root "plugins\chrome\extension-host"),
        (Join-Path $Root "plugins\computer-use\scripts\computer-use-client.mjs"),
        (Join-Path $Root "plugins\computer-use\node_modules\@oai\sky\bin\windows\codex-computer-use.exe"),
        (Join-Path $CodexHome "plugins\cache\$MarketplaceName\chrome\latest\scripts\browser-client.mjs"),
        (Join-Path $CodexHome "plugins\cache\$MarketplaceName\chrome\latest\extension-host"),
        (Join-Path $CodexHome "plugins\cache\$MarketplaceName\computer-use\latest\scripts\computer-use-client.mjs"),
        (Join-Path $CodexHome "plugins\cache\$MarketplaceName\computer-use\latest\node_modules\@oai\sky\bin\windows\codex-computer-use.exe")
    )
    foreach ($path in $paths) {
        if (Test-Path -LiteralPath $path) {
            Write-Info "OK: $path"
        }
        else {
            Write-Info "MISSING: $path"
        }
    }
}

function Add-HashPair {
    param(
        [System.Collections.ArrayList]$Pairs,
        [Parameter(Mandatory)][string]$Label,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Destination
    )
    if ($null -eq $Pairs) {
        throw "Hash pair collection was not initialized."
    }
    [void]$Pairs.Add([pscustomobject]@{
        Label = $Label
        Source = $Source
        Destination = $Destination
    })
}

function Test-CriticalFileHashes {
    param(
        [Parameter(Mandatory)][string]$BundledRoot,
        [Parameter(Mandatory)][string]$FixedRoot,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$MarketplaceName,
        [Parameter(Mandatory)][string]$ResourcesRoot,
        [Parameter(Mandatory)][string[]]$Plugins
    )

    $pairs = [System.Collections.ArrayList]::new()
    $relativePluginFiles = @(
        ".agents\plugins\marketplace.json",
        "plugins\chrome\.codex-plugin\plugin.json",
        "plugins\chrome\scripts\browser-client.mjs",
        "plugins\chrome\scripts\check-native-host-manifest.js",
        "plugins\chrome\scripts\installManifest.mjs",
        "plugins\chrome\extension-host\windows\x64\extension-host.exe",
        "plugins\computer-use\.codex-plugin\plugin.json",
        "plugins\computer-use\scripts\computer-use-client.mjs",
        "plugins\computer-use\node_modules\@oai\sky\bin\windows\codex-computer-use.exe"
    )

    foreach ($relative in $relativePluginFiles) {
        Add-HashPair -Pairs $pairs -Label "bundled->fixed $relative" -Source (Join-Path $BundledRoot $relative) -Destination (Join-Path $FixedRoot $relative)
    }

    foreach ($plugin in $Plugins) {
        $pluginSource = Join-Path $FixedRoot "plugins\$plugin"
        $pluginCacheLatest = Join-Path $CodexHome "plugins\cache\$MarketplaceName\$plugin\latest"
        $pluginVersion = Get-PluginVersion -PluginRoot $pluginSource
        $pluginCacheVersion = if ($pluginVersion) { Join-Path $CodexHome "plugins\cache\$MarketplaceName\$plugin\$pluginVersion" } else { $null }
        $pluginFiles = @(".codex-plugin\plugin.json")
        if ($plugin -eq "chrome") {
            $pluginFiles += @(
                "scripts\browser-client.mjs",
                "scripts\check-native-host-manifest.js",
                "scripts\installManifest.mjs",
                "extension-host\windows\x64\extension-host.exe"
            )
        }
        elseif ($plugin -eq "computer-use") {
            $pluginFiles += @(
                "scripts\computer-use-client.mjs",
                "node_modules\@oai\sky\bin\windows\codex-computer-use.exe"
            )
        }

        foreach ($relative in $pluginFiles) {
            Add-HashPair -Pairs $pairs -Label "fixed->latest $plugin\$relative" -Source (Join-Path $pluginSource $relative) -Destination (Join-Path $pluginCacheLatest $relative)
            if ($pluginCacheVersion) {
                Add-HashPair -Pairs $pairs -Label "fixed->version $plugin\$relative" -Source (Join-Path $pluginSource $relative) -Destination (Join-Path $pluginCacheVersion $relative)
            }
        }
    }

    $localBin = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
    foreach ($exe in @("codex.exe", "node.exe", "node_repl.exe", "codex-command-runner.exe", "codex-windows-sandbox-setup.exe")) {
        $source = Find-BundledExecutable -ResourcesRoot $ResourcesRoot -FileName $exe
        if ($source) {
            Add-HashPair -Pairs $pairs -Label "runtime $exe" -Source $source -Destination (Join-Path $localBin $exe)
        }
    }

    foreach ($pair in $pairs) {
        if (-not (Test-Path -LiteralPath $pair.Source)) {
            Write-Info "HASH SKIP source missing: $($pair.Label)"
            continue
        }
        if (-not (Test-Path -LiteralPath $pair.Destination)) {
            Write-Info "HASH MISSING destination: $($pair.Label)"
            continue
        }
        try {
            $sourceHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pair.Source).Hash
            $destinationHash = (Get-FileHash -Algorithm SHA256 -LiteralPath $pair.Destination).Hash
            if ($sourceHash -eq $destinationHash) {
                Write-Info "HASH OK: $($pair.Label)"
            }
            else {
                Write-Info "HASH MISMATCH: $($pair.Label)"
            }
        }
        catch {
            Write-Info "HASH ERROR: $($pair.Label): $($_.Exception.Message)"
        }
    }
}

function Get-StaleReferenceRows {
    param(
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$MarketplaceName,
        [Parameter(Mandatory)][hashtable]$PluginVersions,
        [Parameter(Mandatory)][string]$CurrentPackageFullName
    )

    $rows = [System.Collections.ArrayList]::new()
    $files = @(
        (Join-Path $CodexHome "config.toml"),
        (Join-Path $CodexHome ".codex-global-state.json"),
        (Join-Path $CodexHome "codex-global-state.json")
    )
    $pathSeparatorPattern = '[\\]+'
    $pluginVersionPattern = [regex]("$([regex]::Escape($MarketplaceName))${pathSeparatorPattern}(?<plugin>chrome|computer-use)${pathSeparatorPattern}(?<version>\d+\.\d+\.\d+)")
    $packagePattern = [regex]"OpenAI\.Codex_(?<package>[^\\'""\s]+)"

    foreach ($file in $files) {
        if (-not (Test-Path -LiteralPath $file)) {
            continue
        }
        $content = Get-Content -LiteralPath $file -Raw

        foreach ($match in $pluginVersionPattern.Matches($content)) {
            $plugin = [string]$match.Groups["plugin"].Value
            $found = [string]$match.Groups["version"].Value
            if ($PluginVersions.ContainsKey($plugin)) {
                $expected = [string]$PluginVersions[$plugin]
                if ($found -and $expected -and ($found -ne $expected)) {
                    [void]$rows.Add([pscustomobject]@{
                        File = $file
                        Kind = "plugin-cache-version"
                        Plugin = $plugin
                        Found = $found
                        Expected = $expected
                    })
                }
            }
        }

        foreach ($match in $packagePattern.Matches($content)) {
            $foundPackage = [string]$match.Groups["package"].Value
            $fullFoundPackage = "OpenAI.Codex_$foundPackage"
            if ($fullFoundPackage -ne $CurrentPackageFullName) {
                [void]$rows.Add([pscustomobject]@{
                    File = $file
                    Kind = "appx-package"
                    Plugin = ""
                    Found = $fullFoundPackage
                    Expected = $CurrentPackageFullName
                })
            }
        }
    }

    return ,$rows
}

function Report-StaleReferences {
    param(
        [System.Collections.IEnumerable]$Rows
    )
    $rowsArray = @()
    if ($null -ne $Rows) {
        foreach ($row in $Rows) {
            if ($null -ne $row) {
                $rowsArray += $row
            }
        }
    }
    $rowCount = ($rowsArray | Measure-Object).Count
    if ($rowCount -eq 0) {
        Write-Info "OK: no stale Codex AppX or openai-bundled version references found in tracked config/state files."
        return
    }

    $groups = $rowsArray | Group-Object File, Kind, Plugin, Found, Expected
    foreach ($group in $groups) {
        $first = $group.Group | Select-Object -First 1
        Write-Info ("STALE REF: {0} kind={1} plugin={2} found={3} expected={4} count={5}" -f (Split-Path -Leaf $first.File), $first.Kind, $first.Plugin, $first.Found, $first.Expected, $group.Count)
    }
}

function Repair-StaleConfigReferences {
    param(
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$MarketplaceName,
        [Parameter(Mandatory)][hashtable]$PluginVersions
    )
    $configPath = Join-Path $CodexHome "config.toml"
    if (-not (Test-Path -LiteralPath $configPath)) {
        Write-Info "Stale config repair skipped, missing: $configPath"
        return
    }

    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    $original = [System.IO.File]::ReadAllText($configPath, [System.Text.Encoding]::UTF8)
    $updated = $original
    foreach ($plugin in $PluginVersions.Keys) {
        $expected = [string]$PluginVersions[$plugin]
        if (-not $expected) {
            Write-Info "Stale config repair skipped for $plugin, expected version missing."
            continue
        }
        $expectedCache = Join-Path $CodexHome "plugins\cache\$MarketplaceName\$plugin\$expected"
        if (-not (Test-Path -LiteralPath $expectedCache)) {
            Write-Info "Stale config repair skipped for $plugin, expected cache missing: $expectedCache"
            continue
        }
        Write-Info "Checking stale config references for $plugin -> $expected"
        $pathSeparatorPattern = '[\\]+'
        $pattern = "(?<prefix>$([regex]::Escape($MarketplaceName))${pathSeparatorPattern}$([regex]::Escape([string]$plugin))${pathSeparatorPattern})\d+\.\d+\.\d+"
        $regex = [System.Text.RegularExpressions.Regex]::new($pattern)
        Write-Info "Matched $($regex.Matches($updated).Count) config reference(s) for $plugin."
        $replacement = '${prefix}' + $expected
        $updated = $regex.Replace($updated, $replacement)
    }

    if ($updated -eq $original) {
        Write-Info "No stale plugin cache version references needed repair in config.toml."
        return
    }

    [System.IO.File]::WriteAllText($configPath, $updated, $utf8NoBom)
    Write-Info "Updated stale plugin cache version references in config.toml."
}

function Test-ChromeNativeHost {
    param(
        [Parameter(Mandatory)][string]$ChromeRoot,
        [Parameter(Mandatory)][string]$ResourcesRoot
    )

    $checkScript = Join-Path $ChromeRoot "scripts\check-native-host-manifest.js"
    if (-not (Test-Path -LiteralPath $checkScript)) {
        Write-Info "MISSING: $checkScript"
        return
    }

    $node = Find-NodeExecutable -ResourcesRoot $ResourcesRoot
    if (-not $node) {
        Write-Info "Node executable not found; skipped Chrome native host manifest check."
        return
    }

    Write-Info "node scripts/check-native-host-manifest.js --json"
    $output = & $node $checkScript --json 2>&1
    $exit = $LASTEXITCODE
    $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"

    if ($text.Trim()) {
        Write-Host $text
    }

    try {
        $status = $text | ConvertFrom-Json
        Write-Info "Native host registry key: $($status.registryKey)"
        Write-Info "Native host manifest path: $($status.manifestPath)"
        Write-Info "Expected host name: $($status.expectedHostName)"
        Write-Info "Expected extension ID: $($status.expectedExtensionId)"

        if ($status.exists -and (Test-Path -LiteralPath $status.manifestPath)) {
            $manifest = Get-Content -LiteralPath $status.manifestPath -Raw | ConvertFrom-Json
            $manifestPathProperty = $manifest.PSObject.Properties["path"]
            if ($manifestPathProperty -and $manifestPathProperty.Value) {
                $nativeHostExecutable = [string]$manifestPathProperty.Value
                if (Test-Path -LiteralPath $nativeHostExecutable) {
                    Write-Info "OK: native host executable exists: $nativeHostExecutable"
                }
                else {
                    Write-Info "MISSING: native host executable from manifest: $nativeHostExecutable"
                }

                $hostConfig = Join-Path (Split-Path -Parent $nativeHostExecutable) "extension-host-config.json"
                if (Test-Path -LiteralPath $hostConfig) {
                    Write-Info "OK: native host config exists: $hostConfig"
                }
                else {
                    Write-Info "MISSING: native host config: $hostConfig"
                }
            }
        }

        if ($status.correct) {
            Write-Info "OK: Chrome native host manifest is registered and valid."
        }
        else {
            Write-Info "PROBLEM: $($status.problem)"
        }
    }
    catch {
        Write-Info "Could not parse native host check JSON: $($_.Exception.Message)"
    }

    if ($exit -ne 0) {
        Write-Info "Native host check exit code: $exit"
    }
}

function Backup-ChromeNativeHost {
    param([Parameter(Mandatory)][string]$BackupDir)

    $registryKey = "HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension"
    $registryBackup = Join-Path $BackupDir "chrome-native-host.reg"
    try {
        $null = & reg.exe export $registryKey $registryBackup /y 2>$null
        if ($LASTEXITCODE -eq 0) {
            Write-Info "Backed up Chrome native host registry: $registryBackup"
        }
        else {
            Write-Info "Chrome native host registry backup skipped, key missing: $registryKey"
        }
    }
    catch {
        Write-Info "Chrome native host registry backup skipped: $($_.Exception.Message)"
    }

    $manifestDir = Join-Path $env:LOCALAPPDATA "OpenAI\extension"
    Backup-Path -Source $manifestDir -BackupDir $BackupDir
}

function Install-ChromeNativeHost {
    param(
        [Parameter(Mandatory)][string]$ChromeRoot,
        [Parameter(Mandatory)][string]$ResourcesRoot,
        [string]$CodexCli
    )

    $installScript = Join-Path $ChromeRoot "scripts\installManifest.mjs"
    if (-not (Test-Path -LiteralPath $installScript)) {
        throw "Chrome native host installer is missing: $installScript"
    }

    $node = Find-NodeExecutable -ResourcesRoot $ResourcesRoot
    $nodeRepl = Find-NodeReplExecutable -ResourcesRoot $ResourcesRoot
    if (-not $CodexCli) { $CodexCli = Find-CodexCli }

    if (-not $node) { throw "node.exe was not found; run with -SetRuntimeEnv first." }
    if (-not $nodeRepl) { throw "node_repl.exe was not found; run with -SetRuntimeEnv first." }
    if (-not $CodexCli) { throw "codex.exe was not found; run with -SetRuntimeEnv first." }

    $installUri = ([System.Uri]$installScript).AbsoluteUri
    $payload = [ordered]@{
        appServerRuntimePaths = [ordered]@{
            codexCliPath = $CodexCli
            nodePath = $node
            nodeReplPath = $nodeRepl
        }
    } | ConvertTo-Json -Compress
    $js = "import { install } from '$installUri'; await install($payload);"

    Write-Info "node --input-type=module -e <install chrome native host manifest>"
    $output = & $node "--input-type=module" "-e" $js 2>&1
    $exit = $LASTEXITCODE
    if ($output) { $output | ForEach-Object { Write-Host $_ } }
    if ($exit -ne 0) {
        throw "Chrome native host installer failed with exit code ${exit}."
    }
}

function Sync-PluginCaches {
    param(
        [Parameter(Mandatory)][string]$SourceRoot,
        [Parameter(Mandatory)][string]$CodexHome,
        [Parameter(Mandatory)][string]$MarketplaceName,
        [Parameter(Mandatory)][string[]]$Plugins
    )
    $tmpMarketplace = Join-Path $CodexHome ".tmp\bundled-marketplaces\$MarketplaceName"
    Write-Step "Syncing bundled marketplace temp cache"
    Copy-DirectoryByStream -Source $SourceRoot -Destination $tmpMarketplace

    foreach ($plugin in $Plugins) {
        $source = Join-Path $SourceRoot "plugins\$plugin"
        $destination = Join-Path $CodexHome "plugins\cache\$MarketplaceName\$plugin\latest"
        Write-Step "Syncing plugin cache for $plugin"
        Copy-DirectoryByStream -Source $source -Destination $destination
    }
}

function Set-UserEnvironment {
    param(
        [Parameter(Mandatory)][string]$ResourcesRoot,
        [Parameter(Mandatory)][string]$BackupDir
    )
    $localBin = Join-Path $env:LOCALAPPDATA "OpenAI\Codex\bin"
    if (Test-Path -LiteralPath $localBin) {
        Backup-Path -Source $localBin -BackupDir $BackupDir
    }
    New-Item -ItemType Directory -Force -Path $localBin | Out-Null

    $envSnapshot = [ordered]@{}
    foreach ($name in @("CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE", "CODEX_CLI_PATH", "CODEX_BROWSER_USE_NODE_PATH", "CODEX_NODE_REPL_PATH")) {
        $envSnapshot[$name] = [Environment]::GetEnvironmentVariable($name, "User")
    }
    $envSnapshot | ConvertTo-Json | Set-Content -Path (Join-Path $BackupDir "environment-before.json") -Encoding UTF8

    $runtimeFiles = @(
        @{ FileName = "codex.exe"; EnvName = "CODEX_CLI_PATH" },
        @{ FileName = "node.exe"; EnvName = "CODEX_BROWSER_USE_NODE_PATH" },
        @{ FileName = "node_repl.exe"; EnvName = "CODEX_NODE_REPL_PATH" },
        @{ FileName = "codex-command-runner.exe"; EnvName = $null },
        @{ FileName = "codex-windows-sandbox-setup.exe"; EnvName = $null }
    )
    foreach ($entry in $runtimeFiles) {
        $exe = [string]$entry.FileName
        $envName = if ($entry.EnvName) { [string]$entry.EnvName } else { $null }
        $source = Find-BundledExecutable -ResourcesRoot $ResourcesRoot -FileName $exe
        if (-not $source) {
            Write-Info "Runtime executable not found, skipped: $exe"
            continue
        }
        $dest = Join-Path $localBin $exe
        Copy-FileByStream -Source $source -Destination $dest
        if ($envName) {
            [Environment]::SetEnvironmentVariable($envName, $dest, "User")
            Set-Item -Path "Env:\$envName" -Value $dest
            Write-Info "Set $envName=$dest"
        }
        else {
            Write-Info "Copied runtime helper: $dest"
        }
    }
    [Environment]::SetEnvironmentVariable("CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE", "1", "User")
    $env:CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE = "1"
    Write-Info "Set CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1"
}

Write-Step "Inspecting Codex paths"
Write-Info "CodexHome: $CodexHome"
Write-Info "FixedRoot: $FixedRoot"
Write-Info "BackupRoot: $BackupRoot"

$codexCli = Find-CodexCli
if ($codexCli) {
    Write-Info "Codex CLI: $codexCli"
}
else {
    Write-Info "Codex CLI not found. Repair can still copy files, but registration/install needs codex.exe."
}

$pkg = Get-CodexPackage
if (-not $pkg) {
    throw "OpenAI.Codex AppX package was not found."
}

$resourcesRoot = Join-Path $pkg.InstallLocation "app\resources"
$bundledSource = Join-Path $resourcesRoot "plugins\$MarketplaceName"
Write-Info "Package: $($pkg.PackageFullName)"
Write-Info "Resources: $resourcesRoot"
Write-Info "Bundled marketplace source: $bundledSource"
Write-Info "Source is WindowsApps protected path: $(Test-IsProtectedPath -Path $bundledSource)"

if (-not (Test-Path -LiteralPath $bundledSource)) {
    throw "Bundled marketplace source is missing: $bundledSource"
}
$pluginVersions = Get-PluginVersionMap -SourceRoot $bundledSource -Plugins $TargetPlugins

Write-Step "Inspecting plugin marketplace and plugin state"
if ($codexCli) {
    Invoke-Codex -CodexCli $codexCli -Args @("plugin", "marketplace", "list") | Out-Null
    Invoke-Codex -CodexCli $codexCli -Args @("plugin", "list", "--marketplace", $MarketplaceName) | Out-Null
}
else {
    Write-Info "Skipped CLI inspection because codex.exe was not found."
}

Write-Step "Inspecting critical files"
Test-CriticalFiles -Root $bundledSource -CodexHome $CodexHome -MarketplaceName $MarketplaceName
if (Test-Path -LiteralPath $FixedRoot) {
    Test-CriticalFiles -Root $FixedRoot -CodexHome $CodexHome -MarketplaceName $MarketplaceName
}

Write-Step "Inspecting latest cache pointers"
Test-PluginLatestCaches -SourceRoot $bundledSource -CodexHome $CodexHome -MarketplaceName $MarketplaceName -Plugins $TargetPlugins

Write-Step "Inspecting critical file hashes"
Test-CriticalFileHashes -BundledRoot $bundledSource -FixedRoot $FixedRoot -CodexHome $CodexHome -MarketplaceName $MarketplaceName -ResourcesRoot $resourcesRoot -Plugins $TargetPlugins

Write-Step "Inspecting stale config/state references"
$staleRows = Get-StaleReferenceRows -CodexHome $CodexHome -MarketplaceName $MarketplaceName -PluginVersions $pluginVersions -CurrentPackageFullName $pkg.PackageFullName
Report-StaleReferences -Rows $staleRows

if ($CheckChromeNativeHost -and ($TargetPlugins -contains "chrome")) {
    Write-Step "Checking Chrome native host manifest"
    $chromeCacheRoot = Join-Path $CodexHome "plugins\cache\$MarketplaceName\chrome\latest"
    $chromeFixedRoot = Join-Path $FixedRoot "plugins\chrome"
    if (Test-Path -LiteralPath (Join-Path $chromeCacheRoot "scripts\check-native-host-manifest.js")) {
        Test-ChromeNativeHost -ChromeRoot $chromeCacheRoot -ResourcesRoot $resourcesRoot
    }
    elseif (Test-Path -LiteralPath (Join-Path $chromeFixedRoot "scripts\check-native-host-manifest.js")) {
        Test-ChromeNativeHost -ChromeRoot $chromeFixedRoot -ResourcesRoot $resourcesRoot
    }
    else {
        Test-ChromeNativeHost -ChromeRoot (Join-Path $bundledSource "plugins\chrome") -ResourcesRoot $resourcesRoot
    }
}

if (-not $Repair) {
    Write-Step "Inspect-only mode complete"
    Write-Info "No files were modified. Re-run with -Repair to back up and repair."
    return
}

$timestamp = Get-Date -Format "yyyyMMdd-HHmmss"
$backupDir = Join-Path $BackupRoot "repair-computer-use-$timestamp"
Write-Step "Creating backup before repair"
New-Item -ItemType Directory -Force -Path $backupDir | Out-Null
Backup-Path -Source (Join-Path $CodexHome "plugins") -BackupDir $backupDir
Backup-Path -Source (Join-Path $CodexHome "config.toml") -BackupDir $backupDir
Backup-Path -Source (Join-Path $CodexHome "codex-global-state.json") -BackupDir $backupDir
Backup-Path -Source (Join-Path $CodexHome ".codex-global-state.json") -BackupDir $backupDir
if ($RepairChromeNativeHost) {
    Backup-ChromeNativeHost -BackupDir $backupDir
}

if ($RepairChromeNativeHost -and (Test-ExistingMarketplaceCacheReady -Root $FixedRoot -CodexHome $CodexHome -MarketplaceName $MarketplaceName)) {
    Write-Step "Skipping marketplace sync because existing Chrome marketplace/cache is complete"
}
else {
    Write-Step "Copying openai-bundled marketplace to user-owned fixed root"
    Copy-DirectoryByStream -Source $bundledSource -Destination $FixedRoot

    Write-Step "Syncing user-owned plugin cache"
    Sync-PluginCaches -SourceRoot $FixedRoot -CodexHome $CodexHome -MarketplaceName $MarketplaceName -Plugins $TargetPlugins

    if ($codexCli) {
        Write-Step "Registering local marketplace source"
        Register-Marketplace -CodexCli $codexCli -Name $MarketplaceName -Root $FixedRoot

        foreach ($plugin in $TargetPlugins) {
            Write-Step "Installing or refreshing $plugin@$MarketplaceName"
            try {
                Invoke-Codex -CodexCli $codexCli -Args @("plugin", "add", "$plugin@$MarketplaceName") | Out-Null
            }
            catch {
                Write-Info "plugin add reported an error; continuing to final verification: $($_.Exception.Message)"
            }
        }
    }
    else {
        Write-Info "Skipped marketplace registration and plugin add because codex.exe was not found."
    }
}

Write-Step "Repairing latest cache pointers"
Repair-PluginLatestCaches -SourceRoot $FixedRoot -CodexHome $CodexHome -MarketplaceName $MarketplaceName -Plugins $TargetPlugins

if ($RepairStaleConfigRefs) {
    Write-Step "Repairing stale config references"
    $fixedPluginVersions = Get-PluginVersionMap -SourceRoot $FixedRoot -Plugins $TargetPlugins
    Repair-StaleConfigReferences -CodexHome $CodexHome -MarketplaceName $MarketplaceName -PluginVersions $fixedPluginVersions
}

if ($SetRuntimeEnv) {
    Write-Step "Copying runtime executables and setting user environment overrides"
    Set-UserEnvironment -ResourcesRoot $resourcesRoot -BackupDir $backupDir
    Write-Info "Restart Codex Desktop so the new user environment variables are loaded."
}

if ($RepairChromeNativeHost) {
    Write-Step "Repairing Chrome native host manifest"
    $chromeCacheRoot = Join-Path $CodexHome "plugins\cache\$MarketplaceName\chrome\latest"
    Install-ChromeNativeHost -ChromeRoot $chromeCacheRoot -ResourcesRoot $resourcesRoot -CodexCli $codexCli
}

Write-Step "Final verification"
if ($codexCli) {
    Invoke-Codex -CodexCli $codexCli -Args @("plugin", "marketplace", "list") | Out-Null
    Invoke-Codex -CodexCli $codexCli -Args @("plugin", "list", "--marketplace", $MarketplaceName) | Out-Null
}
Test-CriticalFiles -Root $FixedRoot -CodexHome $CodexHome -MarketplaceName $MarketplaceName
Write-Step "Checking latest cache pointers after repair"
Test-PluginLatestCaches -SourceRoot $FixedRoot -CodexHome $CodexHome -MarketplaceName $MarketplaceName -Plugins $TargetPlugins
Write-Step "Checking critical file hashes after repair"
Test-CriticalFileHashes -BundledRoot $bundledSource -FixedRoot $FixedRoot -CodexHome $CodexHome -MarketplaceName $MarketplaceName -ResourcesRoot $resourcesRoot -Plugins $TargetPlugins
Write-Step "Checking stale config/state references after repair"
$finalPluginVersions = Get-PluginVersionMap -SourceRoot $FixedRoot -Plugins $TargetPlugins
$finalStaleRows = Get-StaleReferenceRows -CodexHome $CodexHome -MarketplaceName $MarketplaceName -PluginVersions $finalPluginVersions -CurrentPackageFullName $pkg.PackageFullName
Report-StaleReferences -Rows $finalStaleRows
if ($CheckChromeNativeHost -and ($TargetPlugins -contains "chrome")) {
    Write-Step "Checking Chrome native host manifest after repair"
    $chromeCacheRoot = Join-Path $CodexHome "plugins\cache\$MarketplaceName\chrome\latest"
    Test-ChromeNativeHost -ChromeRoot $chromeCacheRoot -ResourcesRoot $resourcesRoot
}
Write-Info "Backup directory: $backupDir"
