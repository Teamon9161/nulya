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
          ——要解析内核打印的 JSON 时也可以是 compiled extension（`extensions/compact`，§0.1 #3）
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
| 6 | AI reviewer 倾向默认开，门在 activate | **默认关**；门放在 **promote-to-native**，而这个门就是"**写一条 pin**"这个动作本身——由人或 evolution session 做，内核只认 pin 不认统计（DESIGN §5.1/§5.5） | existence 几乎免费（一个目录）；promote 才有真实成本（cache prefix + 每 session token）。高门槛抑制尝试、诱发 theater |
| 7 | Tool 是演化旗舰，Skill "不竞争不统计" | 优先级：**Skill / notes > 脚本 tool > native tool（= 一条 pin） > driver**；加 `session_outcome` 事件 | 现在模型最能复利的自演化是知识与方法；driver 演化来源本就是"重复的人类 correction 结晶"；outcome 是评价 Skill / Prompt 的唯一 ground truth |

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
- **M2b ✅ 已落地 → DESIGN §7.1/§7.4：** `runtime.entry` 前缀区分编译/脚本，脚本不编译、version = hash(snapshot)（不含 compiler）；`nulya ext init --script`；`ext run --arg k=v`。e2e：`run.ps1`/`run.sh` extension 走完 init → build(seal) → activate → run → 被 pin 成 native 并经 interpreter 执行；version 不含 compiler identity、rebuild 稳定。
- **M2c · Compaction / handoff（§3.4）✅ 已落地 → DESIGN §11：** fork 原语（`session new --parent`）+ driver 主动的 `/compact [focus]`（TUI，tui.md T7）+ **模型主动的 handoff**：随仓库带的 `extensions/handoff`（只 propose、落盘 `.nulya/handoffs/<session>-<n>.md`、缺节 / 不在 session 里都不落盘）· `compact` 的 `brief_file` 分支（只 fork，旧文件逐字节不变）+ 两条路径都由代码追加父指针 footer · `drivers/goal.sh` / `goal.ps1`（第一个 driver，`--pin` 的第一个真实 consumer；stdout 只有控制行、stderr 原样透传 `session step --stream`）。**内核零改动**，只给 `launch.ScriptedProvider` 加了第四档离线替身（DESIGN §13）。验收：`zig build test` / `e2e` 在 Windows 全绿，e2e 新增四条（compact 的 `brief_file`、handoff 的拒绝与落盘、`--with` + `--pin` 的 native 执行、真实 driver 脚本跑完两阶段）。
  - **落地时改了三处措辞**（理由已在 DESIGN §11 / goals/M2c.md §3）：① `handoff` 是 **compiled** extension 而不是 §3.4.1 说的 script——tool 要读 JSON-RPC、回同一个 `id`、校验分节，而一个 manifest 只有一个 `interpreter`，随仓库带的东西没法 ps1 + sh 各一份还共用一个 version（PLAN §0.1 #3 给 Zig 留的正是这种情况）；② 父指针 footer 由 **compact 的代码**追加，不靠模型记得写（driver 经 `session append` 投一条 user turn，仍是 propose→append 的正统用法）；③ `/goal` 是**脚本对**而不是 extension——一个 driver 一跑几十分钟，而 `ext run` 强制 manifest 的 `timeout_ms`（上限 600s），driver 不是一次 tool call；信号因此走文件与行协议，两份脚本都不解析 JSON（这也是它们各能压在 70 行内的原因）。

### M3 · `nulya src` + 文档（§3.10）✅ 已落地 → DESIGN §14
- 已做：build.zig 把 `src/**/*.zig` `@embedFile` 进二进制（恒开无 gate）；`nulya src [path] [--tests]` 打印（无参数列全树），**默认剥 top-level `test` 块**、`--tests`/`--raw` 原样（`source.zig`）；测试留在文件里，剥离是投影不是存储。`nulya ext api` 的协议 topic 变成 `nulya src extension/protocol.zig` 的特例（零漂移），去掉手抄的 wire shapes。
- 验收（`tests/e2e.zig` 绿）：`nulya src prompt.zig --raw` 与磁盘 `src/prompt.zig` 逐字节相等；默认视图更短且无第 0 列 `test` 头；`nulya src` 列出含 `extension/protocol.zig`；`ext api` 打印真实 protocol 源码。

### M4 · Anthropic / Codex provider + 真实 cache 验证（§3.9）✅ 已落地 → DESIGN §13
- 已做：`providers/wire.zig`（三个 provider 共用的 POST + SSE + PromptIR 块解码，各文件只剩自己的 wire shape）；`anthropic`（Messages API，两个 `cache_control`——冻结 system 尾 + 最后一条 message 的最后一块，后者随 append 前移；同 role 块合并成一条 message；usage 合并而非覆盖；native 用 `output_config.effort`，兼容端点用 `thinking.budget_tokens`）；`codex`（ChatGPT 订阅的 responses 端点，OAuth 走 `~/.codex/auth.json`、401 自动 refresh 回写，prompt cache key 由 **durable session id** 确定性派生 → 跨 `session step` 进程同域）；config `ProviderKind` + `default.toml` 加 anthropic / codex / deepseek / deepseek-anthropic 四个 profile。
- 验收（`zig build integration`，无 `NULYA_INTEGRATION_PROFILE` 即 skip）：`deepseek`（openai 口）/ `deepseek-anthropic`（anthropic 口）/ `codex` 三条真实链路，连续四步 `cache_read` 单调不减且从第二步起 ≥ 上一步 input 的 90%；批量 tool turn 在三种 wire format 上都跑到 end-turn。
- **仍未验的一处**：DeepSeek 的 anthropic 口做的是 implicit prefix cache（`cache_creation_input_tokens` 恒 0），所以「`cache_control` breakpoint 被真正采纳」只在 first-party Anthropic key 上才能确认，现在只证明了「这个序列化不破坏缓存」。

