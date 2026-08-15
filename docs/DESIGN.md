# Nulya — 设计文档 (v0.1 frozen core + v0.2 evolution draft)

> A minimal immutable kernel + a self-evolving native capability layer.
>
> Nulya **不是** extension / plugin system，而是一个让 Agent 能**制造、验证、积累、演化自身能力**的最小内核。
> 内核只有两个工具（shell、edit），第三个工具由 Nulya 自己造出来。

**三层定位（读全文的地图）：**

```
Agent              决定学什么 / 造什么              ← 不在 kernel 里，是模型的推理
  ↓
Evolution Policy   决定什么值得留下 / 晋升 / 替换   ← kernel 之上，可替换（§15.2）
  ↓
Capability Kernel  execute / verify / version / authorize / evidence / rollback / compose   ← 不可自生长
```

这七个动词是 **Capability Kernel 的 target contract**，不是"已全部实现"的宣告。诚实分界（§15.2 详列）：**v0.1 已落地 `Execute / Version / Observe(evidence) / Rollback / Compose`（外加大部分 Validate）；`Verify`（正式生命周期门）与 OS 强制的 `Authorize` 是 v0.2 增量**（§18.4、§18.6 Phase C/F）——现在的 authority 仍是 §9 的"env 净化 + 诚实的 session 边界"，还不是 sandbox 强制。

一句话：**Agent 决定学什么；Policy 决定什么值得留下；Kernel 保证学出来的东西可信、可追踪、可执行、可回退。** kernel 不负责"聪明地进化"，只负责让进化**安全、可观测、可回退、可学习**（§15.2–§15.3）。这条分界是 Nulya 相对普通 plugin harness 的核心差异，也是抵抗后续 feature creep 的那把尺。

**产品原则（决定 Nulya 会不会重新陷入 feature race）：**

> **Nulya 不参与内建 Agent 功能的军备竞赛。新的 harness 行为应尽可能由 Agent 基于稳定 Kernel primitives 自行实现为 Extension，而不是修改 Kernel。**
> Nulya does not compete on built-in agent features. New harness behavior should be expressible as extensions composed from stable kernel primitives.

这把 §15 的"Everything above the kernel is learnable"从**能力（数据面）**推进一层到 **harness 行为（控制面）**。于是能力扩展分成两条对偶的轴：

```
Tool / Skill / Prompt   数据面 (data plane)     控制世界      给 Agent 长"手"
SessionDriver           控制面 (control plane)  控制 Agent    给 Agent 长"脑回路 / 工作方式"
```

Claude 明天出 agents，不去追着改 Nulya——直接让 Nulya 自己长一个 extension 去读现有 agent 定义；想要 `/goal`、想要 `plan → review → 共识 → implement → review`，同理（规范例见 §19）。据此 v0.1 的一句话使命升级：

> **v0.1: Nulya lets an agent manufacture its own tools.**
> **now:  Nulya lets an agent manufacture both new capabilities and new ways of using itself.**
> Kernel 的职责是提供**一组稳定的 primitives**，让 tools / agents / workflows / loops / reviewers / 未来的 harness 功能都能在不改 kernel 的前提下长出来。

本文档是设计基线，不是最终 API。**v0.1 的能力底座已冻结（§15.1）——它让 Nulya 会"长"能力；v0.2 的主题是能力演化（§18）——让 Nulya 开始判断自己长出来的能力是不是更好**，全部在冻结底座外生长，不改 kernel 骨架。术语：**ledger** = 会话事件日志；**generation** = 缓存世代；**step** = 一次 model 请求-响应；**PromptIR** = provider 无关的 prompt 逻辑块投影；**capability** = 一个逻辑能力（一个 tool / skill / ...），与其具体 implementation version 分开（§18.1）。

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

Ledger 不是 `Vec<Message>` 加随手 truncate，而是一条 **durable、append-only 的事件日志**。

**目标事件集合**（v0.1 只实现其中 kernel 当前所需的子集）：

```
CURRENT（已实现，`ledger.Event`）：
  user_text | assistant | tool_results | capability_note
  —— assistant 内含 tool calls；tool_results 是一条 batch（多个结果合一 turn，见 §4）；
     capability_note 是对话中新增能力的追加（§5.3）。

POST-v0.1（DESIGN 目标形态，尚未实现）：
  registry_selection    // 对话开始选定的 tools[] 记进 ledger 当 generation base（§5.1）
  extension_build | extension_activate
  extension_review      // policy hook 结论，见 agents-and-review.md
  review_question | review_answer   // 主 agent ↔ 审阅者的 append-only 通信
  compaction            // 见 §11
```

> 当前 skeleton 刻意只用最小 alphabet：工具使用统计走**独立** usage journal（§3.3），extension build/activate 是文件系统上的不可变版本操作（§7.4）而非 ledger 事件，`registry_selection` 未落地（§5.1；见 §16 Deferred）。上表 POST-v0.1 是方向，不是已实现清单。

每条事件：`seq`（单调）、`generation`、`parent_seq`、内容、`content_hash`。整条日志内容可寻址。

### 3.2 API 约束（硬性）

- **没有 `edit_event` / `delete_event` / `reorder`**。API 表面只有 `append(event)` 和只读的 `read/replay/fork`。
- "纠正"语义 = **append 一条纠正事件**（例如工具结果错了，append 一条新的 tool_result 修正 + 一条说明），或 **fork 一条新 ledger**。
- **fork 与父 ledger 结构共享前缀**（copy-on-write）；前缀部分的 prompt-cache 依旧有效。"重新生成上一轮"在语义上只能是 fork 出新分支，不能原地改。
- 发给模型的 `PromptIR.stable_blocks` 是 `events[0..k]` 的**纯函数**。Provider request bytes 是 PromptIR 经 provider serializer/cache policy 的结果；kernel 只断言 §1 的块级前缀不变式。

### 3.3 派生视图（projection）

UI、trajectory、metrics 是 conversation ledger 的**投影**，不持久化 mutable 状态。

工具使用统计走的是**同一条哲学、另一条日志**：它不是 conversation ledger 的投影，而是一条**专用的 durable append-only usage ledger** `<workspace>/.nulya/tool-usage.jsonl` 的投影。每条 usage 事件只记原始事实 `{ tool_id, ok }`（`tool_id` 是稳定身份 `ext:<id>/<tool>` / `builtin.shell`，跨实现版本累计），排序 / recency / promotion 全是读时派生，从不落盘：

