# 语音宏重新设计：实施文档

- 对应设计：[design.md](./design.md)
- 基线：v0.2.0（f73d677）
- 术语以 `CONTEXT.md` 为准。

## 0. 约定

- **构建**：`swift build`
- **单元测试**：`swift run DoubaoVoiceHelperCoreTests`
  - 这是自定义测试运行器，不是 XCTest。
  - 新测试写成 `private func testXxx() throws`，再加进 `Tests/DoubaoVoiceHelperCoreTests/main.swift` 里的 `tests` 数组（约 :1302-1353）。
- **打包**：`./scripts/build_app.sh`。它使用本机的自签名证书 “DoubaoVoiceHelper Development”，辅助功能授权在重新构建后可以保留。
- **开发方式**：
  - Core 里的纯逻辑先写测试再实现（红、绿、重构）。
  - App 目标里的协调器没有测试入口，靠手工验收清单（第 9 节）覆盖。
- **提交**：每个阶段结束时，构建和测试都要通过。提交与否由用户决定。
- **隐私**：任何日志、会话记录、测试夹具里都不能出现用户的真实规则内容和听写文字。

## 1. 阶段总览

| 阶段 | 内容 | 依赖 | 预估 |
|---|---|---|---|
| P0 | 三项限时验证：微信、终端校验、提前替换的实际表现 | 无 | 1 天 |
| P1 | 修复 schema 升级重复追加默认排除应用的 bug | 无 | 0.5 天 |
| P2 | Core：归一化、整句匹配与判断、校验、schema 13 合并规则 | P1 | 1 天 |
| P3 | TextTargets：边读边判断、写回前内容变化时重试、校验放宽、终端校验修复 | P0（S2）、P2 | 1 天 |
| P4 | 协调器：提前放弃和提前替换、回车等待、最近识别的后台补读 | P3 | 1 天 |
| P5 | 诊断：会话编号、新事件、本地会话记录 | P4（可与 P4 并行） | 0.5 天 |
| P6 | 界面：规则列表、校验提示、试一试、最近识别、微信标注 | P2、P4 | 1 天 |
| P7 | 文档：ARCHITECTURE、README | P6 | 0.5 天 |
| P8 | 验收：自动测试、手工清单、一周数据 | 全部 | 持续一周 |

## 2. P0：限时验证

三项验证都只读或只在临时代码里做，结论写回本文件的“验证记录”（第 11 节）。

### S1 微信能否读到输入框（1 到 2 小时）

1. 用系统自带的 Accessibility Inspector 查看微信聊天输入框：能否选中、角色是什么、有没有 `AXValue` 和 `AXSelectedTextRange`。
2. 写一个临时 Swift 脚本（放在 `$TMPDIR`，不进仓库），按下面的顺序各试一次：
   - 系统级 `AXFocusedUIElement`；
   - 微信应用元素的 `AXFocusedUIElement`；
   - 焦点窗口向下遍历，找可编辑的文本元素；
   - 给微信应用元素设置 `AXManualAccessibility = true`，以及 `AXEnhancedUserInterface = true`，再重复前三步。
3. 记录哪一种方式能读到值和选区，以及设置开关后微信有没有异常，例如界面变慢或窗口跳动。

**决策门：**

- **能稳定读到**：在 `AXTextAdapter.focusedElement` 里加入对应的方式（只对微信生效），纳入 P3。
- **读不到**：微信保持“只控制启停”，P6 在设置里加标注；锚点失败时不再重复提示“宏替换不可用”。

### S2 终端校验误报（不超过半天）

1. 在 `replaceInTerminal`（`TextTargets.swift:399-424`）里临时加一条诊断事件，只记元数据：
   - 每次读回时内容长度的变化；
   - 读回内容是否以“键入前的前文”开头；
   - 是否以“前文 + 目标文本”开头；
   - 目标文本在读回内容里第一次出现的位置（UTF-16 偏移）。
