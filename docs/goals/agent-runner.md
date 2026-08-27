# Goal · agent-runner：delegation 一层世界观——d-* 身份、send/interrupt 语义、runner 契约、外部 agent（codex/claude/pi）接入

> 这是一份**执行契约**，不是设计文档。设计来源：2026-08-26 的两轮评审对话（本仓库外，结论都收进 §3）。背景：[CLAUDE.md](../../CLAUDE.md)（physics + T32 四期现状）、DESIGN §6.1（后台任务 / `task_finished`）、§4（gate）、§14（`session *`）、`extensions/agent/src/{main,runner,defs}.zig`（现状实现）、tui.md §5.10（TUI 侧委派）。
> **每次 compaction 后先重读本文件**，尤其 §6 进度区。
> 已定的决策（§3）不要重开；认为错了就写进 §6 `BLOCKED:` 并停下，不要自行改方向。

## 0. 目标（一句话）

主模型永远只有**一个** delegation 世界观——`agent{name|session, task}`：创建 sub-agent、追加指导（运行中也行）、中断改向、收报告、继续追问；nulya 自己的 session、Codex、Claude、Pi 乃至第三方 harness 只是它背后可替换的 **runner**。第三方接一个新 harness 只写"怎么跟它说话"，d-* 身份 / 追问 / wake 保证 / 报告回父场 / readonly / depth 全部免费继承。**内核零改动**——报告照旧走 `task_finished`，一切新盘面都是 `extensions/agent` 包私有的。

## 1. 范围（分阶段；本轮派发 ar-a/b/c 与 ar-t1，其余是后续轮次）

**ar-a · d-\* delegation 身份与记录（`extensions/agent`）**

- 新目录 `.nulya/delegations/<d-id>/`（agent 包私有，kernel 不知道）：
  - `record.jsonl` — append-only journal（一行一条、写端持锁、读端忽略残尾——`journals/journal.zig` 的纪律，但**实现归本包**，extension 不 import `src/`）：
    - 创建行 `{v:1, kind:"created", at, agent, runner:"nulya", runner_version?, remote:"s-…", parent:"s-…", readonly, profile?, model?}`
    - 每次 send（含首个任务）一行 `{v:1, kind:"turn", at, interrupt?}`
  - `inbox/`、`interrupt`、`.runner.lock` —— ar-b 使用，本阶段只定布局。
- d-id 形状 `d-<12 hex>`（`s-` 的同款 mint 方式）；**exchanges = record 里 turn 行数**（取代今天数子场 `user_text` 的 `turnsSent`——对外部 runner 也成立的唯一计数）。
- 模型面参数**仍叫 `session`**，值改为 d-\*：`agent{session:"s-…"}` 拒绝并指路 d-\*（D11，pre-release 不留兼容）；回执与 report 框架（`<agent-report session="d-…">`）都改说 d-id，但 report 尾部照旧指路 remote transcript（nulya runner：`nulya session events <s-…>`）——透明不隐藏（D2）。
- followUp 的四道门重排：① d-\* 形状；② record 存在且给出 persona（取代 `wornPersona` 对子场 header 的读——record 是本包自己写的真相）；③ "还在跑就拒绝"**删除**（ar-b 的 send 语义取代）；④ `max_exchanges` 从 record 数。`allowedHere`（父场白名单）与 depth 兜底不动。

**ar-b · send / interrupt 语义 + wake 不变量（`extensions/agent`）**

- **send（默认）**：`agent{session:d-…, task}` 在子 agent 运行中**不再拒绝**——投递消息、返回"已排队，报告随后到"。与主 session 的 append 语义逐位一致（D3）。
- **投递通道按 runner**（D5）：nulya runner = 直接 `session append` 子场（保住 mid-step 投递——子场 kernel 在每个 step 边界排干自己的 inbox）；外部 runner（ar-d 起）= 写 `<d>/inbox/` 一文件一消息（runner 在自己的事件粒度上排干）。
- **wake 不变量（D4，逐字实现，不许简化）**：*凡被 accept 的消息，必须最终有人 drive。*
  - runner 全程持 `<d>/.runner.lock`（**OS advisory 排他锁**，进程死亡自动释放；不是 marker 文件）；
  - runner 退出序列：锁内检查 pending（nulya：子场 `<sid>.inbox/` 非空；外部：`<d>/inbox/` 非空）→ 空则**释放锁 → 再查一次 pending** → 仍空才退出；不空则**尝试重抢锁**，抢到继续 drive，抢不到直接退出（持锁者会看见）；
  - send 路径：**先投消息 → probe 锁**（`openFile` 探针，TUI `probeWriterLease` 同款手法）→ 空闲才 spawn 新 runner（`task run`，与今天同款）。两侧配合下每条消息至少被一方看见，且不产生"抢锁失败打空报告"的垃圾 task_finished。
- **interrupt**：`agent{session, task, interrupt:true}` = 先按 send 投消息，**再写 `<d>/interrupt` 标记**（空文件）。runner 在读 `--stream` 行的循环里顺带轮询标记（delta 流里天然高频）：见标记 → 删标记 → kill 当前 `session step` 子进程树 + `nulya session cancel <sid>`（残尾修复靠内核既有机制）→ 回到循环下一轮（消息已在通道里）。interrupt 不是新消息类型，是执行控制（D3）。
- runner.zig 从"drive 一轮就退"改成上述带锁循环；报告 = 本次 task 驱动的**最后一条** assistant 文本（跨多轮取最后）。readonly gate 应答逻辑不动。

**ar-c · `runner:` 字段 + enum+switch 收拢（`extensions/agent`）**

- 定义 frontmatter 加 `runner:`（缺省 `nulya`；未知值 warn-and-skip 整个定义，与坏 frontmatter 同款）；`list` / `render` 投影带上。
- 包内 `Runner` enum（本轮只有 `.nulya` 一个 arm）+ 概念动词 `start / send / interrupt / drive / pending`，现有逻辑收成 nulya arm——**验收标准是收完之后现有 e2e 行为不变**（抽象没把现状搞复杂）。
- 创建行冻结 `runner` 进 record；每轮调用按冻结值走。**`runner_version` 分两种强度**（2026-08-27 澄清）：`ext:<id>` = pinned execution identity（冻下的 `v-…` 就是每轮实际调用的实现，旧版本仍在 store 所以钉得住）；`claude` / `pi` = creation-time provenance（开场 `--version` 的观察值，后续轮次跑 PATH 上此刻的二进制——PATH 二进制没有可钉的东西，mismatch refusal 只会杀掉本来能 resume 的对话而换不回可复现性）。不做版本比对、不记 change event。原则：**只声称真正 enforce 得了的 freeze**。

**ar-t1 · TUI：主 agent 的 queue lane + interrupt-and-deliver（`tui/`，与 ar-a/b/c 无依赖、可并行）**

- **queue lane**：`pendingCount > 0` 时输入框上方一行（WorkingStatus 同区）：`⏸ N queued — enter queues · ctrl+j interrupts & delivers`，逐条截一行列出排队消息；点击任一条 = 下述手势（inbox FIFO 排干，不假装能单条插队）。transcript 里的 `· queued` 行不动（那是真相所在）。
- **手势 `ctrl+j`**（keymap 可覆盖，走 `tui.toml` 既有 keymap 机制）：输入框有字 → 先 append（queued）；然后 kill 当前 step（T27 既有 kill 路径）；step 进程退出后**立即** re-step（不等 idle 定时器）。idle 时该手势等价普通发送。
- 全部是现有动词接线（append / kill / step），**内核零改动**；不新增状态机——判据复用 `driver` 的现有状态。

**后续轮次（本轮不做，写在这里当尺子）：**

- ~~**ar-d · Codex runner**~~ —— **已落地**（§6，2026-08-26）。App Server 的六个动词全部实测存在（`initialize` / `thread/start|resume` / `turn/start|steer|interrupt`），行分隔 JSON-RPC over stdio；`runner_model:` 已加。
- ~~**ar-e · Pi runner**~~ —— **已落地**（§6，2026-08-26）。`pi --mode rpc` 的 JSONL 全部实测存在；`steer` / `follow_up` 存在但**不用**（理由见 §6），一轮的终点取 `agent_settled`。
- ~~**ar-f · Claude runner**~~ —— **已落地**（§6，2026-08-26）。`claude -p --input-format stream-json --output-format stream-json --verbose` 双向 stdio + `control_request{subtype:"interrupt"}` 全部实测存在，**没有退化成 kill**；不用 Agent SDK（D12）。
- ~~**ar-g · 外置验证 + 契约定稿**~~ —— **已落地**（§6/§7，2026-08-26）。`runner: ext:<id>` + 固定 `internal` tool `agent_runner`（两个 op、版本开场冻死）；契约在 §7、`external.zig` 模块注释、DESIGN §7.8 与 guide skill。
- **ar-t2 · TUI 跟随 d-\***：SubSessionCard 经 record 解析 d→remote（nulya 开 tab，外部看 task log）；`/agent` picker 显示 runner 列。

**不做（明确越界）：**

- **内核 `src/` 零改动**（唯一候选"cancel 带 note"明确不在本契约）。
- 不做 extension dependency / `provides` capability registry / runner 自动 discovery（D7）。
- 不做 live channel / 常驻 runtime——通信 = 盘面事件 + re-drive（agents-and-review §2 仍然成立）。
- 不做 swarm / fan-out / 图编排——不符合"单一 conversation identity 的 harness"模型的东西自己做扩展，不进 runner 契约。
- 外部 runner 的 transcript 观察（v1 看 task log）；"有什么模型可选"的 discovery（D9 延后）。
- 对既有测试的顺手重构；push。

## 2. 完成标准（可机器验证）

- `zig build test` 与 `zig build e2e` 本机（Windows）全绿；`cd tui && bun test` 全绿（快照有意变更在 §6 说明）。
- e2e 钉住：① running 中 followUp 不拒绝、消息最终进子场 ledger 且报告只来一份；② wake 不变量的 race 面（至少：runner 退出后 send 能自起新 runner；redundant spawn 抢锁失败不产生垃圾报告）；③ exchanges 按 record 计数、超限拒绝；④ `s-…` 给 session 参数被拒并指路；⑤ interrupt 标记让当前 step 死、消息下一轮进场。**测试守机制不守细节**（CLAUDE.md 工作约定）——不断言报文措辞。
- ar-c 收拢后既有委派 e2e 语义不变。
- TUI：queue lane 渲染与手势有测试（bun test，走既有 gate/driver 测试的形状）。
- 文档与代码同轮更新：CLAUDE.md 现状条目、DESIGN §7.8 一段、tui.md §5.10/§11 追记；本文件 §6。

## 3. 已定决策（不要重开）

