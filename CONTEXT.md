# 语音输入助手

面向 macOS 的本地语音增强层，通过鼠标映射控制当前语音输入法（如豆包输入法），并对听写文本执行确定性的本地语音宏替换。

## Language

### Voice Input

**Voice Input Method**（语音输入法）:
输入法自带的语音听写功能（如豆包输入法、微信输入法、讯飞、搜狗），由本应用模拟快捷键控制启停，文字由输入法直接写入焦点控件；同一时刻只有一个当前语音输入法。
_Avoid_: 语音工具, voice app, ASR engine, 豆包（泛指时）

**Voice Input Profile**（输入法档案）:
对一个语音输入法固定特性的描述：默认启停快捷键、取消键、回车是否顺带提交并停止听写、文字稳定的判定参数，以及哪些窗口属于它。用户实际使用的启停快捷键是全局设置，不属于档案。
_Avoid_: 预设, preset, adapter, driver, config

### Core Entities

**Macro Rule**:
一条确定性的文本替换映射规则，包含触发词（source）、目标文本（replacement）与启用开关；只有一次听写的 Inserted Text 整句等于触发词时才生效。
_Avoid_: Shortcut, prompt, template, snippet

**Macro Alias**:
同一条 Macro Rule 触发词中以 `|` 分隔的多个说法，用于兼容同音误识别，命中任一说法都输出同一目标文本。
_Avoid_: Fuzzy match, synonym

**Macro Engine**:
纯本地的整句匹配引擎：判断一次听写的 Inserted Text 是否整句等于某条 Macro Rule 的触发词，比较时忽略标点、空格、大小写与全角半角差异；不在句中查找或替换。
_Avoid_: AI rewriter, grammar fixer, NLP parser, 句中替换

**Early Reject**（提前放弃）:
听写停止后，一旦已写入的文字不可能再整句等于任何触发词，就立即结束本次语音宏处理，不再等待 Settled Text。
_Avoid_: 跳过, skip, abort

**Early Replace**（提前替换）:
听写停止后，已写入的文字一旦整句等于某个触发词，就立即执行替换，不等待 Settled Text，也不观察语音输入法之后的改动。
_Avoid_: 抢先写回, 预替换

**Recent Dictations**（最近识别）:
最近几次较短的 Inserted Text 及其是否命中触发词的记录，只存在于内存中，供用户发现识别偏差并补充 Macro Alias。
_Avoid_: 历史记录, transcript log, 识别日志

**Text Session Anchor**:
在向语音输入法发出开始快捷键之前，对当前激活控件身份、焦点元素、已有文本及光标选中范围捕获的只读快照。
_Avoid_: Text cursor, input state, buffer snapshot

**Settled Text**:
听写停止后，焦点控件的值保持不变达到输入法档案规定的静默期的状态；未能通过 Early Reject 或 Early Replace 提前得出结论时，以该状态下的 Inserted Text 作最终判断。
_Avoid_: Final result, committed text

**Inserted Text**:
语音听写结束后，由语音输入法实际注入到焦点控件、且能被前后锚点唯一证明的纯增量文本。
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
从鼠标触发开始、到语音输入法停止且语音宏处理结束（或被取消）为止的一次听写；同一时刻最多存在一个，由 Dictation Coordinator 持有。
_Avoid_: Recording, request, job

**Cancel**（取消）:
在语音输入法正常停止之前结束 Dictation Session，且不执行语音宏；已写入的文字是否保留由语音输入法决定，本应用不负责删除。
_Avoid_: 丢弃, discard, abort, undo

**Trigger Only**:
当目标应用无法通过辅助功能证明文本范围（锚点不可读、整屏有其他变化、写入不被接受且不在名单内等）时，仅控制语音输入法启停并保留原始输入文本的安全降级模式。
_Avoid_: Passthrough, fallback, ignore mode