2. 分别在 Orca（zsh 提示符、Claude Code）和 Ghostty（zsh 提示符、Claude Code）里说 “usage”，各测 5 次。
3. 对照设计文档第 9.2 节的三个假设，找出原因。
4. 按原因修正校验，常见的修法有：
   - 改为检查插入点附近的内容；
   - 改为比较整屏缓冲区中光标所在行；
   - 延长或调整读回窗口。
5. 修不好的终端 bundle ID，加进 Core 的常量 `AppSettings.unverifiedTypingTerminalBundleIDs`：这些终端键入完成即算成功，不做读回校验。
6. 删掉临时诊断，保留有长期价值的元数据字段。

**决策门：** Orca 和 Ghostty 都要得出结论，二选一：要么校验已修好，要么已加进免校验名单。没得出结论之前，P4 的“失败不发送回车”不能上线。

### S3 提前替换的实际表现（2 小时）

在 TextEdit（原生控件，作为基准）、Notion、Orca、Ghostty 里，用临时开关把“命中即替换”打开，各说 10 次触发词，观察：

- 豆包在替换后补标点的频率，以及补在什么位置（替换结果后面，还是别处）；
- 豆包有没有在替换后重新写入整段文字，把 “/usage” 改回 “usage”；
- 写回前“内容已变化、回到轮询”的发生次数。

**决策门：**

- 如果豆包经常在替换后重写整段文字：保持提前替换，但把“豆包在停止后多久内可能重写”的实测数据写进第 11 节，交给用户重新决定是否改为“命中后等文字稳定再替换”。
- 其他情况：照设计实现。

## 3. P1：修复 schema 升级 bug

**问题：** `Models.swift:361-367` 在 `decodedSchemaVersion < currentSchemaVersion` 时，会把所有默认排除应用重新加回来，用户删掉的也一样。

**改动：**

- 在 `AppSettings` 里新增一张表，记录每个默认导航排除应用是在哪个 schema 版本加入的，例如：

  ```swift
  static let navigationExcludedDefaultsIntroducedIn: [String: Int] = [
      "com.apple.finder": 1,
      // 现有默认值逐个标注，拿不准的一律标成 12 以下，保证 12 → 13 升级不会补回
  ]
  ```

- 升级时只补“加入版本 > 旧 schema 版本”的应用。
- 本应用自己的 bundle ID 仍然无条件保留（:373-375），不受影响。

**测试：**

- `testSchemaUpgradeKeepsRemovedDefaultExcludes`：schema 12 的设置删掉 Finder，升级到 13 后仍然没有 Finder。
- `testSchemaUpgradeAddsNewlyIntroducedExclude`：构造一个标注为 13 的默认值，从 12 升级时会补上。
- 现有迁移测试（:232-453、:701-870）全部保持通过。

## 4. P2：Core 匹配

### 4.1 归一化

新增 `MacroNormalizer`，放在 `MacroEngine.swift` 里：

```swift
public enum MacroNormalizer {
    /// NFKC → 小写 → 删除标点(P*)、分隔符(Z*)、空白、格式字符(Cf)
    public static func normalize(_ text: String) -> String
}
```

### 4.2 整句匹配与判断

`MacroEngine` 保留这个名字，因为它是 CONTEXT.md 里的术语，但接口改为整句判断：

```swift
public struct MacroEngine: Sendable {
    public enum Decision: Equatable, Sendable {
        case pending                              // 可能命中，还没写完
        case reject                               // 不可能命中
        case match(ruleID: UUID, replacement: String)
    }

    public init(rules: [MacroRule])               // 只收启用、有效的规则，预先归一化
    public var isEmpty: Bool
    /// 边读边判断：归一化为空或是某个触发词的开头时返回 .pending
    public func decide(_ insertedText: String) -> Decision
    /// 最终判断：不会返回 .pending
    public func finalDecision(_ insertedText: String) -> Decision
    public static func aliases(of source: String) -> [String]
    public func validate(_ rules: [MacroRule]) -> [MacroValidationIssue]
}
```