- **D1 · 一层世界观。** 模型面只有一个 `agent` tool；runner 差异全部藏在 runner 层。不做 nulya-agent/claude-agent/… 四套工具。
- **D2 · d-\* 归 agent 包，抽象不隐藏。** delegation 身份、runner 与版本冻结、exchanges、readonly 都住在 record；模型面用 d-\* 指代对话；但 record 可 inspect、report 照旧指路 remote transcript——nulya 的风格是事实透明、抽象在其上。
- **D3 · send / interrupt 是两个执行语义，不是两种消息。** 消息永远是普通 user turn；send = 排队等自然边界（与主 session append 逐位一致），interrupt = 停下当前方向立刻消化。不发明 steer/follow_up 消息类型。
- **D4 · wake 不变量用"释放后复查 + 投递后探测"闭合。** 单靠"退出前看一眼 inbox"关不掉 TOCTOU（append 恰落在最终检查之后、释放之前/之后的窗口）；releaser 释放锁后必须复查 pending（非空则重抢或让位），sender 投递后必须探测锁（空闲则 spawn）。两侧合起来每条消息至少被一方看见。锁必须是进程死亡自动释放的 OS advisory 锁。
- **D5 · 投递通道按 runner 定义。** nulya runner 直投子场 inbox（mid-step 投递是内核白给的，不为对称性放弃）；外部 runner 用 `<d>/inbox/`。pending 检查随通道走。
- **D6 · interrupt = 消息先行 + 标记后写。** runner 在自己流事件的粒度上轮询标记并翻译成各 harness 的方言（nulya：kill 子 step + `session cancel`；codex：`turn/interrupt`；pi：`abort`；claude：控制通道）。
- **D7 · 内置 runner 住包内 enum+switch，第一天按契约形状写。** 不做 vtable、不做 extension dependency；外部 runner = `runner: ext:<id>` + 固定名 internal tool `agent_runner`，创建时解析 current 并**冻结版本**进 record（session freeze 同一哲学）。"搬一个出去不用改 agent"是契约的验收测试（ar-g）。
- **D8 · 内核零改动；delegation 盘面是包私有契约。** 读写双方都是本包与其 runner（契约的一部分），不是要求每个 driver 学的 folklore——不违反"欠答案走 inbox 事件"（报告仍走 `task_finished`）。
- **D9 · 模型选择：nulya runner 照旧 profile/model 三层优先级；外部 runner 用 `runner_model:` 与调用时 `model` 透传（不透明字符串，错误原样回）。** "有什么模型可选"delayed——将来契约可加 `agent_models` verb，现在不做。
- **D10 · readonly fail-closed。** runner 翻译不了 readonly（nulya：gate；codex：`--sandbox read-only`；claude：权限模式；pi：对应机制）就 refuse 整个委派，绝不静默降级。
- **D11 · pre-release 不留兼容。** `session` 参数只认 d-\*；旧的 s-\* 委派没有 record，拒绝并指路重新委派。
- **D12 · Claude 走 stream-json CLI 协议，不走 Agent SDK。** SDK 会把 TS/Python runtime 钉进一个编译 Zig 包；CLI 的双向 stdio 协议就是 SDK 底下用的那条。真需要 SDK 的那天，按 ar-g 把 claude runner 搬成独立扩展再说。

## 4. 参考（先读这些，再动手）

- `extensions/agent/src/main.zig`：`delegate`（:337 双形态分派与门）、`newDelegation`（:404，spawn argv）、`followUp`（:529，四道门——本契约要重排的）、`startRunner`（:600，task run 命令拼装）、`runnerRunning`（:634，**将被 D4 的锁探测取代**）、`turnsSent`（:665，**将被 record 计数取代**）。
- `extensions/agent/src/runner.zig`：整个文件（drive 一轮的现状；带锁循环 + interrupt 轮询要长在这里）；`gateVerdict`（:235，不动）。
- `extensions/agent/src/defs.zig`：`Def`（:34，加 `runner:`）、frontmatter 解析（:208 附近，warn 纪律样板）、`wornPersona`（:423，followUp 侧被 record 取代，`allowedHere` 侧保留）。
- `src/journals/journal.zig`（append-only + 锁 + 残尾纪律的**样板**，不能 import，抄纪律）；`src/cli/task.zig`（supervisor 语义）；`tests/e2e/extension.zig`（bundled-agent 既有 e2e，扩它别新起炉灶）。
- TUI：`tui/src/driver.ts`（pending / kill / step）、`tui/src/ui/App.tsx`、`tui/src/ui/WorkingStatus.tsx`、`tui/src/state/tasks.ts`（`startedTaskOf` 读回执——回执格式变了要跟）、keymap 机制（`tui.toml` `[keymap]`）；tui.md §4.4b / §5.10。
- 构建：Zig 0.16；`zig build test` / `zig build e2e`（e2e 会编译 bundled extensions，慢是正常）；裸 `zig` 命令经 anyzig shim 要写 `zig 0.16.0 …`；`bun test` 必须 `cd tui/`。

## 5. 工作方式

- 分支 `agent-runner`（已建）；实现者**不 commit**——review 后由派发者按子项 commit（`ar-x: …`）。**不 push。**
- 代码注释英文，docs 中文；测试与模块同文件；`zig fmt` 只 fmt 自己改的文件。
- 每完成一个子项在 §6 记一行；卡住 / 契约自相矛盾 → §6 写 `BLOCKED:` 停下。

## 6. 进度区（执行时更新）

- 2026-08-26 · 契约落地，派发 ar-a/b/c（opus）与 ar-t1（sonnet）。
- 2026-08-26 · **ar-a 落地**（无偏离）。新 `extensions/agent/src/record.zig`：`.nulya/delegations/<d>/record.jsonl` append-only（写端持 `record.jsonl.lock` 排他 lease + 修 crash 残尾，读端忽略残尾——纪律抄 `src/journals/journal.zig`，未 import `src/`）；`d-<12 hex>` mint 走 `io.random`（`genSessionId` 同款）；`created` / `turn` 两种行，`runner` / `runner_version` / `remote` / `parent` / `readonly` / `profile` / `model` 冻在开场行。`agent{session}` 只认 d-\*，`s-…` 与形状不对各有一句拒绝并指路（D11）；`followUp` 改名 `sendTurn`，四道门按契约重排（形状 → record 给出 persona → `max_exchanges` 从 record 的 turn 行数 → 「还在跑就拒绝」删除），`runnerRunning` / `turnsSent` 与 `followUp` 里对 `wornPersona` 的那一读一并删除（`allowedHere` 侧的 `wornPersona` 保留）。回执与 `<agent-report … session="d-…">` 改说 d-id，同时仍点名 `remote session s-…` 并在 contract 尾指路 `nulya session events <s-…>`（D2）——**TUI 因此零改动**：`startedTaskOf` 的 `running as background task <sid>/tN` 与 registry 的 `\bs-…\b` 回退都照旧命中（只改了 `tui/src/nulya/ledger.ts` 里一句示例注释）。
- 2026-08-26 · **ar-b 落地**（一处实现细节说明，见下）。send 运行中不再拒绝，nulya arm 直投子场 `session append`（D5）。wake 按 D4 逐字实现：`record.takeLease`（`lock_nonblocking` 的 OS advisory 排他锁，进程死亡自动释放）+ runner 退出序列「锁内查 pending → 释放 → **释放后复查** → 非空则重抢锁继续 / 抢不到退出」+ send 侧「先投消息 → `leaseHeld` 探锁 → 空闲才 `task run`」（`main.wake`）；抢锁失败的 runner **stdout 一个字节都不打**。`runner.zig` 从单轮改成带锁循环（`driveOnce` 一轮 + `max_rounds = 64` 兜底，防「remote 消费不了自己的 inbox 就在一个 task 里空转」；一轮 `code != 0` 且无 assistant 文本即停），报告取本 task 内最后一条 assistant 文本，`gateVerdict` 未动。interrupt = 先投消息 → 写 `<d>/interrupt` → 探锁；runner 在 stream 读循环里每行轮询标记（路径预先算好一次），见到即删标记、跳出读循环、`session cancel` + `child.kill`。
  - **实现细节（非方向偏离，记录以备复核）**：① kill 用 `std.process.Child.kill`，杀的是 `session step` **这一个进程**而不是整棵进程树——树杀要在包内重造一份 `src/environment/tree.zig`（job object / pgid），而契约明确不许 import `src/`；孙进程（step 起的 tool 子进程）由该 step 死后自然收敛，残尾由内核 `completeInterruptedToolBatch` 在下一轮 step 边界修。② 顺序是 `session cancel` **先**、`kill` 后（契约文字未定序）：反过来标记必然留在盘上，而 `prepareStep` 消费 cancel 标记**早于** `drainInbox`，那会让下一轮空转一次。即便如此标记仍可能残留（kill 通常快过 step 走到下一个边界），代价是**至多一轮空转且消息不丢**（`consumeCancel` 在 `drainInbox` 之前返回，消息仍在 inbox）——e2e 实测未出现。③ 一轮开始前先清一次陈旧 interrupt 标记：否则「没人在跑时 interrupt」会让刚起的 runner 打断它自己刚起的那一轮，白付一轮。
- 2026-08-26 · **ar-c 落地**（无偏离）。新 `extensions/agent/src/runners.zig`：`Runner` enum（今天只有 `.nulya`）+ 概念动词 `start` / `send` / `pending` / `stop`（`drive` 是 `runner.zig` 的整个进程，一并按 enum 分派）；`defs.Def.runner` 缺省 `.nulya`，未知值 → `ParseError.UnknownRunner` → warn-and-skip 整个定义（与 `NoFrontMatter` / `NoBody` / `BadName` 同一处 skip）；`render` / `list` 各多一列 `"runner"`；创建时把 `runner` 冻进 record，`run` 从 record 读回它。子进程调用面收进新 `extensions/agent/src/proc.zig`（`Run` / `run` / `detail` / `firstLine`，`main` 与 `runners` 两个 consumer）。既有委派 e2e 语义不变（三条老测试逐字未改仍绿）。
  - **测试**：`zig build test` 495 pass / 2 skip（新增 `record.zig` 3 条：id 形状 + mint、record 开场一次 + 数 turn + 残尾不算数、lease 排他 + interrupt 标记取一次；`runners.zig` 1 条：`runner:` 词表；`defs.zig` 多两条断言）。**build.zig 加了第二个 agent 测试模块**（`record.zig` 自己做 root）——`defs.zig` 够不着它，而 test 只在被分析到的文件里跑。`zig build e2e` 97 pass（agent 6 条：三条老的 + 重写的「d-id / record 计数 / 旧词指路」+ 新的「wake 不变量」+ 新的「interrupt」）。`cd tui && bun test` 393 pass / 0 fail。契约 §2 五条 e2e 覆盖齐：① wake 测试的 ①③（busy 时不拒绝、消息不丢、报告一份一份来）· ② wake 测试的 ①②③（探锁不起第二个 runner / 抢锁失败零输出 / 锁放开后自起）· ③ d-id 测试的 ②③（旁路 `session append` 两条不动预算，第三轮放行第四轮拒）· ④ d-id 测试的 ④ · ⑤ interrupt 测试（子场 ledger 里出现内核的 interrupted-batch 修复文本 + sentinel 进场 + 标记被消费）。
  - **内核 `src/` 零改动**（`git diff --stat` 可查）。文档：DESIGN §7.8 改了四段（tool 表的 `run` 签名、追问那段整段重写为 d-id/record、新增 send-interrupt / wake / `runner:` 三段、报告 sentinel 那句）。CLAUDE.md 现状条目与 tui.md §5.10/§11 未动——前者按派发范围留给 review 后统一收；后者属 ar-t1。
