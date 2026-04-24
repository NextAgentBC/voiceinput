# Voice Input 语音输入

[English](#english) | [中文](#中文)

---

## 中文

按住 Fn 键说话，松开自动输入文字到任何应用。简单、快速、支持中英文。

### 安装

1. 下载 [VoiceInput-0.3.0.dmg](https://github.com/NextAgentBC/voiceinput/releases/latest)
2. 打开 DMG，将 **VoiceInput.app** 拖到 **应用程序** 文件夹
3. 双击打开 VoiceInput
4. 授权 **辅助功能** 权限（全局快捷键必需）：
   - 打开 **系统设置 → 隐私与安全 → 辅助功能**
   - 点 **+**，添加 **VoiceInput.app** 并打开开关
5. 菜单栏出现 🎤 图标 — 完成！

### 使用方法

| 操作 | 功能 |
|------|------|
| **按住 Fn** | 开始录音 |
| **松开 Fn** | 停止录音，自动转写并输入 |
| **Escape** | 取消录音 |
| **Cmd+Z** | 撤销已输入的文字 |

适用于任何应用 — 微信、Chrome、备忘录、VS Code 等。

### 语音引擎

点击菜单栏 🎤 → **Settings** 选择引擎：

| 引擎 | 说明 |
|------|------|
| **Apple (本地)** | 默认。免费、离线、无需配置 |
| **Cloud API** | 自定义 STT 服务器，需填 API 地址和 Key |
| **Local Whisper** | 即将推出 |

### 自动发送

如果你在聊天应用（如微信）中使用，可以开启自动发送：
1. 点击菜单栏 🎤 → **Settings**
2. 勾选 **Auto Send**
3. 选择发送快捷键：**Enter** 或 **Cmd+Enter**（需与你的聊天应用设置一致）

### 系统要求

- macOS 14.0 (Sonoma) 或更高
- Apple Silicon 或 Intel Mac

### 常见问题

**Q: 按 Fn 没反应？**
A: 请检查辅助功能权限（系统设置 → 隐私与安全 → 辅助功能）。重新安装后需要重新授权。

**Q: Fn 触发了表情选择器？**
A: 在系统设置 → 键盘中，将「按下 🌐 键时」改为「不执行任何操作」。

**Q: 支持哪些语言？**
A: 简体中文、English、日本語、한국어。在 Settings 中切换。

### 隐私

- **Apple 引擎**：所有数据在本地处理，不上传任何服务器
- **Cloud API**：音频发送到你自己配置的服务器
- VoiceInput 不收集任何用户数据

---

## English

Hold the Fn key to speak, release to automatically type the transcription into any app. Simple, fast, supports Chinese and English.

### Installation

1. Download [VoiceInput-0.3.0.dmg](https://github.com/NextAgentBC/voiceinput/releases/latest)
2. Open the DMG, drag **VoiceInput.app** to **Applications**
3. Launch VoiceInput
4. Grant **Accessibility** permission (required for global hotkey):
   - Open **System Settings → Privacy & Security → Accessibility**
   - Click **+**, add **VoiceInput.app** and enable the toggle
5. A 🎤 icon appears in the menu bar — done!

### Usage

| Action | Function |
|--------|----------|
| **Hold Fn** | Start recording |
| **Release Fn** | Stop recording, transcribe and paste |
| **Escape** | Cancel recording |
| **Cmd+Z** | Undo pasted text |

Works in any app — WeChat, Chrome, Notes, VS Code, etc.

### Speech Engines

Click the 🎤 menu bar icon → **Settings** to choose:

| Engine | Description |
|--------|-------------|
| **Apple (Local)** | Default. Free, offline, no setup needed |
| **Cloud API** | Custom STT server (requires endpoint + API key) |
| **Local Whisper** | Coming soon |

### Auto Send

For chat apps (e.g. WeChat), enable auto-send to press Enter after transcription:
1. Click 🎤 → **Settings**
2. Enable **Auto Send**
3. Choose send key: **Enter** or **Cmd+Enter** (must match your chat app setting)

### System Requirements

- macOS 14.0 (Sonoma) or later
- Apple Silicon or Intel Mac

### FAQ

**Q: Fn key doesn't work?**
A: Check Accessibility permission (System Settings → Privacy & Security → Accessibility). Re-installation requires re-authorization.

**Q: Fn triggers emoji picker?**
A: In System Settings → Keyboard, change "Press 🌐 key to" to "Do Nothing".

**Q: What languages are supported?**
A: Simplified Chinese, English, Japanese, Korean. Switch in Settings.

### Privacy

- **Apple engine**: All data processed locally, nothing uploaded
- **Cloud API**: Audio sent to your configured server only
- VoiceInput collects no user data

---

## License

Licensed under the [Apache License, Version 2.0](LICENSE).

Copyright 2026 Yao Song.

## Links

- [GitHub](https://github.com/NextAgentBC/voiceinput)
- [Download](https://github.com/NextAgentBC/voiceinput/releases/latest)

Made with ❤️ by [NexAgent AI Solutions](https://nextagent.ca)
