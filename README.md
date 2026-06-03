# Repair Codex Computer Use on Windows

中文说明: [README.zh-CN.md](README.zh-CN.md)

Safely diagnose and repair Codex Desktop for Windows when the bundled `openai-bundled` plugins are missing, half-cached, or installed but unusable.

Primary targets:

- `chrome@openai-bundled`
- `computer-use@openai-bundled`

This repair is intended for the Windows Store/MSIX Codex app, where bundled plugins live under the protected `WindowsApps` package directory.

## What This Fix Does

- Starts with inspect-only diagnostics by default.
- Backs up user Codex state before repair.
- Copies Codex's bundled `openai-bundled` marketplace into a user-owned directory.
- Re-registers the local marketplace and refreshes target plugins.
- Repairs `latest` cache pointers after Codex version updates.
- Checks Chrome native messaging host registration.
- Optionally repairs the Chrome native host manifest and HKCU registry key.
- Optionally relocates Codex runtime executables out of `WindowsApps`.
- Reports stale config/state references without dumping private config contents.

## What This Fix Does Not Do

- It does not delete `%USERPROFILE%\.codex`.
- It does not reset all Codex settings.
- It does not change `WindowsApps` permissions.
- It does not take ownership of `WindowsApps`.
- It does not modify unrelated marketplaces or plugins.

## Quick Start

Open PowerShell and run inspect mode first:

```powershell
$skill = "C:\path\to\repair-computer-use"
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -InspectOnly
```

Run the standard repair:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair
```

If Computer Use, Chrome runtime, or `node_repl` still fails after restarting Codex:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -SetRuntimeEnv
```

If Chrome native host registration is broken:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairChromeNativeHost
```

For a full repair after a Codex update:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -SetRuntimeEnv -RepairChromeNativeHost
```

Restart Codex Desktop after runtime or native-host repair.

## Optional Stale Config Repair

Inspect mode reports stale `openai-bundled\<plugin>\<version>` references in tracked config/state files.

To update stale plugin cache version references in `config.toml`, use the explicit switch:

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairStaleConfigRefs
```

This does not rewrite `.codex-global-state.json`.

## Expected Success Indicators

`codex plugin list --marketplace openai-bundled` should show:

```text
chrome@openai-bundled        installed, enabled
computer-use@openai-bundled  installed, enabled
```

Inspect output should also show:

- critical file checks are `OK`,
- `latest` cache pointers are current,
- important hashes are `HASH OK`,
- Chrome native host check reports `correct: true` when Chrome repair is relevant.

## Useful Issue Details

When opening an issue, include:

- Codex Desktop version or `codex --version`,
- `codex plugin marketplace list`,
- `codex plugin list --marketplace openai-bundled`,
- inspect output from this script,
- whether `-SetRuntimeEnv` or `-RepairChromeNativeHost` was used.

Do not paste full `config.toml` or `.codex-global-state.json` unless you have reviewed and redacted it.

## License

Choose a license before publishing this repository publicly.
