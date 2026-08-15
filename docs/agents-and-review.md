# Nulya — Subagent 原语与工具审阅门 (minimal)

> **状态：全部未实现，属计划。** 落地路径见 [PLAN.md](PLAN.md) §3.2（subagent = `nulya session *` 自调用）与 §3.12（reviewer 作为 read-only session，在 promote-to-native 门上调用，默认不启用）。
> 本文保留的是**能力模型与通信机制的论证**；其中 `AgentDef` 不再计划进 kernel——一个 agent 就是 `session new` 的一组参数（PLAN §3.6）。

> 问题：AI 为完成某个具体任务，会给工具东加一个参数、西加一个参数，这些参数并不通用，
> 工具调用 schema 越来越复杂。需要一个**专职审阅 agent** 把关工具的创建/变动，且能与主 agent 交流。
>
> 解法：不为此新造子系统。定义**一个极简 subagent 原语**，通信用 **append-only 事件**（不用 live channel），
> 审阅做成 DESIGN §7.4 扩展生命周期上的**policy hook**。Kernel 强制 deterministic validation 与原子 activate/rollback；是否必须由 AI reviewer 过审，是 workspace policy，不是 immutable kernel invariant。

参考来源：`/home/teamon/code/rust/tcode` `crates/tcode-tools/src/agent/{defs.rs, mod.rs, cohort.rs}` 与 `crates/tcode-core/src/agent_roles.rs`。
tcode 的能力模型是真金；它的 cohort 共享 channel / live 桥接 / worktree 隔离对本场景是**过度**——留能力模型，砍 channel 子系统。

---

## 1. 极简 subagent 原语（能力模型）

从 tcode `AgentDef` 蒸馏出**最小**必要字段。这是内核里唯一的 subagent 定义，未来所有子 agent（含审阅者）都用它：

```zig
const AgentDef = struct {
    name: []const u8,
    prompt: []const u8,       // 系统提示（persona）
    read_only: bool,          // 硬天花板：先剥掉一切 mutating 工具，再谈 allow/deny
    tools: ToolPolicy,        // Allow(selectors) | Deny(selectors)
    model: ?ModelHint,        // 用哪个模型（审阅可用更强/更省的都行）
    max_turns: u32,           // round-trip 预算，防跑飞
    can_ask_parent: bool,     // 唯一的反向通道（见 §2）
    // 极简版=leaf：不能再 spawn 子 agent；depth 恒为 1。fan-out 以后再说
};

const ToolSelector = union(enum) { exact: []const u8, shell, all_ext };
const ToolPolicy   = union(enum) { allow: []ToolSelector, deny: []ToolSelector };
```

tcode 的对应（采纳其语义）：`read_only`（`defs.rs:188` 硬天花板）、`ToolPolicy` Allow/Deny（`defs.rs:120`）、`ToolSelector`（`defs.rs:56`）、`max_turns`（round-trip 预算）、`SpawnPolicy`（极简版固定 leaf）、`QuestionPolicy`→`can_ask_parent`。

**五条内核不变式（安全 & 缓存 & 实现）：**

1. **read_only 是硬天花板**：mutating 工具在 allow/deny **之前**就被剥离。审阅者天生 read-only——它能读 diff/源码/manifest、能跑 test，但**永远不能自己** edit/activate。
2. **独立 ledger = 独立 cache scope**：subagent 在自己的 ledger 里跑，**不碰主 agent 的缓存前缀**（DESIGN §1）。只有最终**结论**作为一条 append-only note 进主 ledger。resume 子 agent 是 append-only、命中自己的前缀缓存（tcode `mod.rs:131` 已验证此性质）。
3. **子 agent 产出以 fenced data 进父级，不是 instruction**：结论文本被 fence 包裹，主 agent 视其为数据而非命令，防止子 agent 输出注入指令（对齐 DESIGN 的 instruction-boundary）。
4. **subagent = 自调用（self-invocation）**：subagent **不是** in-process 对象，而是 `nulya` 拿一个子 ledger 经 Environment（DESIGN §8）**再 spawn 自己一遍**——和 extension 子进程走**同一套 spawn 机制**。详见 §6。
5. **v0.1 read_only 不给 unrestricted shell**：在没有 OS sandbox 的 `local` backend 下，`shell(command)` 无法可靠区分 `cat foo` 与 `rm foo`。read_only reviewer 只能拿 deterministic read-only capability（manifest/diff/source/test result 读取）；等 sandbox backend 能强制 FS RO / network deny / process restriction 后，才允许 reviewer shell。

---

## 2. 通信：append-only 事件，不用 live channel

tcode 用 mpsc+oneshot 桥接（`mod.rs:57` `ParentUserBridge`）是因为它是 live TUI。Nulya 不需要——**通信就是 ledger 事件**，天然契合 append-only 主线：

