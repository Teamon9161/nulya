# Nulya — 设计文档 (v0.1 draft)

> A minimal immutable kernel + a self-evolving native capability layer.
>
> Nulya 不给 AI 一堆工具，而是给 AI 一个足够可靠的"制造工具的底座"。
> 内核只有两个工具（shell、edit），第三个工具由 Nulya 自己造出来。

本文档是设计基线，不是最终 API。术语：**ledger** = 会话事件日志；**generation** = 缓存世代；**step** = 一次 model 请求-响应；**PromptIR** = provider 无关的 prompt 逻辑块投影。

---

## 0. 三条硬约束（一切设计服从于此）

1. **Ledger 从 API 层就不可变**：会话是严格 append-only 的事件日志，没有任何"改历史"的接口。目的是把 prompt-cache 命中率变成一个**可断言的不变式**，而不是一句愿望。
2. **尽量少与模型交互**：core 允许同一 turn 内有多个 tool call，全部完成后合成**一条** user turn 回传，绝不一个工具一次请求。batch 的核心是不增加模型 round-trip，不要求默认并发执行工具。
3. **单文件可执行、离线可跑**：Zig 工具链内嵌进二进制（`@embedFile`），拷一个可执行文件过去就能编译/运行 extension，无任何网络下载。

这三条都由 **kernel** 保证，不下放给"让 AI 自己实现"。

---

## 1. 贯穿全局的主线：缓存世代 (cache generation)

缓存世代不是对完整 HTTP/API request bytes 做断言。完整 JSON request 会因为数组/对象闭合字节而天然不满足“上一请求完整字节是下一请求前缀”：`{"messages":[A,B]}` 不可能是 `{"messages":[A,B,C]}` 的逐字节前缀。

Kernel 保证的是 provider 无关的逻辑 prompt 块前缀稳定：

```
Ledger
  ↓ projection
PromptIR
  ├── tools
  ├── system
  └── message blocks
       ↓
Provider serializer/cache policy
```

> **在同一个 generation 内，`PromptIR[N].stable_blocks` 是 `PromptIR[N+1].stable_blocks` 的前缀。**

Provider runtime 负责把这个逻辑块前缀映射到具体厂商的序列化和 cache 机制：Anthropic 的 tools → system → messages prompt prefix、deferred tools、OpenAI 的 prompt caching/cache breakpoints 等都属于这一层。Nulya 的 kernel 不把某一家 provider 的 JSON bytes 当成架构不变量。

`generation` 是 ledger 事件的投影，而不是第二份可变状态。compaction、system/tool definition 变更、registry selection 等事件自然决定当前 generation；普通 append 只延长当前 generation 的 PromptIR stable blocks。

| 事件 | 为什么会炸缓存 | 设计对策 |
|---|---|---|
| 工具集合变化 | native `tools[]` 通常位于缓存前缀最前面，一变会使下游缓存失效 | **对话内默认不改 tools[]**；工具集只在对话开始时选定并冻结（见 §5）。支持 deferred tools 的 provider 可走 provider-specific 优化，但不能破坏 PromptIR 块级前缀不变量 |
| Compaction | 它重写历史 = 定义上就是炸前缀 | 让 compaction 罕见、边界明确；compaction 后新摘要成为新的稳定基座（见 §11） |
| system prompt / 工具定义变化 | 同样改变稳定块 | 把易变量（时间戳、随机 id）挤到非缓存区或新 generation 边界之后 |

**可测性**：core 测试断言 `prompt_blocks[N] is a prefix of prompt_blocks[N+1]`。Provider integration test 再分别检查实际 `cached_tokens` / `cache_read_input_tokens` / cache breakpoint 行为。

---

## 2. 架构总览

```
                         ┌───────────────┐
                         │      LLM      │
                         └───────┬───────┘
                                 │  immutable ToolSetSnapshot (frozen per step)
                                 │  PromptIR stable_blocks = prefix-stable within a generation
                  ┌──────────────┴──────────────┐
                  │            KERNEL            │
                  │  ┌────────────────────────┐ │
                  │  │ Agent loop / step m/c   │ │  ← batch, immutable snapshot per step
                  │  │ Ledger (append-only)    │ │  ← the immutable API
                  │  │ Cache-generation proj   │ │
                  │  │ Provider runtime        │ │  ← normalize + place cache breakpoints
                  │  │ Compaction              │ │
                  │  │ Tool registry           │ │
                  │  │ Extension manager       │ │  ← build/validate/test/activate/rollback
                  │  │ Execution Environment   │ │  ← local | sandbox | remote
                  │  │ Authority / policy      │ │
                  │  │ Managed Zig toolchain   │ │  ← @embedFile'd, extracted on first use
                  │  └────────────────────────┘ │
                  └──────────────┬──────────────┘
             ┌──────────────┬────┴─────┬──────────────┐
          shell           edit    (对话开始选入的      Extensions
        (builtin)      (builtin)   少量 native 工具)   (subprocess, JSON stdio)
```

模型永远只直接看到 **builtin(shell, edit) + 本场对话选定的少量 native 工具**。其余能力全部经 `shell → nulya ext run` 调用。

### 2.1 Frontend / Core 分离 + subagent = 自调用

- **Core 是 headless、以 ledger 为中心的引擎**（上图 KERNEL）。**CLI / live TUI / app / ACP 都只是 core 之上的薄客户端 / transport**：观察 ledger（tail append-only 日志）+ 追加 user 事件。这保证多种前端共用同一个 core。**ACP 属于这一层**（editor↔agent 通信协议），不是 Environment backend（§8）。
- **`AgentSession` 是这些前端的公共 host API（后续抽出）**：把当前 `main.zig` 里手工组装的 `ledger + model + environment + extension composition + tool snapshot + cancellation` 收成一个一等对象，`prompt() / cancel() / close()`。CLI / TUI / App / ACP 都只是它的薄客户端；ACP 的 `session/new|prompt|cancel` 直接翻译成 `AgentSession` 调用。**别在只有 CLI 时就把 fork/resume/lifecycle 全建起来**——先做 refactor，等第二个前端（ACP/TUI）出现再长 lifecycle。
- **Subagent = 自调用（self-invocation）**：subagent 不是 in-process 对象，而是 `nulya` 拿一个子 ledger、经 Execution Environment **再 spawn 自己一遍**，与 extension 走**同一套 spawn 机制**。因为通信是 append-only 事件（见 agents-and-review §2），且 ledger 持久化让 **resume ≡ 重新 spawn**，subagent 轮间不常驻，承载状态的是磁盘上的子 ledger。
- 独立子 ledger = 独立 cache scope，**不碰主 agent 缓存前缀**；前端是长期进程，re-spawn 的只是 worker，**UI 状态不丢**。唯一需要常驻进程的是"子 agent 与真人持续流式对话跨多轮"——DESIGN §7.3 `process_mode = persistent`，纯后期加法。详见 [agents-and-review.md](agents-and-review.md) §6。