```
durable append-only usage facts { tool_id, ok }
        └─ projection ─▶ ToolStats { uses_total, uses_recent, last_used, success_rate }
```

拆成两条日志是刻意的：usage 事实在没有 conversation 的纯 CLI 调用（`nulya ext run`）里也会产生，把它塞进 conversation ledger 反而会污染 §1 的 prompt 前缀。原则不变——**persist facts, derive stats**；统计口径以后改了可以重算，这也是为什么工具排序（§5）能安全演进。（v0.1 只记 `ok`，没有 `latency`；latency 属 post-v0.1，见 §17。）

> **v0.2 增量（§18.2）**：这条事实里现在缺 `version`——`tool_id` 跨实现版本累计，看不出某版 regression。v0.2 给 fact 加 `version`（journal `v:1→v:2`），再从同一条日志派生出 `VersionStats` 投影服务 rollback/comparison，`ToolStats` 名字与冻结语义不变。

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
- 选择规则（在 session-setup 边界一次算出、冻结进 `SessionComposition`；把这次选择另记成一条 `registry_selection` ledger 事件当 generation base 属 post-v0.1，见 §17）：
  1. builtin：`shell`, `edit`（永远在，位置固定最前）。
  2. 用户 pin 的 native 工具（配置指定）。pin 是 operator 意图：pin 指向的工具解析不到就**硬失败**，绝不静默跳过。
  3. 自动按使用统计排序补足到上限 K（`uses_recent` + `uses_total` + `last_used` + `success_rate` 的投影排序）。best-effort：解析不到 / 撞名的候选按 rank 顺序跳过直到填满，从不失败。K 是早期默认值（如 6–8），非永久。
- 排序**只在此刻发生一次**。对话开头本就是新前缀、无缓存可炸，所以"晋升"零成本。**排序绝不在对话中途重排**（那才是缓存杀手）——由 `SessionComposition` 在 `init` 冻结 membership 保证，`tests/e2e.zig` 全环证明。

### 5.2 native 工具的位置稳定性

选入的 native 工具在 `tools[]` 里**按稳定 ID 排序**，不因"刚调用过一次"就前移。位置抖动同样伤缓存与可复现性。

Registry 里 `id` 是稳定身份，`name` 是 model-facing 名字；同一个 `ToolSetSnapshot` 内 `name` 必须唯一。builtin 名字 `shell` / `edit` 永久保留，extension 不能占用。

### 5.3 对话中新增能力 = append 一条 Note（不改 tools[]）

Agent 在对话中途造出/发现新 extension 时：

- **不修改** `tools[]`（改了就 miss）。
- **append** 一条 `capability_note` 事件，内容形如：
  > Extension `web.search` version `v-a8fc…` is now available：列出该版本贡献的所有可调用 tool，并给出 `nulya ext run web.search <tool> '{...}'` 调用方式。
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
| System prompt（静态文本） | 下游 | ✅ | manifest `contributes.system_prompts[]`：纯文本贡献，build 期校验 UTF-8 + 大小上限（`max_system_prompt_bytes`），进 PackageSnapshot 参与 version id；session 组合时按稳定 id 顺序拼进 system blocks（§7.4 组合冻结）。**无需 runtime**，与 Skill 一样是"文件即能力" |
| Hook | 下游 | 🟡 窄 | 只落 Provider / Middleware / Observer 三类机制，**不做 Pi 那样的 event 洪流** |
| Command / Prompt | 下游 | ⚪ 命名保留 | schema 占位，v0.1 不实现 |
| Provider（model） | **上游** | ⚪ 存疑 | model provider 在 loop **上游**，决定 PromptIR 序列化 / cache breakpoint / streaming，机制与下游 Contribution 不同构，**暂不设计**，仅占位（§17） |
| **SessionDriver（控制面）** | **外层** | ⚪ 占位 | 驱动 session 的**控制流**（何时继续 / 终止、spawn 与编排 child session），经 Session Host API 组合 kernel primitives。是第一个需要 **host callback**（extension→kernel）的 Contribution，与下游"被 kernel 调用"的 Tool 方向相反。完整定义见 §19 |

**数据面 vs 控制面**：上表除 SessionDriver 外全是**数据面**——它们是 kernel *之上/之下* 的能力注入（Tool 被 kernel 调用、Provider 供 kernel 序列化），改变的是"Agent 能对世界做什么"。SessionDriver 是**控制面**——它包在 loop *外层*，改变的是"session 怎么推进"。二者调用方向相反，故不同表、不同 seam（§19）。

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

v0.1 runtime **仍不做** daemon / persistent worker / streaming / bidirectional events / host callbacks。当前 `tool/call` 请求用专用的 `ToolCallRequest` 类型表达；响应必须包含与请求相同的 `id`，否则视为 invalid response。等真正出现 `skill/get` / `hook/call` / `driver/run`（§19）等第二种 runtime 方法时，再抽 `JsonRpcRequest { id, method, params_json }`，不提前制造万能 RPC framework。其中 **`driver/*` 是目前看最可能率先出现的第二种，且它会一并把上面这条"仍不做 host callbacks"变成真实需求**——driver 要反向调进 kernel（`session/create/step/…`），是第一个非"请求-响应一来一回"的 Contribution（§19.3）。

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

> **v0.2 把 `validate/test` 这段显式拆成 `Validate`（manifest/协议/权限合法，deterministic）与 `Verify`（能力真的符合自己声称的行为，跑 `tests/`/`evals/`）两道门，见 §18.4。** activation（current 指针）与 promotion（native 面，§5）是两条独立状态轴，见 §15.2。