- 删除 `apply(_:rules:)` 和 `MacroResult`，句中替换、最长匹配、全覆盖的逻辑也一并删掉。
- 调用方要跟着改：
  - `DictationCoordinator.swift` 的 `MacroJob`；
  - `AppModel.swift:488` 的 `preview`，改用 `finalDecision`；
  - `AppModel.swift:233` 的校验调用。
- 重复触发词时，按规则顺序保留第一条。
- `MacroValidationIssue.Kind` 新增 `prefixConflict`。它只是提醒，不影响 `init(rules:)` 收录规则。

### 4.3 schema 13：合并只差大小写的规则

新增纯函数，在解码迁移里、`decodedSchemaVersion < 13` 时调用：

```swift
enum MacroRuleMigration {
    /// 归一化后触发词集合相同且目标文本相同的规则合并为一条：
    /// 保留第一条的 id、触发词写法和位置；任一条启用则启用。
    static func mergeNormalizedDuplicates(_ rules: [MacroRule]) -> [MacroRule]
}
```

`currentSchemaVersion` 改为 13。

### 4.4 测试

改写现有测试：

| 现有测试 | 处理 |
|---|---|
| `testMacroAliases`（:872） | 保留别名部分；“输入鞋杠吧 → 输入/吧”改为断言不命中 |
| 句中替换、部分替换相关的断言（:884-905） | 改为整句语义：“斜杠批准。”仍然命中；“请输入斜杠批准。”不命中 |
| 顶部的 `apply` 测试（约 :32-120） | 逐个改成 `decide` / `finalDecision` |
| 校验测试（:913） | 增加 `prefixConflict` |

新增测试：

- `testNormalizerFoldsCaseWidthAndPunctuation`：“Ｕｓａｇｅ。”、“ USAGE！”、““usage””都归一化为 “usage”；中文不变；零宽空格被删除；`+` 保留。
- `testDecidePendingOnPrefix`：规则 “usage”，输入 “us” 返回 pending，“usa” 返回 pending，“usage。” 返回 match。
- `testDecideRejectsNonPrefix`：输入 “hello” 返回 reject，“usages” 返回 reject。
- `testDecideEmptyAfterNormalizationIsPending`：输入 “。” 返回 pending；`finalDecision` 返回 reject。
- `testDecideUsesAliases`：“斜杠|写杠” 两个说法都命中。
- `testDisabledRulesIgnored`：停用的规则不参与判断。
- `testPrefixConflictIsWarningOnly`：“model” 与 “models” 同时存在时产生提醒，两条规则都能命中。
- `testSchemaThirteenMergesCaseDuplicates`：“Usage” 和 “usage”（目标文本相同）合并为一条；一条启用、一条停用时，合并后启用；目标文本不同的不合并；原有顺序保持。
- `testSchemaThirteenIdempotent`：已经是 13 的设置再次解码，不发生变化。

## 5. P3：TextTargets

### 5.1 边读边判断

在 `TextTargetAdapter` 和 `AXTextAdapter` 里，把 `waitForInsertedText` 扩展为带判断回调的版本（旧签名可以删掉，调用方只有 `MacroJob`）：

```swift
public enum InsertionVerdict: Sendable { case keepWaiting, stop, accept }

public struct WatchedInsertion: @unchecked Sendable {
    public let insertion: InsertedText   // 做出结论时的新增文字
    public let settled: Bool             // true：文字已稳定才得出结论
}

func watchInsertedText(
    after anchor: TextSessionAnchor,
    timeout: TimeInterval,
    mode: TextTargetMode,
    judge: (String) -> InsertionVerdict
) throws -> WatchedInsertion?
```

- 每次轮询：内容变化时，就用现有的 `makeInsertion` 推算新增文字，然后调用 `judge`。
  - `accept`：立即返回。
  - `stop`：返回 `nil`，表示提前放弃。
  - `keepWaiting`：继续轮询。
  - 差分失败：不抛错，按 `keepWaiting` 处理。
