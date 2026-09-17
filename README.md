# doubao_helper

豆包语音助手：面向 macOS 的本地增强层。它使用额外鼠标键触发豆包听写，并对本次听写文本执行确定性的本地语音宏替换。

> 产品化需求和目标架构见：
>
> - [`docs/PRODUCT_REQUIREMENTS.md`](docs/PRODUCT_REQUIREMENTS.md)
> - [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md)

## 当前原型行为

- 前进键按住：模拟左 Ctrl（豆包开始）；松开：再模拟左 Ctrl（结束）
- 后退键单击：回车（发送）
- 排除：Finder / Safari / Chrome / Ego lite 等，前进后退仍是系统导航

原型仍保留在 `src/`、`app/`、`config/` 和 `plists/` 中，作为行为参考。正式 App 不依赖个人目录、LaunchAgent 或 Logi Options+ 私有数据库。

## 正式 App

## 目录

| `Package.swift` | Swift Package 的 Core、App 和测试目标 |
| `Sources/DoubaoVoiceHelperCore/` | 规则引擎、设置、权限、快捷键和 AX 文本适配器 |
| `Sources/DoubaoVoiceHelper/` | 菜单栏 App、事件监听、设置窗口和状态浮层 |
| `Tests/` | 语音宏与设置持久化测试 |
| `scripts/build_app.sh` | 构建并生成可手工分发的 `.app` |

### 开发

需要 macOS 14+ 和 Swift 5.9 或更高版本。当前环境若只有 Command Line Tools，也可以运行核心测试和 Swift Package 构建；完整 Xcode 主要用于签名、调试和发布。

```bash
swift build -c release
swift run DoubaoVoiceHelperCoreTests
./scripts/build_app.sh
```

生成的 App 位于 `build/DoubaoVoiceHelper.app`。首次启动需要在“系统设置 → 隐私与安全性”中授予辅助功能权限；本 App 不需要麦克风权限。

双击 App 会直接打开设置窗口；之后也可以从菜单栏的麦克风图标打开设置。先在设置中捕获鼠标额外按键，再录入豆包快捷键。

首版的语音宏只在 AX 能够证明文本范围时写回。Terminal.app、Ghostty、Cursor/VS Code 内嵌终端的真实兼容性仍需在目标 macOS 版本上逐一验收；无法证明时只触发豆包并保留原文。
3. 打开 `DoubaoMousePTT.app`，辅助功能允许
4. 豆包快捷键保持左 Ctrl（点一下开、再点一下关）