- 每次 build 产出**不可变版本**，版本 id = `hash(canonical PackageSnapshot + compiler_identity + target)`。`PackageSnapshot` 第一版收 `extension.json`、runtime 存在时的 `src/**`、以及 manifest 中声明的每个 `contributes.skills[]` 整棵目录；按 `relative_path + file_length + file_bytes` 排序后 hash。`versions/`、`.zig-cache/`、顶层测试输入不进 snapshot。（v0.1 版本只是 build artifact，无"为什么存在"；**v0.2 给它加 `parent_version? + reason?`，让 version 从 artifact 变成 evolution step，见 §18.3**。）
- 版本目录冻结 snapshot：`versions/v-…/extension.json` 是 frozen manifest，`versions/v-…/package/src/**` 和 `versions/v-…/package/skills/**` 是 frozen package 内容，`bin/` 只放编译产物。runtime 编译必须从 frozen `package/src/main.zig` 进行，不能再读 mutable draft。
- `compiler_identity` 取实际执行的 `zig version`。production 通常是 managed pinned Zig；dev/test override 时，hash 记录 override 编译器的真实身份，而不是假装成 pinned 版本。
- 布局：`foo/versions/{v-a8fc3c, v-b193ab}/…`，`foo/current -> v-b193ab`。
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

> **当前实现状态**：freeze 已落地——`SessionComposition` 在 `AgentSession.init()` 解析 active extensions 并 pin 住版本（Tool/Skill/System-prompt 一并冻结），组合内**内存**冻结。§5.1 选择规则第 1、2 档已接线：builtin（`shell`/`edit`）恒在，加上**配置显式 pin 的 native extension 工具**（`registry.pinned_native_tools`）晋升进 `tools[]`。每个被 pin 的工具在 session 开始时冻结出**绝对 `entry_path`**（基于 pin 时的版本，绝不二次读 `current`），运行期只按此路径 `invokeTool`，无任何 store/version 解析——这正是 §7.4 freeze 语义延伸到 native 层。`max_tools` 作为 provider-facing 总数硬上限（builtin 占 `registry.builtin_count`），超额直接报错、不静默截断；未知 pin 直接报错、不静默跳过。**尚未接线**：第 3 档 stats 自动排序补足（`registry.weights` 暂未使用）；以及"记一条 ledger 事件当 generation base"——`currentGeneration` 恒为 0，composition selection 还没进 ledger `Event` alphabet（§3.1 列的 `registry_selection` 同属这一档）。事件化留待 registry_selection 接线时一起做。可撤销注册（§7.4 末 `Registration[]`）同样待做。

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
- **不提前抽 Provider 抽象**（与 §16 已落地状态一致）：当前 skill 只有 extension 一个来源，`SkillRegistry` 直接吃它的 `list(cwd) / get(name)` 行为即可，先只暴露 summary、需要时再加载完整定义——与 §5 的 shell-first、渐进披露一脉相承。**等第二个真实来源出现（local / user / remote / MCP）**，再从现有 `list/get` 行为提炼 `SkillProvider { list, get }` source 抽象。这正是本设计反复锁定的品味：**第二个 consumer/source 出现之前，不抽 abstraction。**

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
- **后续里程碑**：`sandbox` backend 上线后，manifest.permissions 才真正被 OS 强制。届时它从"声明"升级为"边界"。这条对应 v0.2 Roadmap Phase F（§18.6）——把结构化 authority 做成系统能力，核心不变量是 **capability 绝不因被生成或被晋升而自动获得 authority**，且始终 `capability authority ⊆ session authority`。

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

> **v0.2 把这里的两类检查显式命名分层（§18.4）**：上面第 4 条（manifest/协议/权限合法）是 **Validate**（deterministic kernel 不变量）；前 3 条（真实输入/对拍验收）是 **Verify**（能力符合自己声称的行为）。二者是不同的生命周期门，Verify 让"AI 不能仅凭编译通过就算学会一个能力"成为规则。

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

### 15.1 v0.1 self-evolution core：freeze list

self-evolution 闭环已由 `tests/e2e.zig` 全环证明（真实 built binary，无 mock）：

- **self-manufacture**（里程碑第一句）：一个只暴露 shell + edit 的 session，由 deterministic 模型经这两个 builtin 跑 `nulya ext init/build/activate/run` 亲手造出新扩展并记录 usage，全程该工具不进 native 面；下一个 session 排名这份 usage 后把它自动晋升为 native 工具并执行。
- **promotion + freeze**：CLI usage → usage journal → session-boundary ranking → 自动 native 晋升 → ToolExecutor spawn 冻结版本；mid-session activate v2 后 session native 仍 v1 / CLI live v2 / 新 session native v2。

下列为该核心的**冻结面**——只往外挂能力，不再改 kernel：

**FROZEN CORE（v0.1，不再改动语义）：**

```
Ledger append-only 语义                         (ledger.zig)
AgentSession 编排 + interrupted-batch repair    (session.zig)
cancellation 语义（step 边界消化）              (loop.zig / session.zig)
shell / edit 永久 builtin                        (tools/)
immutable extension package + 内容寻址版本       (extension/store.zig, integrity.zig)
build / activate / rollback / integrity          (extension/build_ext.zig, store.zig)
extension JSON-RPC (tool/call) 调用              (extension/protocol.zig, invoke.zig)
SessionComposition 版本冻结（pin + auto 同一路径）(composition.zig)
ToolExecutor / Binding（builtin/extension 同构）  (tool.zig, extension/tools.zig)
skills + 渐进披露 catalog                         (skill.zig, extension/skills.zig)
system prompts 投影                               (prompt.zig, composition.zig)
durable append-only usage journal                (tool_stats.zig, .nulya/tool-usage.jsonl)
ranking policy（纯函数：facts → 偏好）           (tool_selection.zig)
session-boundary 自动晋升（一次算出即冻结）      (promotion.zig → composition.zig)
```

分层不变量（§5 边界，锁进 v0.1）：`facts → ranking preference → composition availability/budget → frozen membership`。`tool_selection.rank` 只吃 facts + weights，绝不碰 active availability / pins / max_tools / Binding 构造；pin = operator intent（硬失败），auto = best effort（跳过）。

**NOT REQUIRED FOR v0.1（缺这些不影响核心成立，属 post-v0.1）：**

```
ACP / MCP transport            persistent extension runtime / hot reload
可撤销注册 Registration/disposer  dynamic ToolSet mutation（中途改 tools[]）
parallel extension scheduling   remote Environment
stats database / index / latency   ranking threshold 调参框架
registry_selection ledger 事件（把 selection 记进 ledger 当 generation base）
```

> 到这一步，项目最大的风险已不是"缺东西"，而是"**继续觉得还缺东西**"。后续 ACP / MCP / UI / richer ecosystem 都是往这个稳定核心外挂能力，不是继续改 kernel。

