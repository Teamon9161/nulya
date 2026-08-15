# Nulya — 计划（方向、路线图、未实现的设计）

> **这份文档描述将来。** 每一项都是尚未落地的设计或路线；落地后（代码 + e2e）搬进 [DESIGN.md](DESIGN.md)，这里删掉对应段落。
> DESIGN 是地板，PLAN 站在地板上：这里任何东西都不能违反 [CLAUDE.md](../CLAUDE.md) 的八条 physics。
> 每节末尾标 `[写实]`（有近期消费者，按路线图落地）/ `[占位]`（概念定死，等真实 consumer 出现再写实）。

---

## 0. 总方向（2026-08 修正）

一句话：**把 subagent、driver、evolution session、resume / fork / compaction 全部收敛到同一个机制——durable ledger 文件 + `nulya session *` CLI + shell 作为万能胶水。**

```
kernel  = ledger 文件格式 + PromptIR 投影 + 一次 step + 工具执行 + composition 冻结 + provider
对外    = nulya session * | nulya ext * | nulya skill *
其余    = 脚本 + SKILL.md（driver / evolution / review gate / agents 导入 …），AI 可读可改
```

这比之前的计划**更小**（不需要 host-callback 通道、`driver/*` 方法、Middleware、in-process session lifecycle），也**更可进化**（可进化层全在 AI 的原生媒介里）。缓存不变量按 session 文件天然成立。

产品原则不变：**Nulya 不参与内建 Agent 功能的军备竞赛。** 新的 harness 行为应尽可能由 agent 基于稳定 kernel primitives 自行实现，而不是改 kernel。Claude 明天出 agents，不去追着改 Nulya——让 Nulya 自己长一个 extension 去读现有 agent 定义。

### 0.1 相对旧计划的七处修正

| # | 旧计划 | 现在 | 为什么 |
|---|---|---|---|
| 1 | ledger 落盘 / resume 属"等第二个前端出现再做" | **排第一** | subagent=自调用、resume≡re-spawn、fork、evolution 读轨迹、crash recovery 全站在"ledger 在磁盘上"的假设上；usage journal 已 durable 而对话不 durable 是倒挂 |
| 2 | generation = 事件投影，compaction 是一种事件 | **generation == ledger 文件**；compaction / fork = 新文件 + parent 指针 | 单文件永远单 generation、只 append，前缀不变量成了文件系统性质；`currentGeneration()` 删掉；fork 免费 |
| 3 | extension 制造路径 = Zig 源码 → 内嵌工具链编译 | **脚本 extension 默认**（`run.sh` / `run.ps1` / `run.py` 任意可执行）；Zig 是**实测需要时**的优化 | 制造循环发生在 AI 所在机器，摩擦决定尝试次数；多数有价值能力在 Zig 里也只是 wrap 系统命令。与"先测量再持久化"同一纪律 |
| 4 | SessionDriver = out-of-process JSON-RPC + host-callback 通道 + `driver/*` 方法 | **driver = 脚本 + `nulya session new\|append\|step\|events\|cancel`** | 黑名单自动成立（CLI 没那些动词）；host callback / 分帧 / 背压全消失；`/goal` 是 20 行 shell |
| 5 | Hook 三类：Provider / Middleware / Observer | **删 Middleware**，只留 Observer + propose→append | "拦截、修改"与"extension 永不 rewrite model-visible 内容"矛盾且未定义 |
| 6 | AI reviewer 倾向默认开，门在 activate | **默认关**；门放在 **promote-to-native** | existence 几乎免费（一个目录）；promote 才有真实成本（cache prefix + 每 session token）。高门槛抑制尝试、诱发 theater |
| 7 | Tool 是演化旗舰，Skill "不竞争不统计" | 优先级：**Skill / notes > 脚本 tool > native tool > driver**；加 `session_outcome` 事件 | 现在模型最能复利的自演化是知识与方法；driver 演化来源本就是"重复的人类 correction 结晶"；outcome 是评价 Skill / Prompt 的唯一 ground truth |

---

## 1. 路线图