- 2026-08-26 · ar-t1 完成（sonnet）。queue lane（`tui/src/ui/QueueLane.tsx`，输入框上方 WorkingStatus 同区，`pendingCount()===0` 时不画，逐条截一行、点击任一行 = 手势——inbox FIFO 整体排干不假装能单条插队）+ `ctrl+j` 手势（`state/driver.ts` 的 `Driver.interruptAndDeliver`：append（复用 `send`）→ kill（复用既有 `kill`）→ 等 `drive()` 真正退出（新内部 `idleOnce()`，不是"发了 kill 信号"那一刻）→ 立即 `step()`，全程零新状态机；`state/attach.ts` 的 `Attachment.interruptAndDeliver` 按角色分派——driver 原样转发，observer 退化成普通排队 `send`，因为没有自己的写者租约可杀）。`ctrl+j` 走 `keymap.ts` 新增的 `interrupt` action（可 `[keys]` 覆盖），但 App 只在"有步在跑或已有排队"时才用一个有条件的 `keymap.registerLayer`（`interruptRelevant`）去抢这个键——空闲且composer 打字用不到它时原样放行给 composer 自己的 `ctrl+j`→换行绑定（非 Kitty 终端下 Shift+Enter 的退路，同 `closeTab`/`ctrl+w` 那条先例）；composer 侧新增 `ComposerApi.triggerInterrupt()`（复用 `submit()` 的清空/历史/粘贴展开路径，只多一个 flag）。**偏离契约一处，已记录在 `Composer.tsx`/`keymap.ts` 注释里**：契约写"idle 时该手势等价普通发送"，但严格做到"任何时候都抢 ctrl+j"会在非 Kitty 终端上彻底吃掉换行功能（用 `@opentui/core` 的 mock-keys 实测确认：默认编码下 ctrl+j 与裸换行字节在协议层不可区分，是同一个按键）；改为仅在"有意义时"抢键，空闲态该手势退化为略过（`composer.isEmpty()` 时才走 flush-queue 分支，非空但空闲时正常 Enter 路径已经够用）。测试：`cd tui && bun test` **393 pass 0 fail**（40 文件，含并行 ar-a/b/c 那半的 `extensions/agent`/`delegate.test.tsx` 一起绿）；新增 `test/queuelane.test.tsx`（纯 props 渲染 + 点击）、`test/interrupt.test.tsx`（真二进制 + `otherModifiersMode` 让 mock 的 ctrl+j 在协议层可辨识，端到端钉住 kill+redeliver 与 lane 静息态）、`driver.test.ts`/`observer.test.ts` 各加若干条（driver 层 kill+redeliver 正确性、idle 退化、blank-idle no-op；observer 层退化到排队 append）。只改了 `tui/`（`state/driver.ts`、`state/attach.ts`、`keymap.ts`、`ui/Composer.tsx`、`ui/App.tsx`、新增 `ui/QueueLane.tsx`）与本文件这一行；`tasks.ts`/`extensions/`/`tests/`/`src/` 一字未动。
- 2026-08-26 · ar-t2 完成（sonnet，只改 `tui/`）。`render/registry.ts` 的 `agent`/`ext:agent/agent` 分支改抽两样东西：`\bd-[0-9a-f]{12}\b` 是这个 delegation 自己的名字（`ToolPresentation` 新增可选 `delegationId`，head line 用它取代过去的 remote s-id），`\bsession (s-[A-Za-z0-9._-]+)/` 是只有首个 delegate() 回执才会说出口的 remote（`sendTurn` 的回复从不重复它，`sessionId` 因此在那种回执上是 null）。**d→remote 解析**分两层：回执里直接有就用（同步、零开销）；没有就由 `SubSessionCard.tsx` 用新的 `Navigate.delegationRecord(id)`（`state/navigate.ts` 新方法；`App.tsx` 接到 `tui/src/nulya/files.ts` 新增的 `readDelegationRecord`）异步兜底——它按 `extensions/agent/src/record.zig` 自己的 wire 格式读 `.nulya/delegations/<d>/record.jsonl` 的 `created` 行（丢残尾、坏行跳过，纪律照抄同文件里的 `readToolUsage`），走的是 `createResource`，只在 `sessionId === null && delegationId !== null` 时才发起读。**非 nulya runner 的退化**：record 一旦读回 `runner !== "nulya"`，那一行不再猜一个打不开的 tab，改说 `see its log in /tasks (runner: …)`，点击调用新的 `Navigate.openTasks()`（`App.tsx` 接到既有 `openOverlay("tasks")`）——这条路径今天在真实数据里不可达（ar-c 的 `Runner` enum 只有 `.nulya` 一个 arm，未知值整份定义被 warn-and-skip），是为 ar-d/e/f 预留的形状，测试因此只能用手搭的 record/`AgentEntry` 而非真委托。`/agent` picker 同一条尺子：`AgentEntry` 新增 `runner`（`listAgents` 从 `ext run agent list` 的新列读回，老二进制缺列时落回 `"nulya"`），`AgentPicker.tsx` 的 `what()` 只在 `runner !== "nulya"` 时说出来（`runner: codex` 这样一段）——本 build 唯一能跑的 `nulya` 不占地方。**测试**：`registry.test.ts` 重写了唯一一条写死旧回执措辞的断言（新形状：首次回执两个 id 都在、followUp 回执只有 delegation 没有 remote）；`render.test.tsx` 更新既有委托卡片测试的回执文本与 head 断言（`→ d-…` 取代 `→ s-…`），新增两条——followUp 回执触发 record 兜底并正确打开 remote、record 说非 nulya runner 时退化成 `/tasks` 提示且点击调用 `openTasks`；`files.test.ts` 新增 `readDelegationRecord` 的 fixture 测试（本文件一贯只用真二进制写的文件，这里例外并写明理由：`record.jsonl` 的格式是 `extensions/agent` 自己的，不是这一侧写的东西，也不是这一侧要验证「二进制写对了没」——覆盖 created 行、torn tail 丢弃、坏 id / 不存在都是 null）；新增 `agentpicker.test.tsx`（`AgentPicker` 的纯组件测试，因为 `runner` 列今天在真实定义里不可达，只能用手搭的 `AgentEntry` 测）；`agents.test.ts` 补一条 `runner === "nulya"` 的断言。`cd tui && bun test` **397 pass 0 fail**（41 文件）；`bun run typecheck` 干净。**无偏离**；`extensions/`、`tests/`、`src/` 一字未动（工作树里另一条并行任务改动的 `extensions/agent/src/*`、新增的 `extensions/agent/src/codex.zig`、`tests/fake_codex.zig` 不是本轮所碰，`git diff --stat -- tui/` 可单独核对本轮改动）。**一个观察，超出本轮范围未动**：TUI 自己的 `/agent <name> <task>`（`App.tsx` 的 `startAgent`）完全绕过 runner 抽象——它直接拿渲染出的 persona 字节 `session new --prompt`，不看 `entry.runner`；等 ar-d/e/f 落地、`defs.zig` 认下第一个非 `nulya` 的 runner 之后，这条路会把一个写着 `runner: codex` 的 persona 静默当成 nulya session 打开，需要专门处理。
- 2026-08-26 · **ar-d 落地（第一个外部 runner：Codex）**。**协议实测结论**（本机 `codex-cli 0.144.5`，判据是 `codex app-server generate-json-schema --experimental` 生成的权威 schema + 一次真实握手，不是猜的）：`codex app-server` 存在，缺省 `--listen stdio://`；设计预期的五个动词**全部存在且形状与预期一致**——`initialize{clientInfo}`（之后要发 `initialized` 通知，在那之前它什么都不答）· `thread/start{sandbox?, approvalPolicy?, developerInstructions?, baseInstructions?, model?, cwd?, …}` → `result.thread.id` · `thread/resume{threadId, sandbox?, …}` · `turn/start{threadId, input:[{type:"text",text}]}` → `result.turn.id`，随后一串通知直到 `turn/completed` · **`turn/steer{threadId, expectedTurnId, input}` 真的有**（所以 mid-run steer 做了，不是退化成下一轮送）· `turn/interrupt{threadId, turnId}`。两处实测才知道的事：① 传输是**行分隔 JSON-RPC**，且**服务端应答不带 `jsonrpc` 字段**（实测 `{"id":1,"result":{…}}` / `{"error":{…},"id":3}`），所以读端按"有没有 `method`／有没有 `id`"分型；② `thread/start` 与 `thread/resume` 的应答里 **`sandbox` 是必填字段、回报的是实际生效的策略**（实测要 `read-only` 回 `{"type":"readOnly"}`，要 `workspace-write` 回 `{"type":"workspaceWrite",…}`）——D10 的 fail-closed 因此有了一个**可确认**的判据，而不是"送出去就当生效了"。没有 BLOCKED。
  - **设计判断**：**persona → `developerInstructions`**（不是 `baseInstructions`——后者**替换** Codex 自己的操作提示，persona 那样送进去会悄悄让 agent 失去它的 harness；`developerInstructions` 是客户端自己的指令通道，正是 persona 是什么）；**`cwd` 不传**（app-server 继承本进程的 workspace 目录，§7.6，再写一遍是同一问题的第二个答案）。**每轮起一条连接、轮末关掉**（`thread/resume` 是 Codex 自己给出的跨进程续接答案，常驻 daemon 只会在租约之上再加一条生命周期）。**model 原样透传**：`runner: codex` 时 `agent{model}` **跳过 `parseModelRef`**（`Runner.usesNulyaModels()` 一处判定），与定义的 `runner_model:` 同一个不透明字符串，优先级仍是**调用 > 定义**，但**不继承父场**（nulya 的 profile 不是 Codex 听说过的名字）；错误由 Codex 原样回上来。哪一套词汇生效由 `runner:` 决定，另一套在 front matter **读完之后**整体丢弃并点名（`defs.crossCheck`——读完再判，因为定义可以按任意顺序写字段）：外部 runner 上 `model:` 单独一句（它是**另一套模型词汇**，指路 `runner_model:`），`pins` / `agents` / `max_steps` 合成一句（它们描述的是**一场 nulya session** 的组合，外部 harness 自己组合自己的；三句关于同一个错误只会把要改的那一处埋掉）。**`max_exchanges` 不清**——它数的是 record 的 turn 行，每个 runner 都有。清而不是留着的理由就是这个函数存在的理由：一个静默不起作用的字段最坏，`agents: [explore]` 写在 codex persona 上会被读成"这个能委派"，而那一场根本没有那个 tool。**readonly fail-closed**：要 `sandbox: "read-only"` 之后**检查回报**，不是 `readOnly` 就拒绝——创建时拒绝整个委派（什么都不建，连 `.nulya/delegations/` 都不出现），resume 时拒绝接手这一轮；非 readonly 用 `workspace-write`（Codex 对非交互运行自己的姿态；`danger-full-access` 比任何定义要过的都宽），两种都 `approvalPolicy: "never"`（后台任务旁边没有人），仍然发来的 server request 一律以 JSON-RPC error 回绝（对**每一种**请求都合法的唯一一种回答）。**steer / interrupt 的顺序**：读事件流的循环里**永远先看 interrupt 标记、再排干 inbox**——两样东西同时在盘上（D6 是先送消息后写标记），先看标记才保得住那条消息，否则它会被 steer 进一轮马上要被砍掉的回答里。`runners.stop` 在 codex arm 上是**空的**并写明理由：停一轮 turn 要在正驱动它的那条连接上按名字点出 turn，那两样事实只有驱动进程有，所以 codex 的 interrupt 是**带内**的。
  - **改了什么**：新 `extensions/agent/src/codex.zig`（App Server 客户端 + 一轮 drive，协议契约写在模块注释顶部）；`runners.zig` 加 `.codex` arm（`start` = 起 app-server 开 thread、handle 是 thread id / `send` = 写 `<d>/inbox/` 一文件一消息 / `pending` = 该目录非空 / `stop` = 空）+ `usesNulyaModels()` + `remoteLabel`/`transcriptHint`（回执与报告共用一处，否则两句话会指向两个不同的东西）；`runner.zig` 的 drive 循环改为**按 `Backend` union 分派**（租约 / release-and-recheck / interrupt 标记 / 报告框架仍各写一遍，**wake 不变量一个字没动**）；`record.zig` 加 `<d>/inbox/` 的 `inboxPut`/`inboxTake`（`<12 位数字>.json`，独占创建取第一个空号，名字怎么排就怎么数；take 而不是 read，因为 `pending` 要在 runner 拿到之后变假）+ `runner_model` 列；`defs.zig` 加 `runner_model` 与 `crossCheck`；`main.zig` 把 model 的解析**推迟到知道 runner 之后**（一个字符串两种语法，只有拿着定义的那一处知道是哪种）、把 `readonly` 传给 `start`（拒绝发生在开场，不是等到驱动）、`render`/`list` 各多一列 `runner_model`。**内核 `src/` 零改动、`tui/` 零改动**（`git diff --stat -- src/` 为空）。
  - **测试**：`build.zig` 为 e2e 编译 `tests/fake_codex.zig`（只答那六个动词的 app-server，装在 `zig-out/test-bin/`、经 `NULYA_FAKE_CODEX` 交给测试、测试再用 `NULYA_CODEX_EXE` 指过去）。**它刻意不在 turn 进行中读 stdin**：那需要线程或非阻塞读才不会与同样在阻塞读的客户端互锁，而换来的只是把 steer 折进答案里——测试真正需要的是**证据**（runner 在对的时刻发了对的请求），所以每个请求进 `FAKE_CODEX_LOG`，turn 中收到的那些在 turn 结束后照样落进去；turn 的长短由 `FAKE_CODEX_HOLD` 这个文件的存在与否从外面决定，测试因此不与它赛跑。三条新 e2e：① 全环（回执说 `codex thread` 而不是 session、record 冻下 `runner:"codex"` / `runner_model` / `remote`、报告经 `task_finished` 回父场且引用了任务原文、**idle send 走 `<d>/inbox/` 并被下一轮排干**、exchanges 从 record 数）——顺带钉住 `model:"/nope"`（nulya 会当场拒绝的字符串）在 codex 上原样通过；② 运行中送一条 → `turn/steer`、interrupt → `turn/interrupt`（等的是 runner 自己的盘面事实：inbox 空了 = 它取走了消息、marker 没了 = 它取走了标记，不猜时间）；③ readonly fail-closed（同一个定义、只有 `FAKE_CODEX_SANDBOX` 不同：回 `workspaceWrite` 就 exit 1 且**什么都没建**，回 `readOnly` 就正常开场）。新单测：`record.zig` inbox 的 FIFO + 取一次（4 条）、`runners.zig` 词表与 `usesNulyaModels`（2 条）、`defs.zig` 的 runner/model 词汇互斥且与书写顺序无关（1 条）；老单测 `runner: codex` → `UnknownRunner` 那条改成 `runner: borges`（codex 现在是个 runner 了）。结果：`zig build test` **498 pass / 2 skip**、`zig build e2e` **100 pass**（97 → 100）。**三条老 nulya 委派 e2e 与 ar-a/b/c 的新 e2e 语义未动、逐字未改。**
  - **文档**：DESIGN §7.8 新增「第一个外部 runner：`runner: codex`」整段（协议 / persona / 通道 / 顺序 / readonly / 模型 / 报告 / 离线可测八条），并把 `runner:` 那段的"今天只有 `.nulya` 一个 arm"更新为两个 arm + `drive` 按 backend 分派。guide skill 在「Sessions and drivers」补一条 bullet（agent 定义文件是什么、`runner:` 两个词、`runner_model:` 与 `model:` 的分工）——那一节此前完全没有提过 agent 定义的 frontmatter，所以是新增而不是修订。CLAUDE.md 现状条目按派发范围留给 review 后统一收。
  - **review 修补（2026-08-26，随 ar-d 一起 commit）**：steer 原是 fire-and-forget——消息已被 `inboxTake` 取走，若 turn 恰在此刻结束、Codex 按 `expectedTurnId` 拒绝这次 steer，消息就永久丢失（违反 D4「accept 的消息终有人 drive」）。修法：每个 steer 记下 `{id, text}`（`codex.Steered`），读循环里它的应答由 `settleSteer` 结算——确认即除名，**拒绝则 `inboxPut` 放回**，下一轮（或探锁后自起的新 runner）接手；`turn/completed` 到达时若仍有未结算的 steer，**继续读到每一个都有应答**再返回（协议保证每个 request 都有 reply，故有界）。修补后 `zig build test` / `zig build e2e` 仍全绿。
  - **一处交接给 review 的已知缺口（本轮范围外，未动）**：ar-t2 记的那条观察现在**真的可达**了——TUI 自己的 `/agent <name> <task>`（`tui/src/ui/App.tsx` 的 `startAgent`）绕过 runner 抽象，直接拿渲染出的 persona 字节 `session new --prompt`，不看 `entry.runner`；一个写着 `runner: codex` 的 persona 从 TUI 的 `/agent` 起，会被静默当成一场 nulya session 打开（从**模型**调 `agent{name}` 走的是正确的路）。修法属 `tui/`，本轮硬性约束是 `tui/` 一字不改。