### M5 · 慢速回路的 substrate + 第一个 evolution extension（§3.7）✅ 已落地 → DESIGN §3.1/§3.3/§7.2/§7.4/§9.5/§14
- 已做（执行契约 [goals/M5.md](goals/M5.md) 逐条对上）：**outcome journal** `.nulya/session-outcomes.jsonl` + `nulya session outcome`（第二条 journal 而不是 ledger 事件；没有行 = unknown ≠ failure；不碰 session 文件，所以正在跑的场也能评）· **per-step usage** 落 `assistant.usage`（不投影，与 `reasoning` 同地位）· **多 store root**（workspace → user `~/.nulya/extensions` → `extensions.paths`，首个持有者胜；project 层不能加 root）· **`ext build` 按 manifest id 落 store**（draft 可以待在仓库任意路径）· **`session new --with <id>[@<version>]`**（composition membership，不是 native pin；fork 不继承）· **`nulya session list [--json]`** 与 header 开始写 `created` · **`extensions/evolution/`**（仓库带的 data extension：identity prompt + skill，不 activate、`--with` 带入、无特权）。
- 验收：`zig build test` / `zig build e2e` 在 Windows 全绿，e2e 新增七例（outcome journal、usage 行、多 root 与遮蔽、build 落点、`--with`、`session list`、bundled evolution）；真实 evolution session 的报告在 [goals/M5.md](goals/M5.md) §6。
- 相对原计划的两处修正（已定，理由见 DESIGN §3.3 / §14）：`session_outcome` **不是** ledger 事件；`--skill` 被更通用的 `--with` 吸收。

### M6 · Version-aware evidence（§3.5，原 v0.2 Phase A–E）
- A usage fact 加可空 `version` **✅ 已落地**（执行契约 [goals/M6a.md](goals/M6a.md) → DESIGN §5.5）→ B `VersionCreatedFact{parent, reason}` → C Seal → Verify(sealed) 门 → D `EvaluationEvidence` → E policy 比较 implementation、建议 rollback。
- **Phase A 刻意拆成两半，只做了 fact 那半**：写下 `version` 是**补不了课**的（journal 只能 append，今天不记，将来判断 rollback 时这段历史永远是 unknown），而 `VersionStats` 投影只是从已有的行里算出来的——什么时候算都不晚。所以投影**等第一个真实 consumer**（"第二个 consumer 出现之前不抽 abstraction"），`aggregate` 一字未动，内核新增读者数为零。
- 相对原计划的一处修正：journal **不升 v2**，是 v1 加一个可选列（理由见 §3.5.2）。
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

✅ **已实现，现状见 [DESIGN §3.4](DESIGN.md)。** 落地形态与原计划一致：`.nulya/sessions/<id>.jsonl`，header 冻结 composition（active 版本 + native tool 选择）+ 每行 `{"seq":n,…}` 事件；`Ledger.createDurable/openDurable/append`，内存 `init` 版保留给测试；`prompt.currentGeneration()` 删除（generation == 文件）；usage journal 仍独立。outcome 是第二条 journal 而不是事件（M5a → DESIGN §3.3）。

**两处实测定的决策（已定，记进 DESIGN §3.4）：**
- **并发 append = 单写者 + inbox 目录**（不是 O_APPEND）。session 文件只有 session 进程一个写者；任何其他进程的事件（CLI 的 `capability_note`、driver 的 `session append`）投进 `<id>.inbox/`，session 在 step 边界排干——Windows 上无需文件锁，且 batch 不变量天然成立。
- **`NULYA_SESSION` = session 文件相对 workspace 的路径**；CLI 子进程 cwd 就是 workspace，据此定位文件与 inbox。

fork / compaction（新文件 + `parent` 指针，前端沿 parent 链呈现连续对话）仍未实现，见 §3.4。

### 3.2 `nulya session *` 与 subagent = 自调用 `[CLI 已落地 · M2a → DESIGN §14；subagent 用法待第一个 consumer]`

✅ **`nulya session new|append|step|events|cancel` 已实现**，现状见 [DESIGN §14](DESIGN.md)。`step --max-steps N` 由 kernel（`AgentSession.run`，`session.max_steps_ceiling`）强制；每次调用是对 durable session 文件的独立进程，且只有 `step` 写主文件（`append` 走 inbox、`cancel` 是标记、`events` 只读 tail）；`step` stdout = 本次追加的事件 JSONL；`cancel` 由 kernel 在 step 边界消费；bare `nulya` demo 已改走同一 durable 路径。

