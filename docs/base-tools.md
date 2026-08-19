# Nulya — 基础工具与输出纪律 (base tools)

> 基础工具（shell / edit / read-via-shell）**AI 无法自我迭代**，所以它们必须从第一天就稳健；
> 但内核又必须简单到 AI 一眼看懂。矛盾的解法：**把所有"脏细节"收敛成 kernel 里一个统一的输出原语**，
> 基础工具本身保持薄，稳健性沉淀在那一个可测的原语里。

参考来源：`/home/teamon/code/rust/tcode`（`crates/tcode-tools/src/{shell.rs, fs/mod.rs, fs/read.rs, fs/edit.rs}`）。
tcode 的数字和教训是真金；它的**问题是 accretion**（per-command 过滤子系统、output-mode 动物园、read 里耦合 vision/redaction）。下面**留教训、砍子系统**。

---

## 1. 一条核心原则：基础工具"报错即教学"

因为 AI 补不了基础工具，基础工具的**错误信息**就是它的健壮性本体。每个失败都必须在**一轮内**告诉模型怎么成功：

| 场景 | tcode 的做法（采纳） | 出处 |
|---|---|---|
| 文件不存在 | 列出父目录实际内容（截 20 条），模型无需再探一轮 | `fs/mod.rs:not_found_help` |
| edit 匹配不到/有歧义 | v0.1 至少返回明确原因和匹配次数；later hardening 再返回最多 5 个候选上下文 | `fs/edit.rs` MAX_EDIT_CANDIDATES=5 |
| old_string 里含裁剪标记 | 匹配前就拒绝，把“为啥匹配不上”变成一行诊断 | `fs/edit.rs:124` |
| 裁剪标记 | 用自描述的 `…[+N bytes]`，不用裸 `…`（裸省略号会被模型抄进 edit 再匹配失败） | `fs/mod.rs:clip` |
| shell 静默失败 | later hardening：附 “did you mean” 解析提示 | `shell.rs:resolution_hint` |

> 这类"会教你的错误"是基础工具真正的护城河，必须内置、不可省。

---

## 2. 一个统一输出原语（这是简化的关键）

不要每个工具各搞一套截断。内核提供**一个**函数，所有工具输出都过它：

```zig
// 伪代码
const OutputBudget = struct {
    max_bytes: usize,        // 单次工具结果进 context 的硬字节上限
    max_line_bytes: usize,   // 单行字节上限；裁剪时退到 UTF-8 boundary
    head_ratio: u8,          // 溢出时头部 byte budget，例如 25
    tail_ratio: u8,          // 溢出时尾部 byte budget，例如 75
};

const StepOutputBudget = struct {
    per_tool: OutputBudget,
    max_step_bytes: usize,   // 一整轮 batched tool_results 的硬上限
};

/// 所有工具的最终输出都经过它。返回给模型的文本 + （若溢出）落盘路径。
fn emit(raw: []const u8, tool: []const u8, spill_key: SpillKey, ctx: *Ctx) EmittedResult;
```

`emit` 做四件事，**全工具统一**：

1. **逐行裁剪**：任何单行超过 `max_line_bytes` → 在 UTF-8 boundary 前截断 + `…[+N bytes]` 自描述标记。这里明确是 byte 上限，不承诺按 codepoint 计数。
2. **整体预算是硬不变量**：整段超过 `max_bytes` → 按 byte budget 保留头/尾（默认 25% / 75%），在预算附近找 newline / UTF-8 boundary，中间挖掉并插入自描述标记。`len(result) <= max_bytes` 必须能写成测试 invariant。`head_lines` / `tail_lines` 最多是 soft hint，不能让结果突破 byte ceiling，也不能产生重叠/underflow。
3. **自动落盘（不是 opt-in 模式）**：一旦发生任何 truncation（单行裁剪或整体裁剪），**总是**把完整原文写到 `scratch/tool-output/...`，并在返回给模型的正文末尾统一追加 footer：`[full output: <path>]`。
   → 这**取代 tcode 的 `full`/`final` 双模式**：只有一种行为，模型永不丢数据、永不需要提前预测输出多大，也不依赖额外 metadata 才知道完整内容在哪里。
