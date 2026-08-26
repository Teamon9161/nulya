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
- 创建行冻结 `runner`（与将来 `runner_version`）进 record；每轮调用按冻结值走（D7 的版本冻结在外部 runner 出现时才有内容，字段现在就占位）。

**ar-t1 · TUI：主 agent 的 queue lane + interrupt-and-deliver（`tui/`，与 ar-a/b/c 无依赖、可并行）**

- **queue lane**：`pendingCount > 0` 时输入框上方一行（WorkingStatus 同区）：`⏸ N queued — enter queues · ctrl+j interrupts & delivers`，逐条截一行列出排队消息；点击任一条 = 下述手势（inbox FIFO 排干，不假装能单条插队）。transcript 里的 `· queued` 行不动（那是真相所在）。
- **手势 `ctrl+j`**（keymap 可覆盖，走 `tui.toml` 既有 keymap 机制）：输入框有字 → 先 append（queued）；然后 kill 当前 step（T27 既有 kill 路径）；step 进程退出后**立即** re-step（不等 idle 定时器）。idle 时该手势等价普通发送。
- 全部是现有动词接线（append / kill / step），**内核零改动**；不新增状态机——判据复用 `driver` 的现有状态。

**后续轮次（本轮不做，写在这里当尺子）：**

- ~~**ar-d · Codex runner**~~ —— **已落地**（§6，2026-08-26）。App Server 的六个动词全部实测存在（`initialize` / `thread/start|resume` / `turn/start|steer|interrupt`），行分隔 JSON-RPC over stdio；`runner_model:` 已加。
- **ar-e · Pi runner**（`pi --mode rpc`：prompt/steer/followUp/abort）。
- **ar-f · Claude runner**（`claude -p --input-format stream-json --output-format stream-json` 双向 stdio + 控制通道 interrupt；**不用 Agent SDK**——不把外来 runtime 钉进本包，D12）。
- **ar-g · 外置验证 + 契约定稿**：把一个内置 runner 搬成独立扩展（`runner: ext:<id>` + 固定 `internal` tool `agent_runner`，创建时解析并冻结版本进 record）；"搬出去 agent 几乎不用改"即边界正确；契约写进 guide skill 与本文件。
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
