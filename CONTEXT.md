# Doubao Voice Helper

面向 macOS 的本地语音增强层，通过鼠标映射控制豆包输入法，并对听写文本执行确定性的本地语音宏替换。

## Language

### Core Entities

**Macro Rule**:
一条确定性的文本替换映射规则，包含来源文本（source）、目标文本（replacement）与启用开关。
_Avoid_: Shortcut, prompt, template, snippet

**Macro Alias**:
同一条 Macro Rule 来源文本中以 `|` 分隔的多个说法，用于兼容同音误识别，命中任一说法都输出同一目标文本。
_Avoid_: Fuzzy match, synonym

**Macro Engine**:
纯本地的字面量文本替换引擎，基于最长匹配优先（Longest-Match First）和区分大小写原则执行全量替换；匹配时忽略识别结果中的标点与空格，整句都是命令时只输出替换结果。
_Avoid_: AI rewriter, grammar fixer, NLP parser

**Text Session Anchor**:
在发出豆包开始快捷键之前，对当前激活控件身份、焦点元素、已有文本及光标选中范围捕获的只读快照。
_Avoid_: Text cursor, input state, buffer snapshot

**Settled Text**:
听写停止后，焦点控件的值保持不变达到静默期（300ms）的状态；只有达到该状态才开始推断 Inserted Text。
_Avoid_: Final result, committed text

**Inserted Text**:
语音听写结束后，由豆包输入法实际注入到焦点控件、且能被前后锚点唯一证明的纯增量文本。
_Avoid_: Dictation result, typed text, delta

**Safe Replacement**:
仅在控件焦点未变、前后快照边界完全一致的前提下，通过系统辅助功能 API 执行并读回校验的无损文本写回操作。
_Avoid_: Force overwrite, auto undo, clipboard paste

**Keystroke Fallback**:
仅对用户名单内的应用启用的写回方式：辅助功能写入被接受但未生效，且光标恰好位于已证明的 Inserted Text 之后时，用退格加模拟输入完成替换，并在完成后读回校验。
_Avoid_: Retype, backspace hack, paste

**Terminal Line Insertion**:
终端名单内的应用中，整屏缓冲区除光标处单行插入（可占用原有空白填充）外完全不变时得到的 Inserted Text；只能通过退格加模拟输入替换，并以“插入点之前的内容紧接替换结果”校验。
_Avoid_: Screen diff, command output, prompt parsing

**Dictation Session**:
从鼠标触发开始、到豆包停止且语音宏处理结束（或被取消）为止的一次听写；同一时刻最多存在一个，由 Dictation Coordinator 持有。
_Avoid_: Recording, request, job

**Trigger Only**:
当目标应用无法通过辅助功能证明文本范围（锚点不可读、整屏有其他变化、写入不被接受且不在名单内等）时，仅控制豆包启停并保留原始输入文本的安全降级模式。
_Avoid_: Passthrough, fallback, ignore mode