- 2026-08-26 · **ar-f 落地（第二个外部 runner：Claude）**。**协议实测结论**（本机 `claude` 2.1.246；判据是 `claude --help` 的完整选项表 + 从**已安装的那个二进制**里取出的 stdin/stdout 消息 schema（它把 zod schema 与 describe 文本一起打进了可执行文件）+ 官方 headless / Agent SDK 文档，**没有起过任何一个真的联网的 claude 进程**——这台机器上的 `claude` 正是跑本任务的 CLI）：① 双向协议存在且形状与预期一致——`claude -p --input-format stream-json --output-format stream-json --verbose`，stdin 一行一个 `StdinMessage`，stdout 一行一个 `StdoutMessage`。② **写进去的 user turn 是 `{"type":"user","message":{"role":"user","content":"…"},"parent_tool_use_id":null}`**——`parent_tool_use_id` 在 schema 里是 `.nullable()` **不是** `.optional()`（required-nullable），所以显式写 `null`；`message` 是一个 Anthropic MessageParam。③ **interrupt 走 control 通道，确实可用**：`{"type":"control_request","request_id":"…","request":{"subtype":"interrupt"}}`（二进制里 `subtype:"interrupt"` 的构造点与 `sendControlRequest({subtype:"interrupt"})` 都在，SDK 的 `interrupt()` 用的就是它），回 `{"type":"control_response","response":{"subtype":"success"|"error","request_id":…}}`——**没有退化成 kill 进程**。④ 会话续接：`--session-id <uuid>`（必须是合法 UUID）开一场、`--resume <id>` 接上，两个 flag 分工明确（文档对每一个都是这么写的；`--session-id` 在已存在的 id 上会不会 resume 无法在不联网的情况下实测，所以**不依赖它**——见下）。record 的 `remote` 存那个 uuid。⑤ **readonly 有可确认的判据**：`system/init` 是每一轮的第一条消息，schema 是 `{type:"system",subtype:"init",cwd,session_id,tools:string[],mcp_servers:[{name,status}],model,permissionMode,…}`，其中 `tools` 是 `t.tools.map(o => Et(o.name))`——**这一场真正在场的 tool 列表**。⑥ 无人应答时 `ask` 是**终结性的**（二进制里那句 describe：`Without one (bare -p / SDK query() with no canUseTool), 'ask' decisions are terminal`），所以后台任务不会卡在审批上。没有 BLOCKED。
  - **设计判断**：**readonly = 机制 + 回声**。机制取**可用性**（`--tools "Read,Glob,Grep,NotebookRead,TodoWrite"`）而不是审批（`--permission-mode plan` / allow-list）：不在这一场里的 tool 没有任何路径够得到，而且它恰好是回声唯一能报的一半；配 `--permission-mode dontAsk`（never-ask 且拒绝一切不在规则里的）与 `--strict-mcp-config`（不带 `--mcp-config` 时等于零个 MCP server）。检查是 `system/init` 的三样：`permissionMode` 必须正是要的那个 · `tools[]` ⊆ 只读集合 · `mcp_servers` 为空。**并且顺序也强制**：readonly 期间在 `init` 之前看到任何「模型开始干活」的行（`assistant`/`user`/`stream_event`/`tool_progress`/`result`）一律拒绝并杀进程——事后才检查的天花板不是天花板。**如实记下的一条**：Claude 的权限 flag 是它自己强制的，我们能确认的只有它自己报回来的那句话，不像 codex 的 sandbox 有一个「我实际应用了什么」的独立字段；这已写进 `claude.zig` 的模块注释与 DESIGN §7.8。**与 codex 的一处诚实差别**：Claude 没有「开一场对话」这个动词（session 在第一次 `claude -p --session-id …` 跑起来时才诞生），所以 readonly 的拒绝发生在**第一轮的第一行**而不是创建时，创建时能验的只有「这台机器上有没有 claude」——codex 那条 e2e 断言的「什么都没建」在这一 arm 上不成立，改为断言「这一轮什么都没产出」。非 readonly 用 `--permission-mode acceptEdits`（Claude 自己对「在 checkout 里干活的 agent」的姿态；`bypassPermissions` 就是这一侧的 `danger-full-access`，比任何定义要过的都宽）。**`--session-id` vs `--resume` 用盘上一个事实分**（`<d>/claude.started`，第一次真的看见 `system/init` 时写下）：这样在**两种语义下都对**（就算 `--session-id` 其实也能 resume，后来的轮次用 `--resume` 仍然正确），而一次「开场前就死了」的尝试下次仍然是创建。**mid-turn steer 不做，而这不是让步**：Claude 对运行中到达的消息本来就是排队、在当前这一轮之后投递——与在 `<d>/inbox/` 里等一模一样，只是我们的 inbox 活得过进程死亡；于是**一轮只取一条消息**（新 `record.inboxTakeOne`），取走就立刻写下去、读到 `result` 为止，中途出任何事原样放回——D4 在这一 arm 上因此是平凡的，不需要 codex 那套 `settleSteer`。**persona 冻进 `<d>/persona.md`**：Claude 每轮从 flag 重建 prompt，没有这份拷贝，定义文件一改这个 delegation 就悄悄变成别人；它作为 `--append-system-prompt` 的参数送出（16 KiB 上限并说明理由——`--append-system-prompt-file` 收路径但它在 `--help` 里是隐藏的）。**`runner_version` 从占位变成有内容**：`claude --version` 在开场时问一次并冻进 record（`runners.Started{run, version}`，codex/nulya 留空）。
  - **改了什么**：新 `extensions/agent/src/claude.zig`（协议契约写在模块注释顶部）· `runners.zig` 加 `.claude` arm + `Started` + `StartOptions.delegation`（**d-id 提前到 `start` 之前 mint**，因为这一 arm 要往 `<d>/` 里冻 persona）· `runner.zig` 的 `Backend` 加一个 arm，并把 `runner_model` 从 record 读回来交给 `openBackend`（外部 harness 的模型是**每轮的 flag**，不像 nulya 冻在 header 里）· `record.zig` 加 `inboxTakeOne` / `mintUuid` / `freezePersona` + `persona_name`（三样都被两个新 arm 共用，所以住在 record 而不是某一个 arm 里）· `main.zig` 三处跟随。**内核 `src/` 与 `tui/` 一个字未改**（`git diff --stat -- src/ tui/` 为空）。
  - **测试**：`tests/fake_claude.zig`（`build.zig` 为 e2e 编译，经 `NULYA_FAKE_CLAUDE` → `NULYA_CLAUDE_EXE`）。与 `fake_codex` 同款手法：argv 与每条 stdin 消息进 `FAKE_CLAUDE_LOG` 作证据，turn 长短由 `FAKE_CLAUDE_HOLD` 从外面控制，`FAKE_CLAUDE_TOOLS` / `FAKE_CLAUDE_MODE` 是回声的两个杠杆。三条新 e2e：① 全环（回执说 `claude session`、record 冻下 `runner:"claude"` / `runner_version` / `runner_model:"/nope"`（nulya 会当场拒的字符串在这里原样通过）· persona 冻在 `<d>/persona.md` · 报告经 `task_finished` 回父场并引用任务原文 · 第一轮 argv 里是 `--session-id <uuid>` 且**没有** `--resume` · idle send 走 `<d>/inbox/`、下一轮**是 `--resume <uuid>`** · exchanges 从 record 数）② interrupt（跑到一半送一条带 `interrupt:true` → 标记被取走 → log 里有 `control_request interrupt` → 那条消息由下一轮答出）③ readonly（同一个定义，只有 `FAKE_CLAUDE_TOOLS` 不同：报 `Read,Glob,Write` 就拒绝这一轮且**不产出报告**，默认就正常跑完；并断言 argv 里真的有 `--tools …` / `--permission-mode dontAsk` / `--strict-mcp-config`）。
