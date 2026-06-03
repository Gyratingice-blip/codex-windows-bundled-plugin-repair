# 修复 Windows 版 Codex Computer Use

English: [README.md](README.md)

这个项目用于安全诊断和修复 Windows 版 Codex Desktop 中 `openai-bundled` 插件源异常导致的 Chrome / Computer Use 不可用问题。

主要目标插件：

- `chrome@openai-bundled`
- `computer-use@openai-bundled`

适用场景包括：

- `Computer Use native pipe path is unavailable`
- Computer Use 或 Chrome 插件显示已安装但不可用
- `chrome\latest` 或 `computer-use\latest` 指向旧版本
- `openai-bundled` marketplace 指向 `WindowsApps` 受保护目录
- Codex 更新后 bundled 插件缓存半残缺
- `node_repl` / `browser-client.mjs` / native host 相关错误

## 它会做什么

- 默认只读检查，不直接修改配置。
- 修复前备份用户 Codex 状态。
- 把 Codex MSIX 包中的 `openai-bundled` 复制到用户目录。
- 重新注册本地 marketplace。
- 刷新 `chrome` 和 `computer-use` 插件缓存。
- 修复 `latest` 指针或目录。
- 校验关键文件 SHA256。
- 检查 Chrome native messaging host。
- 可选修复 Chrome native host 注册表和 manifest。
- 可选复制 Codex runtime helper，避免 WindowsApps 启动限制。
- 报告并可选修复 `config.toml` 中旧版本插件路径。

## 它不会做什么

- 不删除 `%USERPROFILE%\.codex`。
- 不重置全部 Codex 配置。
- 不修改 `WindowsApps` 权限。
- 不接管 `WindowsApps` 所有权。
- 不删除无关 marketplace 或插件。

## 快速开始

先运行只读检查：

```powershell
$skill = "C:\path\to\repair-computer-use"
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -InspectOnly
```

标准修复：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair
```

如果重启 Codex 后 Computer Use、Chrome runtime 或 `node_repl` 仍不可用：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -SetRuntimeEnv
```

如果 Chrome native host 注册异常：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairChromeNativeHost
```

Codex 更新后的完整修复入口：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -SetRuntimeEnv -RepairChromeNativeHost
```

涉及 runtime 或 native host 修复后，需要完全退出并重开 Codex Desktop。

## 可选：修复旧配置引用

只读检查会报告 `config.toml` / state 文件里残留的旧 `openai-bundled\<plugin>\<version>` 路径。

如需修复 `config.toml` 中的旧版本路径，使用显式开关：

```powershell
powershell -ExecutionPolicy Bypass -File "$skill\scripts\Repair-CodexBundledComputerUse.ps1" -Repair -RepairStaleConfigRefs
```

这个开关只改 `config.toml` 中的旧插件 cache 版本号，不重写 `.codex-global-state.json`。

## 成功标志

`codex plugin list --marketplace openai-bundled` 应显示：

```text
chrome@openai-bundled        installed, enabled
computer-use@openai-bundled  installed, enabled
```

`-InspectOnly` 还应显示：

- 关键文件检查为 `OK`
- `latest` 指向当前版本
- 关键文件为 `HASH OK`
- 没有 stale config/state 引用
- Chrome native host 在相关场景下为 `correct: true`

## 提交 issue 时建议提供

- Codex Desktop 版本或 `codex --version`
- `codex plugin marketplace list`
- `codex plugin list --marketplace openai-bundled`
- 本脚本的 `-InspectOnly` 输出
- 是否运行过 `-SetRuntimeEnv` 或 `-RepairChromeNativeHost`

不要直接粘贴完整 `config.toml` 或 `.codex-global-state.json`，除非已经检查并脱敏。

## 许可证

MIT License.