按可落地性与依赖排序。每个 M 写：目标 / 要做 / 验收 / 进 DESIGN 的条件。

### M1 · Durable ledger（§3.1）✅ 已落地 → DESIGN §3.4
- 目标：一 session 一个 JSONL 文件；`resume` = 重读文件；CLI 子进程可投递 note。
- 已做：事件加 `seq`；文件格式 + header（冻结 composition）；`Ledger.createDurable/openDurable/append` 落盘；`session.prepareStep` 的每步扫盘对账改为排干 CLI 投进 `<id>.inbox` 的 `capability_note`；crash 后 `completeInterruptedToolBatch` 从文件恢复。
- 验收（`tests/e2e.zig` 三例全绿）：进程 A 跑两步退出、进程 B `resume` 后 PromptIR 与 A 逐块相等；独立 CLI `ext activate` 投的 note 下一步被读到；磁盘残尾 assistant-with-calls 在 resume 时被修复。

### M2 · `nulya session *` + 脚本 extension（§3.2、§3.3）
- 目标：session 可被任何进程驱动；extension 制造无需编译。
- **M2a ✅ 已落地 → DESIGN §14：** `session new|append|step|events|cancel`（`step --max-steps N` 由 kernel 夹到 `session.max_steps_ceiling`）；`main.zig` demo 已改走 durable session 路径。e2e：shell 脚本 driver 完成 `/goal` 循环、`--max-steps` 被 kernel 强制。review 后收紧（DESIGN §3.4/§4/§14）：只有 `step` 写主文件——`append` 走 inbox、`cancel` 是 `<id>.cancel` 标记且由 kernel 在 step 边界消费（mid-run 也能停）、`events` 只读 tail；`close` 因无语义删除；`persist` 加第二写者守卫。
- **M2b ✅ 已落地 → DESIGN §7.1/§7.4：** `runtime.entry` 前缀区分编译/脚本，脚本不编译、version = hash(snapshot)（不含 compiler）；`nulya ext init --script`；`ext run --arg k=v`。e2e：`run.ps1`/`run.sh` extension 走完 init → build(seal) → activate → run → 晋升为 native 并经 interpreter 执行；version 不含 compiler identity、rebuild 稳定。

### M3 · `nulya src` + 文档（§3.10）
- 要做：内嵌 `src/**`（剥 `test` 块或拆 `*_test.zig`），`nulya src [path]` 打印；`nulya ext api` 变成它的特例；ARCHITECTURE 内容并入 CLAUDE.md 模块表（已做）。
- 验收：`nulya src prompt.zig` 输出与仓库一致。

### M4 · Anthropic provider + 真实 cache 验证（§3.9）
- 要做：Messages API，`cache_control` 放在 tools 后 / system 后 / 最后稳定块后；读 `cache_read_input_tokens`。
- 验收：integration test（需 key，可跳过）——连续三步 `cache_read` 单调不减且 ≥ 前一步 input 的 90%。

### M5 · `session_outcome` + 第一个 evolution SKILL.md（§3.7）
- 要做：可选事件 `session_outcome{ verdict, note? }`（前端 / 用户在 session 尾 append）；`skills/evolution/SKILL.md`（读 ledger 目录 + usage journal → 找重复 / regression / 值得沉淀 → 提案）；用户手动 `nulya session new --skill evolution`。
- 验收：跑一次真实 evolution session，产出至少一条"别造"的 null result 与一条提案。

### M6 · Version-aware evidence（§3.5，原 v0.2 Phase A–E）
- A usage fact 加可空 `version`（journal v1→v2 兼容读）+ `VersionStats` 投影 → B `VersionCreatedFact{parent, reason}` → C Seal → Verify(sealed) 门 → D `EvaluationEvidence` → E policy 比较 implementation、建议 rollback。
- 进 DESIGN：每个 phase 单独进。

### M7 · Authority / sandbox（§3.8）
- `sandbox` backend（Linux landlock+seccomp / macOS sandbox-exec / Windows AppContainer 或容器）；`manifest.permissions` 从声明升级为 OS 强制边界。

