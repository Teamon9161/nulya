# Goal · acp：编辑器驱动 nulya，是第三个 driver，不是内核的事（2026-09-05）

> 这是一份**执行契约**。地图与 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §14（行协议与 `--gate`）/ §3.4 / §4，前端契约在 [tui.md](../tui.md)。
> 计划里的那一句是 [PLAN.md](../PLAN.md) §3.11：「ACP：`session/new|prompt|cancel` 直接翻译成 `nulya session *`」。本文把落点与边界钉死。
> 与 [mcp.md](mcp.md) 只在一处相遇（决策 F），那一处**必须按本文这么答**。

## 0. 结论（一段）

ACP（Agent Client Protocol）让编辑器当 client、agent 当 server 说 JSON-RPC over stdio。
nulya 站 **agent 那一侧**，落点是 **`tui/` workspace 的第二个 entry**（TypeScript），
复用已经存在的那层 CLI 绑定。**内核零改动**：逐方法对过一遍，ACP 要的每一样东西
今天的行协议、`--gate`、durable ledger 都给得出，剩下三个边角都在 adapter 里。
目标是 **v1**（现行稳定版），不是 v2（draft，且删掉了我们最强的那件东西）。

## 1. 已定决策

### A · 落点：`tui/src/acp/`，不是 `src/` 的一个 Zig 动词

**不是 extension**：M2c 已经为 `/goal` 记过同一条理由（PLAN §1 M2c 落地修正③）——`ext run` 强制
manifest 的 `timeout_ms`（上限 600 s），而一个 driver 一跑几十分钟；再加 §7.3 明写"不做 daemon /
persistent worker / streaming / host callback"，而 ACP agent 恰好要握一条长连接、要在 tool call
中途反问权限。extension 这条路是关着的。

**不是内核**：把它删掉，八条 physics 一条都不失效——它不是内核（CLAUDE.md 工作约定）。
PLAN §3.11 早已把它归类成"core 之上的薄客户端"。

**是 TS 而不是 Zig**，三条理由：

1. `tui/src/nulya/cli.ts`（~1570 行）+ `ledger.ts`（~509 行）**一行 solid-js 都不 import**，
   已经是整个 CLI 面的类型化绑定：`sessionNew` / `sessionAppend` / `sessionEvents` / `sessionCancel` /
   `sessionFollow` / `sessionStep(ws, id, {gate, onLine})` 全在里面，`--gate` 的管道与 fail-closed
   已经写好、测过。ACP adapter 要的就是这些，别的一样不要。
2. `approvals.ts`（~269 行，纯逻辑）就是 `session/request_permission` 需要的那套 policy。
3. schema 白拿：官方 TS SDK 是 `@agentclientprotocol/sdk`。写 Zig 意味着把一份还在演进的大 schema
   手抄进 `src/`——正是"内核只长 substrate，不长便利"要拦的东西。

**不碰 `tui/src/state/*`**（那半是 solid 的、是屏幕的状态机）。adapter 自己那点状态自己拿。
`build.ts` 加第二个 entrypoint，`bun build --compile` 出 `nulya-acp` 单文件；与 TUI 同一条纪律：
**它是进程边界外的 driver 客户端，不是第二个 harness**，运行时仍要一个 `nulya` 二进制。

### B · 方法映射（v1 全表）

| ACP | 怎么答 | 备注 |
|---|---|---|
| `initialize` | adapter 常量 | 声明 `loadSession: true`（见 E）；`fs` / `terminal` **不声明**（G） |
| `authenticate` | `authMethods: []` | credential 缺失时 `session new` exit 1 + stderr 一句指路（§9.5），把那句话原样交回 client |
| `session/new {cwd, mcpServers}` | `nulya session new`，cwd 就是那个 workspace | `mcpServers` 见 F |
| `session/prompt` | `session append` → `sessionStep({gate})` | 返回 StopReason，见 D |
| `session/cancel`（通知） | `session cancel` | **语义逐字对上**：标记 + step 边界消化，ledger 永远合法（physics #7） |
| `session/load` | 重放 `session events` | 见 E |
| `session/update`（通知） | 行协议翻译，见 C | |
| `session/request_permission` | `--gate` 的一问一答 | 见 D |
| `session/set_mode` | adapter 自己的两档（`ask` / `unsafe`，同 TUI） | v2 已删除 modes，**不要为它设计任何持久形状** |