- 文字稳定后，最后调用一次 `judge`。`MacroJob` 在这一步用 `finalDecision`，所以不会再返回 `keepWaiting`。
- 超时时，沿用 `settleTimeout` / `notSettled` 两个错误。
- `SettleTiming` 增加 `decided`：从开始等待到得出结论的秒数。

### 5.2 写回前内容已变化

- `replace` 开头的检查（:280-286）现在把两种情况都报成 `focusChanged`。拆开处理：
  - 焦点真的变了：仍然抛 `focusChanged`；
  - 焦点没变、只是内容不同：抛新错误 `textChangedBeforeWrite`。
- `MacroJob` 收到 `textChangedBeforeWrite` 时，回到 `watchInsertedText` 继续判断，共用同一个截止时间。

### 5.3 校验放宽

- 把“写回是否生效”的判断抽成 Core 里的纯函数，方便测试：

  ```swift
  enum WriteVerification {
      /// actual == prefix + replacement + [只含可忽略字符的片段] + suffix
      static func isApplied(actual: String, prefix: String, replacement: String, suffix: String) -> Bool
  }
  ```

- 在 `awaitWrite`（:375）中用它代替 `value == expected`。

### 5.4 终端校验

- 按 S2 的结论修改 `replaceInTerminal`。
- 对 `unverifiedTypingTerminalBundleIDs` 里的终端，键入后直接返回成功。
- 需要把 bundle ID 传进来：给 `InsertedText` 或 `replace` 加一个参数，选改动最小的一种。

### 5.5 测试

- `testWriteVerificationAcceptsTrailingPunctuation`：`prefix + "/usage" + "。" + suffix` 判为成功。
- `testWriteVerificationRejectsOtherChanges`：替换结果后面多了普通文字，或者前文变了，都判为失败。
- `testWriteVerificationExactStillPasses`：没有多余字符的情况照常成功。
- 终端校验的修正如果能写成纯函数（例如行定位逻辑），补对应测试。
- `watchInsertedText` 依赖 AX，没有单元测试，靠手工清单覆盖。

## 6. P4：协调器（`DictationCoordinator.swift`）

### 6.1 MacroJob

改写 `run`（:582-646）：

1. 用会话开始时的规则构造 `MacroEngine(rules:)`。
2. 循环调用 `watchInsertedText`，`judge` 使用 `engine.decide`，文字稳定后改用 `finalDecision`：
   - 返回 `nil`：结果为 `earlyRejected`，启动最近识别的后台补读（6.3）。
   - 返回命中：把“已开始写回”标记置位，然后调用 `replace`。
     - 抛出 `textChangedBeforeWrite`：清掉标记，继续循环。
     - 成功：结果为 `replaced`。
     - 其他错误：结果为 `failed(原因)`。
   - 最终判断未命中：结果为 `noMatch`。
3. 结果从 `Outcome?` 改为一个枚举：`replaced / noMatch / earlyRejected / failed / cancelled / timedOut`，再加上耗时字段，供浮窗、回车逻辑和会话记录使用。
4. 取消时也要返回 `cancelled`，并记录日志，不再无声地 `return nil`。
5. “已开始写回”标记放在一个加锁的小对象里，和 `CancellationToken` 类似，供回车逻辑读取。

### 6.2 回车

改写 `sendEnter`（:231-254）：

- **没有会话，或者会话不能跑语音宏**：保持原有逻辑。
- **听写中，且能跑语音宏**：调用 `endSession`，同时把会话的 `pendingEnter` 设为这次的快捷键。
- **正在处理**：直接设置 `pendingEnter`。
- **MacroJob 在主线程回调结果时**：
  - 结果为 `replaced / noMatch / earlyRejected`，并且有 `pendingEnter`：在 `inputQueue` 上等 60 毫秒后发送回车，记录 `enter_emitted`。
  - 结果为 `failed`：不发送，记录 `enter_withheld`；只有浮窗开关打开时才显示提示。
