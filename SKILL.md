---
name: repair-computer-use
description: Diagnose and safely repair Codex Desktop on Windows when openai-bundled plugins such as chrome@openai-bundled and computer-use@openai-bundled are missing, half-cached, installed but unusable, or report native pipe / node_repl / browser-client.mjs problems. Use for Windows Store/MSIX Codex bundled plugin source issues, WindowsApps copy failures, Computer Use unavailable, Browser/Chrome plugin unavailable, or requests to restore openai-bundled without resetting user configuration.
---

# Repair Computer Use

## Core Rules

Always start read-only. Explain each command before running it.

Do not change WindowsApps permissions, do not take ownership of WindowsApps, do not delete the whole `.codex` directory, and do not reset user configuration.

Before any repair, back up:

- `%USERPROFILE%\.codex\plugins`
- `%USERPROFILE%\.codex\config.toml`
- `%USERPROFILE%\.codex\codex-global-state.json`
- `%USERPROFILE%\.codex\.codex-global-state.json`

Treat `browser@openai-bundled` as optional unless the user explicitly asks for it. The usual repair target is `chrome@openai-bundled` and `computer-use@openai-bundled`.

## Quick Workflow

1. Locate this skill directory and run the bundled script in inspect mode:

```powershell
$skill = "C:\path\to\repair-computer-use"
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -InspectOnly
```

2. If `openai-bundled` is missing, points into WindowsApps, or plugin/cache files are incomplete, run repair mode:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair
```

3. To explicitly include the Chrome native host registry/manifest check, add `-CheckChromeNativeHost`. The script runs this check by default unless `-SkipChromeNativeHostCheck` is passed:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -InspectOnly -CheckChromeNativeHost
```

4. If the Chrome native host registry or manifest is missing and the user wants Chrome extension communication repaired, use the explicit native-host repair switch:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairChromeNativeHost
```

This backs up the existing native host registry key and `%LOCALAPPDATA%\OpenAI\extension` when present, then uses the Chrome plugin's own `scripts\installManifest.mjs` to write the manifest and HKCU registry value.

When running from Codex, execute this command through host PowerShell / an approved escalated command. Some Codex sandbox contexts can show a virtualized HKCU view; native host repair must be written to the real user registry hive to affect Chrome.

5. If Codex still cannot expose `node_repl`, Computer Use tools, or Chrome browser runtime after restarting Codex, repeat repair with runtime environment overrides:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -SetRuntimeEnv
```

If both runtime relocation and Chrome native host are broken, combine the explicit switches:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -SetRuntimeEnv -RepairChromeNativeHost
```

6. If inspect mode reports runtime drift after a Codex Desktop / Microsoft Store update, synchronize the local runtime from the current AppX package:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairRuntimeDrift
```

Runtime drift means the active or relocated `%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe`, `node_repl.exe`, or helper executables no longer match the current `OpenAI.Codex` AppX package. This can break new thread/task creation with errors such as `Invalid request: missing field inputSchema`.

If the runtime files are locked by a running Codex Desktop/app-server process, close Codex and rerun the command above. If you intentionally want the repair script to close and relaunch Codex for you, use the explicit force switch:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairRuntimeDrift -ForceRestartCodex
```

7. Restart Codex Desktop after `-Repair -SetRuntimeEnv`, `-RepairRuntimeDrift`, or `-RepairChromeNativeHost` unless `-ForceRestartCodex` already relaunched it.

`-SetRuntimeEnv` also copies `codex-command-runner.exe` and `codex-windows-sandbox-setup.exe` next to the relocated `codex.exe`. This matters when logs show `windows sandbox failed: spawn setup refresh` or `codex-windows-sandbox-setup.exe: program not found` after moving Codex runtime binaries out of WindowsApps.

8. If inspect mode reports stale `openai-bundled` version references in `config.toml`, repair them only with the explicit stale-config switch:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairStaleConfigRefs
```

This switch updates stale plugin cache version segments in `%USERPROFILE%\.codex\config.toml` only after the expected cache directory exists. It does not rewrite `.codex-global-state.json`.

9. Verify CLI state:

```powershell
$codex = "$env:LOCALAPPDATA\OpenAI\Codex\bin\codex.exe"
& $codex plugin marketplace list
& $codex plugin list --marketplace openai-bundled
```

Expected target lines:

```text
openai-bundled          C:\Users\<user>\.codex\openai-bundled-fixed
chrome@openai-bundled        installed, enabled
computer-use@openai-bundled  installed, enabled
```

## Chrome Native Host Check

The bundled script calls the Chrome plugin's own checker:

```text
scripts/check-native-host-manifest.js --json
```

This checks the Windows registry key:

```text
HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension
```

and validates:

- the native host manifest exists,
- the manifest name is `com.openai.codexextension`,
- `allowed_origins` includes the configured Codex Chrome extension ID,
- the registry default value points to the checked manifest,
- the manifest's `path` target exists,
- sibling `extension-host-config.json` exists.