### 15.2 三层演化模型：kernel 是 primitives，policy 是 interpretation

§15 的"kernel vs learnable"二分，进一步锐化成**三层**（顶部地图的展开）。中间那层——**Evolution Policy**——过去散落在 §3.3 / §5.1 / §15.1 里没被单独命名，这里正式立成一等概念。

**Kernel 的职责压成七个动词——这是 target contract，不是"已全部实现"的清单**（比"支持 Tool/Skill/Prompt/Hook/Agent/MCP…"这种按 Contribution 类型罗列更耐久）。末尾标 v0.1 已落地 / v0.2 增量：

```
Execute    能力经受控 substrate 运行（§8 Environment）                               [v0.1]
Version    每个被接受的 implementation 内容寻址、不可变（§7.4）                        [v0.1]
Observe    记录 durable factual evidence，从不解释它（§3.3、§18.2）                    [v0.1；v0.2 加 version 维度]
Rollback   旧的不可变版本永远可恢复（§7.4）                                            [v0.1]
Compose    session 可见的能力面确定、冻结（§5.1、§7.4）                                [v0.1]
Verify     sealed version 满足自己声称的 contract / tests（§18.4）                     [v0.2 增量]
Authorize  生成的代码不能超出被授予的 authority（capability authority ⊆ session authority）  [v0.1 是 §9 诚实版：env 净化 + 边界；OS 强制属 v0.2 Phase F]
```

（Validate——manifest/协议/权限 deterministic 合法，§12——已在 v0.1 落地大部分，是 Verify 的前置门，二者 v0.2 显式分层，见 §18.4。）

Kernel 只提供 primitives：`activate(version)` · `rollback(version)` · `evidence(tool/version)` · `lineage(version)`。

**Evolution Policy 在 kernel 之上，消费 primitives 产出判断**：`retain` / `native promote` / `improve` / `rollback recommendation` / `retire`。当前的 `tool_selection.rank()`（§15.1）**就是第一代 Evolution Policy**——它只吃 facts + weights，产出一个偏好排序。

**由此得到本层最重要的不变量：**

> **Facts are durable; policy is replaceable.**
> Evidence 与不可变 history 永不丢失；解释它们的 policy 可以整个换掉。

推论：§5.1 现在的排序权重（`uses_recent` / `uses_total` / `last_used` / `success_rate`）与上限 K，是 **v0.1 selection policy，不是 kernel invariant**。统计口径、权重、甚至整个排序算法以后都能重算/替换，而底层 usage facts 不动（§3.3 已埋下这条哲学，这里把它提成显式边界）。**Activation（§7.4，当前 implementation 是哪个 version）与 Promotion（§5，逻辑能力要不要进下一 session 的 native 面）是两条完全不同的状态轴**——它们各自消费 evidence 的不同投影（§18.2），永远不该被合并成一个"分数"。

### 15.3 显式 non-goals：intelligence 不进 kernel

以下这些**永远不做成 core subsystem**。它们是 substrate 之上的 *intelligence*，属于 Agent 或 Evolution Policy 层，可学习、可替换：

```
GapDetector             （"哪里缺能力"由模型推理，不由 kernel 检测）
WorkflowMiner           （"什么工作流值得沉淀成工具"是模型的判断）
ToolSynthesisManager    （造工具是 Agent 经 shell 干的，不是 kernel 服务）
AutomaticRefactorManager
RewardModel             （kernel 存 evidence，绝不定义 reward，§18.5）
AutoPromptOptimizer
SkillPopularityEngine
```

Kernel **不** hard-code 诸如"shell 命令重复 3 次 → 造工具"这种启发式。`连续多次 parquet → rolling → covariance，值得编译成工具` 这类推理，Agent 自己应当能做——**Everything above the kernel is learnable**（§15）。

> 同理，上表里 `WorkflowMiner` 那类 orchestration"智能"永不进 kernel——但**它们要能长在 kernel 之上**，靠的正是 §19 的 SessionDriver 控制面 seam：`/goal`、plan mode、review workflow、swarm 全部表达成 driver extension，kernel 只多出一个窄 Session Host API，而非把这些 workflow 内建。

每当有人想往 core 塞智能，问一句尺子：

> **这是 substrate，还是 intelligence？** 若属 intelligence，就放到 kernel *之上*。

**收尾原则（放在最显眼处）：**

> **Nulya does not make capability evolution intelligent in the kernel.
> It makes capability evolution safe, observable, reversible, and learnable.**

---

## 16. v0.1 实现状态（status snapshot）

> **完整开发历史已迁出**——底座 7 组提交、Extension 从 Tool-only 拓宽的 11 点落地/未落地清单，见 [history/v0.1.md](history/v0.1.md)。本节只留当前状态快照。规范真相源是 **§15.1 冻结面** + **§18 v0.2 演化层**两条时间轴，读当前架构不必回溯历史。

**已落地（跑通 E2E，语义见 §15.1）：**

- Ledger append-only + deep-copy ownership；`generation` 事件投影
- PromptIR + 块级前缀不变量（`prompt.zig`）
- ToolSetSnapshot per-step 冻结 + builtin schema
- bounded emit budget + 大输出落盘留指针；atomic edit
- Environment 边界（`local`）+ `Model` ptr/vtable 实例
- crash-aware step + bounded-concurrent batch + 统一 `std.Io` cancellation 链
- Extension 闭环：`contributes{}` manifest v2 · PackageSnapshot 内容寻址版本 · JSON-RPC `tool/call` · ToolExecutor 同构 · build / activate / rollback
- AgentSession 编排（loop 不 import extension）
- SkillRegistry + Agent Skills 兼容 · system-prompt 投影
- usage journal → ranking → session-boundary 自动晋升 → 版本冻结

**Deferred（不影响 v0.1 核心成立）：**

- registry_selection ledger 事件（composition 记进 ledger 当 generation base）· 可撤销注册 Registration/disposer
- ACP / MCP transport · persistent runtime / hot reload · parallel / subagent 取消传播 · remote Environment
- **v0.2 能力演化层整体**（version-aware evidence / lineage / verify gate / evaluation，§18）

**里程碑（项目之魂）：**

> **Nulya v0.1 自带两个工具。第三个工具由 Nulya 自己创造。**