---

## 3. Ledger：不可变的会话 API

### 3.1 数据模型

Ledger 不是 `Vec<Message>` 加随手 truncate，而是一条 **durable、append-only 的事件日志**。事件类型（初版）：

```
user_message | assistant_message | tool_call | tool_result
| tool_available_note      // 对话中新增能力，见 §5.3
| registry_selection       // 对话开始时选定的 tools[]
| extension_build | extension_activate
| extension_review         // policy hook 结论，见 agents-and-review.md
| review_question | review_answer   // 主 agent ↔ 审阅者的 append-only 通信
| compaction               // 见 §11
```

每条事件：`seq`（单调）、`generation`、`parent_seq`、内容、`content_hash`。整条日志内容可寻址。

### 3.2 API 约束（硬性）

- **没有 `edit_event` / `delete_event` / `reorder`**。API 表面只有 `append(event)` 和只读的 `read/replay/fork`。
- "纠正"语义 = **append 一条纠正事件**（例如工具结果错了，append 一条新的 tool_result 修正 + 一条说明），或 **fork 一条新 ledger**。
- **fork 与父 ledger 结构共享前缀**（copy-on-write）；前缀部分的 prompt-cache 依旧有效。"重新生成上一轮"在语义上只能是 fork 出新分支，不能原地改。
- 发给模型的 `PromptIR.stable_blocks` 是 `events[0..k]` 的**纯函数**。Provider request bytes 是 PromptIR 经 provider serializer/cache policy 的结果；kernel 只断言 §1 的块级前缀不变式。

### 3.3 派生视图（projection）

工具统计、UI、trajectory、metrics 全部是 ledger 的**投影**，不持久化 mutable 状态：

```
immutable events ──projection──▶ ToolStats { uses_total, uses_recent, last_used, success_rate, latency }
```

统计口径以后改了可以重算。这也是为什么工具排序（§5）能安全演进。

---

## 4. Agent loop 与 batch（少交互的核心）

一个 **step** 的生命周期，core 保证如下不变式：

```
build request (freeze ToolSetSnapshot for this step)   ← 工具集在一个 step 内不可变
        ↓
model response  (可能含多个 tool_use A, B, C)
        ↓
按执行策略运行 A,B,C（v0.1 安全默认串行；后续只有明确 parallel_safe 的工具才可有界并行）
        ↓
等【全部】 resolve —— 绝不提前回传任何单个结果
        ↓
按 tool_use_id 有序合成【一条】 user turn（多个 tool_result block）
        ↓
commit registry changes（若 A 造了新工具，见下）
        ↓
next step 的请求才反映新工具（通过 append note，不改 tools[]）
```

**关键子规则（ChatGPT plan 第 12 条，采纳）**：若 A 在本 turn 中激活了新能力，B、C 仍然只看见**本 step 冻结的旧快照**；新能力最早在**下一个 step** 通过 append 的 note 出现。即：

> **ToolSetSnapshot = immutable for one model step.** 写进 kernel invariant。

**batch 友好性**：batch 的收益是多个 tool call 只产生一次模型回传；是否并行执行是独立的安全策略。因为低频能力走 shell，模型若明确知道命令彼此独立，也可以在**一条** shell 命令里自行并发（`nulya ext run a & nulya ext run b & wait`）。

---

## 5. 工具面与缓存（本设计的核心决策）

### 5.1 对话内 `tools[]` 冻结

- 一场对话**开始时**，按规则选定 `tools[]`，**整场冻结**。对话内 `generation` 不因工具变化而 bump。
- 选择规则（`registry_selection` 事件记录）：
  1. builtin：`shell`, `edit`（永远在，位置固定最前）。
  2. 用户 pin 的 native 工具（配置指定）。
  3. 自动按使用统计排序补足到上限 K（`uses_recent` + `uses_total` + `last_used` + `success_rate` 的投影排序）。K 是早期默认值（如 6–8），非永久。
- 排序**只在此刻发生一次**。对话开头本就是新前缀、无缓存可炸，所以"晋升"零成本。**排序绝不在对话中途重排**（那才是缓存杀手）。

### 5.2 native 工具的位置稳定性

选入的 native 工具在 `tools[]` 里**按稳定 ID 排序**，不因"刚调用过一次"就前移。位置抖动同样伤缓存与可复现性。

Registry 里 `id` 是稳定身份，`name` 是 model-facing 名字；同一个 `ToolSetSnapshot` 内 `name` 必须唯一。builtin 名字 `shell` / `edit` 永久保留，extension 不能占用。

### 5.3 对话中新增能力 = append 一条 Note（不改 tools[]）

Agent 在对话中途造出/发现新 extension 时：

- **不修改** `tools[]`（改了就 miss）。
- **append** 一条 `tool_available_note` 事件，内容形如：
  > 新能力可用：`web_search`。调用方式：`shell` 执行 `nulya ext run web.search '{"query": "..."}'`。
- 因为是追加，前缀不动，缓存继续命中；模型下一 step 即可经 shell 调用。
- 该 extension 会在**下一场对话**的 §5.1 选择里，凭统计有机会被晋升进 `tools[]`（此时零缓存成本）。

> 一句话：**晋升发生在对话边界，对话中途只追加 note。** 这条规则同时满足"缓存不可变"与"能力可增长"。

### 5.4 为什么不做 ChatGPT 的动态 promotion/eviction/ranking

它的机制漂亮，但每次 activate/evict 都在对话中途改 `tools[]` = 全量 cache miss，与头号诉求正面冲突。§5.1–5.3 拿到它的全部好处（stats 驱动的能力增长）而**零缓存代价**。

---

## 6. 两个内置工具

> 输出截断/落盘/裁剪的细节与踩坑数字见 [base-tools.md](base-tools.md)。核心：**一个统一 `emit` 原语 + 自动落盘**，基础工具保持薄。

### 6.1 shell

- 单一工具，不拆 `bash`/`powershell`/`sh`/`zsh`。model-facing schema 恒定：`{ "command": "..." }`。
- 系统提示告知当前 `shell_dialect = bash | powershell`。dialect 由 Execution Environment（§8）决定。
- 所有 `nulya ext ...` CLI 都经 shell 调用 → 保持模型工具面极小。

### 6.2 edit