### M8 · Ecosystem adapters（§3.11）
- MCP client 作为 extension（tools 同构进 ToolSetSnapshot）；ACP 作为前端 transport；TUI。作为输入 / 输出适配器，不是主架构。

**`M1 → M2` 是分水岭**：做到 M2，"subagent = 自调用"（§3.2）、agents-and-review §6 的 re-spawn 通信、§3.6 的 driver、§3.7 的 evolution session 全部有了 substrate，之后都是脚本。

---

## 2. 跨路线图的纪律

- **统一生命周期，不统一数据类型。** Tool 进完整演化闭环；Skill 只需 discovery；Prompt 更像 configuration。不为 API 对称造 `ToolStats / SkillStats / PromptStats`。
- **第二个 consumer 出现前不抽 abstraction。**（SkillProvider、JsonRpcRequest、AgentSpec、Evidence union framework 全是这条）
- **概念全定义，有消费者才写实。** 让 schema 稳定，但不提前造框架。
- **Facts are durable; policy is replaceable。** 失败也是 fact。
- **这是 substrate 还是 intelligence？** 是 intelligence 就放 kernel 之上。

---

## 3. 各主题设计

### 3.1 Durable ledger；generation == 文件 `[已落地 · M1 → DESIGN §3.4]`

✅ **已实现，现状见 [DESIGN §3.4](DESIGN.md)。** 落地形态与原计划一致：`.nulya/sessions/<id>.jsonl`，header 冻结 composition（active 版本 + native tool 选择）+ 每行 `{"seq":n,…}` 事件；`Ledger.createDurable/openDurable/append`，内存 `init` 版保留给测试；`prompt.currentGeneration()` 删除（generation == 文件）；usage journal 仍独立。`session_outcome` 事件属 M5。

**两处实测定的决策（已定，记进 DESIGN §3.4）：**
- **并发 append = 单写者 + inbox 目录**（不是 O_APPEND）。session 文件只有 session 进程一个写者；任何其他进程的事件（CLI 的 `capability_note`、driver 的 `session append`）投进 `<id>.inbox/`，session 在 step 边界排干——Windows 上无需文件锁，且 batch 不变量天然成立。
- **`NULYA_SESSION` = session 文件相对 workspace 的路径**；CLI 子进程 cwd 就是 workspace，据此定位文件与 inbox。

fork / compaction（新文件 + `parent` 指针，前端沿 parent 链呈现连续对话）仍未实现，见 §3.4。

### 3.2 `nulya session *` 与 subagent = 自调用 `[CLI 已落地 · M2a → DESIGN §14；subagent 用法待第一个 consumer]`

✅ **`nulya session new|append|step|events|cancel` 已实现**，现状见 [DESIGN §14](DESIGN.md)。`step --max-steps N` 由 kernel（`AgentSession.run`，`session.max_steps_ceiling`）强制；每次调用是对 durable session 文件的独立进程，且只有 `step` 写主文件（`append` 走 inbox、`cancel` 是标记、`events` 只读 tail）；`step` stdout = 本次追加的事件 JSONL；`cancel` 由 kernel 在 step 边界消费；bare `nulya` demo 已改走同一 durable 路径。

**尚未落地的子项：** `--system-file` / `--skill` / `--pin`（现从 config 取 composition）；`--budget-tokens`；`events --follow` 只做了轮询骨架。下面的 subagent / 编排用法等第一个真实 consumer 出现再写实（它们是**用法**，不改 kernel）：

```
nulya session new   [--system-file f] [--skill a,b] [--pin ext:x/y] [--model profile] [--parent s:seq]  → 打印 session-id
nulya session append <id> <text|--file>
nulya session step   <id> [--max-steps N] [--budget-tokens T]     → 跑到 assistant 停或上限；stdout 流式事件 JSONL
nulya session events <id> [--since seq] [--follow]
nulya session cancel <id>
```