闭环示例（用户：“帮我分析这个 parquet 数据”）：

```
无 parquet 能力 → nulya ext find parquet → 无 → AI 写 parquet-inspect/src/main.zig
→ nulya ext build → nulya ext test(真实数据) → policy hooks → append capability_note
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
- **SessionDriver / Session Host API 的确切形状**（§19）：`session/*` 的最小方法集（要不要 `fork`）、host callback 通道的分帧与背压、driver 与主 loop 的 cancellation 传播；以及 driver 的 budget/step-ceiling 由 kernel 强制的具体机制（driver 只 propose "继续/停"，硬上限归 kernel）。待第一个真实 driver consumer（大概率是 `/goal`）出现再定。

---

## 18. v0.2：能力演化层（capability evolution）

v0.1（§15.1 冻结面）证明了**Nulya 会长能力**：能自造扩展、记 usage、在 session 边界把高频能力晋升成 native。v0.2 的主题是下一句——**Nulya 开始判断自己长出来的能力是不是更好**：哪个 implementation 更强、哪版 regress 了、该不该回退、该不该造后继版本。

它整个长在 §15.1 冻结底座**之外**，遵守 §15.2–§15.3：新增的都是 **evidence（facts）与 primitives**，"聪明"留在 Agent / Policy 层。纪律同 §7 taxonomy：**概念全定义，让数据模型稳定；但只有有近期消费者的先写实，其余显式占位。** 下面每节末尾标 `[写实]` / `[占位]`。

> 一条贯穿本节的原则（承 §1"不统一数据类型"）：**统一生命周期，不统一数据类型。** Tool 进入完整演化闭环；Skill 只需 discovery / catalog；Prompt 更像 configuration，其优化来自 eval/experiment 而非 invocation stats。**不要为了 API 对称造 `ToolStats / SkillStats / PromptStats`。** 本节只谈 Tool。

### 18.1 双身份：logical capability id vs implementation version

现在 `ext:web.search/web_search` 同时承担"逻辑能力身份"与"usage 聚合身份"（§3.3），这没错，但缺一维。v0.2 让每次 invocation 同时携带两个维度：

```
logical_tool_id   ext:web.search/web_search   ← 这个能力值不值得保留 / native 晋升
implementation    v-a83f… | null              ← 当前这版实现是否比上一版更好
```

`implementation` 是 **可空** 的：extension tool 有 content-addressed version，`builtin.shell` / `builtin.edit` 没有——它们是 in-core 内置、无 immutable 版本。**version-aware 分析（VersionStats、§18.2）只处理 version-known 的 capability**，builtin 与旧历史留 `null`，避免"builtin version 填什么"这种特殊情况。

**stable id 的 identity rule（authoring / verification invariant，不是 kernel-enforced invariant）：**

> **同一个 stable tool id *声明* 自己属于同一个 logical capability contract。**
> `web_search(query)` 可以从 v1 naive 演进到 v2 pagination / v3 retry / v4 better parser——**implementation 变，stable id 不变**；但如果它从 `web_search(query)` 变成 `database_query(sql)`（语义/契约破坏），**即使名字没变，也应当是新的 stable id**。

**分层说清楚（这条规则谁来强制）：**

- **Kernel 只强制 identity 的 *语法***——同一个 stable id 指向同一条 usage 聚合线、同一 registry 槽位。它**无法**自动证明 v2 有没有偷换 `web_search(query) → web_search(sql)` 的语义契约。
- **"没有偷换语义契约"由 candidate 的 Verify / review 保证（§18.4）**，不是 kernel 检测。违反 identity rule = verification / review failure，不是 kernel 报错。

所以这条**不叫 kernel invariant**——初版不做 JSON Schema 兼容性检查器 / contract fingerprint，先锁 authoring 规则 `same stable id ≈ compatible semantic contract`；真需要机器强制时再升成 kernel-enforced（schema compatibility / contract versioning）。`[规则 + 占位]`

### 18.2 Version-aware evidence（Phase A，最先落地）

**现状缺口（已核对 `tool_stats.zig`）**：usage fact 现在是 `{v:1, tool_id, ok}`，且 `tool_id` **跨实现版本累计**（源码注释明说）。于是 `web_search v1: 100 calls / 92 ok` 与 `v2: 20 calls / 8 ok` 会糊成 `120 / 100`——**v2 的 regression 根本看不出来**。

**最小改动**：给 usage fact 加**可空** `version`。新写的事件带 `v:2` schema，携带 `version`（extension）或 `null`（builtin）：

```
durable append-only fact { tool_id, version: v-a83… | null, ok }
        └─ projection ─┬─ LogicalToolStats  { uses_total, uses_recent, last_used, success_rate }   → 服务 native promotion（§5），吃全部历史
                       └─ VersionStats      { version, uses, successes, … }                        → 只吃 version-known 事实，服务 retain / compare / rollback（§18.6）
```

**关键：schema 升级不能丢历史（否则违反 §15.2 `facts are durable`）。** 现有 `tool_stats.zig` 的 `v` 字段是"遇到不认识的版本就精确报错"的守卫——那对*真正未知的未来格式*仍适用，但 v1→v2 这次**已知的**演化必须**兼容读**，不能让升级后旧 journal 触发 `UnsupportedStatsVersion`、连带 promotion 全停：

```
reader 同时接受 v1 + v2：
    v1 event → version = null（过去不知道 exact version，就诚实标 unknown）
    v2 event → version = exact | null（builtin）
```

于是 `LogicalToolStats` 用 v1+v2 全部历史，`VersionStats` 只用 version-known 的 v2 事实。这比"bump 后拒绝所有历史"更符合 Nulya 自己的哲学：**过去不知道就标 unknown，而不是丢掉历史。** 等 v1 事件自然消失，再删兼容分支。两个投影喂两条状态轴（§15.2）：LogicalToolStats → promotion，VersionStats → activation/rollback。**Stats 只是 evidence 的 projection**，不落盘。`[写实]`

> 命名不改冻结面：`tool_stats.zig` / `ToolStats` 保留原名（§15.1 冻结契约），v0.2 是**在同一条 journal 上加可空字段 + 加一个 VersionStats 投影 + reader 向后兼容 v1**，不是把 ToolStats 翻新成"Capability Evidence"。

### 18.3 Capability lineage（Phase B）

现在 version id = `hash(snapshot + compiler + target)`（§7.4），是个 build artifact，没有"为什么存在"。v0.2 给它加 lineage——但**必须与 content-addressed identity 严格分开**，否则埋雷。

**硬规则：provenance 绝不进 version hash。** version 回答"这是什么 implementation"（`= content hash`，同样源码 = 同样 version）；lineage 回答"为什么会出现这个 implementation"。若把 `reason` / `parent` 塞进 hash，同一份源码因 Agent 两次写不同 reason（"fix pagination" vs "retry failed"）就变成两个 version——**content-addressed identity 被 provenance 污染**。所以拆成两层：

```
Implementation identity（content hash，不含 provenance）
    version = hash(snapshot + compiler + target)          ← §7.4 不动

Evolution provenance（独立的 durable evidence，keyed by version）
    VersionCreatedFact {
        version:      v-b193…
        parent?:      v-a8fc…        ← 单亲即可，v0.x 不做 DAG
        created_by:   agent | human | …
        reason?:      "pagination repeatedly failed → add cursor pagination"
    }
```

于是能力演化成一条可读的链：`v1 → v2 → v3`；rollback = `activate(v2)`。真需要分支时再自然升级成 DAG。

> `VersionCreatedFact` 本质也是 evidence——和 `InvocationFact`（§18.2）、`EvaluationEvidence`（§18.5）同族。**但现在不造通用 Evidence union framework**（§15.3 纪律）：先在设计上把 identity 与 provenance 分开即可，三种事实各自最小落地，等真需要统一查询时再抽。`[写实：parent + reason 作独立 fact；DAG / 通用 evidence 框架占位]`

### 18.4 Verify：独立于 Validate 的生命周期门

§7.4 现在是 `build → validate/test → activate`，其中 validate（manifest/协议/权限合法）与"能力真的符合它声称的行为"混在一起。v0.2 把生命周期显式化——**并且 Verify 必须在 Seal *之后***：

```
Scratch → Build → Validate → Seal (immutable version) → Verify (sealed artifact) → Activate → Observe → Retain / Improve / Rollback
```

- **Build**：能不能编译。
- **Validate**（deterministic，已是 kernel 不变量，§12）：manifest schema / 协议往返 / integrity / `permission ⊆ session_authority`。
- **Seal**：产出 content-addressed 不可变版本（§7.4 已是 build 期封版）。
- **Verify**（新门）：跑 package 自带的 `tests/` / `evals/`，证明这个 capability 真的符合自己声称的行为。初版不需要框架，manifest 声明测试入口 + `nulya ext test <id>` 即可。

**为什么 Verify 在 Seal 之后（TOCTOU）**：若先 Verify mutable candidate 再 Seal，验证过的东西和最终 activate 的 immutable artifact 理论上不是同一个。对一个把 `exact / immutable / reproducible` 当命脉的系统，必须**先冻结"要测的到底是什么"，再测它**。推论两条：

- **Verify 失败不删除 version**：该 immutable 版本照样存在，只是标 `sealed but unverified / not active`——留下"AI 曾造过一个失败版本"的可审计证据，而不是抹掉。
- **验证套件本身参加 seal**：定义"这一版声称能通过什么"的 `tests/` / `evals/` 必须进 package snapshot，否则会出现"version immutable 但它的测试事后可被改松"。这**细化**了 §7.4 现在"顶层测试输入不进 snapshot"那条——外部/大体量 golden *输入数据* 可以留在 snapshot 外，但**定义验收门槛的 verification suite 要随版本冻结**；两者的确切边界在 Phase C 落地时定死。

核心思想：**AI 不能仅凭"编译通过"就证明自己学会了一个能力。** 这很可能是 Nulya 与"模型随手写插件"真正拉开差距处，且 deterministic test 比 outcome utility 更可靠、更容易先落地。`[写实]`

### 18.5 Evaluation evidence：区分 execution success 与 utility

`ok=true` 只说明**工具正常执行并返回了结果**，不说明**它真的帮到了任务**（web_search 跑通但结果是垃圾、task 最终失败，不该算优秀工具）。所以 evidence 分两层——**但要分清"客观观测"与"某人的判断"**：

```
InvocationFact       { tool_id, version, ok }                      ← 客观 runtime 观测：工具跑通了吗（§18.2 已写实）
EvaluationEvidence   { tool_id, version, source, at, passed|score } ← 某个 judge 的判断的 durable 记录
```

**为什么不叫 `EvaluationFact`**：`reviewer score = 0.82` **不是**"工具 utility 的客观事实"。客观事实是——"**source X 在上下文/时刻 Y 给出了 0.82**"。kernel 绝不声称 `score 0.82 == 真实 utility 0.82`，只如实记录"某 judge 产出了这个判断"。所以它是 **evidence of a judgment**，不是 fact of utility。

由此天然容纳多 evaluator 冲突，全部合法、都留证：

```
test:        passed
AI reviewer: 0.4
human:       good
```

**Policy 自己去解释/权衡这些判断**（§15.2）。**关键约束：kernel 存 evidence，绝不定义 reward（§15.3）**；`source` 可来自 `test / benchmark / reviewer / agent self-eval / human / external`；Evaluator 产出判断、Policy 解释判断，都在 kernel 之上。这让 `facts are durable; policy is replaceable` 更严谨：**durable 的是"谁在何时判了什么"，可替换的是"如何据此决策"**。v0.2 不做通用 Reward Framework。`[占位：EvaluationEvidence schema，消费者随 Phase D 再接]`

### 18.6 v0.2 Roadmap（按可落地性排序，evidence 先行）

```
Phase A  Invocation evidence 知道 implementation   usage fact 加可空 version（journal v1→v2 兼容读）+ VersionStats 投影   ← 最先，不加任何 utility score（§18.2）
Phase B  Provenance / lineage                       version 加独立的 VersionCreatedFact（parent + reason，不进 hash）（§18.3）
Phase C  Verify exact immutable version             Seal → Verify(sealed) 成 lifecycle 门，验证套件随版本冻结（§18.4）
Phase D  Record external judgments                  引入 EvaluationEvidence，kernel 仍不算 reward（§18.5）
Phase E  Policy compares implementations            用 VersionStats + EvaluationEvidence 检测 v2 regression → recommend/perform rollback（真正的 self-improvement 起点）
Phase F  Enforce generated-code authority           把 §9 的"诚实版"升级成结构化、OS 强制的 authority（生成/晋升永不自动获得 authority）
Phase G  Ecosystem adapters                         MCP / ACP / remote —— 作为 evolution kernel 的输入/输出适配器，不是主架构
```

**`A → C` 是这条路线的分水岭**：做到 C，Nulya 就比"让模型自己写了个 plugin"多出明确的一层——

```
AI 造出来 → exact artifact immutable（B 之后还带 provenance）→ exact artifact 自证（Verify）→ 观测的是 exact artifact 的真实使用
```

到 E 才进一步变成"系统能判断后继版本是不是真的更好"。分界重申（§15.2）：A–E 全是 **facts + primitives + 一层可替换 policy**；没有一步把"智能"写进 kernel。

---

## 19. 控制面：SessionDriver（让 Agent 长出新的工作方式）

§7 的 Contribution 全是**数据面**：Tool 给 Agent 一双手，Skill / Prompt 告诉它怎么用手。它们都无法表达"**这个 session 该怎么推进**"——何时该继续 step、何时算完成、要不要 spawn 子 session、多个 session 之间怎么编排。这层是**控制面**，v0.1 里它被硬编码在 `loop.zig` / `session.zig` 的 default 行为里，不可扩展。你举的 `/goal`、`plan → review → 共识 → implement → review`、读 Claude agents，全落在这半——它们要改的是控制流，不是能力。

**为什么 Tool / Skill 都做不到这件事：**

- **Skill 能表达 intent，但 enforce 不了控制流。** "目标没完成前别停"写进 Skill 只是 prompt——模型仍可能一句 "Done." 就让 AgentSession 返回。
- **Tool 也不行。** 一个 `check_goal()` tool 能算"到没到"，但决定不了 assistant 完成后 kernel 到底 terminate 还是继续 step。这个决定权在 kernel 的循环里，`/goal`、plan-review workflow、swarm 想要的正是**替换这个决定**。

### 19.1 定义

> **Kernel 负责 session 怎么正确运行；SessionDriver 负责 session 为什么、什么时候、以什么顺序运行。**

AgentSession 本已是一台 state machine（§2.1：`prompt() / cancel() / close()`，内部 `appendUser / step / usage`）。Kernel 自带一个隐式 **DefaultDriver**：

```
DefaultDriver
  user message → step → (有 tool call? → 再 step : 结束)
```

SessionDriver 把这个"结束还是继续"的决定权变成可替换的控制面扩展，**完全不改 AgentSession**：

```
GoalDriver                          PlanReviewDriver
  goal → step 到 assistant 停         create planner → 取 plan
       → 评估目标                      → create reviewer → review
       → 未达成: append 续写 → step     → review 回传 planner，往复到 accept
       → ...                           → create implementer → execute → reviewer
```

`plan → review → 共识 → implement → review` 本质是一台小型 agent runtime：一个 Controller 编排 planner / reviewer / implementer 几个 child session，靠 append-only 事件通信直到共识——这**复用 §2.1 的"subagent = 自调用"机制**，不是新造 spawn。Agent 只是 `Session + instructions + model + capability composition`，不是新的一等对象（§19.4）。

### 19.2 Session Host API（kernel 需要新增的唯一 substrate）

Driver 是 **out-of-process** 的（同 §7.1，wire protocol 即 ABI，不绑定 Zig）。它**不拿** `*AgentSession` / `*Ledger` / `*Registry` 这些内部指针，只经一个很窄的 host API 请求 kernel 代它操作 session：

```
session/create   （instructions + model + capability composition → 一个 child session）
session/append
session/step
session/events
session/cancel
session/close
```

> **一条边界划死 driver 的权力：driver 控制"时间"（何时、哪个 session 运行），不重新定义"已创建的 session"。**
> Driver can decide *when* and *which* session runs; it cannot redefine a session that already exists.

真需要再加 `session/fork`——**一开始不加**（同 §2.1、§7.3 的克制）。因为只能调合法 primitives，driver 永远**不能**改 session 的内容定义。这条要写成 API 表面就长不出的**显式黑名单**：

```
禁止的 driver 方法（永不提供）：
    session/setTools()      session/setSystemPrompt()   session/setModel()
    session/replaceHistory()  session/setMessages()     session/mutateComposition()
    provider/rewriteRequest()
```

想换 model / tools / system / authority？答案统一是 **create another session**。这与 §7"extension 只 propose，kernel append"、§9"`capability authority ⊆ session authority`"是**同一条不变量的控制面投影**：

> **Extension 能组合 kernel primitives，但不能打破 kernel invariants。**

四条必须写进 kernel 侧的硬约束：

- **续写 = append，不是 rewrite。** GoalDriver 的"继续"只能 append 一条续写事件再 step——和 §5.3 append-note 同一个合法路径，前缀不动，§0.1 / §1 缓存不变量**免费继承**。child session 各有独立子 ledger = 独立 cache scope（§2.1），不碰父 session 前缀。要表达"进度 43%"就 `append` 一条 message，绝不去 mutate system prompt（那会让 system block 每轮都变、炸掉稳定前缀——这正是 Pi `before_agent_start` 每轮改 system prompt *合法但危险*的地方，§19.5）。
- **换 composition = 换 session，绝不原地 mutate。** 一个 `plan(read-only) → implement(shell/edit) → review(read-only)` workflow 的正解是**三个各自 frozen composition 的 session**，而不是在一个 session 里反复 `setTools`。每个 session 的 `system / tools / skills / instructions / authority` 在 `session/create` 时一次决定、之后全冻结——这不是"动态改当前 agent"，是"创建另一个 immutable agent context"，各自独立 cache scope，对缓存极友好。
- **hidden state 可调度，model-visible state 只能 append。** driver 自己的隐藏状态（`iterations=7` / `phase=review`）随便存，只要它**只影响编排**（`if phase==review: 选 reviewer_session`）；一旦这个 state 要影响**模型看到什么**，就必须显式 `append("进入 review 阶段…")` 或 `session/create` 一个新 session。**Hidden driver state may control scheduling; model-visible driver state must enter through explicit append or session creation.** 这条顺带保住可复现性：replay 时模型看到的一切 = `session/create config + ledger + frozen composition` 的纯函数，没有 `before_provider_request` 那种事后偷改 payload 的黑洞。
- **budget / termination / cancellation 的最终权在 kernel。** driver 只 propose"继续还是停"；step 上限、token budget、cancellation（`loop.zig`，冻结面 §15.1）是 kernel invariant，driver 越不过——否则一个失控 driver 能把 session 拖进死循环烧 token。

### 19.3 这是 §7.3 预留的"第二个真实 runtime method"

§7.3 曾刻意**不**把 JSON-RPC envelope 泛化，理由是"等第二种 runtime 方法真出现再抽"。SessionDriver 就是那第二种：当前只有 `tool/call`，driver 带来 `driver/run`（或 `driver/start` + `driver/event`）。到这时再从 `ToolCallRequest` 提炼通用 `JsonRpcRequest { id, method, params_json }`，就是**有真实第二用例**，不是预设计——这**回头印证了 §7.3"先别泛化"的决定是对的**。

同时 SessionDriver 是第一个需要 **host callback（extension→kernel）** 的 Contribution：Tool 是被 kernel 调用（kernel→runtime，请求-响应一来一回），driver 反过来要**调进 kernel**（`session/create/step/…`）。§7.3 明说 v0.1 runtime"仍不做 host callbacks"——SessionDriver 正是将来把这条通道做出来的理由，同样遵守"有消费者才建"的纪律，在此之前只占位。

### 19.4 Agent 先不做成独立 Contribution

既然 Claude 有 `agents/`，直觉会想给 manifest 加 `contributes.agents[]`。**先不要**（同 §7.7 skill provider、§18 的克制）。一个 Agent 本质只是 `Session + instructions + model + capability composition`——它可以就是某个 SessionDriver extension 自带的**数据**（`agents/researcher.md` …），由 driver 自己 parse，再 `session/create({ instructions, model, skills, tools })`。等出现三个真实 consumer（Claude agent importer / OpenAI importer / Nulya 原生 agents）都要同一种 Agent 表示时，再抽 `AgentSpec / AgentRegistry`。**第二个 consumer 出现前不抽 abstraction**——这是全文反复锁定的品味。

于是"支持 Claude agents"这件事的正解是：告诉 Nulya → 它长一个 `claude-agents` extension，extension 内 scan `.claude/agents/*.md` → parse → `session/create` 起 child session。**kernel 不需要懂 Agent，只需要懂 Session。**

### 19.5 与非目标（§15.3）的连接，以及现实定位

§15.3 把 `WorkflowMiner` / 各种 orchestration"智能"列为**永不进 kernel 的 non-goal**——它们属于 kernel *之上*。SessionDriver 正是让这些 workflow **能以 extension 形式长在 kernel 之上**的那道 substrate 缝：`/goal`、plan mode、review workflow、swarm 全部变成 driver extension，而 kernel 只多出一个窄 Session Host API。做到这一点，Nulya 的 core 反而可以比 Pi / DeepSeek-TUI **更小**——它们把大量 orchestration 内建，或开一个巨大的 in-process callback API（且 extension 拥有完整系统权限）；Nulya 走"少量稳定 primitive + out-of-process 组合"，更符合本文全程的取舍。

**两种"灵活"要分清（Nulya 与 Pi 的架构分野）：**

```
Pi:     mutation power    — extension 直接改当前 harness：tools / system prompt / messages / provider payload / UI / session state
Nulya:  composition power — driver 编排稳定 primitives：Session A / Session B / Tool X / Skill Y / Evidence / Environment，每个 primitive 本身不可被篡改
```

> **Pi gives extensions mutation power. Nulya gives extensions composition power.**

Pi 的自由度更"强"（能改 kernel 原本的语义——运行时切 active tools、每轮改 system prompt、改 context messages、rewrite provider payload 都合法），代价是 cache stability / 可复现 / security 这些约束要靠 extension **自觉遵守**，core 无法对*任意* extension 保证稳定前缀。Nulya 选择"workflow 可以随便长，但改不了 kernel physics"——用组合自由度换取 kernel 能对*任意* driver 做出的保证。这不是能力弱，是把"什么可变"这件事收进 kernel。

> **诚实定位**：就"让 AI 自己写插件改变 harness 行为"而言，**今天** Pi > DeepSeek-TUI > 当前 Nulya。但差距只是这一道 seam——AgentSession 已是 state machine、extension 已 out-of-process，缺的就是 Session Host API + `driver/*` 方法。补上它，Nulya 不追功能数量也能表达同样的愿景，且控制面天然继承 §0.1 缓存不变量与 §9 authority 收窄——这是 Pi 的 in-process 全权限模型给不了的。

**规范例（写进 DESIGN 当尺子，抵抗 feature race）：**

```
Claude-style agents                          → extension（driver 自带 agent 数据，§19.4）
/goal（目标达成前不结束）                     → SessionDriver extension
plan mode                                    → SessionDriver extension
plan → review → 共识 → implement → review     → SessionDriver extension
loop until objective                         → SessionDriver extension
```

**Kernel physics（所有 Contribution 都在其上运行，改不了）** —— 这不是新规则，是 §0 / §7 / §9 / §15 应用到控制面的**同一套**，汇一处便于当尺子（权威定义仍在各自章节）：

```
1. Ledger 只能 append                          (§0.1, §3)
2. SessionComposition 不可变                     (§5.1, §7.4)
3. model-visible 状态只经 append 改变            (§7 硬约束, §19.2)
4. 换 composition 必须换 session / generation    (§19.2)
5. capability version 内容寻址、不可变            (§7.4)
6. authority 不隐式增长（⊆ session authority）    (§9)
7. cancellation 只有一个 kernel 定义的语义        (§15.1)
8. driver 只能调度 primitive，不能 rewrite 它     (§19.2)
```

Tool / Skill / SessionDriver / MCP adapter / Claude-agent importer / plan workflow / goal loop / swarm —— 全部只能在这套 physics 上**组合**。这才是 **Everything above the kernel is learnable**（§15）的确切含义：不是"extension 什么都能改"，而是"**extension 什么都能组合，物理规则改不了**"。

`[概念全定义；Session Host API + `driver/*` 方法 + host-callback 通道，待第一个真实 driver consumer（大概率 /goal）出现再写实]`