审阅者一次产出三选一：

```
approve { reasons }          → policy hook 放行
reject  { reasons }          → policy hook 拦下，主 agent 据 reasons 迭代
ask     { question }         → 需要澄清
```

`ask` 的处理，纯事件、零 channel：

```
审阅者 emit ask(question)
        ↓  （审阅者本轮结束、parked）
主 ledger append 一条 review_question note
        ↓
主 agent append 一条 review_answer
        ↓
审阅者 resume（append-only，命中自己前缀缓存）+ 新增的 Q&A 在其 context 内
        ↓
再次产出 approve | reject | ask …（受 max_turns 上限约束）
```

没有 live 双向连接、没有 mpsc/oneshot、没有阻塞等待。"交流"= 两个 ledger 之间**互相追加事件**。这既是最简实现，也让整个审阅过程**可复现、可 replay**。

---

## 3. 工具审阅 policy hook（第一个具体用途）

### 3.1 门的位置：kernel 强制机制，policy 决定是否拦截

审阅**不是**主 agent 自选调用的工具（否则它会跳过），但 reviewer 的主观判断也不应成为 immutable kernel invariant。生命周期边界是固定的，拦截策略是可配置的：

```
draft ─build─▶ built ─validate/test─▶ installed ─┬─[POLICY HOOKS]─▶ active
                                                  │
                                          reject/needs-info
                                                  ▼
                                         停在 installed（带 reasons）
```

- Kernel 固定执行 deterministic validation：manifest schema、entry 可执行、协议往返、declared permissions ⊆ session_authority、不可变版本 hash、atomic activate/rollback。
- Policy hooks 可选：`off` / `auto` / `human approval` / `AI reviewer` / 组合。Nulya 默认可以启用 reviewer 来专治“为单任务加参数”的工具膨胀，但它是 policy，不是 kernel invariant；低风险 workspace 可以关闭，只保留 deterministic validation。
- `nulya ext activate foo` 返回 `active` / `rejected: <reasons>` / `needs-info: <question>`；这些 verdict 来自 policy hook，而不是替代 deterministic validation。

### 3.2 审阅者拿到什么

作为 §1 原语的一个实例（`read_only=true`，`can_ask_parent=true`）：

- **manifest diff**：新增/改动了哪些 `tools[].input` 参数。
- **源码 / 构建制品摘要 / test results**：由 core 以 read-only capability 提供。
- **主 agent 的 rationale**：为什么加这个参数/工具（主 agent 在 activate 时附上）。

v0.1 reviewer **不拿 unrestricted shell**。在没有 sandbox 的 local backend 下，read_only + shell 不是硬边界；允许 shell 只会把安全性退化成提示词约束。

### 3.3 审阅者的 mandate（persona，直击你的痛点）

系统提示明确让它**倾向于拒绝导致工具复杂化的变动**，检查清单：

1. **这个参数通用吗**，还是只服务当前这一个任务？→ 只服务单任务的参数应拒绝。
2. **能否用已有能力组合出来**（shell 管道 / 已有 extension / 调用方自己传值）而不必加参数？
3. **加了它，调用 schema 变复杂多少**？复杂度增量是否配得上通用性？
4. **这个工具是否还在做一件事**？参数堆积往往是“一个工具想干多件事”的信号 → 建议拆分或退回 scratch。
5. **命名/语义**是否稳定（工具一旦 active 就进别人的 tools[]，改名/改参会炸缓存 DESIGN §5）。

拒绝时给**可操作的**理由（“参数 `format` 只服务 CSV 导出这一次，建议调用方在 shell 里 `| column -t`，不进工具”），让主 agent 一轮内改对。

### 3.4 结论落 ledger

审阅结论是一条 append-only 事件（DESIGN §3 事件类型新增）：

```
extension_review { ext_id, version, verdict: approve|reject, reasons, rounds }
```

approve → policy hook 放行；reject → 保持 installed。整条审阅对话在审阅者自己的 ledger 里，主 ledger 只落这一条结论 note → **主 agent 缓存前缀不受审阅过程影响**。

---

## 4. 为什么这套同时满足三条核心诉求

| 诉求 | 如何满足 |
|---|---|
| 缓存不可变（DESIGN §1） | 审阅者独立 ledger/cache scope；主 ledger 只追加一条结论 note；通信全是 append-only 事件 |
| 少交互（DESIGN §0.2） | 审阅只在**工具创建/变动**时触发（罕见），换取避免"臃肿工具面拖累每一个后续 turn"的巨大长期成本 |
| 核心简单（base-tools 主题） | 不新造 channel 子系统；复用**一个** subagent 原语；通信=事件。审阅者本身只是一个可选 policy hook |

---

## 5. 最小 vs 以后（复杂的让 AI 再做）