- **不采纳** ChatGPT"纯 patch"的激进方案（AI patch 上下文常 fuzzy、apply 失败就多一轮 round-trip，违反 §0.2）。
- 采用**精确匹配 + 优质报错**（类 Claude Code）：`old_string` 唯一匹配替换 / `replace_all` / 新建 / 删除，作为一个事务。apply 失败要给出可操作的 diff 上下文，让模型一次纠正。
- 读文件交给 shell（`cat`/`rg`/`sed`/`git diff`）——读本就要一个 round-trip，native read 并不省，故不必为它单列工具。

---

## 7. Extension 模型

Extension 不再等于"Tool 的打包方式"，而是 Nulya 的**通用能力注入机制**。三个概念必须分开——这是本节的脊椎，7.1 以下都是它的推论。

**Package ≠ Runtime ≠ Contribution**

- **Extension Package**：可安装、可版本化、可 rollback 的能力包。**可以没有可执行文件**（纯 Skill 包完全合法）。
- **Extension Runtime**：只有当某个 Contribution 需要代码时才存在的子进程（§7.1 形态、§7.3 协议）。
- **Contribution**：Package 真正向 kernel 贡献的东西。**Tool 只是其中一种。**

**Contribution 分类**（taxonomy 全定义，让 manifest schema 稳定；v0.1 只实现有消费者的那几种）：

| Contribution | 位置 | v0.1 | 说明 |
|---|---|---|---|
| Tool | 下游 | ✅ | 经 executor 进 ToolRegistry；builtin / extension / MCP 同构（§7.3、§5） |
| Skill | 下游 | ✅ | `SKILL.md` + 渐进披露，经 `nulya skill load` 走 shell（§7.7）；**无需 runtime** |
| Hook | 下游 | 🟡 窄 | 只落 Provider / Middleware / Observer 三类机制，**不做 Pi 那样的 event 洪流** |
| Command / Prompt | 下游 | ⚪ 命名保留 | schema 占位，v0.1 不实现 |
| Provider（model） | **上游** | ⚪ 存疑 | model provider 在 loop **上游**，决定 PromptIR 序列化 / cache breakpoint / streaming，机制与下游 Contribution 不同构，**暂不设计**，仅占位（§17） |

**三类机制取代 Pi 的几十个 lifecycle event**：`Provider`（提供能力）/ `Middleware`（拦截、修改）/ `Observer`（只观察）。这比"everything = event"更容易让行为可复现，也天然避免"四个 extension 抢着改 prompt"。

**硬约束（不可谈判，Nulya 相对 Pi 的核心设计差异）：**

> 任何 **model-visible** 的东西必须能从 ledger 重建。Extension 只能 **propose**，由 kernel **append** 成 ledger 事件，再由 PromptIR **project**。**Extension 永不 rewrite PromptIR / systemPrompt。**

Pi 的 `before_agent_start` 直接改 systemPrompt，对 Nulya 是**定义级违规**——它破坏 §1 的 `Ledger → PromptIR` 纯投影，也就破坏全部 cache 不变量。因此 dynamic context 的唯一合法路径就是 §5.3 的 append-note：extension 提出一条 note → kernel 追加事件 → PromptIR 投影，绝不偷偷 rewrite。

**Middleware 排序决定论**：多个 extension 贡献同类 Middleware 时，顺序影响可复现性。规则：**顺序 = frozen session composition 的确定函数**——v0.1 按**稳定 extension id 排序**，并像 `registry_selection` 一样记进 ledger（§7.4 组合冻结）。后续可让 extension 声明式约束次序（"排在 X 之后" / 优先级 / 签名），作为 opt-in 特殊情况（§17）。

### 7.1 形态：Native Executable + stdio JSON-RPC（不是 .so/.dll）

采纳 ChatGPT 第 3 条。动态链接对 AI 生成代码是灾难（ABI / Zig 版本 / crash 带死 host / allocator 所有权 / 跨平台）。Extension = 子进程，wire protocol 就是 ABI，也因此不绑定 Zig（Rust/Go/Python/TS 都能实现，Zig 是官方默认语言）。

### 7.2 目录与 manifest（`contributes{}`）

manifest 从"一张 tools 表"提升成"一束 Contribution"。带 runtime 的 Tool extension：

```
.nulya/extensions/web-search/
├── extension.json      # manifest：runtime + contributes{} + permissions
├── src/main.zig
└── tests/*.json        # 真实验收用例，见 §12
```

`extension.json`（带 runtime）：

```json
{
  "schema": "nulya.extension/v2",
  "id": "web.search",
  "version": "0.2.0",
  "runtime": { "entry": "bin/web-search", "mode": "oneshot" },
  "contributes": {
    "tools": [{
      "name": "web_search",
      "description": "Search the web and return relevant results.",
      "input": { "type": "object",
        "properties": { "query": { "type": "string" } },
        "required": ["query"] }
    }]
  },
  "permissions": { "fs": [], "network": ["https"], "process": [] }
}
```

**纯 Skill 包——没有 `runtime`、没有 `tools`，完全合法**：

```json
{
  "schema": "nulya.extension/v2",
  "id": "finance-skills",
  "version": "1.0.0",
  "contributes": {
    "skills": ["skills/risk-parity", "skills/portfolio-review"]
  }
}
```

由此 deterministic validation 里旧的 `tools.len > 0` 不变量（当前实现为 `error.NoTools`）**删除**，改成：**至少存在一种 contribution**（`runtime` 只在有 Contribution 需要代码时才要求）。

**manifest 是 schema 的唯一真相**（采纳 ChatGPT 第 4 条）：绝不"启动 binary 再问它有什么"，避免 source / manifest / runtime describe() 三份状态漂移。runtime 只负责实现 manifest 声明的各 handler（§7.3 的 `method`）。

> 注：在 §5 的 shell-first 方案下，`tools[].input` schema **只在该 tool 被晋升进 tools[] 时**才喂给模型；平时它只是 `nulya ext find` 的可发现性元数据 + 供 shell 调用者参考的用法。这让 v0.1 的 manifest 负担很轻。

### 7.3 Wire protocol（JSON-RPC，`method` 解耦 runtime 与 Tool）

当前 envelope 把 `tool` 写死成唯一动词，等于把 runtime 协议锁死成 Tool 执行。趁未发布改成 **JSON-RPC 2.0**——**重点不是"JSON-RPC 更标准"，而是 `method` 把 runtime 协议从 Tool 解耦**，让同一个 runtime 能服务多种 Contribution：

```
oneshot:    spawn → stdin(one JSON-RPC request) → stdout(one response) → exit
persistent: 长管道 + 分帧 → 多条 JSON-RPC（§7.3 末尾，后期）
```