- 2026-08-26 · **ar-e 落地（第三个外部 runner：Pi）**。**协议实测结论**（本机装了 pi：`where pi` 命中 mise 的 node 目录，`pi --help` 正常。判据是 `pi --help` + **随包分发的 `docs/rpc.md`**（这是三个外部 harness 里唯一把协议当文档写出来的）+ 直接读 `dist/` 里的实现（`modes/rpc/rpc-mode.js`、`main.js` 的 `createSessionManager`、`core/tools/index.js`、`core/resource-loader.js`），全程离线）：① `pi --mode rpc` 存在，JSONL 严格以 LF 分隔（文档明确警告不要用会在 U+2028/U+2029 上断行的 reader）。② 设计预期的动词全在：`prompt` / `steer` / `follow_up` / `abort`，外加 `get_state` / `get_last_assistant_text` / `new_session` 等；响应是 `{"type":"response","command":…,"success":…}`，事件是另一套 `type`。③ **一轮的终点是 `agent_settled` 而不是 `agent_end`**——后者是一次底层 run 结束，后面还可能跟自动重试、压缩重试或排队的续跑。④ **`--session-id <id>` 一个 flag 既开也续**（`createSessionManager`：本 project 里有这个 id 就 open，没有就 stderr 警告一句并用那个 id 新建）——所以这一 arm 不需要 claude 那个 `<d>/claude.started`。⑤ **`--append-system-prompt <值>` 在值是一个存在的路径时读文件**（`resolvePromptInput`），于是 persona 直接交路径，命令行长度不成问题。⑥ 内建 tool 恰好七个：`allToolNames = ["read","bash","edit","write","grep","find","ls"]`。⑦ **没有 tool 回声**：`get_state` 回的是 model / thinkingLevel / isStreaming / 队列模式 / sessionFile / sessionId / 计数，**没有 tool 列表**，协议里也没有别的地方有。没有 BLOCKED。
  - **设计判断**：**readonly = 可强制的机制 + 事件流上的检查**（这正是「没有可确认的判据时按『可强制的机制』标准取舍并记录」那一条）。机制是 `--tools read,grep,find,ls`——它是一张覆盖 pi **全部** tool 来源（内建 / extension / 自定义）的 allowlist，由 pi 自己强制；检查是 `tool_execution_start`（协议里唯一会逐个报出「某个 tool 正在开始」的东西），一个落在读集合之外就 `abort` + 拒绝这一轮。**如实记下它比另外两个弱**：它拦在第一个 tool 而不是第一个字之前，因为这套协议给不出更强的；写进了 `pi.zig` 的模块注释与 DESIGN §7.8。**`steer` / `follow_up` 一个都不用**（虽然都存在）：两者都会把消息交给一个可能与进程一起死掉的队列，而它们买到的东西——当前这一轮之后投递——正是在 `<d>/inbox/` 里等本来就会给的（D3）；要把边界提前就是 `abort`（D6）。其余与 claude arm 逐位同构：一 task 一进程、一轮一条消息、persona 冻进 `<d>/persona.md`、`pi --version` 冻进 `runner_version`、模型是不透明字符串走 `--model`。
  - **改了什么**：新 `extensions/agent/src/pi.zig` + `runners.zig` / `runner.zig` 各多一个 arm；`record.zig` 的三样共用件（`inboxTakeOne` / `mintUuid` / `freezePersona`）一行未再改——**第二个外部 arm 没有让任何共用件长出新形状，这本身就是 ar-c 那层抽象的验收**。**内核 `src/` 与 `tui/` 一个字未改。**
  - **测试**：`tests/fake_pi.zig`（`NULYA_FAKE_PI` → `NULYA_PI_EXE`；杠杆 `FAKE_PI_LOG` / `FAKE_PI_HOLD` / `FAKE_PI_TOOL`）。三条新 e2e，与 claude 那三条一一对应：① 全环 + `--session-id` 一个 flag 两用 + persona 走路径 + record 三列 + exchanges ② interrupt → `abort`，消息由下一轮答出 ③ readonly：`FAKE_PI_TOOL=write` 就停掉这一轮且不产出报告、`=read` 就正常跑完，并断言 argv 里真的有 `--tools read,grep,find,ls`。（readonly 那条**没有**断言 log 里有 `abort`：拒绝之后进程立刻被关掉，fake 来不及把它读回来记下——而 `abort` 真的下了线由 interrupt 那条钉住。）
  - **结果**：`zig build test` **499 pass / 2 skip**（+1：`record.zig` 的 uuid 形状；`runners.zig` 的词表与 `usesNulyaModels` 各多两句断言）· `zig build e2e` **106 pass**（100 → 106）· `cd tui && bun test` **397 pass 0 fail**。**三条老 nulya 委派 e2e、ar-a/b/c 的新 e2e、ar-d 的三条 codex e2e 全部逐字未改、语义未动。**
  - **文档**：DESIGN §7.8 新增「第二个外部 runner：`runner: claude`」与「第三个外部 runner：`runner: pi`」两整段，并把 `runner:` 那段的「两个 arm」更新为四个 + `runner_version` 从占位变成有内容那句。guide skill 的 runner 词表补上 `claude` / `pi` 与「readonly 在每个 runner 上都算数」。CLAUDE.md 现状条目按派发范围留给 review 后统一收。
  - **一处交接给 review 的观察（本轮范围外，未动）**：ar-d 记的那条 TUI 缺口现在多了两个 arm——`tui/src/ui/App.tsx` 的 `startAgent` 仍然不看 `entry.runner`，一个写着 `runner: claude` / `runner: pi` 的 persona 从 TUI 的 `/agent` 起会被静默当成一场 nulya session 打开（从模型调 `agent{name}` 走的是正确的路）。另外：claude/pi 的 remote 是 UUID，而 `tui/src/render/registry.ts` 抽 delegation 用的那个 `d-` + 12 位十六进制的模式，在「第四段恰好以 d 结尾」的 uuid 上会有一次多余的匹配（回执里真正的 `d-…` 排在更前面，取首个匹配就没事）——两条都属 `tui/`，本轮硬性约束是 `tui/` 一字不改。
  - **review 核实（2026-08-26，随 ar-e/f 一起 commit）**：上面两条交接**都不需要动作**——① `startAgent` 的 runner 守卫在 ar-t2 的 commit `3739cf5` 里已经加了（非 nulya persona 从 `/agent` 起被当场拒绝并指路「在对话里委派」），两轮 agent 因被禁改 `tui/` 只是转抄了修复前的观察；② UUID 误匹配不成立：`\bd-` 要求 `d` 前面是非词字符，而 UUID 第四段里任何 `d` 的前一个字符必是十六进制（词字符），词边界不成立、不会匹配。另记一笔：全套 e2e 在一次与 `bun test` 并行的高负载运行中偶发失败过一次（未捕获到具体条目），随后连续三次全绿——与既知的「lease / 时序类测试高负载下会 flake」一致，复现时用 `-Dtest-filter` 定位。
- 2026-08-26 · **ar-g 落地（外置 runner + 契约定稿）**。`runner: ext:<id>` 是第五个 arm，也是最后一个需要写在这个包里的：**契约见 §7**（两个 op、参数表、输出表、最短配方），同一份还写在 `extensions/agent/src/external.zig` 模块注释、DESIGN §7.8 与 guide skill。
  - **形状判断**：① `Runner` 从 enum 变**tagged union**，`.ext` 带一个 payload——**存整个词** `"ext:<id>"` 而不是拆出来的 id，因为那个词正是 record 冻下来、`list`/`render` 报出去的东西，一个字段两处拼装就是两个答案（`extId()` 只是它的后缀）；`label()` 因此不需要 allocator。旁路字段（`Runner` 保持 enum + `Def.runner_ext`）被否掉：一个只在某个 tag 下有意义的字段是"一个决定在两层各做一遍"。② 解析纪律不变：`ext:` 后面不是一个合法 extension id（`manifest.isValidId` 的同一条规则）就是 `null` → `UnknownRunner` → **skip 整个定义**，与拼错一个词完全同价。③ **`agent_runner` 一个固定名 + 一个 `op` 参数**，不是两个 tool：D7 的原文就是"固定名 internal tool"，而"哪个 tool 驱动一轮"不该是定义要携带的决定。
  - **契约的两处判断，都记在这里**：① **输出是 stdout 的 JSON 对象，不是"stdout 就是报告文本 + 退出码词表"**。理由是 ext-review-3 Lane W 那条纪律（退出码不做词表）在这里同样成立——一轮要回的是内置三个 arm 的 `RoundResult`（text / interrupted / failure），把 interrupted 编进第三个退出码会让"做成了但结果不同"和"没做成"共用一个数字；而 driver-facing 的 tool 打 compact JSON 在这个仓库里本来就是先例（`render` / `list` / `compact` / `handoff`）。于是：**exit 0/非 0 = wire 已有的两值语义**（非 0 时 stderr 就是话），细分在 JSON 里。派发说明里写的"stdout = 本轮报告文本；exit code 语义"因此只落实了一半，这是有意的偏离，理由如上。② **`message` 走文件（`message_file`）而不是 `--arg message=<64KB>`**：Windows 整条命令行 32 KiB，而 `max_task_bytes` 是 64 KiB——`--arg` 传任务在这台机器上会直接 spawn 失败。`persona` 本来就是路径，于是契约成一条干净的规矩：**两段文本走路径，其余走值**。`<d>/message.txt` 进 `record.zig` 的盘面注释（它是 delegation 布局的一部分，不是某个 arm 的私产）。
  - **`idle` 不在契约里**：inbox 空时 agent 包**根本不调** `op=round`（消息是这边取的——取走才能让 `pending` 变假，D4 是这边的不变量），所以 runner 永远不需要表达"没什么可做"。这是"契约里少一个词"而不是"少一个能力"。
  - **版本冻结的实现**：`current` 由 `external.resolveCurrent` 问**内核自己的 `ext list`**（第一列 id、第二列版本，`(shadowed)` 的行跳过），不在包里重造一份 root 顺序 / `current` 语义；两种失败分开说（没建过 → 指 `ext build`；建了没 activate → 指 `ext activate`），因为改法不同。纯函数 `versionIn` 抽出来带单测，`build.zig` 因此多了**第三个 agent 测试模块**（`external.zig` 自己做 root——`defs.zig` 够不着它，`record.zig` 的同一条先例）。
  - **验收：这次外置改了 agent 包里的哪几行。** **`main.zig` 与 `defs.zig` 一个字未改**（0 行）——委派的入口、四道门、白名单、depth、render/list 的投影全都不需要知道有这么一个 arm。`record.zig` **+1 行代码**（`message_name` 常量）+ 布局注释。`runner.zig` **+36 行代码**：`Backend` 多一个 arm、`driveOnce` 多一个 case、`openBackend` 多一个分支、外加从 record 多读回一列 `runner_version`——**wake 不变量（租约 / release-and-recheck / 报告框架）一个字未改**。`runners.zig` **+81 行代码**，其中约一半是 `Runner` 那个词本身（union + `parse`/`label`/`extId` + 两条新单测），另一半是 `start` 的 `.ext` arm（解析版本 → 冻 persona → `op=open`）与四个 switch 上各加一个标签。新文件 `external.zig` 410 行 = 那个 arm 的方言，与 `pi.zig`（440）同量级——**"搬出去 agent 几乎不用改"成立的具体形状是：入口零改动，循环加一个分支，其余是新方言。**
  - **一处如实记下的代价**：`op=open` 被拒绝时，`<d>/persona.md` 已经写下了（persona 必须先于 open 存在——runner 要拿它开对话）。所以 codex 那条 e2e 断言的"连 `.nulya/delegations/` 都不出现"在这一 arm 上不成立，改成断言**没有任何 record**——record 才是"这条 delegation 存在"的判据（`read` 回 null = 不存在），一个孤零零的 persona 文件不被任何东西读到。删掉那棵树是 3 行，但"失败路径上删目录"不值得为一个没有读者的文件引入。
  - **测试**：e2e 里的 runner extension 是一个**脚本** extension（`run.ps1` / `run.sh`，`tests/e2e/extension.zig` 里写出来、经真实的 `ext build` + `ext activate` 装进 workspace store）——**这本身就是验收的一部分**：第三方接一个 harness 不需要 zig、不需要动这个仓库。三条新 e2e：① 全环 + **版本冻结**（开场冻 v1 → 中途 build+activate v2 → 追问仍由 v1 答出，log 里没有 `round v2`）+ record 三列 + persona 冻在 `<d>/` + 报告经 `task_finished` 回父场 + 消息走 `<d>/inbox/` + exchanges 从 record 数 ② readonly fail-closed（同一个定义，只有 runner 那侧的开关不同：拒绝时 exit ≠ 0、runner 自己那句话到得了模型、**没有任何 record**；接受时正常跑完）③ **interrupt 过界**（hold 住一轮 → 带 `interrupt:true` 送一条 → runner 取走标记、报 `{"interrupted":true}` → 下一轮答出那条消息，而被砍掉那一轮的答案不进报告）。结果：`zig build test` **501 pass / 2 skip**（499 → 501：`runners.zig` 的 `ext:` 词表、`external.zig` 的 `versionIn`）· `zig build e2e` **109 pass**（106 → 109）。**既有 106 条 e2e 逐字未改、语义未动；内核 `src/` 与 `tui/` 一个字未改**（`git diff --stat -- src/ tui/` 为空）。
  - **文档**：本文件 §1（ar-g 划掉）与新 §7 · DESIGN §7.8 新增「runner 可以住在别的扩展里」整段并把 `runner:` 那段的"四个 arm"更新为五个 · guide skill 在 agent 定义那条 bullet 后面补一条完整配方（两个 op 的表 + manifest 骨架 + 装法与版本冻结那句）。CLAUDE.md 现状条目按前几轮的先例留给 review 后统一收。
  - **交接给 review 的一点**：TUI 侧 `render/registry.ts` 与 `AgentPicker` 判断"非 nulya runner"用的是 `runner !== "nulya"` 的字符串比较，`ext:<id>` 天然落在正确的一侧（显示 runner 名、退化成 `/tasks` 提示、`startAgent` 当场拒绝），所以本轮 `tui/` 无需改动；但 `/ext` 那张表不会告诉任何人某个扩展是一个 runner（manifest 里也没有说"我是 runner"的字段——`agent_runner` 这个名字就是全部声明）。要不要让前端认出它，属于 ar-t 系列的下一轮判断。