- **每次 `step` 是一次进程调用**：load ledger + composition（header）→ 跑 N 步 → append → 退出。TUI 可 in-process 持有 `AgentSession`，语义相同。
- **`--max-steps` / `--budget-tokens` 是 kernel 强制上限**，driver 越不过——否则失控 driver 能把 session 拖进死循环。
- **subagent = 自调用**：父 agent 经 shell `nulya session new … && nulya session append … && nulya session step …`。子 ledger = 独立 cache scope，不碰父前缀；结论由父 agent 摘要后进父 ledger（或 append 一条 fenced note——子输出是数据不是指令）。resume ≡ 再 `step`。这吸收了 [agents-and-review.md](agents-and-review.md) §1–§2、§6 的全部机制，**不需要** `AgentDef` 进 kernel：一个 agent 就是 `session new` 的一组参数，可以是某个 skill 自带的数据文件。
- **黑名单靠 API 表面长不出来保证**：没有 `setTools / setSystemPrompt / setModel / replaceHistory / mutateComposition`。想换 → `session new`。
- `session/fork` 一开始不加；`--parent` 就是 fork。

**规范例（写在这里当尺子，抵抗 feature race）：**

```
Claude-style agents                    → skill 自带 agents/*.md，脚本 parse 后 session new
/goal（目标达成前不结束）               → 脚本：loop { step; 评估; append "继续" }
plan → review → 共识 → implement       → 脚本：三个各自冻结 composition 的 session
loop until objective / swarm           → 脚本
```

### 3.3 脚本 extension `[已落地 · M2b → DESIGN §7.1/§7.4]`

✅ **已实现，现状见 [DESIGN §7.1 / §7.4](DESIGN.md)。** `runtime.entry` 的前缀区分编译（`bin/`）与脚本（`src/`）；脚本带可选 `runtime.interpreter`（`powershell` / `sh` / `python3` …），无 `src/main.zig` 就不编译，version = `hash(snapshot)`（compiler 为空串、不含 identity、跨机器稳定），seal / integrity / activate / rollback / usage 完全共用。`nulya ext init --script` 按宿主生成骨架；`nulya ext run --arg k=v` 按 manifest schema 类型生成 JSON（`'<json>'` 仍可用）。

- 能力谱：**shell 一行 → 脚本 extension（`ext init --script`）→（实测有需要）native Zig** 成立。
- persistent runtime（warm worker 池、LRU、TTL）仍是**先测量再做**的后期加法。

### 3.4 Compaction = 开新 ledger 文件 `[写实 · M1 后]`

- 触发是 policy（`compaction.max_input_tokens` 等，config 已有键），不是 physics。
- 动作：由 agent 或 kernel 生成结构化 summary（保留近期上下文、文件操作记录）→ `session new --parent <id>:<seq>` 新文件，summary 为首条事件 → 前端切到新文件。旧文件不动。
- 边界尽量放自然断点（一个 task 完成后），让它罕见。

### 3.5 能力演化 evidence（原 v0.2 Phase A–E）`[写实 · M6]`

**3.5.1 双身份。** 每次 invocation 同时携带 `logical_tool_id`（`ext:web.search/web_search`，这个能力值不值得保留 / 晋升）与 `implementation`（`v-a83f…` | null，这版实现是否比上版好）。builtin 与旧历史 `null`。

**Identity rule（authoring 规则，非 kernel 强制）：** 同一 stable id 声明自己属于同一 logical contract。`web_search(query)` v1→v4 实现变、id 不变；变成 `database_query(sql)` 就该是新 id。kernel 只强制 identity 的语法；"没偷换语义"由 Verify / review 保证。

**3.5.2 Version-aware evidence（A）。** usage fact 加可空 `version`（`v:2`）。**reader 同时接受 v1 + v2**：v1 → `version = null`（过去不知道就诚实标 unknown，不丢历史）。两个投影喂两条状态轴：`LogicalToolStats`（吃全部历史 → promotion）、`VersionStats`（只吃 version-known → activation / rollback）。`ToolStats` 名字与语义不变。

**3.5.3 Lineage（B）。** **provenance 绝不进 version hash**（否则同源码因两次不同 reason 变两个 version）。独立 fact：`VersionCreatedFact{ version, parent?, created_by, reason? }`。单亲，v0.x 不做 DAG。