**尚未落地的子项：** `--budget-tokens`；`events --follow` 只做了轮询骨架。`--pin` 已落地并有了第一个真实 consumer（`drivers/goal.*` 带入 `handoff`，§3.4.1 → DESIGN §11）。`--system-file` / `--skill` **已被 `session new --with <id>[@<version>]` 吸收**（M5e → DESIGN §14）：把一个 built 的 data extension 带进这一场，system_prompt 与 skill 一起进——比两个各管一半的 flag 更小，也让 mode 这件事不需要新机制。**2026-08-21 修正：吸收的论证只对"制品"成立，对"参数"不成立。** T32 的 agent persona 是 per-session 的正文（每次委派现渲染、没有独立于一场 session 的生命周期），被迫材料化成 `agent-<name>` data extension 走 `--with`，结果 store 与 `/ext` 长出不该按的派生包，且 persona 场的 resume 与 `ext prune` 耦合（persona 每改一次就多一个非 current 版本，prune 掉就 resume 不出来）。`--system-file` 因此以正确形式回来：**`session new --prompt <file>`**——创建时读字节冻进 header（`ModelDescriptor` 的同一先例：冻解析结果不冻引用），resume 从 header 读、不经 store。尺子：文本有独立生命周期（evolution / handoff / plan）→ extension；没有 → `--prompt`。执行契约见 [goals/session-prompt.md](goals/session-prompt.md)。下面的 subagent / 编排用法等第一个真实 consumer 出现再写实（它们是**用法**，不改 kernel）：

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
/goal（目标达成前不结束）               → 脚本：loop { step; 见 handoff call → fork（§3.4）; 评估; append "继续" }
plan → review → 共识 → implement       → 脚本：三个各自冻结 composition 的 session
loop until objective / swarm           → 脚本
```

### 3.3 脚本 extension `[已落地 · M2b → DESIGN §7.1/§7.4]`

✅ **已实现，现状见 [DESIGN §7.1 / §7.4](DESIGN.md)。** `runtime.entry` 的前缀区分编译（`bin/`）与脚本（`src/`）；脚本带可选 `runtime.interpreter`（`powershell` / `sh` / `python3` …），无 `src/main.zig` 就不编译，version = `hash(snapshot)`（compiler 为空串、不含 identity、跨机器稳定），seal / integrity / activate / rollback / usage 完全共用。`nulya ext init --script` 按宿主生成骨架；`nulya ext run --arg k=v` 按 manifest schema 类型生成 JSON（`'<json>'` 仍可用）。

- 能力谱：**shell 一行 → 脚本 extension（`ext init --script`）→（实测有需要）native Zig** 成立。
- persistent runtime（warm worker 池、LRU、TTL）仍是**先测量再做**的后期加法。

### 3.4 Compaction = 开新 ledger 文件 `[已落地 · fork 原语 → DESIGN §11/§14；第一个 driver = extensions/compact]`

✅ **已实现。** 内核侧只补了 fork 原语的缺口（`session new --parent` 校验父存在 + 不点名模型时继承父的冻结身份，composition 仍现解）与一个 `NULYA_EXE`（子进程找得到 harness，DESIGN §7.6），现状见 [DESIGN §11](DESIGN.md)。压缩本身**没有进内核**：它是 driver 用 `session append` + `session step` + `session new --parent` 组合出的过程，第一个实现是随仓库带的 **`extensions/compact`**（compiled extension，因为 driver 要解析 `session step` 打印的 JSONL），TUI 的 `/compact` 只是 build 它、run 它、跟着它（[tui.md](tui.md) §11 T9）——前端是客户端，不是过程的所有者。

**一处实测定的决策：摘要在旧 session 内部生成，不开子 session。** 压缩恰好发生在缓存前缀最大的时候，让旧 session 总结自己是一次几乎全命中的请求；开子 session 等于把整份转录当全新 input 再付一次全价——正是要压缩的那个东西。代价是请求与摘要成为旧 ledger 里两条真实事件，这是诚实的：那个文件因此记下了自己为什么结束。

仍未做的相邻项：
- **自动触发**。没有对应的 config 键；TUI 只在 ctx ≥60% 时把 `/compact` 显示出来，不代替人按。自动压缩失手的代价是一整段对话，所以先让人按，等有真实使用证据再说。
- **沿 parent 链呈现连续对话**。`/sessions` 目前把父与子列成两行，不显示它们是同一场（`session list --json` 的 `root` 已经算好了，前端还没用它连起来）。

#### 3.4.1 Handoff：同一个 fork，换个触发者 `[已落地 · M2c → DESIGN §11]`

✅ **已实现**（`extensions/handoff` + `compact` 的 `brief_file` 分支 + `drivers/goal.*`，现状见 [DESIGN §11](DESIGN.md)）。下面保留的是设计本身；三处措辞在落地时改了，记在 §1 M2c 里。

`/compact` 是 driver 因为"满了"发起；handoff 是**模型**因为"一个阶段做完了、剩余工作不再需要过程细节"发起。动作完全相同——旧 session 写 brief → `session new --parent` → brief 作首条 turn → 旧文件不动；只有触发者、信号、brief 侧重三处不同：

| | `/compact` | `handoff` |
|---|---|---|
| 触发 | driver：用户敲命令 / token 压力 | 模型：阶段边界（/goal 里用户可预设阶段计划） |
| 信号 | driver append 一条请求 `user_text`，下一条 assistant 文本就是 brief——由构造保证，**文本够用** | 模型调 `handoff` **tool**（下）——模型"发起"靠约定字符串太脆（忘写 / 写在正文中间 / 包进 code fence，driver 只能 regex 猜）；tool call 结构化、可校验、说明书随 tool description 每场可见 |
| brief 侧重 | 继续这场对话所需的一切 | 上一阶段的**结论** + 下一阶段的**任务**，明确丢掉过程 |
| 执行 | `extensions/compact` 的 fork 过程（DESIGN §11） | **同一个** fork 过程（调同一个 tool，brief 由 handoff 提供） |

**`handoff` tool 的形状（内核零改动）：**

- **不是第二个 builtin**，是一个随仓库带的 extension contribute 的 tool（与 `extensions/evolution/` 同层；落地为 **compiled**，理由见 §1 M2c ①）。落点就是 extension > cli > kernel 的正统位置。nulya **没有 "std tool" 层**——一个"永远在模型面前"的标准工具集只是第二、第三个 builtin 换了名字；随仓库带的一方 skill / extension 是**默认可得、按需可见**。（`extensions/std` 正是这句话的例证而不是反例：它叫 std、是一个普通 compiled extension、默认不在任何 composition 里、只经用户自己写的 pin 进模型工具面，DESIGN §7.8。2026-08 连 `edit` 都从内核搬进了它——"标准工具"与"内核工具"在这里是真的分开的。）
- **默认不在任何 composition 里；由需要它的 driver 在 `session new` 时 pin。** 极简 / 交互模式（人坐在 TUI 前，只有 shell 加自己 pin 的那几个）不给：那时 driver 是人、人有 `/compact`，模型替人决定"这场对话该换文件"是越位；没人消费的 tool 是对模型撒谎（result 说"已记录"而什么都不发生）；每场白占一个 `max_tools` 槽和前缀 token，常驻的逃生口诱发不当使用。physics 上两边都合法，所以这是 composition 的选择，归组 session 的人——`/goal` 的 `session new --pin ext:handoff/…` 才带上它。这使 handoff 成为 `--pin` 的**第一个真实 consumer**。这是 tool 方案唯一比文本多出的依赖——tool 必须在冻结的 composition 里。
- schema 分节 `done` / `next_task` / `keep` / `drop?`。extension **校验**（缺节 → 返回错误让模型重来）→ **落盘** `.nulya/handoffs/<session>-<n>.md`（诚实的实际效果，人可看；`n` 是 per-session 计数，不是 ledger seq——tool 拿不到 ledger）→ 返回"handoff 已记录，不要再调工具，结束本轮"。
- **tool 只 propose、不 fork。** driver 是唯一决定"现在 step 哪个文件"的人：tool 自己 `session new --parent` 会留下 driver 没跟上的孤儿子 session，且 fork 代码会有两处。driver 看到**新落盘的那个文件** → 走 `/compact` 同一个 fork 过程（`compact --arg brief_file=<它>`）→ 切到子 id。落地时信号从"解析 step 输出里的 call"换成了文件，因为文件让两份 driver 脚本都不必解析 JSON（§1 M2c ③）。这与 physics §3 同构：模型 propose，driver 决定。
- **不加** `session transfer` CLI 动词，**不加** `<id>.handoff` 标记文件（`<id>.cancel` 是 kernel 消费的；driver 语义的文件混进内核布局就越界）。physics §8："何时该继续"是 policy。

**brief 的一条硬约定：带上父 session id。** 旧 ledger 还在盘上，新 session 有 shell——carried 文本末尾写"父 session `<id>`，细节 `nulya session events <id>`"，lossy 压缩就变成 lazy 检索，模型判断失误也有救。落地时这段由 **compact 的代码**追加、两条路径都加，不靠模型记得写（§1 M2c ②）。

**关于省 token，诚实地说：** 有 prefix cache 后（DESIGN §13 实测 cache_read ≥ 90%），长 context 每步的边际成本 ≈ cache_read 价（约 0.1×）× 前缀长度，handoff 的节省约是朴素估算的 1/10——长时 /goal 里 phase 1 探索产生的大量 tool 输出被 phase 2 每步重读、cache TTL 过期后的重写，仍然可观，但**更大的收益是质量**：context 越长模型越糊，阶段性换到干净 context 常比省钱更值。真正的成本是信息丢失（转述游戏），靠"父 session 可回查"与边界选择缓解。

**守卫（都是 driver policy，不进内核；第一版 driver 一条都没做，等真实使用证据）：** 模型判断"阶段完了"不可靠、也可能拿 handoff 逃避难题——`/goal` 已经让用户给阶段计划（"explore → design → implement → verify，阶段间 handoff"，缺省也是这四段）；还没做的是 context 太小时忽略提议（fork 没意义）、brief 太短退回 `/compact` 再要一次。两种触发共存——边界优先 handoff、压力兜底 compact——已经是一条代码路径了。

**前端跟随（归 tui.md T10，未做）：** `/goal` 作为脚本跑时 TUI 是 observer，driver handoff 后 tab 要切到子 session。落地后前端不必猜：driver 的 stdout 就是控制行（`session` / `handoff <old> -> <new>` / `done`），stderr 是 `--stream` 行协议原样透传，喂给已有的解析器即可。

### 3.5 能力演化 evidence（原 v0.2 Phase A–E）`[写实 · M6]`

**3.5.1 双身份。** 每次 invocation 同时携带 `logical_tool_id`（`ext:web.search/web_search`，这个能力值不值得保留 / 晋升）与 `implementation`（`v-a83f…` | null，这版实现是否比上版好）。builtin 与旧历史 `null`。

**Identity rule（authoring 规则，非 kernel 强制）：** 同一 stable id 声明自己属于同一 logical contract。`web_search(query)` v1→v4 实现变、id 不变；变成 `database_query(sql)` 就该是新 id。kernel 只强制 identity 的语法；"没偷换语义"由 Verify / review 保证。

**3.5.2 Version-aware evidence（A）。** usage fact 加可空 `version`。**老行 → `version = null`**（过去不知道就诚实标 unknown，不丢历史）。两个投影喂两个决定：`LogicalToolStats`（吃全部历史 → 要不要为它写一条 pin）、`VersionStats`（只吃 version-known → activation / rollback）。两个决定都在内核之外做。`ToolStats` 名字与语义不变。

> **相对本节原文的两处修正（已落地，goals/M6a.md）。** ① 这一列**不升 `v:2`，是 `v:1` 加一个可选列**：这条 journal 的纪律从来是"加可选列、reader 忽略未知列、同 `v` 的新写者不破坏老读者"（`at` / `session` / `duration_ms` 三个先例都是这么进来的），升 v2 只会让老读者（老二进制、TUI 的 `files.ts`）对每一条新行报 `UnsupportedStatsVersion`，零收益；`v` 留给真正的格式断裂。② **只落了 fact 那半，两个投影都没做**：写 `version` 补不了课（journal 只能 append），投影什么时候算都不晚——所以它等第一个真实 consumer。今天的 `version` 只写不读，`aggregate` 一字未动。

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

### 3.6 SessionDriver 作为脚本 `[已落地 · M2c → DESIGN §11；第一个 consumer = drivers/goal.*]`

> **Kernel 负责 session 怎么正确运行；driver 负责 session 为什么、什么时候、以什么顺序运行。**

Kernel 自带隐式 DefaultDriver：`user message → step → (有 tool call? 再 step : 结束)`。driver 把"结束还是继续"变成可替换的脚本，**完全不改 AgentSession**。

四条 kernel 侧硬约束（都是 physics 在控制面的投影）：

1. **续写 = append，不是 rewrite。** 要表达"进度 43%"就 append 一条 message，绝不动 system prompt。
2. **换 composition = 换 session。** `plan(read-only) → implement(shell/edit) → review(read-only)` = 三个各自冻结的 session。
3. **hidden state 可调度，model-visible state 只能 append。** driver 自己的 `iterations=7` 随便存；一旦要影响模型看到什么，必须显式 append 或 `session new`。
4. **budget / termination / cancellation 最终权在 kernel。** driver 只 propose；`--max-steps` 越不过。

**第一个真实 driver = `/goal`，✅ 已落地为 `drivers/goal.sh` + `drivers/goal.ps1`**（各 ≤ 70 行、逐行对齐，现状见 DESIGN §11）。设计当初长这样，落地形状只在"信号怎么读"上不同（`id` 是 driver 的 hidden state）：

```
id = session new …；append id <目标 + 阶段计划 + "阶段做完就调 handoff">
loop {
  out = session step id --max-steps 1
  if out 里有 name=="handoff" 的 call → brief = 它的 arguments；new = session new --parent id:<seq>；append new brief；id = new；continue   # §3.4.1
  if calls 为空 → 评估目标；达成则退出，否则 append id "继续"
}
```

"现在 step 哪个文件"永远只有 driver 知道——模型经 `handoff` tool 提议，driver 决定并执行 fork。**fork 那一段没有写第二遍**：`extensions/compact` 已经是它（DESIGN §11），`/goal` 拿到 brief 后调同一个 tool 的 `brief_file` 分支，`session new --parent` 因此仍然只在一处被调用。落地时 `/goal` **没有**做成 extension 而是一对脚本：`ext run` 对 extension tool 强制 manifest 的 `timeout_ms`（上限 600s），而一个 driver 一跑几十分钟——driver 不是一次 tool call；且 script extension 一个 manifest 一个 interpreter，跨平台就得两个包。信号因此走文件（handoff 落盘的那个 md）与行协议（`"stopped":"end_turn"`），两份脚本都不解析 JSON。TUI 的 `/goal` 只是 spawn 它并以 observer 跟随（含跟到子 session）；不在 TUI 里内建 goal loop（tui.md T10，未做）。

**两种"灵活"要分清：** Pi 给 extension **mutation power**（改 tools / system prompt / messages / provider payload），代价是 cache / 可复现 / security 靠 extension 自觉；Nulya 给 **composition power**（编排 Session A / B / Tool X / Skill Y，每个 primitive 不可篡改）。"workflow 可以随便长，但改不了 kernel physics"。

Agent 不做成独立 Contribution：一个 Agent = `session new` 的参数集，可以是 skill 自带的数据文件。等三个真实 consumer 都要同一种表示再抽 `AgentSpec`。

### 3.7 慢速回路：Evolution Session `[M5 起第一档；整体占位]`

**3.7.1 能改 ≠ 有动机改。** 干活的 agent 的 reward 是"完成当前任务"，造工具的成本落在当前 session、收益归 future sessions；只要 shell 够用，局部最优就是"别造"。这不是模型不聪明，是目标结构决定的；靠 prompt 喊"记得改进自己"只是掩盖。

**3.7.2 两个时间尺度。**

```
FAST LOOP   User → Agent → tool/shell → Result        reward: 把现在这件事做完
                └─ evidence（invocation / version / evaluation / episode / outcome）