### C · `session/update`：行协议已经够了

| ACP 变体 | 行协议里的哪一行（DESIGN §14） |
|---|---|
| `agent_message_chunk` | `{"stream":"model","event":"text_delta"}` |
| `agent_thought_chunk` | `thinking_delta`（`reasoning_item` **不转发**，它只为回放） |
| `tool_call` | `tool_use_start`（`call_id` / `name`）+ `tool_use_input_delta` 累积 `rawInput` |
| `tool_call_update` | `{"stream":"tool","event":"begin"/"end"}` 与那一步的 `tool_results` 事件行（`ok` → `completed`/`failed`） |
| `user_message_chunk` | adapter 自己回显（见 D 的边角①） |
| `plan` | `extensions/plan` 的 `todo` 调用（它已经带 `ui:{render:"checklist"}`，是本来就要画成清单的那个东西） |
| `available_commands_update` | 冻结 manifest 的 `contributes.commands`——`tui/src/` 已经在解析它 |
| usage | `{"stream":"model","event":"usage"}`（v1 无对应变体则并进 adapter 自己的日志，不编一个 update 出来） |

**`toolCallId` / `messageId` 不发明**：用内核的 `call_id` 与 `seq`——它们本来就是稳定且可回放的。

### D · 权限：`--gate` 与 `session/request_permission` 是同构的

每个 call 执行前一行 stdout（`call_id` / `tool` / `tool_id` / `readonly` / `args`）+ 阻塞读 stdin 一行
（`allow` / `deny` / `deny <note>`），EOF = fail closed。翻成 ACP 的一次 `session/request_permission`：

- `allow_once` / `reject_once` → 直接答那一行。
- `allow_always` / `reject_always` → **adapter 自己的 always 集合**，与 TUI 现在做的一模一样
  （PLAN §3.8.1："判断在 driver"）。**内核不知道也不需要知道 always 是什么。**
- 三张规则表（`allow` / `ask` / `deny`）与 `manifest_readonly` 直接复用 `approvals.ts`。

**三个边角**（都在 adapter，都不是内核改动）：

1. `session append` 走 inbox，下一次 step 之前 `events` 看不见它（PLAN §4 已记）→ adapter 自己回显
   `user_message_chunk`，TUI 已经这么做。
2. StopReason 映射：`end_turn` → `end_turn`，`canceled` → `cancelled`，`max_tokens` → `max_tokens`，
   `budget` → `max_turn_requests`。四个值来自 `{"stream":"run","event":"done","stopped":…}`。
3. 诊断只有一条路：`{"stream":"run","event":"error"}` + 非零退出 → 翻成 JSON-RPC error，
   **不吞掉**（stdout 上没有非 JSON 行，所以不必猜）。

### E · `session/load`：这是我们的强项，别放过

ACP v1 的 `session/load` 是 capability-gated 的可选项，多数 agent 不做——因为要自己存历史。
nulya 的历史**本来就在盘上**（generation == 文件，physics #2 的直接结果）：`session events` 重放成
`user_message_chunk` / `agent_message_chunk` 序列，读完答 `null`。几乎白送。

**声明 `loadSession: true`。** 沿 `parent` 链把 fork 出来的对话拼成连续一条**不在本轮**
（那是 PLAN "没做的"里已有的一项，`session list --json` 的 `root` 已经算好、前端还没连；
两边将来一起做）。

### F · `mcpServers`：v1 明说不接