**3.5.4 Verify（C）。** 生命周期显式化，且 **Verify 在 Seal 之后**（TOCTOU：先冻结"要测的是什么"再测）：

```
Scratch → Build → Validate → Seal → Verify(sealed) → Activate → Observe → Retain / Improve / Rollback
```

- Validate = deterministic（manifest / 协议 / integrity / permission ⊆ authority，已是 kernel 不变量）；Verify = 跑 package 自带 `tests/` / `evals/`，证明能力符合自己声称的行为。初版：manifest 声明测试入口 + `nulya ext test <id>`。
- Verify 失败不删 version：标 `sealed but unverified`，留下"AI 曾造过一个失败版本"的审计证据。
- **验证套件随版本冻结**（进 snapshot）；大体量 golden 输入数据可留在外面。
- 门通过 ≠ 正确，只是"没有明显坏"。对模型和用户都说清。

**3.5.5 EvaluationEvidence（D）。** `ok=true` 只说明跑通了，不说明帮到了任务。分两层：`InvocationFact{tool_id, version, ok}`（客观）与 `EvaluationEvidence{tool_id, version, source, at, passed|score}`（**某 judge 的判断的 durable 记录**，不是 utility 的事实）。多 evaluator 冲突全合法、都留证；policy 去解释。kernel 存 evidence，绝不定义 reward。

**3.5.6 Policy 比较（E）。** 用 VersionStats + EvaluationEvidence 检测 v2 regression → recommend / perform rollback。真正的 self-improvement 起点。

`A → C` 是分水岭：AI 造出来 → exact artifact immutable → exact artifact 自证 → 观测的是 exact artifact 的真实使用。

### 3.6 SessionDriver 作为脚本 `[写实 · M2 后，第一个 consumer = /goal]`

> **Kernel 负责 session 怎么正确运行；driver 负责 session 为什么、什么时候、以什么顺序运行。**

Kernel 自带隐式 DefaultDriver：`user message → step → (有 tool call? 再 step : 结束)`。driver 把"结束还是继续"变成可替换的脚本，**完全不改 AgentSession**。

四条 kernel 侧硬约束（都是 physics 在控制面的投影）：

1. **续写 = append，不是 rewrite。** 要表达"进度 43%"就 append 一条 message，绝不动 system prompt。
2. **换 composition = 换 session。** `plan(read-only) → implement(shell/edit) → review(read-only)` = 三个各自冻结的 session。
3. **hidden state 可调度，model-visible state 只能 append。** driver 自己的 `iterations=7` 随便存；一旦要影响模型看到什么，必须显式 append 或 `session new`。
4. **budget / termination / cancellation 最终权在 kernel。** driver 只 propose；`--max-steps` 越不过。

**两种"灵活"要分清：** Pi 给 extension **mutation power**（改 tools / system prompt / messages / provider payload），代价是 cache / 可复现 / security 靠 extension 自觉；Nulya 给 **composition power**（编排 Session A / B / Tool X / Skill Y，每个 primitive 不可篡改）。"workflow 可以随便长，但改不了 kernel physics"。

Agent 不做成独立 Contribution：一个 Agent = `session new` 的参数集，可以是 skill 自带的数据文件。等三个真实 consumer 都要同一种表示再抽 `AgentSpec`。

### 3.7 慢速回路：Evolution Session `[M5 起第一档；整体占位]`

**3.7.1 能改 ≠ 有动机改。** 干活的 agent 的 reward 是"完成当前任务"，造工具的成本落在当前 session、收益归 future sessions；只要 shell 够用，局部最优就是"别造"。这不是模型不聪明，是目标结构决定的；靠 prompt 喊"记得改进自己"只是掩盖。

**3.7.2 两个时间尺度。**

```
FAST LOOP   User → Agent → tool/shell → Result        reward: 把现在这件事做完
                └─ evidence（invocation / version / evaluation / episode / outcome）
SLOW LOOP   Evolution Session：读 evidence + 失败 + 成本 + 反馈 → 找「什么反复发生 / 什么贵 / 什么常失败 / 什么值得沉淀」
                → propose: 新 Skill 条目 | 脚本 Tool | Tool v2 | Driver v2
                └─ verify / scoped trial → future sessions
```