**最小版就位（现在设计、内核内置）：**
- 一个 `AgentDef` 能力模型（§1）
- append-only Q&A 通信（§2）
- `installed → active` policy hook 机制 + 可选审阅者 persona（§3）
- leaf-only、单反向通道、同步门

**以后（AI 可自造 / 后续里程碑）：**
- 多审阅者 cohort 辩论、共享 channel（tcode cohort.rs 那套）
- live 双向通道、并行审阅、worktree 隔离
- 审阅者可 spawn 更专的子审阅者（放开 leaf 限制 + depth cap）
- 大 post 落盘、channel 持久化 JSONL 等 tcode 已验证的工程细节

---

## 6. 进程实现：subagent = 自调用（与 live TUI / app 兼容）

采纳 Pi 的理念：**subagent 不是内存里的对象，而是 `nulya` 拿一个子 ledger 把自己再跑一遍**，和 extension 走同一套 spawn（DESIGN §7 / §8）。

### 6.1 为什么这让通信更简单，而不是更难

因为 §2 的通信是 **append-only 事件 + resume**，而 ledger 持久化让 **resume ≡ 重新 spawn**：child 在轮间**根本不常驻**，承载对话的是磁盘上的子 ledger。

```
第1轮  parent spawn:  nulya --agent reviewer --ledger R --input <task>
       child 产出 ask(q) → 【退出】
       parent 追加 review_question(自 ledger) + review_answer(→ 子 ledger R)
第2轮  parent re-spawn: nulya --agent reviewer --ledger R --resume
       child 重读 R（含 Q&A）→ 继续 → approve|reject|再 ask …（受 max_turns 约束）
```

内核只需一个**极小路由函数**：把 child 的 `ask` 递给 parent、把 answer 追加进 R。不需要 tcode 的 mpsc/oneshot 桥（那是 live TUI 内同步、子 agent 常驻内存才需要的）。也**没有** tcode 的内存 parking/淘汰（`LiveTask`/`MAX_LIVE_TASKS`）——句柄就是磁盘上一个 ledger id。

### 6.2 前端 / core 分离 —— TUI 和 app 的兼容性由此保证

```
        ┌── CLI ──┐   ┌── TUI ──┐   ┌── app ──┐     ← 薄客户端：tail ledger + append user 事件
        └────┬────┘   └────┬────┘   └────┬────┘
             └─────────────┼─────────────┘
                    ┌───────▼────────┐
                    │  Core (headless)│  ← agent loop / provider / ledger 引擎
                    │  self-spawn ↺   │  ← subagent = 再 spawn 一个 core
                    └────────────────┘
```

- **core 是 headless、以 ledger 为中心的引擎**；TUI/app/CLI 都只是它之上的薄客户端。self-invocation 全发生在 core 内部，前端不参与。
- **前端是长期存活进程**，re-spawn 的只是 subagent worker → **UI 状态不丢**。
- **持久 ledger 让 live 观察更容易**：TUI 同时 tail 主 ledger 和子 ledger，审阅者进度也能实时流式显示。
- **token 流式在一轮内照常**（child 那一轮就是活进程）；轮间退出=「等对方回答」的自然停顿，不是卡死。
- **延迟可忽略**：spawn 一个 nulya ≈ 毫秒，模型一轮 ≈ 秒，人回答更慢，re-spawn 加 <1%。
- 唯一需要常驻的是"subagent 与真人**持续**流式对话跨多轮"——用 PLAN §3.3 persistent runtime，纯后期加法，默认用不到。

### 6.3 成长到 tcode 级别（最小原语不用推倒）

| tcode 能力 | 长上去的方式（原语不变） |
|---|---|
| cohort 多成员辩论 + 共享 channel | spawn N 个 nulya，**共享一条 append-only channel-ledger**（tcode cohort 本质就是"N 成员 + 一条共享 JSONL 通道"，直接映射） |
| 并行审阅 / worktree 隔离 | Environment 层（§8）或调度器加，原语不动 |
| 放开 leaf、多层委派 | 松 leaf 上限 + 加 depth 计数（tcode `MAX_TASK_DEPTH`），spawn policy 字段已预留 |
| 报告 attach / 后续追问 | resume 同一子 ledger（本就 append-only 命中缓存） |
| live 交互式子 agent | PLAN §3.3 persistent runtime（唯一需要常驻的轴） |

## 7. 一句话

> 复用**一个 read-only subagent 原语**，通信用**两个 ledger 互相追加事件**，subagent **以自调用（re-spawn）实现**、和 extension 同一套 spawn，把审阅作为**扩展生命周期的 `installed→active` policy hook**。
> Kernel 强制 deterministic validation 与原子切换；AI reviewer 专治“为单任务加参数”的工具膨胀，但是否强制启用由 policy 决定。