4. **确定性且不碰撞**：落盘文件名不要用运行时自增计数器，也不要用 `base_seq * 64 + i` 这类隐藏上限。用 content hash（如 BLAKE3(raw)）或 `<ledger-id>/<event-seq>-<call-index>` 派生，保证 replay/fork/subagent 下路径稳定且不碰撞。

**批量输出再过一层 StepOutputBudget**：同一 assistant turn 可能返回 N 个 tool call。每个工具 `<= 128KB` 仍可能让一整轮膨胀到 MB 级，所以 batched `tool_results` 合成前还要有 `max_step_bytes`。顺序预算，但**有保底**：预算约束正文、不约束可见性——装不下的结果落盘后保留 prefix + 一条完整的 `[… full output: <path>]` footer（footer 不计入预算；比 footer 还短的结果直接保留原文、不落盘），所以最后一个 call 的报错和第一个一样可见，执行顺序不决定谁进 context。可见总量 ≤ `max_step_bytes` + 每 call 一条 footer。

**收益**：`shell`、`edit` 回显、以及未来任何 native 工具，截断/落盘/裁剪逻辑**只有一份**，在一个文件里，可单测，AI 一眼看懂。不再有 per-command 的 `shell_filter/` 子系统。

---

## 3. 具体数字（留 tcode 的，理由附上）

这些是**内核默认常量**，集中在一处，可配置：

| 常量 | 值 | 理由（多为踩坑结论） |
|---|---|---|
| `MAX_READ_FILE_BYTES` | 10 MB | 超过绝不整文件塞内存；范围读大日志/数据集该用 grep/`sed -n`，读时直接拒绝并这么提示 |
| `MAX_LINE_BYTES` | 16384 | 单行 byte 上限**故意开很大**，裁剪时退到 UTF-8 boundary。比 prose/config/长 markdown 高两个数量级——tcode 曾用 500，对普通文件误触发，每次误伤都让模型多花一轮去绕。宁可漏，别误伤 |
| `MAX_READ_OUTPUT_BYTES` / `max_bytes` | 128 KB（起点，可调） | 单个 tool result 的硬字节闸；最终返回文本必须 `<= max_bytes`。这个值直接决定单个 tool result 的 token 成本，**是首要调参旋钮** |
| `DEFAULT_READ_LIMIT` | 2000 行 | read 默认窗口 |
| `MIN_READ_WINDOW` | 120 行 | **把过小的 read 请求放大**到这个下限：多读几行很便宜，模型拿 10 行小窗一片片爬文件，每片一个 round-trip 才贵（直接违反"少交互"） |
| `head_ratio` / `tail_ratio` | 如 25 / 75 | 溢出时头尾 byte budget；shell 结果尾部更重要，故尾 > 头。行数只能是 soft hint，不能突破 byte ceiling |
| `MAX_STEP_OUTPUT_BYTES` | 256 KB（起点，可调） | 一整轮 batched tool_results 的硬上限；避免 10 个工具各 128KB 把下一轮 prompt 撑到 MB 级 |
| `DEFAULT_TIMEOUT_MS` / `MAX` | 120s / 600s | shell 超时（**已实现**，`tool.Timeouts`）；模型给的 `timeout_ms` 夹进 `[1, MAX]`，超时 kill 子进程并把**被杀前已捕获的输出**一并返回（`shell.rs:append_partial_output`）。extension 的 oneshot 调用共用这张表（缺省 30s；tool 的 manifest 可以自己声明 `timeout_ms`，上限同为 600s，DESIGN §7.3） |

> read 是否给行号：tcode 的结论是 **read 不加行号**（每行 7 字节、长会话累积不划算；edit 用精确串匹配不需要行号，footer 报窗口边界即可），只有 edit/append **回显改动片段**时才加行号。采纳。

---