```json
// request
{ "jsonrpc": "2.0", "id": 17, "method": "tool/call",
  "params": { "name": "web_search", "arguments": { "query": "..." } } }
// success
{ "jsonrpc": "2.0", "id": 17, "result": { "results": [] } }
// error（标准 JSON-RPC error object）
{ "jsonrpc": "2.0", "id": 17,
  "error": { "code": -32000, "message": "...", "data": { "retryable": true } } }
```

method 随 Contribution 自然扩展，协议不用推翻：`tool/call` · `hook/call` · `skill/list` · `skill/get` · `command/call` · `provider/stream`（后期）。

好处的边界要说清：这**不会**让 ACP / MCP / extension 三套业务协议变成同一份代码，但 framing / request-id / error / notification 这些**基础机制**不用反复发明——ACP、MCP 本身也都以 JSON-RPC 为底。oneshot extension 用不到 notification / batching 机制，只借 envelope 形状，transport 仍是 spawn-per-call。

v0.1 runtime **仍不做** daemon / persistent worker / streaming / bidirectional events / host callbacks——只是 envelope 从"`tool` 写死"换成"`method` 通用"。

**关于"每次 spawn 会不会慢 / 会不会堆一大堆进程"（重要，写清）：**

- **不会堆积**：oneshot 模型是"读请求→干活→写结果→**退出**"，毫秒级消失。默认串行执行时任意时刻只多一个 extension 进程；后续若某些 `parallel_safe` 工具 opt in 有界并行，活着的进程数也受内核并发上限约束，干完全退并归零。**会堆积一大堆常驻进程的恰恰是持久化没管好生命周期时**——oneshot 天生不残留。
- **spawn 本身很便宜**：原生 Zig binary spawn ≈ 1–5ms（Linux；无解释器/VM 预热，不同于 Python/Node），对比模型 round-trip ≈ 秒级、真干活的工具自身几十 ms–秒级 → **spawn 开销对绝大多数工具 <1%**。且**最高频的 shell/edit 是 in-core 内置、根本不 spawn**，extension 是低频长尾。
- **真正的成本不是进程启动，是某些 extension 每次调用的重初始化**（browser 每次启 Chromium、DB 每次重连、embedding 每次 load 模型）——这跟"是不是子进程"无关，in-process 一样痛。

**对策：默认 oneshot，`persistent` 按 extension 声明、按需 opt-in**（manifest `runtime.mode = "persistent"`，默认 `"oneshot"`）。只有当某 extension 的重初始化被**实测**证明是瓶颈时才开。开启后内核给它一个**有界 warm worker 池**：

- 复用长连接，**同一套 JSON 协议**，只是 transport 从"spawn-stdin-stdout-exit"换成"长管道 + 分帧" → **扩展代码无需改写**，两种模式共享协议；
- **上限 N 个 warm worker（LRU 淘汰）+ 空闲 TTL（如 60s 无调用即退出）** → 有界、会自回收，不堆积；
- worker 崩溃重启，仍崩不死 host（隔离保留）。

> 纪律：**先测量再持久化。** 不为想象中的慢提前造 daemon。
>
> 考虑过 WASM in-process（免进程 + 沙箱），**否决**：与"原生 Zig + 内嵌工具链"冲突，要拉入 WASM runtime、削弱语言无关性、WASM 沙箱自带性能/复杂度成本。原生子进程的 crash 隔离与语言无关更值。

### 7.4 生命周期：不可变版本 + 原子切换（deterministic gate + policy hooks）

绝不“改源码直接覆盖正在运行的工具”。状态机：

```
draft ──build──▶ built ──validate/test──▶ installed ──policy hooks──▶ active
                                                                    │
                                                     update│        │disable
                                                           ▼        ▼
                                                    new immutable  installed
                                                       version
```

- 每次 build 产出**不可变版本**，版本 id = `hash(source + zig_version + target + manifest)`。
- 布局：`foo/{v-a8fc3c, v-b193ab}, current -> v-b193ab`。
- 更新 = build 新版本 → deterministic validate → test → policy hooks → **原子切换 current**；旧版本保留。
- rollback 本质就是 `current = old_version`，无需复杂逻辑。B 挂了 A 完全不动。
- **kernel 强制的是机制，不强制某个 LLM reviewer 的品味**：manifest schema、协议往返、hash、权限包含关系、原子 activate/rollback 这些 deterministic validation 是内核不变量；“这个参数是否足够通用”属于 policy。
- policy hooks 可配置：`off` / `auto` / `human approval` / `AI reviewer` / 组合。Nulya 默认可以启用 AI reviewer 来抑制工具膨胀，但 reviewer 结论不是 immutable kernel invariant；低风险 workspace 也可以关闭 policy hook，只保留 deterministic validation。详见 [agents-and-review.md](agents-and-review.md)。

**组合在 session 开始冻结（keystone，Contribution 系统免费继承 §1 cache 不变量）：**

```
session 开始 → resolve extension composition（含每个 extension 的 pinned version）
            → freeze（像 ToolSetSnapshot §5.1）
            → 记一条 ledger 事件（composition selection）→ 这条就是 generation base
```

- 冻结意味着：session 中途 AI 就算重写出 `web.search` 的 v-c3d4 并 activate，**当前 session 已 native 注册的仍是 v-a1b2**；新版本只能经 shell `nulya ext run` 显式调用 + note 告知（§5.3），native 组合下一场 session 才换。可复现性极好。
- 这不是新机制，是把 §5.1 的 frozen snapshot 不变量**延伸到整个 Contribution 层**（Tool / Skill / Hook 版本一并 pin）。

**注册是可撤销的 effect（借 DeepSeek，极简版）：** activate 一个 extension = 把它的每个 Contribution 注册进对应 registry，产出 `Registration[]`；卸载 = 逆序 `dispose()` 后再 kill runtime。永不出现"extension 卸载了但 tool 还在 registry / hook 还在触发 / skill 还在 catalog"。注意 Nulya 需要的这套机制比 DeepSeek 轻得多：**immutable snapshot + 对话边界晋升本身就给了干净的隐式 teardown**（下一场 session 从头重组），reversible registration 主要服务于中途 disable / rollback。


### 7.5 能力三级（采纳 ChatGPT 第 8 条，略调整）

```
Scratch    一次性：shell 里 `nulya toolchain zig run /tmp/foo.zig`，不进工具库
   ↓
Extension  复用第 2、3 次：沉淀为 .nulya/extensions/foo，经 `nulya ext run` 调用（仍不进 tools[]）
   ↓
Native     真高频：下一场对话 §5.1 选择时晋升进 tools[]
```

Scratch 与 Extension 其实是一条连续谱：唯一区别是"是否存盘 + 给 manifest"。