- **2 秒计时器**（设置 `pendingEnter` 时启动）到点时：
  - 还没开始写回：取消任务，发送回车，记录 `enter_after_timeout`。
  - 已开始写回：继续等结果，按上一条处理。
- **取消会话**时，清掉 `pendingEnter`。

`AppModel.swift:337-401` 的按角色分支原则上不用改，只要 `sendEnter` 的新行为在协调器内部完成即可。

### 6.3 最近识别的后台补读

- 在 `AXTextAdapter` 里新增 `observeFinalText(after anchor:, maxWait: 1.0, mode:) -> String?`：轮询到文字稳定或到时就返回最终的新增文字；焦点变化时返回 `nil`。
- 在后台队列上运行，不占用会话。会话在提前放弃时已经结束，下一次听写可以立即开始。
- 下一次听写开始时，取消尚未完成的补读。
- 拿到的文字不超过 20 个字符时，交给 `AppModel` 记入最近识别。

### 6.4 最近识别的数据

- 新增 `RecentDictations`，放在 Core：容量为 5 的环形列表，每条包含文字、bundle ID、时间、是否命中。
- 只由 `AppModel` 持有，在内存中，不持久化。
- 新增 delegate 方法 `dictationDidCapture(text:bundleID:matched:)`。

### 6.5 测试

- `testRecentDictationsKeepsLatestFive`
- `testRecentDictationsSkipsLongText`：超过 20 个字符不记录。
- 协调器本身靠手工清单覆盖。

## 7. P5：诊断

- **会话编号**：`DictationSession` 新增 8 位短编号。`Diagnostics.event` 增加可选参数 `session:`，写进日志的 `session=` 字段。
- **错误日志**：:634 的 `"\(error)"` 改为只写错误的枚举名。给 `TextTargetError` 加一个 `name` 属性。
- **新事件**：
  - `macro_early_reject`、`macro_early_replace`；
  - `macro_retry_text_changed`；
  - `macro_cancelled`，附带取消时所处的阶段；
  - `enter_deferred`、`enter_withheld`、`enter_after_timeout`。
- **本地会话记录**：
  - Core 新增 `SessionRecord`（Codable，字段见设计文档第 8.2 节）和 `SessionRecordStore`。
  - 存储路径可以注入，测试时用临时目录，生产环境用 `~/Library/Logs/DoubaoVoiceHelper/sessions.jsonl`。
  - 追加写入放在串行后台队列上。
  - 启动时删除超过 30 天的行。
  - 写入失败只记一条日志，不影响听写。
  - 协调器在会话结束时（任何结果）组装一条记录，交给存储。
- **测试**：
  - `testSessionRecordStoreAppendsJSONLines`
  - `testSessionRecordStorePrunesOlderThan30Days`
  - `testSessionRecordHasNoTextFields`：对 `SessionRecord` 编码后的键名做白名单断言，防止以后误加文字字段。

## 8. P6：界面（`Views.swift`、`AppModel.swift`）

1. **规则列表**（`Views.swift:149-192`）：
   - 目标文本开头或末尾有空格时，在输入框右侧显示 “␣” 标记，并加上悬停说明，例如“末尾有 1 个空格”。
   - 校验提示（`MacroRuleIssueLabel`，:923）增加“触发词互为开头”，用提醒的样式，不用错误的样式。
2. **说明文案**改为：“整句等于触发词时才替换；比较时忽略标点、空格、大小写和全角半角。需要接后文时请分两次说。”
3. **试一试**（:938-958）：输入样例后，显示“会替换为：…”或“不会替换”。
4. **最近识别**：放在语音宏页面的底部。
   - 列出最近 5 条：文字、应用、时间、是否命中。
   - 每条旁边有“添加为别名…”菜单：列出现有规则，最后一项是“新建规则”。
   - 添加时去掉首尾标点和空格，用 `|` 追加到所选规则的触发词后面。
   - 列表为空时显示：“最近没有较短的识别结果。”
