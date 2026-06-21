---
name: repair-computer-use
description: 在 Windows 版 Codex Desktop 中安全诊断并修复 openai-bundled 插件源问题，尤其是 chrome@openai-bundled 和 computer-use@openai-bundled 缺失、缓存半残缺、安装但不可用、native pipe、node_repl、browser-client.mjs 或 Chrome native host 相关问题。
---

# 修复 Computer Use

## 核心原则

始终先只读检查。运行命令前说明命令作用。

不要修改 `WindowsApps` 权限，不要接管 `WindowsApps` 所有权，不要删除整个 `.codex` 目录，不要重置用户全部配置。

修复前必须备份：

- `%USERPROFILE%\.codex\plugins`
- `%USERPROFILE%\.codex\config.toml`
- `%USERPROFILE%\.codex\codex-global-state.json`
- `%USERPROFILE%\.codex\.codex-global-state.json`

默认目标是：

- `chrome@openai-bundled`
- `computer-use@openai-bundled`

`browser@openai-bundled` 默认视为可选，除非用户明确要求。

## 快速流程

只读检查：

```powershell
$skill = "C:\path\to\repair-computer-use"
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -InspectOnly
```

标准修复：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair
```

修复 Chrome native host：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairChromeNativeHost
```

修复 runtime helper 和环境变量：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -SetRuntimeEnv
```

修复 Codex 更新后的 runtime drift，例如新建对话/任务时报 `Invalid request: missing field inputSchema`：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairRuntimeDrift
```

如果 Codex 正在占用 runtime 文件，并且用户明确允许脚本自动关闭并重启 Codex：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairRuntimeDrift -ForceRestartCodex
```

Codex 更新后完整修复：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -SetRuntimeEnv -RepairChromeNativeHost
```

修复 `config.toml` 中旧版本插件路径：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairStaleConfigRefs
```

涉及 `-SetRuntimeEnv`、`-RepairRuntimeDrift` 或 `-RepairChromeNativeHost` 后，完全退出并重开 Codex Desktop；如果使用了 `-ForceRestartCodex`，脚本会尝试自动完成这一步。

## 修复思路

Windows Store/MSIX 版 Codex 的 bundled 插件源位于受保护的 `WindowsApps` 目录。安全修复方式是把：

```text
<Codex AppX>\app\resources\plugins\openai-bundled
```

复制到用户目录：

```text
%USERPROFILE%\.codex\openai-bundled-fixed
```

然后把这个用户可读写目录注册为 `openai-bundled` marketplace。

脚本还会维护：

```text
%USERPROFILE%\.codex\.tmp\bundled-marketplaces\openai-bundled
%USERPROFILE%\.codex\plugins\cache\openai-bundled\<plugin>\<version>
%USERPROFILE%\.codex\plugins\cache\openai-bundled\<plugin>\latest
```

如果 `latest` 是旧 junction，脚本只会在预期插件 cache 目录内部移除该 reparse point 并重建；不会删除整个 `.codex`。

## Chrome Native Host

脚本会调用 Chrome 插件自己的检查脚本：

```text
scripts/check-native-host-manifest.js --json
```

它会验证：

- `HKCU\Software\Google\Chrome\NativeMessagingHosts\com.openai.codexextension`
- `%LOCALAPPDATA%\OpenAI\extension\com.openai.codexextension.json`
- manifest 名称、allowed origin、registry 指向、`extension-host.exe` 和 `extension-host-config.json`

只有用户明确使用 `-RepairChromeNativeHost` 时才写 HKCU 注册表和 manifest。

## Runtime Helper

`-SetRuntimeEnv` 会把这些文件复制到：

```text
%LOCALAPPDATA%\OpenAI\Codex\bin
```

包括：

- `codex.exe`
- `node.exe`
- `node_repl.exe`
- `codex-command-runner.exe`
- `codex-windows-sandbox-setup.exe`

并设置用户级环境变量：

```text
CODEX_ELECTRON_ENABLE_WINDOWS_COMPUTER_USE=1
CODEX_CLI_PATH=%LOCALAPPDATA%\OpenAI\Codex\bin\codex.exe
CODEX_BROWSER_USE_NODE_PATH=%LOCALAPPDATA%\OpenAI\Codex\bin\node.exe
CODEX_NODE_REPL_PATH=%LOCALAPPDATA%\OpenAI\Codex\bin\node_repl.exe
```

`-RepairRuntimeDrift` 专门处理 Codex Desktop / Microsoft Store 更新后的版本漂移：当前 AppX 包中的 `codex.exe` 已更新，但 `%LOCALAPPDATA%\OpenAI\Codex\bin` 中的旧 `codex.exe`、`node_repl.exe` 或 helper 仍被配置引用。脚本会从当前 AppX 包重新同步 runtime，并在存在相关条目时更新 `config.toml` 中的 `BROWSER_USE_CODEX_APP_VERSION`、runtime 路径和 `browser-client.mjs` trusted hash。

## 验证

CLI 应显示：

```text
chrome@openai-bundled        installed, enabled
computer-use@openai-bundled  installed, enabled
```

`-InspectOnly` 应显示关键文件 `OK`、hash `HASH OK`、`latest` 指向当前版本、active/bundled `codex.exe` 版本一致，并且没有 stale config/state 引用。

不要只凭 `plugin list` 判断成功；如果用户报告工具不可用，还要做 runtime 初始化验证。