### 7.6 工具的上下文模型（tool 拿得到什么、拿不到什么）

**大原则：tool 是无状态纯函数 `f(args, environment, ctx_header) → result`，它拿不到 ledger。**

core 探索到的信息分两类，走两条完全不同的路——这是本节的核心区分：

| 信息类型 | 例子 | 持有者 | tool 如何获得 |
|---|---|---|---|
| **事实性 / 持久** | 文件内容、目录结构、命令输出、代码 | **工作区文件系统** | 经 environment（cwd/fs）**直接读**；文件系统 = 共享持久记忆，不是"重新探索" |
| **语义性 / 对话** | "决定用方案 B"、"X 是根因" | **ledger（模型上下文）** | **不给 tool**；由**模型提炼进 `args`** |

所以 core **不是**"零信息只有 shell"——它信息丰富，但那份丰富是**模型的**（在 ledger 里）。tool 与 core 共享的是**文件系统**，不是 ledger。

**为什么坚决不把 ledger 给 tool：**

1. **模型是上下文路由器**：模型读了一切、挑出相关的塞进 `args`；tool 需要什么模型已备好。
2. **开销爆炸**：大对话几 MB，每次 spawn 都序列化 + IPC 一遍（正是"对话大了开销大"的来源）。
3. **最小权限**：AI 生成的 extension 不应能读整段对话（§9 authority）。
4. **可复现**：保持 `args → result` 纯函数，审阅门 golden 测试（§12）才成立。

**tool 只拿一个恒定大小的 `ctx_header`**（与对话大小无关）：workspace root / cwd / os / shell dialect / scratch+cache 目录 / 截断上限 / 权限描述。经 env var 或 request 里一个 `_ctx` 字段注入。

**tool↔tool 共享知识，只走两条正道：**

- **(a) 模型中转（默认）**：A 出结果 → 模型 → 把相关部分作为 B 的 `args`。模型是 tool 间的导线，无需 tool 耦合。配合 base-tools §2 **大输出落盘留指针**：大结果落盘、只回指针+摘要，模型把**指针**传给 B、B 自读文件 → 大数据不经过模型上下文，只有指针流动。
- **(b) 磁盘制品（贵的派生态）**：A 把索引/embedding/解析树写进 `.nulya/cache/`，B 直接读（真实工具就这么干：ctags 写 tags、LSP 维护自己的索引）。

**反模式（禁止）**：tool 直接互相调用 / 共享内存态——重建耦合、毁掉无状态可复现。

**防"每个 tool 重新探索"**：共享 fs + `.nulya/cache/` 磁盘缓存 + 模型路由，让事实落 fs、派生态落 cache，谁都便宜复用；再加可选的 **agent 维护的项目笔记/记忆文件**（模型 `read` 便宜、tool 经 fs 可读）——轻约定，可自生长，不做重内核。

**分界线（自调用送的礼）：**

> **凡"真的需要对话/ledger"的东西，就不是 tool，而是 subagent。**

subagent = 自调用，有**自己的子 ledger**；需要上下文时由**父级模型挑一份相关切片喂进子 ledger**（或 attach 报告）。于是"要不要给 tool ledger"被彻底化解：**tool 永远无 ledger；需要 ledger 的都是 subagent 且各有其一。**

**"那给 tool 一个 ledger 文件路径呢？"——伪解，否决。** 它不省开销，只是把成本从"序列化进 request"挪成"**每个 tool 各自读+解析一遍**"（同样几 MB，还乘以 N），并把"上下文路由"塞进每个 tool（那是模型的活），同时毁掉最小权限与可复现。正解相反：让 ledger 待在**已解析好**的地方（core/模型），只传**蒸馏后的 args**。

**唯一窄例外**：本职就是操作对话本身的 tool（导出转录、搜历史）——"对话"才是它的 args。即便如此：① 只给**那一个** tool、作为**显式 arg**（`export_transcript(ledger_id)`）；② 给的是 core 提供的**只读查询 API**（"取第 N 条 / 搜 X"），**不是**让 tool 自己 parse 原始文件（否则又回到"每个 tool 重复解析"）；③ 这类东西多半本就是 core 功能（compaction）或 subagent。

### 7.7 Skill Contribution：兼容 Agent Skills，经 `nulya skill load`

Skill 是拓宽 Extension 后**性价比最高**的新能力：几乎免费——它就是文件 + 渐进披露，天生贴合 Nulya。

- **直接兼容 Agent Skills 标准，不发明 Nulya 格式**。目录轻：`skill-name/{SKILL.md, scripts/, references/, assets/}`；`SKILL.md` 用 YAML frontmatter，至少 `name` + `description`。
- **渐进披露正是 Nulya 想要的**：启动只看 `name + description`；需要时读完整 `SKILL.md`；再需要才读 `references/scripts/assets`。
- **不做第三个 builtin tool**。session 开头 append 一段 `<available_skills>` note（summary 级），模型经 `shell` 调 `nulya skill load <name>` 拉取完整定义。`nulya skill load` 隐藏 provider 与物理路径——比 `cat /some/path/SKILL.md` 干净，且统一了 filesystem / package-bundled / user / remote 各来源。
- **Skill 也是 Provider 架构**：`SkillProvider { list(cwd), get(name) }`，多个 source 合并进一个 `SkillRegistry`（local / package / remote），先只暴露 summary，需要时再加载完整定义——与 §5 的 shell-first、渐进披露一脉相承。

> Skill 与 Tool 的分工：Tool 是"能执行的能力"，Skill 是"要遵循的方法/知识"。二者都是 Contribution，但走不同 registry，互不侵占模型工具面。

---

## 8. Execution Environment 抽象（DeepSeek 理念）

把 **原生/云环境、本地、沙箱、远程** 统一成一个 `Environment` 接口——shell 与 extension 的执行都经它，方便快速切换执行目标。

> **ACP 不是 Environment backend（已从枚举移除）。** Environment 是 agent→世界的**执行目标**；ACP 是 editor/client→agent 的**通信协议**，方向相反。ACP 归 **Frontend / Transport 层**（§2.1），与 CLI / TUI / App 并列，只把 `session/new|prompt|cancel|close` 翻译成对 core 的调用。把它塞进 Environment 是概念层次放错。

```
Environment (interface)
├── run_shell(command, dialect, authority) -> result
├── run_extension(entry, request_json, authority) -> response
├── fs view / cwd / env (sanitized)
└── dialect() -> bash | powershell
```

后端：

