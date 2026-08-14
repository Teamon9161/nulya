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
| edit 匹配不到/有歧义 | 返回最多 5 个候选，每个带 2 行上下文、每行截 120 字 | `fs/edit.rs` MAX_EDIT_CANDIDATES=5 |
| old_string 里含裁剪标记 | 匹配前就拒绝，把"为啥匹配不上"变成一行诊断 | `fs/edit.rs:124` |
| 裁剪标记 | 用自描述的 `…[+N chars]`，不用裸 `…`（裸省略号会被模型抄进 edit 再匹配失败） | `fs/mod.rs:clip` |
| shell 静默失败 | 附 "did you mean" 解析提示 | `shell.rs:resolution_hint` |

> 这类"会教你的错误"是基础工具真正的护城河，必须内置、不可省。

---

## 2. 一个统一输出原语（这是简化的关键）

不要每个工具各搞一套截断。内核提供**一个**函数，所有工具输出都过它：

```zig
// 伪代码
const OutputBudget = struct {
    max_bytes: usize,        // 单次工具结果进 context 的字节上限
    max_line_chars: usize,   // 单行字符上限
    head_lines: usize,       // 溢出时保留的头部行数
    tail_lines: usize,       // 溢出时保留的尾部行数
};

/// 所有工具的最终输出都经过它。返回给模型的文本 + （若溢出）落盘路径。
fn emit(raw: []const u8, tool: []const u8, seq: u64, ctx: *Ctx) EmittedResult;
```

`emit` 做四件事，**全工具统一**：

1. **逐行裁剪**：任何单行超过 `max_line_chars` → 截断 + `…[+N chars]` 自描述标记；尾部附一条 note 点名被裁的行号（"这些行不能原样当 edit old_string，需要就用 grep 精确取"）。
2. **整体预算**：整段超过 `max_bytes` → **保留头 `head_lines` + 尾 `tail_lines`，中间挖掉**，插入自描述标记：
   `[… 省略 N 行 / M 字节；完整输出见 <path>，用 sed -n / rg 取 …]`
   —— 头保留是因为命令/上下文常在开头，尾保留是因为结果/报错常在结尾。
3. **自动落盘（不是 opt-in 模式）**：一旦溢出，**总是**把完整原文写到 `scratch/tool-output/<tool>-<seq>.txt`，标记里给出路径。
   → 这**取代 tcode 的 `full`/`final` 双模式**：只有一种行为，模型永不丢数据、永不需要提前预测输出多大。
4. **确定性**：落盘文件名从 `seq`（或内容 hash）派生，**不用运行时自增计数器**。因为 ledger 是 append-only、要能逐字节复现（见 DESIGN §1），同一输出必须产生同一截断字节。
   > tcode 的 `shell-final-{id:04}` 用了 AtomicU64 计数器（`shell.rs:741`）——在 nulya 里改成 `seq` 派生。

**收益**：`shell`、`edit` 回显、以及未来任何 native 工具，截断/落盘/裁剪逻辑**只有一份**，在一个文件里，可单测，AI 一眼看懂。不再有 per-command 的 `shell_filter/` 子系统。

---

## 3. 具体数字（留 tcode 的，理由附上）

这些是**内核默认常量**，集中在一处，可配置：

| 常量 | 值 | 理由（多为踩坑结论） |
|---|---|---|
| `MAX_READ_FILE_BYTES` | 10 MB | 超过绝不整文件塞内存；范围读大日志/数据集该用 grep/`sed -n`，读时直接拒绝并这么提示 |
| `MAX_LINE_CHARS` | 16384 | 单行上限**故意开很大**。比 prose/config/长 markdown 高两个数量级——tcode 曾用 500，对普通文件误触发，每次误伤都让模型多花一轮去绕。宁可漏，别误伤 |
| `MAX_READ_OUTPUT_BYTES` / `max_bytes` | 128 KB（起点，可调） | 独立于行数的字节闸；2000 行长行 ≈ 1 MB，必须再加这道闸。这个值直接决定单个 tool result 的 token 成本，**是首要调参旋钮** |
| `DEFAULT_READ_LIMIT` | 2000 行 | read 默认窗口 |
| `MIN_READ_WINDOW` | 120 行 | **把过小的 read 请求放大**到这个下限：多读几行很便宜，模型拿 10 行小窗一片片爬文件，每片一个 round-trip 才贵（直接违反"少交互"） |
| `head_lines` / `tail_lines` | 如 20 / 80 | 溢出时头尾保留量；shell 结果尾部更重要，故尾 > 头 |
| `DEFAULT_TIMEOUT_MS` / `MAX` | 120s / 600s | shell 超时；超时要把**被杀前已捕获的输出**一并返回（`shell.rs:append_partial_output`） |

> read 是否给行号：tcode 的结论是 **read 不加行号**（每行 7 字节、长会话累积不划算；edit 用精确串匹配不需要行号，footer 报窗口边界即可），只有 edit/append **回显改动片段**时才加行号。采纳。

---

## 4. 三个基础工具各自的形态

### shell
- 单工具，`{ command, cwd?, timeout_ms?, run_in_background? }`。**去掉 `output_mode`**——溢出由 §2 `emit` 自动落盘，模型不用选。
- exit code 追加；静默+非零 → 解析提示。
- stderr 以 `--- stderr ---` 分隔追加。
- `run_in_background` → 立即返回 task id，输出流入后台，无超时（长任务）。kill_on_drop + pipe drain 超时兜底。
- **不做** per-command 输出过滤子系统。噪声大的命令：要么模型自己 `| tail`/`| rg`，要么 §2 的头尾+落盘通用兜底。

### edit
- 精确串替换：`{ path, old_string, new_string, replace_all?, target_line? }`。
- old_string 唯一匹配才动手；歧义→返回带上下文的候选（§1）。**匹配本身就是校验**，不设 read-before-edit 门。
- 空 old / old==new / old 含裁剪标记 → 匹配前直接拒绝。
- 回显改动片段时带行号。

### read
- 经 `shell`（`cat`/`rg`/`sed -n`）即可满足读取——**read 不必是独立基础工具**（DESIGN §6.2）。若为体验保留一个 native `read`，也让它只做：窗口 + `emit`（§2），**不耦合** 图片解码 / vision 角色 / redaction（那些 tcode 的耦合是 accretion 之源）。

---

## 5. 与缓存/少交互的关系（别忘了主线）

- **落盘确定性**（§2.4）直接服务 DESIGN §1 的前缀不变式：ledger 复现必须逐字节一致。
- **MIN_READ_WINDOW 放大小读**、**溢出落盘而非报错让模型重试**：都在减少 round-trip（DESIGN §0.2）。
- **统一 `emit`** 让"工具输出"在 ledger 里格式稳定 → compaction/投影更可预测。

---

## 6. 一句话总结简化思路

> tcode 的**数字和"教你的错误"全留**；tcode 的**子系统（output-mode 双模式、per-command 过滤、read 的 vision/redaction 耦合）全砍**，换成 **一个 `emit` 原语 + 自动落盘**。
> 基础工具因此变薄到 AI 一眼看懂，稳健性集中在一个可单测的原语里——这正是"核心足够简单、基础工具足够稳健"的解。