SLOW LOOP   Evolution Session：读 evidence + 失败 + 成本 + 反馈 → 找「什么反复发生 / 什么贵 / 什么常失败 / 什么值得沉淀」
                → propose: 新 Skill 条目 | 脚本 Tool | pin（把已有 tool 放上 native 面） | Tool v2 | Driver v2
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

**3.7.6 outcome：ground truth。** ✅ **已落地（M5a）→ DESIGN §3.3。** 落地形态是**第二条 journal**（`.nulya/session-outcomes.jsonl` + `nulya session outcome`）而不是 ledger 事件：session 尾往往没有下一个 step 来排干 inbox；verdict 是关于这场 session 的判断而不是其中一轮；ledger 不该长出"存了但不投影"的事件种类。composition 冻结且记在 header，`session list --json` 把两者 join 起来，所以"有 skill X 的 session vs 没有的"是可派生投影。

**3.7.7 统一生命周期，不统一评价方式。**

| | Identity | Verify | Evidence 单位 | 评价 |
|---|---|---|---|---|
| Tool | stable tool id | unit / contract test | invocation | deterministic test 起步，可较激进 |
| Driver（脚本） | stable driver id | workflow eval | **episode**（整个任务：outcome / cost / tokens / turns / retries） | 像实验，须保守 |
| Skill / Prompt | stable id | — | **仅间接**：采用它的 session 的 outcome | 不竞争、不统计 |