| backend | v0.1 | 说明 |
|---|---|---|
| `local` | ✅ | 直接在宿主执行；env 净化（§9）；shell-equivalent authority |
| `sandbox` | 后续 | landlock+seccomp / namespaces（Linux）、sandbox-exec（macOS）、AppContainer/restricted token（Windows）、或容器 |
| `remote` | 后续 | 远程执行环境 |
| `ssh` / `container` | 后续 | 候选 backend（远程 shell / 容器隔离），按需再定 |

关键：**authority model 与 environment 解耦**——同一套 permission 概念投射到不同 backend 的强制机制上。v0.1 只实现 `local`，但接口就位，后面加 backend 是 drop-in。

---

## 9. Authority / 安全（v0.1 诚实版）

**明确不假装 manifest.permissions 是安全边界。** AI 生成的原生 binary = 任意机器码；`"network": []` 在没有 OS 强制时拦不住 `curl`。所以 v0.1：

- **规定 extension 与 shell 共享同一个 `session_authority`**（≈ 当前用户全权限）。像 DeepSeek 对 Cordis 那样**明说**这个边界，不给虚假安全感。
- **env 净化（必做）**：extension/shell 子进程**默认不继承 host 环境**。`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `AWS_SECRET_ACCESS_KEY` / `SSH_AUTH_SOCK` 等**只存在于 host**，永不下传给 AI 生成的 binary。
- **同一 authority model 管 shell 和 extension**：permission 只能在 `session_authority` 内**继续收窄**（`extension_permissions ⊆ session_authority`），绝不能因为注册成 extension 就获得 shell 本来没有的权限。
- **后续里程碑**：`sandbox` backend 上线后，manifest.permissions 才真正被 OS 强制。届时它从"声明"升级为"边界"。

---

## 9.5 配置解析链 (config resolution chain)

Nulya 读取**自身**配置走一条分层链，优先级 **项目 > 用户 > 系统 > 内置 default**（参考 tcode 的 `default → user → project` 合并，nulya 多预留一个机器级 system 层）：

```
@embedFile default.toml                                  ← 零配置基座，随二进制走（§10 同哲学）
      ↓ merge
system   /etc/nulya/config.toml | %ProgramData%\nulya\   ← 机器级（受管安装/共享机场景；接口预留，v0.1 可不实装）
      ↓ merge
user     ~/.config/nulya/config.toml | %AppData%\nulya\  ← 用户级：provider profile、secret 引用、policy 档位、tunable 初值
      ↓ overlay（过 sanitizeProject）
