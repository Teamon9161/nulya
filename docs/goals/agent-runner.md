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

- **ar-d · Codex runner**（App Server：`thread/start|resume` + `turn/start|steer|interrupt`，JSON-RPC over stdio，Zig 直说）——第一个外部 runner，契约缺口以它为准补；定义加 `runner_model:`（外部 runner 的不透明模型字符串，D9）。
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
