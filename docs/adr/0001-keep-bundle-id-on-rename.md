# 改名只改显示名，bundle ID 保持不变

应用不再只服务豆包输入法，因此显示名（CFBundleDisplayName）从“豆包语音助手”改为“语音输入助手”；bundle ID `com.jarod.doubao-voice-helper`、CFBundleName 与代码 target 名 `DoubaoVoiceHelper`、设置目录 `~/Library/Application Support/DoubaoVoiceHelper` 都保持不变。改 bundle ID 会让每位用户重新授予辅助功能（以及使用侧键时的输入监控）权限；应用内更新要求更新包的 bundle ID 与当前一致（`UpdateVerifier`），所以会失效一次、只能手动下载新版；设置目录也要迁移，以后若引入钥匙串，条目还得跟着迁移。显示名与内部标识不一致是有意为之，不要顺手统一。