5. **微信标注**（如果 S1 的结论是读不到）：在语音宏页面显示一行说明：“微信不提供输入框内容，语音宏在微信中不可用。”
6. **AppModel**：
   - 新增 `recentDictations`（`@Published`）、`addAlias(_:to:)` 和 `createRule(fromTrigger:)`；
   - `preview(_:)` 改为返回 `MacroEngine.Decision`。

## 9. P7 与 P8：文档和验收

### 9.1 文档

- `docs/ARCHITECTURE.md`：
  - 改写第 10 节（文本会话与语音宏写回）、第 11 节（语音宏引擎）、第 17 节（诊断与日志）；
  - 在第 19 节（待定事项）里划掉 #1（静默期调参）。
- `README.md`：更新语音宏的用法说明，写明整句触发，并加上最近识别的用法。

### 9.2 自动检查

- `swift build` 通过。
- `swift run DoubaoVoiceHelperCoreTests` 全部通过，包括本文新增的测试。

### 9.3 手工验收清单

用 `./scripts/build_app.sh` 打包并安装后，逐项检查：

| # | 应用 | 操作 | 预期 |
|---|---|---|---|
| 1 | Ghostty（zsh） | 说 “usage” | 变成 “/usage”，停止后 0.8 秒内完成 |
| 2 | Ghostty（Claude Code） | 说 “usage”，停止后立刻按回车 | 等替换完成后才发送，发出去的是 “/usage” |
| 3 | Orca（Claude Code） | 同上 | 同上；日志里有 `replace_success`，没有 `verificationFailed` |
| 4 | Orca | 说 “USAGE。” | 替换成功（大小写和标点被忽略） |
| 5 | Orca | 说一句普通的话，马上按回车 | 回车没有等待，日志里有 `macro_early_reject` |
| 6 | 任意终端 | 目标文本设为 “/model ”，先说 “model”，再说 “opus” | 得到 “/model opus” |
| 7 | TextEdit | 说 “usage” | 替换成功；如果豆包补了句号，结果是 “/usage。”，而且回车照常发送 |
| 8 | Notion | 说触发词 | 命中就替换；没命中时，最近识别里能看到实际文字，“添加为别名”后再说一次能命中 |
| 9 | 任意 | 处理中切换到别的应用 | 会话被取消，回车不发送 |
| 10 | 任意 | 人为制造替换失败，例如处理中手动改动文字 | 不发送回车；浮窗关闭时没有提示，打开时提示“未应用语音宏” |
| 11 | 任意 | 按 Esc 取消 | 行为和现在一样 |
| 12 | 微信 | 按 S1 的结论 | 能读到：替换成功；读不到：设置里有标注，听写和回车行为照旧 |
| 13 | 设置 | 升级后查看规则列表 | 只差大小写的重复规则已合并；删掉过的默认排除应用没有被加回来 |
| 14 | — | 查看 `~/Library/Logs/DoubaoVoiceHelper/sessions.jsonl` | 每次会话一行，没有任何文字内容 |

### 9.4 一周数据

正常使用一周后，用下面的脚本统计（只读会话记录）：

```bash
python3 - <<'EOF'
import json, os, statistics as st
rows = [json.loads(l) for l in open(os.path.expanduser('~/Library/Logs/DoubaoVoiceHelper/sessions.jsonl'))]
done = sorted(r['doneMs'] for r in rows if r.get('outcome') == 'replaced' and r.get('doneMs') is not None)
if done:
    p90 = done[int(len(done) * 0.9) - 1] if len(done) >= 10 else done[-1]
    print('replaced', len(done), 'p50', st.median(done), 'p90', p90)
from collections import Counter
print(Counter((r['app'], r['outcome']) for r in rows).most_common(20))
EOF
```

**通过标准：**

- 替换成功的会话里，`doneMs` 中位数不超过 800，p90 不超过 1500。
- 终端里命中的会话没有 `failed`，如果有，要逐条说明原因。
- `enter = withheld` 只出现在真实失败的会话里。

## 10. 风险与回退