ACP 的 `session/new` **必带** `mcpServers`（client 每场告诉 agent 连哪些 server）。
按字面实现它就是"运行时把这些 server 的工具挂上模型面"——**直接推翻 composition 冻结（physics #2）**。

**本轮的答案**：按名字映射到本机**已经生成并 activate 的** `mcp.<name>` 包（[mcp.md](mcp.md) 的形状），
对不上的**明说不接**（一条 client 看得见的 notice，不静默）。

这是两条线唯一会互相伤害的地方，所以 **MCP 先做、ACP 后做**：先有"生成包 + 冻结快照"这个形状，
这里的正确答案才是显然的。

### G · 不做

- **v2**（draft）。它删掉了 `session/load`、modes、client 侧 fs/terminal——为它设计等于为一份还没定的
  规格付两次钱。v1 是现行稳定版，Zed 今天跑的就是它。
- **`fs/read_text_file` / `fs/write_text_file`**：v1 里是可选 capability，而 `extensions/std` 在本地干得了。
  将来接它的**唯一**收益是"看得见编辑器里没存盘的 buffer"——那是个真收益，但等有人真被咬到再说。
- **`terminal/*`**：同上，且 nulya 自己那套更强（后台任务 → supervisor → inbox 的一条 `note`，§3.13）。
- **反方向**（nulya 当 ACP client 去驱动别人家的 agent）：那不是一个新项目，是 `extensions/agent`
  的第六种 runner（`acp:<cmd>`，与现有五种同形）。等有人真要再说，不在本轮。

## 2. 验收

`bun test`（`tui/test/` 同一套 preload 与 NULYA_HOME 隔离）：

1. **一整趟**：`initialize` → `session/new` → `session/prompt` → 收到 `agent_message_chunk` 与
   `tool_call`/`tool_call_update` → `end_turn`。跑在 **scripted provider** 上（离线，`NULYA_SCRIPTED_MODE`）。
2. **权限**：一次 `session/request_permission`，`reject_once` 之后那个 call 的结果是 `ok=false` 且带
   marker；`allow_always` 之后同名工具**不再问**。
3. **取消**：`session/prompt` 跑到一半发 `session/cancel`，`stopped == "canceled"` → `cancelled`，
   且**ledger 仍是合法的**（assistant-with-calls 后有一条匹配的 tool_results）——这一条守的是
   physics #7 没有被 adapter 破坏。
4. **`session/load`**：新进程 load 一个已有 session，重放出的 chunk 序列与 `session events` 逐条对齐。
5. **`mcpServers` 对不上时明说不接**（F 的守门测试：不静默、也不试图动态挂工具）。
6. 一次**真实 Zed 手测**记在落地记录里（不进自动化）。

## 3. 同一 commit 内必须同步的

`docs/PLAN.md` §3.11 删掉 ACP 那一行、M8 相应收窄 · `docs/tui.md`（`tui/` 目录说明多一个 entry，
§3 的模块表 + §7 说清 `nulya-acp` 不读 `tui.toml` 的哪些节）· `tui/build.ts` 的模块头
（今天那句"Only `src/main.tsx` is an entry point"要改）· `tui/package.json` 的 `compile` 脚本。

**不改**：`src/**` 一个文件都不动。本轮若发现必须改内核，那是设计错了——回来重读本文 §1。

## 4. 落地记录（2026-09-05）

落在 `tui/src/acp/` 五个文件（~910 行）+ `tui/test/acp.test.ts`（271 行）。**`src/` / `extensions/` /
`tests/` / `drivers/` 一个字节未动**，`tui/src/nulya/*` 与 `approvals.ts` 也一行没改——现成的绑定全够。
`build.ts` 两个 entry，一次编出 `nulya-tui` 与 `nulya-acp`。SDK 是 `@agentclientprotocol/sdk@1.4.0`
（它的 `PROTOCOL_VERSION` 是 1）。