project  .nulya/config.toml                              ← 项目级：不可信输入，只能收窄不能放宽
```

合并语义同 tcode：标量"set 即胜"，列表按 key 合并/拼接；default 是每次 load 的基座，上层只写增量与覆盖。**内置 default 用 `@embedFile("default.toml")`**——零配置即可跑，和 §10 内嵌工具链是同一个"单文件、离线、零网络"（§0.3）信条的又一次体现。（实现代价：Zig 无 std TOML，需 vendored 一个 TOML parser 进构建，无网络下载。）

### 9.5.1 config 承载什么

provider profiles（provider kind / model / base_url / `api_key_env` / effort，§13）· registry 选择（pinned native tools、上限 K、排序权重，§5.1）· policy hook 档位（off/auto/human/AI reviewer，§7.4）· environment backend 选择与参数（local/sandbox/remote，§8）· compaction 触发阈值（§11）· 项目本地 extension 搜索路径（§7.2）。

§17 里"待定初值"的一堆 tunable（K、`uses_recent` vs `success_rate` 权重、compaction 阈值）从此有了确定的安放处：它们是 **default.toml 里的初值 + 上层可覆盖**，不再是散落在代码里的魔数。

### 9.5.2 信任边界：项目层只能收窄（与 §9 同一不变量）

项目 `.nulya/config.toml` 随 repo checkout 而来，**可能不是本机用户写的**，因此是不可信输入。它过一道 `sanitizeProject`：

> **项目层可以"更严"，不能"更松"。** 可设：pin 哪些 native 工具、选 model profile、项目本地 extension 路径、把 policy hook 调到**更严**档位、把 K **调小**。**不可**：关掉 policy hook、把 environment backend 从 `sandbox` **降级**成 `local`、放宽 authority、注入 `api_key_env` 名字去外泄 host env。

这不是新发明——它是 tcode `sanitize_project_config`（剥掉项目层的 `auto_mode` / `tcode_state`）的同构，而在 nulya 里它**和 §9 的 `extension_permissions ⊆ session_authority` 是同一个不变量的另一面**：无论走 extension 注册还是走项目 config，checkout 一个 repo 都不该能拓宽你机器上的权限或削弱安全策略。system 与 user 层是管理员/本机用户所有，视为可信，不过 `sanitizeProject`；只有 project 层过滤。

### 9.5.3 secret 不入文件（§9 净化不动）

config 文件只持 `api_key_env`（一个**名字**，如 `"OPENAI_API_KEY"`），不持真值。真正的密钥仍留在 host env、由 host 进程读取、**绝不下传给 extension/shell 子进程**（§9）。于是现有的裸读 env 做法不作废，而是**降级为 secret 通道**，config 文件接管 selection 通道。允许内联 `api_key`，但同 tcode 一样不鼓励。

### 9.5.4 与 ledger 的关系（本版范围）

config 文件在磁盘上可变，但 §1 反对"第二份 mutable state"。**目标终态**：对话开始时解析出的 effective config 作为一个 ledger 事件记入，驱动 §5.1 的 `registry_selection` 与 provider 选择，使 replay/fork 可复现；磁盘 config 中途变更只在**下一对话边界**生效（同 §5.3 工具晋升）。**本版范围**：先只实现 `default → system → user → project` 的纯函数解析 + `sanitizeProject`，返回 effective config struct；落 ledger 留到 `registry_selection` 真正接线时一起做。

---

## 10. 内嵌 Zig 工具链

- **`@embedFile` 宿主平台那一份 Zig（pinned，如 0.16.x）压缩包进 nulya 二进制**，首次需要时解压到 `~/.local/share/nulya/toolchains/zig/<ver>/`（Windows 用 AppData）。
- nulya 二进制本就平台相关，故只需内嵌宿主平台一份；而**一份宿主 Zig 即可交叉编译到所有 target** —— 白赚跨平台构建。
- 代价：二进制 +~50MB（linux/mac）/ +~90MB（win）；nulya 自更新时重新带上。**符合"不差这点大小、拷一个文件就能跑、零网络"**。
- **删除** ChatGPT 的"按需下载 + hash 校验 + pinned 漂移 + 网络失败处理"整套复杂度——净简化。
- AI **不直接** `zig build`，而是 `nulya ext build .nulya/extensions/foo`，由 nulya 统一决定 zig version / optimize / cache dir / target / output，保证**可复现构建**。
- 可选：另出一个不内嵌 Zig 的瘦身版给"确定系统已有 Zig"的用户；主版内嵌。

---

## 11. Compaction 与缓存

- Compaction 是 ledger 里的一个**事件**，不是"随手 truncate"。它保留近期上下文，把旧消息压成结构化 summary（记录文件操作等），参考 Pi。
- 它**必然**炸一次缓存（重写前缀）→ 因此它是一次显式 `generation++`。设计目标：**让它罕见、边界明确**；compaction 后，新的 summary 成为**新的稳定基座**，之后请求在其上纯前缀延长，缓存重新建立。
- compaction 边界应尽量放在自然断点（一个 task 完成后），避免频繁触发。

---

## 12. 质量门（不让 AI 自证）

ChatGPT 的 validate/test 门是空心的：工具与测试都 AI 写，测试只证明它自洽。要让门有意义，验收标准**不能只由 AI 出**：

- `tests/*.json` 里的 golden 输入/期望输出，优先来自**用户/真实数据**，或人可 review。
- `nulya ext test` 在**真实输入**上跑，结果给人看（尤其首次 install）。
- 高价值工具支持**对拍**（与已知正确实现 diff）。
- validate 至少含：manifest schema 合法、entry 可执行、协议往返正常、声明的 permission ⊆ session_authority。
- **门通过 ≠ 正确**，只是"没有明显坏"。文档里对模型和用户都说清楚这一点。

---

## 13. Provider 抽象与 cache breakpoints

Provider runtime 归一化不同厂商协议；在**generation-稳定的 PromptIR 块边界**放置或声明 cache breakpoint：tools 之后、system 之后、最后一条稳定消息之后（append-only 让“最后”这个断点持续前移）。

`Model` 不是裸函数指针，而应是带实例状态的 provider 接口：

```
Model { ptr, vtable.step(ptr, alloc, prompt_ir, options) }
```

真实 provider 至少需要 client、model name、endpoint、auth、cache policy、capabilities、request options；没有 `ptr` 最终只能依赖 global state。

Provider capability 以能力位表达，不写死成唯一策略：

```
ProviderCapabilities {
    deferred_tools,
    explicit_cache_breakpoints,
    mid_conversation_system,
    cached_token_metrics,
}
```

默认 generic strategy 仍是 frozen native tools + shell ext run。若 provider 明确支持 deferred native tools 或显式 cache breakpoint，可以在 provider 层优化，但不能破坏 §1 的 PromptIR stable_blocks 前缀不变量。

---

## 14. CLI 表面（都不是 LLM tool，经 shell 调用）

```
nulya ext init | find | list | inspect | build | test
             | activate | deactivate | rollback | run | api
nulya skill list | load <name>    # Skill contribution，渐进披露，隐藏 provider/路径（§7.7）
nulya toolchain zig <args>        # scratch 用
nulya ext api [protocol|permissions|examples]   # 模型查【本机】真实 API，杜绝猜签名
```

**`nulya ext api`（采纳 ChatGPT 第 17 条）**：所有协议/权限/示例由**当前 nulya 二进制自己生成**，模型永远查本机，不会出现"模型知识里的 v0.4 API 与用户机器 v0.7 不一致"。→ 模型工具面恒为 `{shell, edit}`（+ 本场选定的少量 native）。

---

## 15. 明确划线：kernel invariants（不可自生长）vs 可自生长能力

**kernel（必须内置、保证正确性，绝不"让 AI 写个 extension"）：**

```
Agent loop / step 状态机 · Ledger append-only 与 PromptIR 前缀不变式 · Cache-generation 投影
Batch（多工具单条回传，执行策略独立）· ToolSetSnapshot per step · Provider 归一 + cache breakpoint/capabilities
Compaction · Tool registry 与对话开始选择 · Extension build/activate deterministic validation · rollback
Contribution 边界（Package/Runtime/Contribution 三分）· typed registries（Tool/Skill/…）· session 组合冻结
"model-visible 必须可从 ledger 重建"（extension 只 propose，kernel append，PromptIR project）· Middleware 排序决定论
可撤销注册（registration = reversible effect）· ToolExecutor 泛化（builtin/extension/MCP 同构）
Subagent 能力模型（read_only 天花板 / ToolPolicy）· subagent=自调用 · policy hook 机制
Frontend/Core 分离（headless ledger 引擎 + 薄客户端 + ACP transport）· AgentSession host API
Execution Environment 抽象 · Authority / env 净化 · Managed Zig · Telemetry · Crash recovery
配置解析链（default→system→user→project）· 项目层信任收窄（sanitizeProject，§9 同不变量）
```

**可自生长（内核之上皆可学习）：**

```
grep glob git web-search browser pdf excel database github docker lsp ripgrep
image/audio kubernetes ssh jira notion ...
```

> 定位差异：Pi = minimal harness + 人/模型写的 TS extension；DeepSeek = microkernel + "Everything is a Plugin" + 运行时自修改。
> **Nulya = minimal immutable kernel + self-evolving native capability layer**。不是"Everything is a Plugin"，而是"**Everything above the kernel is learnable**"。

---

## 16. Roadmap（先修底座，再跑 extension 闭环）

当前阶段先暂停 extension/subagent 的继续实现，把会被后续全部依赖的底座不变量修对。优先级按下面 7 组提交推进：

1. **Ledger owns appended events**
   - `Ledger.append(event)` 第一版对传入 slice 做 deep copy，append 成功后事件生命周期与调用者彻底无关；如果后续实测 copy 成为瓶颈，再另加 `appendOwned(...)` / ledger allocator builder 作为显式快路径。
   - `Ledger.deinit()` 释放 nested allocations，消灭 `main.zig` / 测试里手工 free assistant calls、tool_results、output 的泄漏式所有权。
   - `generation` 从 Ledger mutable field 改为事件投影：compaction/system_change/registry_selection 等事件决定当前 generation。

2. **Introduce PromptIR and cache-prefix invariant**
   - 新增 `prompt.zig`：`Ledger -> PromptProjection -> PromptIR { tools, system, message blocks }`。
   - 测试改为断言 `PromptIR[N].stable_blocks` 是 `PromptIR[N+1].stable_blocks` 的前缀，不再断言完整 request bytes 前缀。
   - Provider integration test 单独检查各家缓存指标。

3. **Freeze registry into ToolSetSnapshot with schemas**
   - `ToolDefinition { id, name, description, input_schema }` 与 handler 分离。
   - `runStep(ledger, model, tool_snapshot, ...)` 在 model request 前冻结 snapshot；`execOne(snapshot, call)` 不再查询 live registry。
   - builtin shell/edit 先用内嵌 raw JSON schema；extension manifest 后续复用同一数据形状。

4. **Make emit budgets actually bounded**
   - `max_bytes` 成为硬不变量；裁剪改成 head/tail byte budget，并在 newline/UTF-8 boundary 附近截断。
   - `max_line_chars` 改名 `max_line_bytes`，按 UTF-8 boundary 裁，不生成 invalid UTF-8。
   - 任意 truncation 都写统一 `[full output: <path>]` footer，模型只看 tool result 文本也能找到完整内容。
   - 去掉 `base_seq * 64 + i`；spill path 用 content hash 或 `<ledger-id>/<event-seq>-<call-index>`，避免 fork/subagent/call-count collision。
   - 增加 `StepOutputBudget`：per-tool 预算之外，再限制整轮 batched tool_results 的总 context 体积。

5. **Make edit writes atomic**
   - `read original -> produce updated -> write sibling temp -> flush/close -> atomic rename`。
   - 失败时 original untouched。
   - `replace_all` 类型错误改为明确 schema error，不再静默当 false。

6. **Introduce Environment boundary and provider/model instances**
   - 新增 `environment.zig`，`shell.run()` 改为 `ctx.environment.runShell(...)`，由 `LocalEnvironment` 统一决定 bash/powershell dialect、cwd、sanitized env。
   - extension subprocess 后续也走同一 Environment。
   - `Model` 改成 `ptr + vtable` 或等价 generic，真实 provider 状态不走 global。

7. **Make agent step crash-aware and bounded-concurrent**
   - assistant tool calls append 后、tool_results append 前 crash 时，pending completion 语义为 `unknown`。
   - 对可能 side-effecting 的 call 绝不自动重放；resume 时让模型检查现实状态。
   - tool definition 预留 `replay_safety = read_only | idempotent | mutating`，第一版先按 unknown/unsafe 保守处理。
   - batch 执行加并发上限，避免“一轮 N 个工具”失控。

上述 7 组底座与首个 extension 闭环（`extension.json`、`ext run`、`ext build`、immutable version、activate、rollback）已落地并跑通 E2E。subagent/reviewer 先作为可关闭、可配置的 policy hook 机制保留，不作为 v0.1 kernel 强制门。

### 16.1 下一阶段：把 Extension 从 Tool-only 拓宽为通用能力注入（本轮讨论产物）

以三分（Package / Runtime / Contribution，§7 脊椎）为主轴。按下面顺序推进——**先修已跑通路径上的正确性问题，再做结构泛化，最后接新能力**：

1. **runExtension 加固（排最前，是正确性 bug 不是架构）**：给 `ExtensionOutcome` 补 `stderr`（当前 [environment.zig] `.stderr = .ignore`，AI 无法自修复）；加 `timeout` + `cancellation`（当前 AI 写出 `while(true){}` 能挂死 host）。这条在"AI 自己造工具"路径上最救命。
2. **ACP 归位**：从 `EnvironmentBackend` 删 `acp`，落到 Frontend/Transport 层（§2.1、§8）。小而清晰。
3. **manifest → `contributes{}`**：删 `tools.len>0`（`error.NoTools`）不变量，改成"至少一种 contribution"；解锁纯 Skill 包（§7.2）。schema 升 `v2`。
4. **`Tool.run fn` → `ToolExecutor { ptr, vtable }`**：与 Model / Environment 同构，给 extension / MCP 留真正执行入口（§7.3、§5）。做完 MCP 就完成一半。
5. **Wire protocol → JSON-RPC `method`**：envelope 从 `tool` 写死改成 `method` + `params`，解耦 runtime 与 Tool（§7.3）。
6. **抽 `AgentSession`**：把 `main.zig` 手工组装收进一等对象，为 ACP/TUI/App 提供公共 host API；同时把 loop 里漏出的 extension 逻辑（`ctx.ext_root`、每 step `notes.sync`）挪进 session 的 step preparation，让 loop 重新"不知道 extension 这个词"。**先 refactor，不建 fork/resume/lifecycle**（§2.1）。
7. **SkillRegistry + Agent Skills 兼容**：`SkillProvider { list, get }`，`nulya skill load` 经 shell，渐进披露（§7.7）。
8. **组合冻结 + 可撤销注册**：session 开始 resolve + freeze extension composition（含 pinned version），记 ledger 事件当 generation base；activate 产 `Registration[]`，disable 逆序 dispose（§7.4）。
9. **（其后）接 MCP**：`McpClient` 作为 ToolProvider/ResourceProvider/PromptProvider 进同一 registry，**不伪装成 extension**；同样走 capability catalog → selection → 6~8 native，避免把上百 tool 全塞模型（§5 哲学）。

**里程碑（项目之魂）：**

> **Nulya v0.1 自带两个工具。第三个工具由 Nulya 自己创造。**

闭环示例（用户：“帮我分析这个 parquet 数据”）：

```
无 parquet 能力 → nulya ext find parquet → 无 → AI 写 parquet-inspect/src/main.zig
→ nulya ext build → nulya ext test(真实数据) → policy hooks → append tool_available_note
→ 经 shell 处理数据 →（三周后再遇 parquet）已有，直接用
→（发现慢）改源码 build v2 → benchmark → 原子切 v2 →（regression）rollback v1
```

---

## 17. 开放问题（待定）

- **compaction 触发策略**：token 阈值 vs task 边界 vs 混合；如何最小化 generation bump。
- **对话开始 tools[] 的上限 K** 与排序权重（`uses_recent` vs `success_rate` 权衡）的初值——安放处已定为 `default.toml`（§9.5.1），待定的是具体初值。
- **`nulya ext run` 的 JSON 手写负担**：低频工具经 shell 时模型要手写 JSON，是否给一个更宽松的 `--arg k=v` 语法降低出错率。
- **ACP / remote environment** 的具体协议选型。
- **cross-conversation 的 extension 复用**在多用户/多 workspace 下的隔离与共享边界。
- **provider cache breakpoint / deferred tools** 的精确放置与各厂商差异核实。
- **policy hooks 默认值**：默认 AI reviewer、人类确认、还是 auto；不同 workspace 的风险档位如何配置。
- **ProviderContribution（extension 供 model provider）的机制**：它在 loop **上游**，与下游 Tool/Skill/Hook 不同构（直接决定 PromptIR 序列化 / cache breakpoint / streaming）。taxonomy 里先占位，具体机制待定——大概率不是 ToolExecutor 那套 vtable。
- **Middleware 声明式排序**：v0.1 按稳定 extension id 排序即可（§7 preamble）。后续是否让 extension 声明"排在 X 之后" / 优先级 / 签名来处理特殊次序，以及冲突（环、互斥）如何裁定。