## 7. `agent_runner` 契约（ar-g 定稿）

> 这一节是**给第三方看的**：接一个新 harness 要写的全部东西。同一份契约还写在
> `extensions/agent/src/external.zig` 的模块注释（代码旁边那一份）、DESIGN §7.8（内核视角）
> 与 guide skill（模型按需读到的那一份）。四处**同一件事只说一次的那部分不同**：这里是完整表格，
> external.zig 是实现旁的契约，DESIGN 是它在这套系统里的位置，guide 是最短配方。

### 7.1 一个 runner extension 是什么

一个普通 extension（脚本或编译都行，脚本更常见——不需要 zig），**声明恰好一个 tool，
名字必须是 `agent_runner`，`surface: "internal"`**（它是 driver 的工具，永不上模型面）。
定义文件写 `runner: ext:<id>` 就用它。

装法与别的扩展一模一样：`nulya ext build <path>` → `nulya ext activate <id> <version>`。
**`current` 只在一条 delegation 开场时解析一次**，`v-…` 冻进 record 的 `runner_version`，
之后那条 delegation 的每一轮都调那个确切版本——activate 新版本决定的是**下一条**
delegation 跑在什么上（physics #2 在包外的推论）。

调用形式（agent 包自己拼，第三方只要知道参数怎么到达）：

```
nulya ext run <id>@<v-…> agent_runner --arg op=… --arg delegation=… …
```

参数按 §7.3 的 plain wire 到达：**stdin 一个 JSON 对象**，同时 **`NULYA_ARG_<key>`
进环境**（字符串原样、布尔是 `true`/`false` 的文本）。空值的参数**根本不传**，所以
`NULYA_ARG_model` 不存在就是"这次没点名模型"。

### 7.2 两个 op

| 参数 | `op=open` | `op=round` | 是什么 |
|---|---|---|---|
| `op` | `open` | `round` | 这次要它做什么 |
| `delegation` | ✓ | ✓ | `d-<12 hex>`；它的盘面在 `.nulya/delegations/<d>/` |
| `persona` | ✓ | ✓ | **路径**：冻结的 system prompt（`<d>/persona.md`） |
| `permissions` | ✓ | ✓ | `readonly` / `default` / `unsafe`（ar-h）。`readonly` 是一个**天花板**，管不了就拒绝（D10）；**认不出的词也要拒**——把没见过的档读成自己的缺省，就是放宽一个没看懂的天花板 |
| `model` | 可选 | 可选 | 不透明模型字符串，那个 harness 自己的词汇（D9） |
| `remote` | — | ✓ | `open` 回的那个 handle |
| `message_file` | — | ✓ | **路径**：这一轮要答的**那一条**消息（`<d>/message.txt`） |
| `interrupt` | — | ✓ | **路径**：一个标记文件，出现了就是"停下"（D6） |

**输出**（stdout 一个紧凑 JSON 对象；未知键忽略，留给以后长）：

| | 成功（exit 0） | 失败（exit ≠ 0） |
|---|---|---|
| `open` | `{"remote":"<handle>"}`——任何能让后来的一轮找回这场对话的字符串 | **拒绝整条委派**：stderr 就是原因，一路回到模型面；record 不写、delegation 不存在 |
| `round` | `{"text":"<本轮最终答案>"}`，被打断时 `{"text":"","interrupted":true}` | 这一轮没跑成：stderr 是原因，**那条消息退回 `<d>/inbox/`** 等下一轮 |

**两段文本走路径而不是值**：一个 persona 和一个任务想多长有多长，而 Windows 把整条命令行封在
32 KiB。其余都是短标量。

**exit code 不做词表**（ext-review-3 Lane W 的同一条纪律）：0 = 做成了，非 0 = 没做成、stderr 是话。
`interrupted` / `idle` 这类"做成了但结果不同"的区别在 **stdout 的 JSON 里**，不在退出码里。
（`idle` 根本不需要表达：没有消息时 agent 包不会调 `op=round`。）

### 7.3 谁负责什么

**留在 `extensions/agent` 的**（runner 一个字都不用管）：delegation 身份与 record（D2）·
exchange 预算 · `<d>/inbox/` 与消息顺序（D5）· runner 租约与 release-and-recheck（D4）·
"标记写在消息之后"（D6）· 报告框架与经 `task_finished` 回父场 · 权限档的**拒绝路径** ·
persona 的冻结与消息的 staging。

**归 runner 的**：怎么跟那个 harness 说话。仅此。

**interrupt 是带内的**：能停下一轮的只有正在驱动它的那个进程，所以 `runners.stop` 在这一 arm
上是空的，marker 路径交给 runner——它自己轮询、自己删、自己翻译成那个 harness 的停止动词。
删掉标记就是"我接住了"；不删的 runner 不会崩，只是那一轮打不断（下一轮开始时 agent 包会清掉
陈旧标记）。

### 7.4 最短配方（一个 echo runner，POSIX sh）

```sh
#!/bin/sh
cat >/dev/null                       # 参数也在 stdin 上；不读就把管道晾在那儿
if [ "$NULYA_ARG_op" = "open" ]; then
  case "$NULYA_ARG_permissions" in
    readonly) echo "cannot enforce read-only" >&2; exit 1 ;;   # 管不了就拒绝（D10）
    default|unsafe) ;;                                         # 翻译成这个 harness 的说法
    *) echo "unknown permission level" >&2; exit 1 ;;          # 没见过的档也拒
  esac
  printf '{"remote":"%s"}' "$NULYA_ARG_delegation"; exit 0
fi
msg=$(cat "$NULYA_ARG_message_file")
# …把 $msg 交给那个 harness，拿回它这一轮的最终答案…
printf '{"text":"heard: %s"}' "$msg"
```

manifest 那一半：

```json
{ "schema": "nulya.extension/v2", "id": "my-runner",
  "runtime": { "entry": "src/run.sh", "interpreter": "sh" },
  "contributes": { "tools": [{ "name": "agent_runner", "surface": "internal",
    "description": "Drive one round of a delegation on <harness>.",
    "input": { "type": "object", "properties": {
      "op": {"type":"string"}, "delegation": {"type":"string"},
      "remote": {"type":"string"}, "persona": {"type":"string"},
      "message_file": {"type":"string"}, "interrupt": {"type":"string"},
      "model": {"type":"string"}, "permissions": {"type":"string"} },
      "required": ["op"] } }] } }
```

用它：`.nulya/agents/<name>.md` 的 frontmatter 写 `runner: ext:my-runner`
（模型可选的话再写 `runner_model:`），正文是 persona。`pins` / `agents` / `max_steps` /
`model:` 描述的是一场 nulya session，写在这里会被丢掉并点名——`max_exchanges` 例外，
它数的是 record 的 turn 行，每个 runner 都有。
- 2026-08-26 · **review 附记（随 ar-g commit）**：全套 e2e 的偶发失败第二次出现（六次运行中两次），这次抓到部分现场——某条在测试里经 `ext build` 调宿主 zig 编译的用例报 `unable to read results of configure phase`，指向 zig 编译缓存层的偶发竞争（单次重跑即绿）。归入测试提速那一轮一并诊断（prebuilt 缓存的并发面 / 每次 compile 的 cache 目录隔离）。
- 2026-08-26 · **两个后续决定（用户拍板）**：① **D13 · nulya runner 的 default 档保持无门**（readonly 之外不挂 gate）——不做字符串猜安全的假天花板，真隔离等 sandbox（PLAN §3.8）；ar-h（三档权限阶梯：readonly → default → unsafe，四个 arm 各自映射，unsafe 的授权显式写在定义/调用里、由父场自己的 gate 裁决，不做前端 mode 的环境继承；中途提权转发记档缓做）待测试提速轮落地后实施（与 extension.zig 拆分冲突）。② **ar-i · 只读命令分类器（TUI）已派发**：ask 档下 shell 命令经引号感知 tokenizer 顶层拆分（`&&` `;` `||` `|`），每段命中白名单才放行；命令替换/写向重定向/解析失败一票否决落回 ask；白名单到子命令与 flag 级（git -c、find -delete、sed -i 等注入向量显式拒），含 nulya 自己的只读动词；readonly 天花板不用它（字符串分类不是安全边界，agents-and-review §1）。
- 2026-08-26 · **ar-i 完成（内核零改动，全在 `tui/`）**：分类器落在 `tui/src/readonlyshell.ts`（纯函数 `classifyShellCommand`），裁决链插在 manifest `readonly` 之后、mode 兜底之前，**只对 `shell`、只在 `ask` 档**（`approvals.judge` 返回 `{decision, via}`，`decide` 是它的薄封装——顺序只写一遍）；卡上一行 dim 标记 `auto-allowed — read-only command`（`ToolItem.autoAllowed`，存在 SessionState 的 id 集合里以熬过 provisional→committed 的替换）；人这侧的开关是 `[approvals] readonly_commands`（整词前缀，只加程序名、买不动任何否决）。**一处判断上的偏离**：`sed` 与 `awk` 都不进白名单（不只是拒 `-i`）——它们的操作数是另一种语言写的程序，那种语言自己能写文件（sed `w`、awk `print > f`）也能跑命令（GNU `s///e`、awk `system()`），flag 级检查不可能完备；`find` 留下正因为它危险的动词是 flag。测试：`test/readonlyshell.test.ts` 表驱动 + `approvals.test.ts` 链位置三条 + `gate.test.tsx` 一条端到端；`bun test` 全绿、`tsc` 干净。文档：tui.md T65 + §5.7 决策序。**顺带发现的既有 flake（非本轮引入）**：`test/interrupt.test.tsx` 的 `not.toContain("queued")` 会撞上随机抽中的开屏 tip（`Welcome.tips` 里有一条含 "queued"）。
- 2026-08-26 · **测试提速（`src/` 与 `tui/` 一字未改，109 条 e2e 一条不加不减、语义未动）**：全套 e2e **116s → 47s**（同机、缓存已热、连跑三次均为 47/46/47s）。三件事：
  - **① 一个二进制拆成四个**（一个二进制只用得上一个核）。`tests/e2e.zig` 删除，换成四个 root + 四个 step，`zig build e2e` 依赖全部四个于是仍是全套，`-Dtest-filter` 四组都认：`e2e-ext`（`tests/e2e_ext.zig`：extension / script_wire / manufacture / source / ext_cli）· `e2e-core`（`tests/e2e_core.zig`：session / cli / gate_pin / vision / background）· `e2e-agent`（`tests/e2e_agent.zig`：新文件 `tests/e2e/agent.zig`）· `e2e-std`（`tests/e2e_std.zig`：std / std_fs / std_search）。**`tests/e2e/extension.zig` 5106 → 2612 行**：委派那一整块（`bundled agent: …` 全部 + codex / claude / pi / 外部 runner 四段 + 它们的 helper）整段搬进 `agent.zig`，**逐字节搬家**（`bundled plan and ask` 留在原处——它不是委派）。单跑耗时 `e2e-ext` 45s · `e2e-agent` 38s · `e2e-core` 20s · `e2e-std` 7s，并行墙钟 = 最大的那个 + 一点点。**为什么先拆三组后来是四组**：按建议的三组做完是 76s，因为 `e2e-core` 一个人就是 72s 的关键路径；按"这一组证明什么"再切一刀（extension 生命周期 vs 内核 session 面）才把关键路径降到 45s。四组恰好落在彼此两倍以内，这是**唯一**的偏离，理由就是这两个数字。
  - **② 等待审计**。先量后改：`zig build e2e-core -Dtest-filter=…` 逐条计时，发现**真正的大头是 `zig build-exe` 本身**——DESIGN §7.4 固定了那个调用（没有 `--enable-cache`），实测**每次 7s 且任何 zig 缓存都缩不短**（本机连测五次：6995/6948/6961ms，`ZIG_LOCAL_CACHE_DIR` 无效，盘上根本不生成本地缓存目录）。改不了（那要动 `src/`），所以只动测试自己的等待：`background.zig` 里三处 `sleep N; echo MARKER` 换成 **hold 文件**（`holdCommand` / `takeHold` / `releaseHold` + `waitUntilRunning`）——那三条测试需要的是"这一刻任务还在跑"（retarget 之前 / cancel 之后 / fork 当口），固定 sleep 只是让它**很可能**成立，是一注押在机器负载上的赌，还要每次付 N 秒；换成测试自己删的文件就是**确定**成立且不花钱（`e2e-core` 24s → 20s）。`ext_cli.zig` 那个 2s 的 `snooze` 脚本**看过、留着**：1000ms 的 manifest 上限与 500ms 的 opt-in 上限都要在它下面，那 2s 是被断言用着的余量，不是等待。其余等待（`task wait`、50ms 轮询、fake 的 HOLD 循环）本来就是事件式的。
  - **③ 等待预算收成一个常量**。`agent.zig` 与 `background.zig` 各加一个 `wait_budget_ms` / `wait_tries`（180s），把散落的 `--timeout-ms 20000/30000/60000/120000` 与 `tries < 600/400` 全换掉。这些是**预算不是延迟**——事件一到立刻返回，所以大数字只在测试已经失败时才付；小数字则是机器一忙就付，付出去的是一次与代码无关的红。见下一条：负载下抓到的第一个 flake 就是 `task wait --timeout-ms 60000` 到点返回 2。
