# Codex Desktop openai-bundled Failure Patterns

Use this reference after the main workflow when deciding whether to repair, explain risk, or continue deeper diagnosis.

## Common Symptoms

- `Computer Use native pipe path is unavailable`
- Computer Use or Browser/Chrome tools are absent in a fresh Codex thread
- `chrome@openai-bundled` shows installed but Chrome cannot be used
- `chrome\latest` exists but misses `scripts\browser-client.mjs`
- `chrome\latest` is a junction pointing to a removed old version directory
- `computer-use\latest` exists but misses `scripts\computer-use-client.mjs`
- `openai-bundled` marketplace root points into `C:\Program Files\WindowsApps\...`
- Copying bundled plugins from WindowsApps fails with unusual OS errors
- `node_repl` is not available even though the plugin appears installed
- `node_repl kernel exited unexpectedly` with `windows sandbox failed: spawn setup refresh`
- Sandbox logs show `codex-windows-sandbox-setup.exe: program not found`
- Sandbox logs show the relocated `codex.exe` cannot find `codex-command-runner.exe`

## Why The User-Owned Copy Helps

Windows Store/MSIX installs Codex under `C:\Program Files\WindowsApps`, which is protected by Windows. Codex updates can copy bundled plugin data into user cache directories. If that copy is interrupted or cannot read an executable/script correctly, the marketplace and plugin cache can become half-populated.

The safer repair is to copy:

```text
<Codex AppX>\app\resources\plugins\openai-bundled
```

to:

```text
%USERPROFILE%\.codex\openai-bundled-fixed
```

and register that local user-owned directory as the `openai-bundled` marketplace source.

Do not modify WindowsApps ACLs. Do not take ownership of WindowsApps.

## Critical Files

Marketplace source:

```text
%USERPROFILE%\.codex\openai-bundled-fixed\.agents\plugins\marketplace.json
%USERPROFILE%\.codex\openai-bundled-fixed\plugins\chrome\.codex-plugin\plugin.json
%USERPROFILE%\.codex\openai-bundled-fixed\plugins\computer-use\.codex-plugin\plugin.json
```

Chrome runtime:

```text
%USERPROFILE%\.codex\plugins\cache\openai-bundled\chrome\latest\scripts\browser-client.mjs
%USERPROFILE%\.codex\plugins\cache\openai-bundled\chrome\latest\extension-host
%USERPROFILE%\.codex\plugins\cache\openai-bundled\chrome\latest\scripts\check-native-host-manifest.js
```

Computer Use runtime:

```text
%USERPROFILE%\.codex\plugins\cache\openai-bundled\computer-use\latest\scripts\computer-use-client.mjs
%USERPROFILE%\.codex\plugins\cache\openai-bundled\computer-use\latest\node_modules\@oai\sky\bin\windows\codex-computer-use.exe
```

Runtime executable overrides, when needed:

```text
%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe
%LOCALAPPDATA%\OpenAI\Codex\bin\node.exe
%LOCALAPPDATA%\OpenAI\Codex\bin\node_repl.exe
%LOCALAPPDATA%\OpenAI\Codex\bin\codex-command-runner.exe
%LOCALAPPDATA%\OpenAI\Codex\bin\codex-windows-sandbox-setup.exe
```

Plugin cache version pointers:

```text
%USERPROFILE%\.codex\plugins\cache\openai-bundled\chrome\<plugin.json version>
%USERPROFILE%\.codex\plugins\cache\openai-bundled\chrome\latest
%USERPROFILE%\.codex\plugins\cache\openai-bundled\computer-use\<plugin.json version>
%USERPROFILE%\.codex\plugins\cache\openai-bundled\computer-use\latest
```

Chrome native host registry and manifest:

```text
HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension
%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json
```

The native host manifest should point to `extension-host.exe`, and the same directory should contain `extension-host-config.json`.

The repair script can rewrite these with:

```powershell
.\scripts\Repair-CodexBundledComputerUse.ps1 -Repair -RepairChromeNativeHost
```

This uses the bundled Chrome plugin's `scripts\installManifest.mjs`; it does not hand-edit WindowsApps permissions.

When Codex runs this command from a sandboxed shell, re-check from host PowerShell. A sandboxed HKCU write can appear correct inside the sandbox but still be missing from the real Chrome-visible registry hive.

## Expected CLI Output

```text
MARKETPLACE             ROOT
openai-bundled          C:\Users\<user>\.codex\openai-bundled-fixed
```

```text
PLUGIN                       STATUS              VERSION
chrome@openai-bundled        installed, enabled  latest
computer-use@openai-bundled  installed, enabled  latest
```

`browser@openai-bundled` can be `not installed` unless the user specifically asked to install it.

## Escalation Guide

If plugin list is correct but runtime still fails:

1. Restart Codex Desktop.
2. Check whether `tool_search` can expose `node_repl`.
3. If `node_repl` is absent, run repair with `-SetRuntimeEnv` and restart Codex again.
4. If sandbox logs mention `codex-windows-sandbox-setup.exe` or `codex-command-runner.exe`, confirm those files exist under `%LOCALAPPDATA%\OpenAI\Codex\bin` and match the current Codex AppX package hashes.
5. Check whether `latest` points to or contains the plugin version declared by the current bundled `plugin.json`.
6. Check Chrome native host state with `-InspectOnly -CheckChromeNativeHost`.
7. If the native host registry or manifest is missing, run repair with `-RepairChromeNativeHost`.
8. If stale `config.toml` version references are reported, use `-RepairStaleConfigRefs` only after confirming backups were created.
9. If `node_repl` exists, import the plugin client scripts and run only lightweight initialization checks.
10. If initialization succeeds but operation fails, diagnose the application-specific failure instead of repeating marketplace repair.

## What Not To Do

- Do not delete `%USERPROFILE%\.codex`.
- Do not remove unrelated marketplaces or plugins.
- Do not recursively delete plugin cache before backing it up.
- Do not edit WindowsApps permissions.
- Do not claim success from `plugin list` alone; verify runtime initialization when the user reported tool absence.
