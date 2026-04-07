# Voice Input — Mac 语音输入工具

按住 Fn 键说话，松开自动输入文字。简单、快速、支持中英文。

## 安装

1. 下载 [VoiceInput-0.1.0.dmg](https://nextagent.ca/VoiceInput-0.1.0.dmg)
2. 打开 DMG，将 **VoiceInput.app** 拖到 **Applications（应用程序）** 文件夹
3. 双击打开 VoiceInput.app
4. 首次打开会提示授权 **辅助功能** 权限 — 这是全局快捷键必需的：
   - 打开 **系统设置 → 隐私与安全 → 辅助功能**
   - 点 **+**，找到 **VoiceInput.app** 添加并打开开关

<img width="400" alt="accessibility" src="https://help.apple.com/assets/67BA58080C06A05919043E35/67BA580A0C06A05919043E45/zh_CN/a2d0a1fe05544c2a83e3dd07a6eed52c.png">

5. 菜单栏出现 🎤 图标 — 安装完成！

## 使用

| 操作 | 功能 |
|------|------|
| **按住 Fn** | 开始录音 |
| **松开 Fn** | 停止录音，自动转写并输入到当前光标位置 |
| **Escape** | 取消录音 |
| **Cmd+Z** | 撤销已输入的文字 |

在任何 App 中都能使用 — Chrome、微信、Notes、VS Code 等。

## 语音引擎

点击菜单栏 🎤 图标 → **Settings** 选择引擎：

| 引擎 | 说明 |
|------|------|
| **Apple (Local)** | 默认。免费、离线、无需配置 |
| **Cloud API** | 自定义 STT 服务器，需填入 API 地址和 Key |
| **Local Whisper** | 即将推出 |

### 使用 Cloud API

如果你有自己的 STT 服务器（如 Whisper API、Cohere Transcribe 等）：

1. 点击菜单栏 🎤 → **Settings**
2. 选择 **Cloud API**
3. 填入 **API Endpoint**（如 `https://your-server.com/v1/audio/transcriptions`）
4. 填入 **API Key**
5. 点 **Test Connection** 验证

API 需兼容 OpenAI Whisper 格式（multipart form，返回 `{"text": "..."}`）。

## 系统要求

- macOS 14.0 (Sonoma) 或更高版本
- Apple Silicon 或 Intel Mac

## 常见问题

**Q: 按 Fn 没反应？**
A: 检查辅助功能权限是否已授权（系统设置 → 隐私与安全 → 辅助功能）。如果从 DMG 重新安装了，需要重新授权。

**Q: Fn 键会触发表情符号选择器？**
A: VoiceInput 会自动拦截 Fn 键。如果表情选择器仍然出现，请在系统设置 → 键盘中将 "按下 🌐 键时" 改为 "不执行任何操作"。

**Q: 使用 Apple 引擎时首次录音很慢？**
A: 首次使用需要下载 Apple 语音模型，之后会更快。

**Q: 支持哪些语言？**
A: Settings 中可选：简体中文、English、日本語、한국어。

## 隐私

- **Apple (Local) 引擎**：所有语音数据在本地处理，不上传任何服务器
- **Cloud API 引擎**：音频发送到你配置的服务器地址
- VoiceInput 不收集任何用户数据

## 开源

[GitHub](https://github.com/user/voiceinput) · MIT License

---

Made with ❤️ by NexAgent AI Solutions