- 2026-08-26 · **flake 根因（承接上一条 §6 里那句"`unable to read results of configure phase`，归入测试提速那一轮一并诊断"）**：**那句话与 `ext build` 无关，也不是 zig 编译缓存的竞争**——它是 `zig build` 前端在**掩盖 build runner 的崩溃**。链条是死的：① 这句字符串在 `zig.exe` 里（`strings` 可见），不在 `lib/` 里，属于 `zig build` 前端；② 它读的是 `<local cache>/tmp/<nonce>`，而写这个文件的**唯一**地方是 `lib/compiler/build_runner.zig:474`，紧跟着 `process.exit(3) // Indicate configure phase failed with meaningful stdout`，条件是 `graph.needed_lazy_dependencies.entries.len != 0`——**本仓库没有 lazy dependency，这条路永不执行**；③ build runner 的正常出口只有 0 / 1 / 2（`build_runner.zig` 尾部那个 `code:` 块）；④ 而 **Windows 上 `std.process.abort()` 就是 `RtlExitUserProcess(3)`**（`lib/std/process.zig:806`），任何 panic 最终走到它。于是 **exit 3 = build runner 崩了**，前端把它误读成"configure phase 有话说"，再因为那个 nonce 文件根本不存在而打出这一句。⑤ 反向也成立：`ext build` 调的是 `zig build-exe`，**没有 configure phase**，它不可能产生这句话；nulya 自己杀进程树用的是 `TerminateJobObject(job, 1)`，也不是 3。**结论：下次见到它，要看的是这句话前面 build runner 打了什么，不是扩展缓存。**
  - **另一类 flake 确实在测试里，且可复现**：16 个 busy loop 压满 20 核之后跑全套，第一次就红——`bundled agent: a codex delegation that is running takes …` 与 `bundled agent: render writes a persona …` 都停在 `task wait --any --timeout-ms 60000` 返回 2（预算到点，不是断言错）。上一条 ③ 把预算提到 180s 之后，同样负载下三次里两次全绿；剩下那次是真的在 180s 里没等到（整轮跑了 233s，约 90 倍降速），那已经超出值得防的条件。
  - **顺带记下的两个事实**（不是本轮的问题，但下一个人会撞上）：`std.testing.tmpDir` 把每个 e2e workspace 建在 **`<repo>/.zig-cache/tmp/<hex>`**，也就是 zig 自己的缓存目录里；`.zig-cache/tmp` 下现有约 140 个**空的**残留目录，说明 `cleanup()` 的 `deleteTree` 偶尔删得掉内容删不掉目录（Windows 上通常意味着还有人把它当 cwd 开着）。频率约每轮 0.5 个，无害，但它是"某个子进程活得比测试久"的唯一可见痕迹。
- 2026-08-27 · **ar-h 落地（三档权限阶梯，内核 `src/` 零改动、`tui/` 源码零改动）**。`readonly: true` 变成 **`permissions: readonly | default | unsafe`**（缺省 `default`），一个词走完定义 → 调用 → record → 五个 arm。
  - **字段最终形状**：`record.Permissions`（enum + `parse` / `label` / `isReadonly` + `default_permissions` + `permission_words`）住在 `record.zig` 而不是 `defs.zig` 或 `runners.zig`——它是**冻进 record 的那一列**，而 `record.zig` 又恰好是四个 arm 与 `defs.zig` 都够得着的那个模块（`runners.zig` import 各个 arm，arm 不能反向 import 它）。**老词直接拒**：`readonly:`（`true` 与 `false` 都算）与任何不认识的档位都是 `ParseError.UnknownPermissions` → **warn-and-skip 整个定义**，与 `UnknownRunner` 同一条纪律走同一处 `continue`。选"拒"而不是"warn + 缺省"的理由是这个字段本身的理由：把"要求只读"读成"普通委派"正是它存在要拦的那件事，而一个静默放宽的天花板比一个不存在的 persona 糟。自带的 `explore.md` 与两个 `tui/test` 的 fixture 一并改写成新词。
  - **调用参数** `agent{permissions?}`：只在**开新委派**时接受（`session` 形态给它 → 拒绝并指路，与 `model` 逐位同构：档位与身份一样在开场冻死）；认不出的词当场拒并列出三个（`record.permission_words`）。优先级 **调用 > 定义**，**没有第三层**——父场档位、前端 mode、环境变量一概不参与；提权的授权点是 `agent{…}` 这个 call 本身要过的**父场 gate**。
  - **各 arm 映射**（表在 `runners.zig` 模块注释顶部、DESIGN §7.8「三档权限阶梯」、guide skill 三处同形）：`nulya` = `readonly` 挂 `--gate` 机械应答 / 另外两档不挂门（D13，`default` 与 `unsafe` 在这个 arm 上行为相同，差别只在 record 冻下的那一列）· `codex` = `read-only`（验回报）/ `workspace-write` / `danger-full-access`（`codex.sandboxWord`，只有 readonly 验回报——回报得更窄不是违约）· `claude` = 窄 `--tools` + `dontAsk` + `--strict-mcp-config`（验 `system/init`）/ `acceptEdits` / `bypassPermissions`（`claude.modeWord`；窄档那两个额外 flag 只随 readonly 出现）· `pi` = `--tools read,grep,find,ls` / 全部内建 / **同 default**（pi 没有更宽的档，如实按 default 跑并在 `pi.zig` 模块注释、DESIGN、guide 三处写明，record 仍冻 `unsafe`——"要什么"与"给得出什么"是两个事实）· `ext:<id>` = `--arg permissions=<三词>` 原样透传（不是 bool），契约同步到 `external.zig` 模块注释 / §7.2 表 / §7.4 配方 / DESIGN §7.8 / guide skill，并写明**认不出的档要拒**（fail-closed 纪律不变）。
  - **record 变化**：`created` 行的 `readonly` 布尔列 → **`permissions` 字符串列**（总是写，不是"非默认才写"——它是这条 delegation 的中心事实）。读回**没有这一列或读不出**一律 `readonly`：一份说不出自己授了什么的 record，就是什么都没授。`run` tool 的参数同样从 `readonly: bool` 变 `permissions: string`，两种缺失分开答——**没写** = `default`（手工调 `run` 从来不意味着最窄），**写了但读不出** = `readonly`。
  - **投影兼容**：`list` / `render` 各多一列 `permissions`（词），**同时保留派生的 `readonly` bool**（= `permissions == "readonly"`），所以 `tui/` 源码一行未改——`/agent` picker、`startAgent` 的 readonly 天花板、`AgentEntry` 都照旧读那一列。**TUI 跟随（把三档画出来、`/agent` 显示档位）属后续轮次**，本轮不做。
  - **一处对"`tui/` 一字不改"的偏离，只在 fixture**：`tui/test/agents.test.ts` 与 `tui/test/delegate.test.tsx` 各有一份用旧词写的 agent 定义 fixture，它们经真实二进制的 `ext run agent list`，改词之后那两份定义被整份 skip，6 条测试红。改动是**两个 fixture 字符串**（`readonly: true` → `permissions: readonly`），与自带 `explore.md` 完全同类的数据改写，`tui/src/**` 一个字节未动。
  - **测试**：`zig build test` **510 pass / 2 skip**（`record.zig` 新增两条：三个词的解析与"不是这三个就是最窄"、以及一条没有 `permissions` 列的 created 行读回 `readonly`；`defs.zig` 的错误表补 `permissions: none` / `readonly: true` / `readonly: false` 三句）· `zig build e2e` **110 pass**（109 → 110）· `zig build e2e-agent` **19 pass / 40s** · `cd tui && bun test test/agents.test.ts test/delegate.test.tsx` **11 pass**。新 e2e 一条（`the permission ladder is one word frozen into the delegation`：两个投影的两列一致 · 老词定义根本不出现在目录里 · 定义的 `unsafe` 冻进 record 且回执说出口 · 调用的 `readonly` 压过定义的缺省）；其余映射断言**长在既有测试里**，不新起炉灶——codex / claude / pi 三条 readonly 测试各多跑一次 `unsafe` 委派并断言 log 里的 `danger-full-access` / `bypassPermissions` / 没有 `--tools`，三条全环测试各多一句 `default` 的断言（`workspace-write` / `acceptEdits` / 没有 `--tools`），外置契约那条多两块（`open v1 default` / `round v1 default` 的透传，与直接 `ext run … --arg permissions=godmode` 被 runner 拒）。`tests/fake_codex.zig` 改了一行：日志从只记 method 改成记**整条请求**——`sandbox` 是一个参数，而它正是这套映射从外面唯一能验的东西。
  - **本轮外的两点**：① 跑测试前撞上两个**上一轮遗留的** `nulya task supervise` 进程（cwd 指向早已删掉的 `.zig-cache/tmp/…`）攥着 `zig-out/bin/nulya.exe`，`zig build` 报 `AccessDenied`——正是 §6 末尾"某个子进程活得比测试久"那条痕迹的具体形态，杀掉即可。② 一次全量 `zig build e2e` 里 codex steer 那条测试红过一次、单跑与随后两次全量都绿，与既知的高负载 flake 一致（我新加的 `workspace-write` 断言读的是 `thread/start` 的同步日志，不参与那条时序）。