Evolution Session **不是新的一等对象**：就是 `nulya session new --skill evolution` 起的一个普通 session，composition 换成"evidence 只读 + manufacture primitives"，instructions 换成"寻找值得沉淀的改进"。kernel 不需要懂"进化"，只需要懂 session。

**3.7.3 动机问题没被解决，只是搬家了。** Evolution Session 同样看不到未来；它被奖励的是"产出一个看起来合理的提案"，于是系统性偏向"找到了点什么"。最有价值的输出恰恰是 null result（"这 5 次表面相似其实是三件不同的事，别造"）——被"找改进"驱动的 session 最不愿说这句。放任 → **evolution theater**：源源不断没人用的 Tool 流水线。

**3.7.4 真正合环的是可证伪 + 负面证据 durable。**

1. 提案是**事后被证伪**的，不是当下被证明的。`VersionCreatedFact` 存在而其后无 `InvocationFact` = "manufactured but never invoked"，可派生负面信号，不需新机制。
2. **失败也是 fact。** "造出来 20 个 session 无人调用"、"trial 输给 baseline"必须落 evidence，否则下一轮重提同一个坏主意。
3. **slow loop 自己也在被告席上。** 它的提案走与普通 Tool 完全相同的 Seal → Verify → trial → rollback。

> **Kernel 不提改进，也不评判改进的好坏；它只保证改进提得出、验得了、比得了、退得回——包括退回 slow loop 自己提的那些。**

**3.7.5 fast loop 的角色 = 廉价面包屑。** 不让干活的 agent 造 Tool（动机陷阱），但让它顺手记一句"这一步我绕了一下 / 这类事做过好几次"。**形态：就是用 `edit` 改一个 notes / skill 文件**——不需要新 fact 类型，零 kernel。这与 non-goal `WorkflowMiner` 的区别：面包屑是 agent 自己的判断被廉价 emit；WorkflowMiner 是 kernel 里的启发式。

**3.7.6 `session_outcome`：ground truth。** 没有它，Skill / Prompt 的间接评价没有数据源。极简可选事件，前端 / 用户在 session 尾 append 一个 verdict（+ 一句话）。composition 冻结且记在 header，"有 skill X 的 session vs 没有的"就是可派生投影。

**3.7.7 统一生命周期，不统一评价方式。**

| | Identity | Verify | Evidence 单位 | 评价 |
|---|---|---|---|---|
| Tool | stable tool id | unit / contract test | invocation | deterministic test 起步，可较激进 |
| Driver（脚本） | stable driver id | workflow eval | **episode**（整个任务：outcome / cost / tokens / turns / retries） | 像实验，须保守 |
| Skill / Prompt | stable id | — | **仅间接**：采用它的 session 的 outcome | 不竞争、不统计 |

Driver 演化比 Tool 保守，因为**归因难**（任务难度 / model / seed 全在漂）与 **blast radius 大**（坏 Tool 让搜索差一点；坏 Driver 报废整个流程）。默认 driver candidate **不自动替换全局 DefaultDriver**，只在 scoped trial 积累 episode。benchmark suite 本身会被 Goodhart、会腐坏，需要和 capability 一样的 version + provenance。

**3.7.8 触发、递归、地板。** 三档触发，每档 threshold 是 policy：① 用户 `nulya session new --skill evolution`（最先）② 主 driver 任务结束时 `if enough new evidence` ③ 每 N 个 episode。Evolution skill 自己也可演化（`evolution v1 → v2`，复用同一套 candidate → verify → trial → rollback）。**递归的地板 = 八条 physics 不可自改**——正是这块不可自改的地板让上面一切可以放心试错。Driver 演化的真实来源多半是**重复的人类 correction 结晶**（"先写 plan""找 reviewer 看"连说十次），不是凭空花样。

### 3.8 Authority / sandbox `[占位 · M7]`