Driver 演化比 Tool 保守，因为**归因难**（任务难度 / model / seed 全在漂）与 **blast radius 大**（坏 Tool 让搜索差一点；坏 Driver 报废整个流程）。默认 driver candidate **不自动替换全局 DefaultDriver**，只在 scoped trial 积累 episode。benchmark suite 本身会被 Goodhart、会腐坏，需要和 capability 一样的 version + provenance。

**3.7.8 触发、递归、地板。** 三档触发，每档 threshold 是 policy：① 用户 `nulya session new --with evolution@<version>`（最先，✅ M5）② 主 driver 任务结束时 `if enough new evidence` ③ 每 N 个 episode。Evolution skill 自己也可演化（`evolution v1 → v2`，复用同一套 candidate → verify → trial → rollback）。**递归的地板 = 八条 physics 不可自改**——正是这块不可自改的地板让上面一切可以放心试错。Driver 演化的真实来源多半是**重复的人类 correction 结晶**（"先写 plan""找 reviewer 看"连说十次），不是凭空花样。

**3.7.9 mode = 贡献 system_prompt 的 data extension + `--with`。** ✅ 机制已在（M5e/M5g）。同一个包两种投放：`activate` = 常驻（每场都有），不 activate、只 `--with` = 按场。evolution 是第一个 mode；`handoff`（§3.4.1）会是第二个形状（tool 而非 prompt，同样"随仓库带、按需带入"）。**不为 mode 造别的机制**：一个"模式"就是一个 data extension 加一次 `--with`，没有 mode 注册表、没有 mode 生命周期。