If this check fails but plugin cache and runtime initialization pass, tell the user Chrome-side setup is the remaining problem. Do not modify WindowsApps ACLs. Prefer reinstalling or refreshing `chrome@openai-bundled` through Codex plugin repair, then restarting Codex and Chrome.

Use `-RepairChromeNativeHost` only when the user agrees to write the HKCU native messaging host registry key and manifest. This is user-scope Chrome configuration, not a WindowsApps permission change.

## Runtime Verification

Use `tool_search` to expose the `node_repl` JavaScript tool, then run lightweight runtime checks.

Computer Use check:

```javascript
const pluginRoot = String.raw`C:\Users\<user>\.codex\plugins\cache\openai-bundled\computer-use\latest`;
const { setupComputerUseRuntime } = await import(`${pluginRoot}\\scripts\\computer-use-client.mjs`);
await setupComputerUseRuntime({ globals: globalThis });
const apps = await sky.list_apps();
nodeRepl.write(JSON.stringify({ ok: true, appCount: apps.length }, null, 2));
```

Chrome runtime check:

```javascript
const pluginRoot = String.raw`C:\Users\<user>\.codex\plugins\cache\openai-bundled\chrome\latest`;
const { setupBrowserRuntime } = await import(`${pluginRoot}\\scripts\\browser-client.mjs`);
await setupBrowserRuntime({ globals: globalThis });
nodeRepl.write(JSON.stringify({
  ok: true,
  hasAgent: !!globalThis.agent,
  agentKeys: Object.keys(globalThis.agent ?? {}).slice(0, 20)
}, null, 2));
```

Do not operate windows, open tabs, or navigate pages during verification unless the user explicitly asks.

## When To Read The Reference

Read `references/failure-patterns.md` when:

- the script reports missing bundled files,
- `plugin list` is correct but runtime tools are absent,
- WindowsApps copy errors recur,
- you need to explain why the repair copies bundled plugins into the user profile.

## Repair Interpretation

The public Windows repair posts that recommend byte-stream copying the bundled `openai-bundled` source into a user-owned directory describe the same core fix: avoid WindowsApps ACL/Protected Application files, then register the copied marketplace and reinstall `chrome@openai-bundled` plus `computer-use@openai-bundled`. This skill keeps that core, but adds:

- required backups for plugins, config, and both possible global-state filenames,
- Chrome native messaging host inspection/repair,
- runtime helper relocation for `node_repl` and Windows sandbox helper failures,
- `latest` cache pointer repair for versioned plugin directories,
- SHA256 checks for critical source/cache/runtime files,
- stale config/state reference reporting, with opt-in config repair,
- cache-critical file checks instead of trusting `plugin list` alone.

The script copies the bundled marketplace from the Codex MSIX install into:

```text
%USERPROFILE%\.codex\openai-bundled-fixed
```

It then keeps user-owned cache paths populated:

```text
%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled
%USERPROFILE%\.codex\plugins\cache\openai-bundled\chrome\latest
%USERPROFILE%\.codex\plugins\cache\openai-bundled\computer-use\latest
```

With `-SetRuntimeEnv`, it also copies `codex.exe`, `node.exe`, and `node_repl.exe` into:

```text
%LOCALAPPDATA%\OpenAI\Codex\bin
```

and sets user-level environment variables:

```text
CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1
CODEX_CLI_PATH=%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe
CODEX_BROWSER_USE_NODE_PATH=%LOCALAPPDATA%\OpenAI\Codex\bin\node.exe
CODEX_NODE_REPL_PATH=%LOCALAPPDATA%\OpenAI\Codex\bin\node_repl.exe
```

It also copies these helper executables to the same directory without setting environment variables:

```text
%LOCALAPPDATA%\OpenAI\Codex\bin\codex-command-runner.exe
%LOCALAPPDATA%\OpenAI\Codex\bin\codex-windows-sandbox-setup.exe
```

Only use `-SetRuntimeEnv` when plugin/cache repair alone is not enough or when logs show Codex cannot relocate or launch bundled executables from WindowsApps.

`-RepairRuntimeDrift` uses the same current AppX package as the source of truth, but is specifically for update drift after runtime relocation. It also updates runtime-related `config.toml` values such as `BROWSER_USE_CODEX_APP_VERSION`, `CODEX_CLI_PATH`, `NODE_REPL_NODE_PATH`, and the trusted `browser-client.mjs` hashes when those entries are present.

## Update-Safe Checks

The script discovers the current `OpenAI.Codex` AppX package with `Get-AppxPackage` and reads each plugin's `.codex-plugin\plugin.json` version. After Codex updates, repair mode repopulates both:

```text
%USERPROFILE%\.codex\plugins\cache\openai-bundled\<plugin>\<version>
%USERPROFILE%\.codex\plugins\cache\openai-bundled\<plugin>\latest
```

If `latest` is a stale junction, the script removes only that reparse point inside the expected plugin cache directory and recreates it. If `latest` is a regular directory, the script synchronizes the current plugin files into it.

Inspect and final verification also report:

- current vs stale `latest` cache pointers,
- SHA256 matches or mismatches for critical files,
- stale AppX/package or `openai-bundled\<plugin>\<version>` references in tracked config/state files.