- `main.ts` argv + stdio · `agent.ts` 那几个方法 · `updates.ts` 纯翻译 · `permission.ts` gate 那一侧 ·
  `catalog.ts` 冻结 manifest → `available_commands_update`。
- **ACP 的 `sessionId` 就是内核的 session id**——这正是 §E 说的「`session/load` 几乎白送」兑现的地方。
- 验收 1–5 全绿（`bun test test/acp.test.ts` → 5 pass / 0 fail）。四条把 agent app 在同进程里接上 **SDK
  自己的 client**（所以断言的是「一个 client 看到的协议」，不是 adapter 自言自语），`session/load` 那条
  真的 spawn 一个进程走真 stdio——「换个进程接得上」本来就是那条的全部主张。五条都驱动**真** `nulya`
  二进制，跑 scripted provider。第 3 条除了 `stopReason === cancelled` 还回头读 `session events` 核对
  每条 assistant-with-calls 后面都跟着 call id 同序的 `tool_results`——physics #7 没有被 adapter 破坏。
- `bunx tsc --noEmit` 干净。验收第 6 条（真实 Zed 手测）**还没做**。

### 契约没说、落地时定了的（七处）

| 处 | 怎么定的 |
|---|---|
| `note` 事件（§C 表里没有它） | 投成 `user_message_chunk`，与 PromptIR 一致（note 是一个只带文本的 turn）。不这么做，后台任务报告会从 client 眼前消失 |
| `session/load` 的返回 | 这个 SDK 的 `LoadSessionResponse` 是全可选对象，答 `{modes}` 而不是 §E 字面的 `null`——否则 load 出来的一场没有 new 出来的那份 mode 状态 |
| credential 缺失 | `internalError` 带内核那句原话，**不是** `authRequired`：`authMethods: []` 时给 client 一个它挑不出东西的鉴权流程是死路 |
| `retry` 行 | ACP 没有这个变体，也没有收回已发 chunk 的办法。作废的 delta 留在 client 屏幕上，retry 本身走 stderr。**adapter 侧修不了** |
| usage | SDK 的 `usage_update` 与 `PromptResponse.usage` 都标 UNSTABLE，所以按 §C「不编一个 update 出来」，每轮一行走 stderr |
| `presentation` 的 diff | ACP 的 `Diff` 要 `path` + 完整 `newText`，而我们带的是 unified patch，不重读文件就无损转不了。`std.edit` 的输出因此按文本进 |
| §F 的 mcp notice 时机 | 推迟到第一次 `session/prompt` 或 `session/load`：`session/new` 还没返回，client 不知道 session id，往一个它不认识的 id 上发通知没有意义。对得上的 `mcp.<name>` 走 `--with` 进成员，**绝不往活着的一场上挂工具** |

### 两处要人拍板的缺口

1. **广告了做不到的命令。** §C 让 `available_commands_update` 来自冻结的 `contributes.commands`，
   而**今天自带的三个命令（`/ask` `/evolve` `/plan`）动作全是 `{with}`**——那要求换 composition，
   而 composition 在 `session new` 就冻了（physics #2/#4）。所以 adapter 列得出它们、执行不了它们；
   ACP v1 里命令又是当**普通 prompt 文本**发回来的，adapter 连「这是一条命令」都分辨不出。
   三个候选：只列 `{run}`/`{skill}`（今天等于列空）· 照列不误，靠文本落到模型面前降级 ·
   让 `nulya-acp --with <id>` 在启动时就戴上，广告只当发现。**这是永久后果不是待修 bug**：
   在 ACP 里 session 由 client 创建，agent 没有开新场的手。
2. **人的 `[approvals]` 到不了编辑器这条路**（见 tui.md §7 那段）：要先决定 `nulya-acp` 读哪个文件。

### 没测到的

`plan` → ACP plan 的翻译，与 `note` 的映射。两者都要先 build `plan` 包（要 zig 工具链 + 每个 workspace
一次慢编译）；`consumers.test.tsx` 是「要不要为此加一道门」的先例。