### 3.8 Authority / sandbox `[占位 · M7]`

- `sandbox` backend 上线后 `manifest.permissions` 才被 OS 强制，从"声明"升级为"边界"。**执行前的那一票否决已经有了**（§3.8.1 的 gate），它是另一件事：拦的是"这一次要不要发生"，不是"发生时能碰什么"。
- 不变量：**capability 绝不因被生成或被晋升而自动获得 authority**；始终 `capability authority ⊆ session authority`。
- 与 config 项目层"只能收窄"是同一不变量的两面：checkout 一个 repo 不该能拓宽机器权限。第三面已落地：**workspace store 的 trust gate**（DESIGN §9）——`.nulya/extensions` 也在 checkout 里，所以随 clone 到达的 store 要被人信任一次才进 composition。
- read-only subagent（reviewer）在 sandbox 之前不给 unrestricted shell（`local` 下无法区分 `cat` 与 `rm`）。

### 3.8.1 权限：gate 是 substrate，mode / 规则是 driver 的 policy `[gate 已落地 · 2026-08 → DESIGN §4/§14；分类器占位]`

`3.8` 是"发生时能碰什么"（OS 强制，未做）。这一节是它前面那半步：**这一次要不要发生**。两件事不该合并，因为它们的答案由不同的东西给。

- **内核只长了一个原语，与 cancellation 同类**（physics #7 的同一形状）：`loop.StepContext.gate` 每个 tool call 执行前问一次，答案只有 `allow` / `deny{note?}` 两种；deny 就是那个 call 的 `tool_results`（`ok=false` + marker + 人的原话），**没有新事件种类、没有新 policy 键、batch 不变量不动**。kernel 里没有任何"该不该问"的判断——那正是它不该有的东西（physics #8）。`session step --gate` 把这个问题接到 stdout 一行 + stdin 一行上（要求与 `--stream` 同用；EOF / 认不出的答案 = fail closed）。
- **判断在 driver**，今天第一个 consumer 是 TUI（tui.md §5.7）：两档 mode（`ask` / `auto`）+ 三张规则表（`deny` / `ask` / `allow`，条目是 tool id 或 shell 命令前缀）+ 本场的 always 集合。它是**可替换的**：另一个 driver 完全可以只答 `allow`（等于今天不带 `--gate`），或者把每个请求转给一个人的手机。内核不知道也不需要知道。
- **`manifest.contributes.tools[].readonly` 是声明不是边界**（DESIGN §7.2.1）：包自己说这个 tool 只读，kernel 解析、冻结、**不强制**；driver 的 policy 可以信它（TUI 默认信，一个键可关）。它与 `permissions` 同级——两者都要等 §3.8 的 OS 强制才谈得上"边界"。同一类的第二个字段 `audience`（这个 tool 是给模型的还是给 driver 的）**已落地** → DESIGN §7.2.1。
- **与 §3.12 的 policy hook 是两扇门，不合并**：这一扇在**每个 call 执行前**（谁都在跑的那条快路径上，答的人是当场的驱动者）；那一扇在 **promote-to-native**（写一条 pin 的时候，答的人是 reviewer 或人，一场 session 只发生一次）。合成一个"权限系统"会把每步都要答的问题和一辈子答一次的问题塞进同一套配置。
- **占位：classifier-as-extension。** tcode 的 auto 档背后有个安全分类器（模型判断这一步是否 destructive）。在 nulya 里那**天然是一个 extension**：driver 在 `ask` 之前调它一次，它答"这条命令属于哪一类"，driver 决定信不信。不进内核（是 intelligence，§0.1）、也不必进 TUI（TUI 只要能 spawn 它）。等有人真被问烦了再做——现在连"哪些规则最常被写进 `allow`"的证据都还没有。

### 3.9 Provider：Anthropic / Codex + cache breakpoints `[已落地 · M4 → DESIGN §13]`

✅ **已实现，现状见 [DESIGN §13](DESIGN.md)。** `anthropic`（含兼容端点）、`codex`（ChatGPT 订阅）与共享的 `providers/wire.zig` 都已落地并经真实端点验收。

仍未做的相邻项：
- deferred tools 等 provider-specific 优化允许，但不能破坏 PromptIR 块前缀不变量。
- ~~**thinking 回放**：ledger 四种事件里没有放 CoT 的地方……等有真实证据再说。~~ 已做（DESIGN §3.1、§13）：证据不用等——Anthropic 一方端点在 thinking 开着时**拒绝**丢了 thinking block 的 tool-use turn（Opus 5 默认开、Fable 5 只能开），Responses 端点不带则每步重推。落地形状不是第五种事件，是 `assistant.reasoning` 一个不透明字段 + `reasoning` block + provider 侧的 `reasoning_item`；codex 上已实测回放被接受。**仍未验**：first-party Anthropic key 上的 thinking-on tool 循环（integration 第三条就是为它写的，同 §4 那条 cache_control 未验项一起等 key）。
- ProviderContribution（extension 供 provider）：在 loop 上游、与下游 Tool 不同构，机制待定，只占位。