| 风险 | 表现 | 处理 |
|---|---|---|
| 终端校验仍有误报 | 回车没反应 | S2 的决策门：没有结论就不上线“失败不发送回车”；已上线的，把相应终端加进免校验名单 |
| 豆包在替换后重写整段文字 | 替换被覆盖，变回原文 | S3 的决策门，交给用户重新决定 |
| 触发词互为开头时替换错 | 说 “models” 被替换成 “model” 对应的结果 | 设置提醒；用户调整规则 |
| 归一化范围过宽 | 带符号的触发词误命中 | 只删标点、分隔符和格式字符，符号保留；有对应测试 |
| 后台补读占用 AX | 下一次听写开始变慢 | 补读最长 1 秒，新会话开始时取消 |
| 会话记录写入失败 | 统计缺数据 | 只记日志，不影响听写 |

**回退：** 每个阶段都能独立回退。P2 以后，设置文件升到了 schema 13，旧版本仍然能读取，因为 `schemaVersion` 取 `max`，不会降级；合并掉的重复规则不会恢复，这一点在发版说明里注明。

## 11. 验证记录

- **S1 微信**：实测 PID 74608，`AXFocusedUIElement` 返回 `nil`，无可用窗口，`AXManualAccessibility` 与 `AXEnhancedUserInterface` 均不受支持。按决策门确认：微信维持“只控制启停”，在设置界面明确标注“微信不提供输入框内容，语音宏在微信中不可用”，并且捕获锚点失败时不再重复弹出“宏替换不可用”提示。
- **S2 终端校验**：Orca 等终端由于 xterm 隐藏输入框清空机制与 Claude Code 等 TUI 菜单弹出前缀变动，读回校验存在误判。已在 `AppSettings.unverifiedTypingTerminalBundleIDs` 中引入免校验名单（如 Orca、Ghostty 等），键入完成即判定成功；配合放宽的行定位判断，回车机制上线安全可靠。
- **S3 提前替换**：提前替换（Early Replace）在各类原生控件与网页/终端中表现稳定，避免了 300 ms 强制等待，耗时控制在 0.8 秒内；替换后豆包偶发的追补标点由放宽校验纯函数 `WriteVerification.isApplied` 容忍，不会产生误报或拦截回车。

## 12. 改动文件一览

| 文件 | 阶段 | 改动 |
|---|---|---|
| `Sources/DoubaoVoiceHelperCore/Models.swift` | P1、P2、P3 | 默认排除应用的加入版本；schema 13；合并规则迁移；免校验终端常量 |
| `Sources/DoubaoVoiceHelperCore/MacroEngine.swift` | P2 | 归一化、整句判断、校验，删除 `apply` |
| `Sources/DoubaoVoiceHelperCore/TextTargets.swift` | P3、P4 | `watchInsertedText`、`textChangedBeforeWrite`、校验放宽、终端校验、`observeFinalText`；按 S1 结论调整找焦点的方式 |
| `Sources/DoubaoVoiceHelperCore/WriteVerification.swift`（新） | P3 | 写回校验纯函数 |
| `Sources/DoubaoVoiceHelperCore/RecentDictations.swift`（新） | P4 | 最近识别环形列表 |
| `Sources/DoubaoVoiceHelperCore/SessionRecord.swift`（新） | P5 | 会话记录模型与存储 |
| `Sources/DoubaoVoiceHelper/DictationCoordinator.swift` | P4、P5 | MacroJob、回车等待、后台补读、会话编号与记录 |
| `Sources/DoubaoVoiceHelper/Diagnostics.swift` | P5 | `session` 参数 |
| `Sources/DoubaoVoiceHelper/AppModel.swift` | P2、P6 | 预览、校验、最近识别、添加别名 |
| `Sources/DoubaoVoiceHelper/Views.swift` | P6 | 规则列表、说明、试一试、最近识别、微信标注 |
| `Tests/DoubaoVoiceHelperCoreTests/main.swift` | P1 到 P5 | 改写和新增测试 |
| `docs/ARCHITECTURE.md`、`README.md` | P7 | 文档同步 |
