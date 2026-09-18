# Doubao Voice Helper

面向 macOS 的本地语音增强层，通过鼠标映射控制豆包输入法，并对听写文本执行确定性的本地语音宏替换。

## Language

### Core Entities

**Macro Rule**:
一条确定性的文本替换映射规则，包含来源文本（source）、目标文本（replacement）与启用开关。
_Avoid_: Shortcut, prompt, template, snippet

**Macro Engine**:
纯本地的字面量文本替换引擎，基于最长匹配优先（Longest-Match First）和区分大小写原则执行全量替换。
_Avoid_: AI rewriter, grammar fixer, NLP parser

**Text Session Anchor**:
在语音听写发起时刻，对当前激活控件身份、焦点元素、已有文本及光标选中范围捕获的只读快照。
_Avoid_: Text cursor, input state, buffer snapshot

**Inserted Text**:
语音听写结束后，由豆包输入法实际注入到焦点控件、且能被前后锚点唯一证明的纯增量文本。
_Avoid_: Dictation result, typed text, delta

**Safe Replacement**:
仅在控件焦点未变、前后快照边界完全一致的前提下，通过系统辅助功能 API 执行的无损文本写回操作。
_Avoid_: Force overwrite, auto undo, clipboard paste

**Trigger Only**:
当目标应用（如终端或非标准文本框）无法通过辅助功能证明文本范围时，仅控制豆包启停并保留原始输入文本的安全降级模式。
_Avoid_: Passthrough, fallback, ignore mode