### 3.10 `nulya src` 与文档 `[已落地 · M3 → DESIGN §14]`

✅ **已实现，现状见 [DESIGN §14](DESIGN.md)。** 内嵌 `src/**`，`nulya src [path]` 打印，AI 读真实代码 = 零 API 漂移；`nulya ext api` 成为它的特例。入口仍是 CLAUDE.md 的模块表，不是让 AI 通读。

**入口已补（2026-08，DESIGN §7.5/§14）。** 自描述面齐全，缺的是"模型怎么知道这些命令存在"：现在 kernel prompt 一句事实（`NULYA_EXE` / `nulya help` / `nulya src` / 可写 extension·skill·prompt·driver）+ `nulya help`（与命令表逐动词对齐、bare 动词族印自己那块）+ 随仓库带的 `extensions/guide`（只贡献 skill，按需 load，不自动装）。三层都**只指路不复制**——真相留在与代码同源的命令里，所以不会漂；且**没有一句劝进化**（§3.7.1：喊话不解决动机结构，造工具的场合是 evolution mode）。**测试取舍拍板**：不拆 `*_test.zig`——测试留在文件里（Zig 惯例、人可读、给 AI 造扩展时的风格参照），`nulya src` 默认剥 `test` 块解决 AI 读结构时的 token 成本，`--tests` 按需取。存储 vs 投影解耦，`src/` 零改动。

### 3.11 前端 / ACP / MCP `[占位 · M8]`

- 前端（CLI 交互 / TUI / app / ACP）都是 core 之上的薄客户端：tail ledger 文件 + append user 事件。**前端是长期进程，re-spawn 的只是 worker，UI 状态不丢。**
- **TUI 已有设计契约与里程碑：[tui.md](tui.md)**（Bun + OpenTUI，仓库顶层 `tui/`；内核改动两处：`session step --stream` 纯观测、`session step --gate` 每个 call 问一次，§3.8.1）。
- ACP：`session/new|prompt|cancel` 直接翻译成 `nulya session *`。
- MCP client：一个 extension，把 MCP tools 适配成 `tool.Tool` 进 ToolSetSnapshot（同构）。
- 唯一需要常驻进程的是"子 agent 与真人持续流式对话跨多轮"——persistent mode，纯后期加法。

### 3.12 Policy hooks / reviewer `[占位]`

（与 §3.8.1 的 gate 是**两扇门**：那一扇在每个 tool call 执行前、答的人是当场的驱动者；这一扇在 promote-to-native 的时候、答的人是 reviewer 或人。不合并。）

[agents-and-review.md](agents-and-review.md) 的审阅门设计保留其**能力模型**（read_only 硬天花板、ToolPolicy allow/deny、max_turns、结论以 fenced data 进父 ledger），但实现方式按 §3.2：reviewer = `session new --with reviewer@<v> [--pin …]` 的一个 read-only session，由人或 evolution 脚本在 **promote-to-native**（= 写一条 pin，§0.1 #6）这个门上调用；`policy.hook` 档位 `off / auto / human_approval / ai_reviewer` 决定是否调用。默认 `auto`（不调 reviewer）。不进 kernel。

### 3.13 后台 shell：supervisor → inbox → `task_finished` `[内核已落地（B1–B4，DESIGN §3.1/§6.1/§8/§11/§14）；只剩 B5 = TUI 的任务面，tui.md T29]`

base-tools.md §4 当年留下的 "later hardening：`run_in_background`"。执行契约在 [goals/background.md](goals/background.md)（内核事实 / B1–B5 / 已定决策 D1–D10），这里只记分界：

- **内核只长两块 substrate**：① `shell {background:true}` 经 `Environment.startShellTask` 起一个**活得过 step 进程**的 supervisor（`NULYA_EXE task supervise`，外壳代码，用现成的 `Tree` / `emit` / `depositEvent`），调用立刻返回回执；② 第五种 ledger 事件 **`task_finished {task, exit_code, text}`**——supervisor 结束时投进 session 的 inbox，step 边界排干、投影成 user-role 文本。与 `capability_note` 同 genre（跨进程的事实），**不是** `tool_results`（那个 call 已经有结果；batch 不变量与 wire 都不允许迟到的 tool_result），也不是 `user_text` + sentinel（ledger 不说谎）。
- **不进内核的**：何时再 step（TUI 的判据是 "driver + idle + `<id>.inbox/` 非空"；`goal.*` 用 `task wait --any`）· fork 带不带任务（`session new --parent` 不动，**compact** 把在跑的任务 `task retarget` 给子场并在 carried 文本里代码追加一行）· 退出杀不杀（不杀）· 后台的缺省 timeout（没有）· 任务注册表（status.json 是真相，`task list` 只是投影）· `--stream` 新事件（ledger 行够了）。
- **注入只加卫生不加边界**：kernel prompt 一句关于 ledger 角色的事实（内核自己把机器事件投成 user role，它得说清）+ `task_finished` 模板自带分隔框 + `tool_results` 不包装；边界仍是 §3.8.1 的 gate 与 §3.8 的 sandbox。
- **分界一句话**：core 只动 `ledger` / `prompt` / 三 provider / `tools/shell` / `environment` / kernel prompt 那一句；supervisor 与 `nulya task list|status|wait|kill|run|retarget` 在 `cli/task.zig`；retarget 的调用者是 `extensions/compact`；唤醒、显示、kill UI、退出提示全在 TUI（tui.md T29）。

---

## 4. 开放问题