- 2026-08-27 · **外部 review 的六条，五条修了一条改成文档（内核 `src/` 零改动、`tui/` 零改动）**。全部落在 `extensions/agent/`。
  - **① inbox 的丢消息竞态（真 bug，P1）**。`record.inboxPut` 从前是「独占 create → 写 → close」，而**目录项在 create 成功时就存在了**，不是 close 时才出现；并发排 inbox 的 runner 会扫到这个名字、`readFileAlloc` 读到半截或零字节、**先 delete 再 parse**（`inboxTakeUpTo` 的删除在解析之前），于是一条已经 accept 的消息永久消失——直接违反 D4。codex/claude/pi/ext 四个 arm 都在 drive 循环里排这个目录，发送方是父场 step 里的另一个进程，不是理论 race。改成内核 inbox 自己的两步（`ledger.depositEvent` 的先例）：**独占 create `<n>.tmp` 抢号 → 写 → close → rename 成 `<n>.json` 发布内容**，读端只认 `.json`。两个 race 两件事，各自需要其中一步。`nextFree` 不用改（它读第一个 `.` 之前的 stem，`.tmp` 天然占号）；崩在中途的 `.tmp` 只赔掉一个号。原注释里那句 "a reader only ever sees a name that was written whole" 是**错的**，一并改掉。
  - **② `max_rounds = 64` 会确定性破坏 wake 不变量（真 bug，P1）**。循环里 `interrupted` 与 `pending` 两条 `continue` 绕过了底部的 release-and-recheck，所以第 64 轮走到任一条就直接跌出 `while` 条件、`defer` 释放 lease、**没有第二次复查也没有后继**——而发送者当时探到 lease held 所以没起 runner，消息挂到下一条消息偶然到达为止。改法两处：**`while (true)` + 每个出口都是写出来的 `break`**（出口不再可能由计数器耗尽产生），以及计数器改成 **`max_idle_rounds`——只数「什么都没说 + 消息还在」的连续轮次**（有产出或吃掉 interrupt 的轮次清零）。**没有做 successor 派生**：能走到放弃的两个出口（一轮完全跑不起来 / 连续空转）都是下一个 runner 同样撞得上的死路，一个在无人值守下自我复制的 runner 是会花真钱的循环；改成**在报告里说出来**（`stranded_note`：消息仍在队列里、委派完好、再送一轮会连它一起答）。同时把模块注释里 advisory lock 那句过度承诺改准——**它保证的是「不会永久锁死」，不是「一定有人接手」**；crash 之后 pending 消息仍要等下一条消息唤醒，这一点现在写在注释里而不是被含糊过去。
  - **③④ record 成为执行端唯一真源（P1 + P2，一处改动同时解决）**。`runner.run` 从前只从 record 取 runner / runner_model / runner_version，**`permissions` 却信 argv**——`ext run agent@<v> run --arg delegation=<冻成 readonly 的 d> --arg permissions=unsafe` 就能以 unsafe 驱动它，与 ar-h 的中心主张直接矛盾（record 说「冻结了」，执行层不以它为准）。同一处还有个 fail-open：`Runner.parse(...) orelse runners.default`——record 里读不懂的 runner 词退成 nulya，于是拿一个 codex thread id 去跑 `session step`（而 `sendTurn` 对同一事实一直是**拒绝**的）。修法按 review 的建议做了**简化而非补丁**：后台命令收成 **`run --arg delegation=d-… --arg depth=N`** 两个参数（`proc.startDelegationTask`，与 `main`/`runner` 两个调用方共用），其余全部由 `runner.run` 从 record 读；给了 `delegation` 而 record 读不出 / runner 词不认识 → **拒绝并说明，什么都不驱动**。`Args` 之后立刻塌成 `Settled`（record 或手工调用二选一，之后的代码只拿得到 `Settled`），所以不存在第二次「argv 还有机会说话」的地方。**顺带关掉 ④**：第三方 runner 的 `remote` 契约上是任意字符串，从前被裸插进交给 shell 的命令串（只有 exe 加了引号），一个含空格的合法 handle 就坏了——现在命令里根本没有 remote，**不需要 escaping helper**。
  - **⑤ 已开始的委派不再查 mutable definition（P2）**。`created` 行新增三列 **`max_exchanges` / `max_steps` / `agents`**（只在非默认时写，老行读回 0/0/空——空 `agents` 是 leaf，最窄的那个答案）。`sendTurn` 的预算从 record 读，`defs.find` 那一读连同「persona 不再定义了」的拒绝一起删除：persona 字节在子场 header 里、天花板在 record 里，删掉定义文件不该终止一场已经存在的对话。`allowedHere` 的委派白名单同样改读 record——反查靠 runner 给它驱动的那一步多设一个 **`NULYA_AGENT_DELEGATION`**（与 `NULYA_AGENT_DEPTH` 同一条路、同一个理由：链的事实、不是 secret 形状、过得了 §7.6 净化）。**保留了一个 fallback**：没有这个变量而 session 又戴着 persona = 人从前端手工驱动的一场（`/agent` 开的正是它），没有冻结过的答案可言，仍读定义——把它压成 leaf 会拿掉 coordinator 在唯一有人看着的场合的全部意义。
  - **⑥ claude / pi 的 `runner_version`：不是 bug，是文档过度承诺**（用户判断，采纳）。`ext:<id>` 是 **pinned execution identity**（旧 `v-…` 还在 store，每轮真调那个）；`claude` / `pi` 是 **creation-time provenance**（PATH 二进制升级即覆盖，没有可钉的东西）。**不做**版本比对 refusal——它恢复不了可复现性，只会杀掉本来能正常 resume 的对话，是承诺一个系统给不出的保证；**也不做** change event（当下没有执行决策价值，却要多一次 subprocess、一种 journal 事件、一套记录语义与 UI 问题）。也不说它「与 profile/model 同一档」：那两个在 nulya session 里是创建时决定、之后按冻结身份执行的，强度不同。改的是 `record.Created.runner_version` 的字段注释（两种强度各一段 + 「只声称真正 enforce 得了的 freeze」）、`claude.probe` / `pi.probe` / `runners.Started.version` 三处注释、DESIGN §7.8 与本文 §D7。字段名维持 `runner_version` 不拆（拆成 `runner_ref` / `runner_version_observed` 语义更纯，但 record 会为 implementation kind 多长一层特殊情况，收益不够）。
  - **测试**：`zig build test` 全绿 · `zig build e2e` **111 pass**（110 → 111）· `cd tui && bun test` **500 pass**。`record.zig` 三条新单测（policy 三列的冻结与读回 · 老行读回 0/0/leaf · **半写的 `.tmp` 既不会被取走也不会被删掉**，且它占掉的号不再发第二次）。新 e2e 一条 `the record is what a delegation is driven by`：① 开场后**删掉定义文件**，追问照跑、预算仍按 record 的 `max_exchanges` 咬人 ② 手工 `run --arg permissions=unsafe --arg session=<不存在的 s->` 驱动一条 readonly 委派——驱动的是 record 指的那一场（denial 计数增加），且**整条 ledger 里没有一个 `"ok":true`**（掉了门就会有，scripted provider 每步都要 shell）③ 没有 record 的 d-id 拒绝且什么都不跑。**这条测试验证过它会失败**：把 `permissions = state.created.permissions` 改回 `args.permissions`，②当场红。
- 2026-08-27 · **第二轮外部 review 的五条，全部成立、全部修（`src/` 与 `tui/` 零改动）**。
  - **① codex 的 interrupt 有 message→marker 两次落盘的竞态（P1，唯一的 blocker）**。`deliver()` 先 `send`（发布 `<d>/inbox/*.json`）后 `markInterrupt`，而 codex 的事件循环是"先看 marker → 再排干 inbox → 把新消息 `turn/steer` 进去"——**只有这个 arm 在 turn 中途 drain**。落在两次写之间的一次 drain 看到的是一条长得很普通的消息，于是它被 steer 进了那条马上要被 `turn/interrupt` 砍掉的 turn。旧注释里"marker before drain, always"证明的是**标记已经在盘上时**顺序正确，不是两次写之间无竞态；旧 e2e 也只钉住了前者（fake 的 held turn 保证 marker 先到）。**修法按 review 的建议**：inbox entry 原子携带执行控制——`record.Message{text, interrupt}`，`{"v":1,"text":…,"interrupt":true}`，一次 rename 同时发布正文与信封。不违反 D3：消息仍是普通 user turn，`interrupt` 描述的是**投递方式**（`appendTurn(interrupt)` 早就这么记）。**不改成 marker 先写**——sender 死在中间就成了"砍了一轮却没有新指示"的反向问题。marker 照旧也写：nulya arm 没有自己的 inbox，claude/pi/ext 一轮只在开头取一条、从不 drain 运行中的 turn，那边一个 marker 就够；codex 上两条路都对（`driveOnce` 每轮开头清陈旧 marker）。
  - **①b review 没看到、但同一条路径上的独立漏洞**：`drainToEnd` 的 `.response => {}` **丢弃 steer 应答**。而"被拒的 steer 把消息放回 inbox"的唯一实现是 `settleSteer`，所以 interrupt 退出时任何一条**回复还没到**的 steer，若之后回的是 refusal，消息就永久消失——而砍掉 turn 恰恰是 steer 最容易被拒的时刻。`turn/completed` 那条路径为此专门写了结算循环，interrupt 这条漏了：同一个不变量在同一个函数里守了一半。抽出 `settleOutstanding` 两处共用，`drainToEnd` 收结算参数。`Steered` 从 `{id, text}` 改成 `{id, msg}`——放回去的必须是拿出来的那个，否则一次 requeue 会把 interrupt 悄悄降级成普通 turn。
  - **② record 的 corrupt policy row 仍 fail-open（P2）**。`intOf` 对字符串/负数/越界一律回 `0`，而 `max_exchanges=0` 是**无限**、`max_steps=0` 是内核缺省——完整但损坏的一行会被读成"无限 follow-up"。判据**不是**"authority 字段一律拒绝"，而是**兜底的方向**：`permissions`→readonly、`agents`→leaf 都是最窄的，corruption 最坏只能关能力（standing record 同一条哲学），照旧兜底；两个预算列的兜底值是最宽的，没有"窄读法"可用，所以 present-but-invalid → `Corrupt.CorruptDelegationRecord` 拒整条 record。完整但非 JSON 的行同理（坏掉的 `turn` 行会悄悄压低 exchange 计数）；**残尾仍然忽略**。三个读点各自给出可读的拒绝：`sendTurn` 点名文件路径、`runner.run` 与"没有 record"分开答（两种修法不同）、`allowedHere` 落回 leaf（那里的空列表**就是**拒绝）。
  - **③ D4 的措辞跟上了行为（P2）**。不变量本身改写成两支："凡被 accept 的消息，要么最终有人 drive，要么原封不动留在队列里、并把驱动它的终结失败报回父场"，并写明**无条件成立的是关于这段代码的那部分**（跑得起来的路径上不因 lease/send 的 TOCTOU 丢唤醒）。理由写进注释：只留"eventually driven"会招来唯一一种修法——放弃的 runner 再起一个 runner——正是上一轮拒绝做的那件事。
  - **④ `agent.model` 的模型面 description 落后（P2）**：那句只对 `runner:nulya` 成立，而代码对外部 runner 是不 parse、不继承父场。改成按 runner 分两句。
  - **⑤ 两个小的（P3）**：`state.turns >= allowed + 1` → `state.turns > allowed`（语义等价，且 `max_exchanges: 4294967295` 不再 overflow）；`runner_model` 的"nothing reads it back"是只有 codex 一个 arm 时写的，claude/pi/ext 每轮 attach 都从 record 读它。
  - **测试**：`zig build test` **520** · `zig build e2e` **112**（111 → 112）· `bun test` 500。`record.zig` 两条新单测（信封随消息往返、requeue 不掉 `interrupt`；两个预算列的坏值与坏行拒绝 record）。新 e2e 一条 `a message that asks to interrupt is never steered into the turn it is about to stop`：**把窗口摆出来**——绕过 sender，直接按 `inboxPut` 的发布纪律（`.tmp` → rename）写一条 `interrupt:true` 的 inbox entry、**不写 marker**，正是那两次写之间的状态；断言 log 里有 `turn/interrupt`、**没有一条带 sentinel 的 `turn/steer`**、且 sentinel 最终由后一轮 `turn/start` 答出。**验证过它会失败**：把 `if (msg.interrupt)` 改成 `if (false)`，`turn/interrupt` 那条断言当场红。