## 4. 三个基础工具各自的形态

### shell
- 单工具，`{ command, cwd?, timeout_ms?, background? }`。**去掉 `output_mode`**——溢出由 §2 `emit` 自动落盘，模型不用选。
- exit code 追加；stderr 以 `--- stderr ---` 分隔追加。
- `timeout_ms` **已实现**：缺省 §3 的 120s、夹进 `[1, 600000]`，非正整数当场教学式拒绝（不替它换个数）。到点杀掉**整棵进程树**（POSIX process group / Windows job object，取消走同一条路径；OS 拒绝 job 时降级为只杀直接子进程，DESIGN §6.1），输出里 `[exit …]` 之前多一行 `[timed out after <n> ms; process killed, output above is partial]`，`ok=false`。
- **正常返回不杀树**：`some-server >/dev/null 2>&1 &` 这样的后台进程活得过这次调用（两个平台一致）。但它**必须重定向 stdio**——否则它继承着管道写端，而 §2 的 drain 要读到 EOF，这次调用就会一直等到它退出。
- **`background: true` 已实现**（当年这里写的 "later hardening：`run_in_background`"，DESIGN §6.1）：命令交给一个 supervisor 进程（`nulya task supervise`）看着跑，调用**立刻返回回执**（任务全名 `<sid>/t<N>` + log 路径 + status / wait / kill 三条命令），结束时结果作为第五种 ledger 事件 `task_finished` 经 inbox 在下一个 step 边界进对话。与前台相反的三条：**没有缺省 timeout 也没有上限**（活得过 step 就是它的意义，收口靠 `nulya task kill`）· **取消 step 不碰任务** · usage journal 记的是那次**发射**。没有 durable session 就 `ok=false` + 教学文案、什么都不启动；`background` 不是 bool 当场拒绝。**没有引入"后台任务子系统"**：内核只多了 `Environment.startShellTask` 与一种事件，supervisor 与 `nulya task …` 全在壳层（`cli/task.zig`）。
- Later hardening：静默+非零时的解析提示。
- **不做** per-command 输出过滤子系统。噪声大的命令：要么模型自己 `| tail`/`| rg`，要么 §2 的头尾+落盘通用兜底。

### edit
- v0.1 skeleton：精确串替换，`{ path, old_string, new_string, replace_all? }`。
- old_string 唯一匹配才动手；歧义→返回匹配次数，让模型补充上下文或显式 `replace_all:true`。**匹配本身就是校验**，不设 read-before-edit 门。
- 空 old / old==new / old 含裁剪标记 / 非 bool `replace_all` → 匹配前直接拒绝。
- Later hardening：候选上下文、`target_line`、回显改动片段时带行号。不要让这些体验增强进入 v0.1 的最小内核。

### read
- 经 `shell`（`cat`/`rg`/`sed -n`）即可满足读取——**read 不必是独立基础工具**（DESIGN §6）。若为体验保留一个 native `read`，也让它只做：窗口 + `emit`（§2），**不耦合** 图片解码 / vision 角色 / redaction（那些 tcode 的耦合是 accretion 之源）。

---

## 5. 与缓存/少交互的关系（别忘了主线）

- **落盘确定性**（§2.4）直接服务 DESIGN §1 的前缀不变式：ledger 复现必须逐字节一致。
- **MIN_READ_WINDOW 放大小读**、**溢出落盘而非报错让模型重试**：都在减少 round-trip（DESIGN §0.2）。
- **统一 `emit`** 让"工具输出"在 ledger 里格式稳定 → compaction/投影更可预测。

---

## 6. 一句话总结简化思路

> tcode 的**数字和"教你的错误"全留**；tcode 的**子系统（output-mode 双模式、per-command 过滤、read 的 vision/redaction 耦合）全砍**，换成 **一个 `emit` 原语 + 自动落盘**。
> 基础工具因此变薄到 AI 一眼看懂，稳健性集中在一个可单测的原语里——这正是"核心足够简单、基础工具足够稳健"的解。