- ~~ledger 文件的并发 append：POSIX O_APPEND vs Windows inbox 目录，实测定。~~ 已定：跨平台统一 inbox 目录 + `persist` 长度守卫（DESIGN §3.4）。剩下的边角：`append` 走 inbox 后，`events` 在下一 step 前看不到 pending 的 user turn——前端若要"立即回显"得自己记。
- session id 与 workspace 的关系；多 workspace / 多用户下 extension 复用与隔离边界。
- ~~compaction 触发：token 阈值 vs task 边界 vs 混合；summary 由谁生成（agent 自己 vs 专用 session）。~~ 已定（§3.4）：混合——边界由模型经 `handoff` tool 主动提、压力由 driver `/compact` 兜底，汇到同一条 fork 路径；summary 一律由旧 session 自己在 cache 前缀上写，不开专用 session。剩下的边角：handoff 的守卫阈值（多小的 context 不值得 fork）、brief schema 分节强制到什么程度——两者第一版 driver 都**故意没做**（§3.4.1），等 `drivers/goal.*` 有真实使用证据再定，不靠想象拍阈值。
- `max_tools` 的初值（安放处 `default.toml` 已定，值待调）。~~排序权重初值~~ 不再是问题：排序 policy 已整个移出内核，native 面只由 pin 决定（DESIGN §5.1/§5.5）。
- ~~`session_outcome` 的最小 verdict 集合；用户不给 verdict 时的默认（缺失 ≠ 失败）。~~ 已定（M5a → DESIGN §3.3）：`success | partial | failure` 三值；**没有行 = unknown ≠ failure**；同一 session 可多行、最后一条作数；不加 `source`（今天只有人写；将来 driver 自动记时再加，届时无 `source` 的 v1 行 = 人评）。
- ~~**随仓库带的 extension 怎么打包？**~~ **源码一半已定并已落地 → DESIGN §7.8 的 `ext seed`**：`extensions/**` 经 `ext_embed` 进二进制，seed 把自带 draft 写进 store root，分发就是二进制本身。剩下的另一半是**编译产物**：compiled 扩展（std / compact / handoff）在用户机器上仍要 `zig build-exe` 一次（首启后台化后不再阻塞，但没装 zig 的机器装不上，首启也非即刻可用）。已定形状（2026-08，未实施）：**两遍发布构建**——CI 先用刚构建的 nulya 对 bundled 扩展跑 `ext build` 得到临时 store，再以 `-Dext-prebuilt=<path>` 二次构建把**已 seal 的版本目录**嵌进二进制（与 `-Dzig-archive` 同一先例）；用户机器上 `ext build`/`sync` 现有的 donor 匹配路径（按 `package_digest + target + compiler` 找、复制后 `.sealed` 复验，DESIGN §7.4）把嵌入集当成多一个 donor。不改"seed 只写源码"的纪律，版本仍内容寻址、门一道不少；代价是二进制 +~14MB、发布流程两遍。**等真做发布流水线时再上**（M8 / 发布）。
- Verify 套件与 golden 输入数据的 snapshot 边界。
- Driver episode 的 benchmark suite 如何 version / 防 Goodhart。
- ~~provider cache breakpoint 各厂商差异核实（Anthropic / OpenAI / 兼容端点）。~~ 已测（M4）：openai / anthropic / codex 三条真实链路都拿到单调不减的 `cache_read`；剩下的是 first-party Anthropic key 上确认 `cache_control` 真被采纳（兼容端点是 implicit cache，看不出来）。
- ~~codex 的 thinking：不回放 reasoning item 对多轮 tool 使用到底损失多少？~~ 已回放（DESIGN §3.1、§13），不再是问题；剩下的验收项是 first-party Anthropic key 上跑通 integration 第三条。
- ~~是否给 `nulya src` 剥 test 块 vs 拆文件~~ 已定（M3）：测试留在文件里，`nulya src` 默认剥、`--tests` 保留——剥离是投影层的事，不动存储（DESIGN §14）。
- ~~**workspace store 的首用 ack**：`.nulya/extensions` 在 checkout 里、又是第一优先 root，clone 一个 repo 就等于让它的 active 版本无声进 composition。候选方案是 direnv 式的内容 hash 确认。~~ **已定并已落地 → DESIGN §9 的 trust gate。** 两处待定项都拍板了，而且都不是当初设想的答案：
  - **粒度：整个 store 一条，key 是 store 路径，不含任何内容 hash。** hash 是错的抽象——agent 每造一个能力、每 activate 一次都会改它，一道每轮都重问的门会把自演化循环卡死。判据换成**出生地**：本机 `ext build` 填满一个空 store 就自动记信任（生于本地），已有内容却无记录就是随 checkout 到达。
  - **拒绝时的行为：硬拒整场**，不跳过该 root。理由正是这条问题自己提示的那个对照——"少一个能力的 session"不是它被要求的那一场（§7.5 对坏 active 版本的硬失败同理）。
  - 落地形状：`journals/trust.zig`（user 层 `<NULYA_HOME | ~/.nulya>/trusted-stores.jsonl`）+ `launch.ensureWorkspaceStoreTrusted`（门在壳层，内核不知道）+ `nulya ext trust`（显式信任，先打印要信任的东西）。只读投影与 `ext run` 不过门。
- ~~**一个 tool 是给模型看的还是给 driver 看的，只有它自己的包知道——今天却由前端按名字猜**（`tui/src/extensions.ts` 的 `bundled_driver_only`）。~~ **已落地 → DESIGN §7.2.1 的 `contributes.tools[].audience`**（`"model" | "driver"`，与 `readonly?` 同级同纪律：kernel 解析、冻结、不强制；缺省 null ≠ `"model"`）。TUI 侧四张硬编码名单随之消失（tui.md §11 T34）。当初留的两个判断都成立：**两半确实要分开**——pin 那一半由 audience 答，`autoActivatable`（开屏该不该 activate）那一半仍只用通则 `contributes.system_prompts`，没有第二个字段；而"按需带入哪个包"仍是 driver 自己的知识，现在是 `tui.toml` 的 `[extensions] session_with` 一个列表键，不是 manifest 说的话。
