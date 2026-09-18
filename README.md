# doubao_helper

豆包语音助手：面向 macOS 的本地增强层。它用三个独立鼠标映射控制豆包切换式语音、按住式语音和回车，并对本次听写文本执行确定性的本地语音宏替换。

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
| `scripts/build_app.sh` | 构建并生成签名的 `.app` |
| `scripts/setup_local_signing.sh` | 一次性创建本机稳定开发签名 |

### 开发

需要 macOS 14+ 和 Swift 5.9 或更高版本。当前环境若只有 Command Line Tools，也可以运行核心测试和 Swift Package 构建；完整 Xcode 主要用于签名、调试和发布。

```bash
swift build -c release
swift run DoubaoVoiceHelperCoreTests
./scripts/setup_local_signing.sh
./scripts/build_app.sh
```

首次在本机开发时运行一次 `./scripts/setup_local_signing.sh`。它会把一个仅用于本机的稳定签名身份存入 macOS 登录钥匙串，不会把证书或私钥写入仓库。之后 `build_app.sh` 会使用同一个身份签名，普通重新编译不会因为代码哈希变化而反复触发辅助功能或输入监控授权。

如果已经有 Apple Developer 签名身份，可以跳过本机签名，并这样构建：

```bash
CODESIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" ./scripts/build_app.sh
```

生成的 App 位于 `build/DoubaoVoiceHelper.app`。首次启动需要在“系统设置 → 隐私与安全性”中授予辅助功能权限；本 App 不需要麦克风权限。请始终启动这一份 App，不要在旧的 `DoubaoMousePTT.app` 或其他路径的副本之间切换。

双击 App 会直接打开设置窗口；之后也可以从菜单栏的麦克风图标打开设置。设置页默认提供：

- 前进键（button 4）→ 左 Control，切换式语音
- 左键（button 0）长按 → 左 Control + Option，按住式语音
- 后退键（button 3）→ Return

首次使用前先授权辅助功能和输入监控，再按需修改三组鼠标键与快捷键。

首版的语音宏只在 AX 能够证明文本范围时写回。Terminal.app、Ghostty、Cursor/VS Code 内嵌终端的真实兼容性仍需在目标 macOS 版本上逐一验收；无法证明时只触发豆包并保留原文。
3. 打开 `DoubaoMousePTT.app`，辅助功能允许
4. 豆包快捷键保持左 Ctrl（点一下开、再点一下关）