- `sandbox` backend 上线后 `manifest.permissions` 才被 OS 强制，从"声明"升级为"边界"。
- 不变量：**capability 绝不因被生成或被晋升而自动获得 authority**；始终 `capability authority ⊆ session authority`。
- 与 config 项目层"只能收窄"是同一不变量的两面：checkout 一个 repo 不该能拓宽机器权限。
- read-only subagent（reviewer）在 sandbox 之前不给 unrestricted shell（`local` 下无法区分 `cat` 与 `rm`）。

### 3.9 Provider：Anthropic + cache breakpoints `[写实 · M4]`

- Anthropic Messages API：`cache_control` 放 tools 后 / system 后 / 最后稳定块后（append-only 让"最后"持续前移）；`ProviderCapabilities.explicit_cache_breakpoints = true`；读 `cache_read_input_tokens` / `cache_creation_input_tokens`。
- deferred tools 等 provider-specific 优化允许，但不能破坏 PromptIR 块前缀不变量。
- ProviderContribution（extension 供 provider）：在 loop 上游、与下游 Tool 不同构，机制待定，只占位。

### 3.10 `nulya src` 与文档 `[写实 · M3]`

- 内嵌 `src/**`（已内嵌 50–90MB 工具链，200KB 源码不算什么），`nulya src [path]` 打印。AI 读真实代码 = 零 API 漂移；`nulya ext api` 成为特例。
- 入口是 CLAUDE.md 的模块表，不是让 AI 通读文档。
- 测试占源码近半：拆 `*_test.zig` 或 `nulya src` 默认剥 `test` 块。

### 3.11 前端 / ACP / MCP `[占位 · M8]`

- 前端（CLI 交互 / TUI / app / ACP）都是 core 之上的薄客户端：tail ledger 文件 + append user 事件。**前端是长期进程，re-spawn 的只是 worker，UI 状态不丢。**
- ACP：`session/new|prompt|cancel` 直接翻译成 `nulya session *`。
- MCP client：一个 extension，把 MCP tools 适配成 `tool.Tool` 进 ToolSetSnapshot（同构）。
- 唯一需要常驻进程的是"子 agent 与真人持续流式对话跨多轮"——persistent mode，纯后期加法。

### 3.12 Policy hooks / reviewer `[占位]`

[agents-and-review.md](agents-and-review.md) 的审阅门设计保留其**能力模型**（read_only 硬天花板、ToolPolicy allow/deny、max_turns、结论以 fenced data 进父 ledger），但实现方式按 §3.2：reviewer = `session new --system-file reviewer.md --pin …` 的一个 read-only session，由 `nulya ext promote`（M6 后）或 evolution 脚本在 **promote-to-native** 门上调用；`policy.hook` 档位 `off / auto / human_approval / ai_reviewer` 决定是否调用。默认 `auto`（不调 reviewer）。不进 kernel。

---

## 4. 开放问题

- ~~ledger 文件的并发 append：POSIX O_APPEND vs Windows inbox 目录，实测定。~~ 已定：跨平台统一 inbox 目录 + `persist` 长度守卫（DESIGN §3.4）。剩下的边角：`append` 走 inbox 后，`events` 在下一 step 前看不到 pending 的 user turn——前端若要"立即回显"得自己记。
- session id 与 workspace 的关系；多 workspace / 多用户下 extension 复用与隔离边界。
- compaction 触发：token 阈值 vs task 边界 vs 混合；summary 由谁生成（agent 自己 vs 专用 session）。
- `max_tools` K 与排序权重初值（安放处 `default.toml` 已定，值待调）。
- `session_outcome` 的最小 verdict 集合；用户不给 verdict 时的默认（缺失 ≠ 失败）。
- Verify 套件与 golden 输入数据的 snapshot 边界。
- Driver episode 的 benchmark suite 如何 version / 防 Goodhart。
- provider cache breakpoint 各厂商差异核实（Anthropic / OpenAI / 兼容端点）。
- 是否给 `nulya src` 剥 test 块 vs 拆文件——取决于对 Zig 同文件测试惯例的取舍。
