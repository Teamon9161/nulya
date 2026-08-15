# Nulya — 设计（现状）

> **这份文档只描述已经落地在 `src/` 里的架构与不变量。** 与代码同步维护：改内核语义，同一 commit 改这里。
> 未实现的方向、路线图、演化层设计全部在 [PLAN.md](PLAN.md)。拆分前的完整论辩记录在 `history/DESIGN-pre-split-2026-08-15.md`，读现状不需要它。
> 章节号是稳定 API（源码注释大量引用 `DESIGN §x`），沿用拆分前编号；不再适用的槽位写明"现状：无 → PLAN §y"。

一句话定位：**A minimal immutable kernel + a self-evolving native capability layer.**
Nulya 不是 plugin system，而是一个让 agent 能**制造、验证、积累、演化自身能力**的最小内核——内核只有两个工具（shell、edit），第三个工具由 Nulya 自己造出来。

三层地图：

```
Agent              决定学什么 / 造什么               ← 不在 kernel 里，是模型的推理
  ↓
Evolution Policy   决定什么值得留下 / 晋升            ← kernel 之上，可替换（§5.5、§15.2）
  ↓
Kernel             execute / version / observe / rollback / compose   ← 不可自生长（§15）
```

**Agent 决定学什么；Policy 决定什么值得留下；Kernel 保证学出来的东西可信、可追踪、可执行、可回退。** 这条分界是 Nulya 相对普通 plugin harness 的核心差异，也是抵抗 feature creep 的那把尺。

术语：**ledger** = 会话事件日志；**step** = 一次 model 请求-响应；**PromptIR** = provider 无关的 prompt 逻辑块投影；**composition** = 一场 session 冻结的能力面；**capability / tool id** = 稳定逻辑身份（`ext:<id>/<tool>`、`builtin.shell`），与具体 implementation version 分开。

---

## 0. 三条硬约束

1. **Ledger 从 API 层就不可变。** 会话是 append-only 事件日志，没有任何"改历史"的接口。目的：把 prompt-cache 命中率变成**可断言的不变式**。
2. **尽量少与模型交互。** 同一 turn 内多个 tool call 全部完成后合成**一条** user turn 回传，绝不一个工具一次请求。batch 的核心是不增加 round-trip，不要求并发。
3. **单文件可执行、离线可跑。** Zig 工具链 `@embedFile` 进二进制，拷一个文件过去就能编译 / 运行 extension。

三条都由 kernel 保证，不下放给"让 AI 自己实现"。

---

## 1. 缓存不变量：PromptIR 块级前缀

不对完整 HTTP request bytes 做断言（`{"messages":[A,B]}` 不可能是 `{"messages":[A,B,C]}` 的逐字节前缀）。kernel 保证的是 provider 无关的逻辑块前缀：

```
Ledger ──projection──▶ PromptIR { system_blocks, stable_blocks }
                            └──▶ provider serializer / cache policy
```

> **`PromptIR[N].stable_blocks` 是 `PromptIR[N+1].stable_blocks` 的前缀。**（`prompt.zig` `isStablePrefix`，单测断言）

`stable_blocks` 是 ledger 事件的纯函数（`user_text` / `assistant_text` / `tool_call` / `tool_result` / `capability_note` 五种 block）。`system_blocks` 来自冻结的 composition（§7.5），整场不变。Provider 负责把块前缀映射到自家 cache 机制（§13）。

会炸缓存的三件事及对策：

| 事件 | 对策 |
|---|---|
| 工具集合变化 | **对话内不改 `tools[]`**：session 开始选定并冻结（§5） |
| system prompt 变化 | system blocks 来自冻结 composition，整场不变 |
| compaction（重写前缀） | 尚未实现（§11）；设计见 PLAN §3.4（= 开新 ledger 文件） |

---

## 2. 架构总览

```
                    ┌────────────┐
                    │    LLM     │  ← 看到：builtin(shell, edit) + 本场选定的少量 native 工具
                    └─────┬──────┘
                          │  ToolSetSnapshot 每 step 冻结；PromptIR 前缀稳定
        ┌─────────────────┴──────────────────┐
        │              KERNEL                 │
        │  session.zig    AgentSession（编排）  │
        │  loop.zig       一次 step / batch     │
        │  ledger.zig     append-only 事件      │
        │  prompt.zig     PromptIR 投影         │
        │  composition    session 能力面冻结    │
        │  registry/tool  ToolSetSnapshot       │
        │  provider       Model vtable          │
        │  environment    shell/extension 执行  │
        │  extension/*    manifest/store/build  │
        │  tool_stats…    usage → rank → promote│
        └────┬──────────┬───────────┬──────────┘
          shell       edit      Extensions（子进程，JSON-RPC stdio）
       (builtin)   (builtin)    ← 经 shell `nulya ext run …`，或被晋升为 native
```

**Core 是 headless、以 ledger 为中心的引擎。** 目前唯一的"前端"是 `main.zig` 的 demo（固定 prompt，最多 4 步）和 `cli.zig`（不经模型）。交互式前端 / TUI / ACP / subagent 见 PLAN §3.2、§3.11。

---

## 3. Ledger（`ledger.zig`）

### 3.1 数据模型（当前 alphabet，仅 4 种）

```
user_text        []const u8
assistant        { text, calls: []ToolCall{id, tool, args_json} }
tool_results     []ToolResultEntry{call_id, ok, output, spill_path?}   ← 一条事件 = 一整批
capability_note  { id, version, text }                                  ← 中途新增能力的宣告（§5.3）
```

事件字母表**可加不可改**：现有四种保留原字段。`seq` 是文件落盘时的 envelope 字段（§3.4），不属于事件负载。

### 3.2 API（硬性）

唯一写口 `append(event)`（deep copy，调用方之后可释放一切 slice）；读只有 `view()` / `len()`。没有 edit / delete / reorder。"纠正" = 再 append。

`Ledger` 有两种后端：`init(alloc)` 纯内存（测试与不落盘路径）；`createDurable` / `openDurable` 加一个 session 文件后端（§3.4），此时每条 `append` 在返回前把事件作为一行 JSONL 落盘，落盘失败会回滚内存那一条，内存与文件永不背离。`view()` / `len()` 语义两种后端一致。

### 3.3 派生视图

UI / trajectory / metrics 是 ledger 的投影，不持久化 mutable 状态。**工具使用统计走另一条日志**（`.nulya/tool-usage.jsonl`，§5.5）——`nulya ext run` 在没有对话的纯 CLI 调用里也会产生 usage 事实，塞进 conversation ledger 会污染 prompt 前缀。原则相同：**persist facts, derive stats**。

### 3.4 Durable session 文件（generation == 文件）

一场 session = 一个 JSONL 文件 `.nulya/sessions/<id>.jsonl`：第一行是冻结的 header，之后每行一个 `{"seq":n,…}` 事件（seq 从 1 单调递增）。

```jsonl
{"kind":"header","v":1,"session":"s-…","parent":{"session":"s-…","seq":41}|null,"model":"openai","model_identity":{"provider":"openai","model":"gpt-4o-mini","base_url":"https://…","api_key_env":"OPENAI_API_KEY"},"created":"…","composition":{"active":[{"id":"web.search","version":"v-…"}],"native_tools":["ext:web.search/web_search"]}}
{"seq":1,"origin":"msg-….json","kind":"user_text","text":"…"}
{"seq":2,"kind":"assistant","text":"…","calls":[{"id":"…","tool":"…","args":"…"}]}
{"seq":3,"kind":"tool_results","results":[{"call_id":"…","ok":true,"output":"…","spill_path":null}]}
{"seq":4,"origin":"note-….json","kind":"capability_note","id":"…","version":"…","text":"…"}
```

（`origin` 只出现在经 inbox 排干进来的事件行上，是投递去重列，绝不投影给模型；见"单写者"条。）

- **一个文件 = 一个 generation = 一个 cache scope。** 文件只 append，所以 PromptIR 的 stable-block 前缀不变量（§1）成了文件系统性质。没有会 bump generation 的事件（§11）。
- **header 的 JSON 形状就是 `ledger.Header` 结构体**（`std.json` 类型化编解码，`OwnedHeader = std.json.Parsed(Header)`）；读端忽略未知字段，所以新写者多出的字段不破坏旧读者。事件行保持平铺的 `kind` 形状（driver 读起来方便），解码经 `WireEvent`。
- **composition + 模型身份冻结进 header。** header 记录本场 active 的每个 extension 的**具体版本**、被选为 native 的 tool 稳定 id，以及创建时**解析后的模型身份** `model_identity`（`provider` / 具体 `model` / `base_url` / `api_key_env`——`model` 字段本身只是 profile 别名，供显示与 effort 查询）。任何进程 `openDurable` 重开时都用 header 重建 composition（`composition.initFrozen`：读那些冻结版本、把 `native_tools` 当 pin），**绝不重扫 `current`、绝不重排 usage journal**——每个 `session step` 进程都看到**同一** composition，中途 `activate` 也移不动它（§5.1、§7.5、physics #2）。replay 时模型看到的一切 = header + events 的纯函数。
- **模型身份创建时冻结、resume 不可变（physics #2/#5）。** 模型解析**只有一处决定**：`launch.resolveDescriptor(prov, env, profile)` 在**创建**时把 profile 解析成 `model_identity`，运行用的 handle 也**只从这个 descriptor** 构建（`launch.buildFromDescriptor`）——所以"实际跑的" == "header 冻结的"，不存在 fork。`resolveDescriptor` 是 **credential-aware** 的：openai profile 若 `api_key_env` 在环境里解析不出 credential，创建时就冻结成 scripted（因为那正是会跑的东西）；此后 config 改动**永不**改变已有 session 的模型。resume 时 `session step` 用 header 的 `model_identity` 重建**恰好那个**模型，只从 `api_key_env` 重解 credential——**不存密钥**，也**没有静默 fallback**：openai session 的密钥不在了就 `MissingCredential` 显式拒跑。**durable credential 只以 `api_key_env` 引用**；inline `api_key` 无法在 resume 时从环境恢复（否则又让 session 依赖 mutable config），因此不参与 durable openai 身份。`provider==""` 的旧 header 当 scripted 处理。
- **resume。** `openDurable` 读回 header + 每条完整事件行；被截断的**最后一行**（写到一半崩溃）丢弃并把文件截回最后一条完整行，坏的**中间**行或乱序 `seq` 则是硬错误（`CorruptLedger`）。崩在 assistant-with-calls 之后（合法但未闭合的 batch）由 `completeInterruptedToolBatch` 在下一步补齐（§4）。
- **单写者租约 + inbox 目录 + cancel 标记。** session 文件**只有一个写者**：`createDurable` / `openDurable` 打开时**原子获取兄弟 `<id>.lock` 上的排他 advisory 锁**（`lock_nonblocking`），第二个写者的打开立刻 `SessionBusy` 失败，而不是去抢同一 offset；锁随句柄生命周期持有、进程崩溃时由 OS 释放（无 stale 锁）。锁挂在专用 `<id>.lock` 上、**不挂在 session 文件本身**——Windows 上文件自身的锁是强制性的会挡住读者，锁 sidecar 则让 `readHeader` / `session events` 的读永不被挡。其他任何进程都不写主文件，只往兄弟路径投递：跨进程**事件**（`ext activate` 在 `NULYA_SESSION` 存在时的 `capability_note`，§5.3；driver 的 `session append` 的 `user_text`）一事件一文件写进 `<id>.inbox/`（`ledger.depositEvent`：先写 `.tmp` 再 rename，排干端永不读到半个文件），由写者在 step 边界（`prepareStep`）按文件名序排干进主文件；**cancel 请求**是 `<id>.cancel` 标记（`session.requestCancel`），同样在 step 边界消费。
- **inbox 应用 exactly-once（投递 at-least-once）。** 每条排干进来的事件把它的 inbox 文件名作为 `origin` 落到 ledger 行上，`Ledger.origins` 集合是这一列、replay 时重建。若"append 进 ledger 成功 → 删 inbox 文件"之间崩溃，文件残留，下一次排干发现 `origin` 已在 ledger 里就只删不再 append——因此重复投递（同名文件再现）与崩溃都不会重复应用。`capability_note` 额外按内容（id+version）去重，任何名字下再宣告同一版本都是 no-op。单写者由 `<id>.lock` 租约独家保证——`persist` 不再做长度核对：那既非并发原语（租约已挡住第二写者），也非完整完整性检查（同尺寸覆写发现不了），ledger corruption 由 replay / seq / JSON 校验负责。读者（`session events`）只读原始行、不打开写句柄。排干只在 step 边界发生，任何投递事件绝不插进一条 batch 中间（§4 的 batch 不变量成立）。`parent` 是 fork / compaction 的机制（compaction 本身未实现，见 PLAN §3.4）。

---

## 4. Agent loop：一次 step（`loop.zig`）

```
freeze ToolSetSnapshot（本 step 不可变）
  ↓
model.step(PromptIR, tool_defs)  →  assistant turn（可能含多个 tool_use）
  ↓ append assistant
串行执行 A, B, C（当前 assert max_concurrent == 1）
  ↓
等全部 resolve —— 绝不提前回传单个结果
  ↓
按 call 顺序合成【一条】tool_results，append
  ↓
下一 step 才反映本 step 期间新增的能力（经 capability_note，不改 tools[]）
```

**ToolSetSnapshot = immutable for one model step。** A 在本 turn 激活了新能力，B、C 仍只见旧快照。

**Cancellation（step 边界消化，ledger 永远合法）：**

- provider 阶段取消：没有 assistant turn 形成，ledger 不动，返回 `status = .canceled`。
- 执行阶段取消：**不抛弃这一批**。已跑的 call 标 `tool execution was canceled; side effects may be partial or unknown`；结果落盘阶段取消标 `completed, but result recording was canceled`；未派发的标 `not executed because the step was canceled`。补齐整批后 append **一条** tool_results。
- 跨进程取消：`session.requestCancel` 在 session 文件旁写 `<id>.cancel`；`prepareStep` 在 step 边界消费它，这一步不调用模型、usage 为 0、返回 `.canceled`，`run` 就此停下。in-process（cancel 步骤的 `Future`）与跨进程（标记）是**同一个** kernel 语义的两种到达方式，都在 step 边界消化。
- `completeInterruptedToolBatch`：进程上次崩在 assistant-with-calls 之后，下次 `prepareStep` 先补一条"interrupted"批次，再继续。
- `prepareStep` 的顺序固定：补齐残尾 → 消费 cancel 标记 → 排干 inbox（§3.4）。
- `AgentSession.run(max_steps)`：预算 = `min(max_steps, session.max_steps_ceiling)`（天花板 50），由 kernel 强制；turn 结束、预算耗尽或任一 step 取消即停。

不变量：**一条 assistant tool-call batch ↔ 恰好一条匹配的 tool_results batch。** `session.recordCompletedToolStats` 直接按这个形状读 suffix 并 assert。

**输出纪律**（`emit.zig`，细节见 [base-tools.md](base-tools.md)）：每个 tool 结果过 head/tail 字节预算（UTF-8 边界截断），超限落盘到 `.nulya/scratch/` 留指针；每 step 另有聚合预算 `StepOutputLimiter`。落盘路径由 ledger seq 决定，replay 一致。

---

## 5. 工具面与缓存（核心决策）

### 5.1 对话内 `tools[]` 冻结

session 开始时一次选定，整场冻结（`composition.zig` `SessionComposition.init`）：

1. builtin `shell`、`edit`：永远在，位置最前。
2. 配置 pin 的 native 工具（`registry.pinned_native_tools`，稳定 id `ext:<ext-id>/<tool>`）。pin 是 operator 意图：解析不到 → **硬失败** `PinnedExtensionNotActive` / `PinnedToolNotDeclared`。
3. 按 usage 统计排序补足到 `max_tools`（含 builtin，默认 8）。best-effort：绑不上 / 撞名的按 rank 顺序跳过。

排序只在此刻发生一次。对话开头本就是新前缀、无缓存可炸，所以晋升零成本；**中途绝不重排**。

### 5.2 位置稳定

选入的 native 工具在 `tools[]` 里按稳定 id 排序（`registry.snapshotWith`），不因刚调用过就前移。同一 snapshot 内 `name` 与 `id` 都唯一；`shell` / `edit` 名字保留，extension 不能占用（manifest 校验）。

### 5.3 中途新增能力 = append 一条 `capability_note`

agent 在对话中经 shell `nulya ext build/activate` 造出新 extension 后：

- **不改 `tools[]`**。
- CLI 子进程（`nulya ext activate`）在 `NULYA_SESSION` 命名了 session 文件时，把一条 `capability_note` **投递**进该 session 的 inbox 目录（`<stem>.inbox/`，一事件一文件；文本确定性，列出 tools + `nulya ext run <id> <tool> '<json>'` 用法 + skills + `nulya skill load <ref>`）。它绝不直接写 session 文件——那是单写者（§3.4）。
- `session.prepareStep` 每步在 step 边界（补齐残尾之后、下一次 model 调用之前）**排干** inbox（`ledger.drainInbox`，机制通用于任何事件）：对 ledger 尚未宣告的 `id@version` append 一条 `capability_note`（note 文本由 `extension/notes.zig` 生成）。排干只在 step 边界发生，note 因此绝不插进一条 batch 中间。
- 前缀不动，缓存继续命中；模型下一 step 经 shell 调用。
- 下一场 session 的 §5.1 第 3 档里凭统计有机会晋升进 `tools[]`。

> **晋升发生在对话边界，对话中途只追加 note。**

（纯内存 session（`Ledger.init`）没有 inbox 可排；投递/排干只对 durable session 生效。）

### 5.4 为什么不做动态 promotion / eviction

每次中途 activate / evict 都改 `tools[]` = 全量 cache miss，与头号诉求正面冲突。§5.1–5.3 拿到 stats 驱动增长的全部好处而零缓存代价。

### 5.5 Usage journal → ranking → promotion（Evolution Policy v1）

```
.nulya/tool-usage.jsonl   每行 {"v":1,"tool_id":"ext:web.search/web_search","ok":true}
        └─ projection ─▶ ToolStats { uses_total, uses_recent, last_used, success_rate }   (tool_stats.zig)
        └─ tool_selection.rank(facts, weights) ─▶ 排序（纯函数）
        └─ promotion.rankExtensionTools ─▶ ranked ids ─▶ composition 第 3 档补位
```

- 写入点：session 每个 completed step 后按 suffix 形状记一次（`session.recordCompletedToolStats`；模型幻觉的名字不记）；CLI `nulya ext run` 成功进入 invocation 后记一次。**`tool_id` 跨实现版本累计**（无 `version` 字段）。
- reader：`v` 未知精确报错（`UnsupportedStatsVersion`）；坏行 / 残尾容忍。
- 分层不变量：`facts → ranking preference → composition availability/budget → frozen membership`。`rank` 只吃 facts + weights，绝不碰 pins / max_tools / Binding。

> **Facts are durable; policy is replaceable.** 权重、K、算法都是 v0.1 selection policy，不是 kernel invariant；底层 facts 不动就能整个换掉。**Activation**（当前 implementation 是哪个 version）与 **Promotion**（逻辑能力要不要进下一场 native 面）是两条独立状态轴，永不合并成一个分数。

version-aware evidence / lineage / verify 见 PLAN §3.5。

---

## 6. 两个内置工具（`tools/`）

### 6.1 shell

单一工具，schema 恒定 `{ "command" }`；系统提示告知 `shell_dialect = bash | powershell`（由 Environment 决定，§8）。所有 `nulya …` CLI 都经它调用 → 模型工具面极小。读文件也交给 shell（`cat` / `rg` / `sed`）：读本就要一个 round-trip，native read 不省，故不单列。

### 6.2 edit

精确匹配 + 优质报错：`old_string` 唯一匹配替换 / `replace_all` / 新建 / 删除，原子写。不做 fuzzy patch（apply 失败多一轮 round-trip，违反 §0.2）。apply 失败要给可操作的上下文，让模型一轮纠正。

细节与数字见 [base-tools.md](base-tools.md)。

---

## 7. Extension 模型（`extension/`）

**Package ≠ Runtime ≠ Contribution**——这是本节的脊椎：

- **Package**：可安装、可版本化、可 rollback 的能力包。**可以没有可执行文件**（纯 Skill 包合法）。
- **Runtime**：只有当某个 Contribution 需要代码时才存在的子进程。
- **Contribution**：Package 向 kernel 贡献的东西。**Tool 只是其中一种。**

| Contribution | 状态 | 说明 |
|---|---|---|
| Tool | ✅ | 经 executor 进 ToolSetSnapshot；builtin / extension 同构 |
| Skill | ✅ | `SKILL.md` + 渐进披露，经 `nulya skill load`；无需 runtime |
| System prompt | ✅ | manifest `contributes.system_prompts[]`：静态文本，build 期校验 UTF-8 + 大小上限，进 snapshot 参与 version；session 组合时按稳定 id 顺序拼进 system blocks |
| Hook / Command / Provider / SessionDriver | ⚪ | 未实现，见 PLAN |

**硬约束（Nulya 相对 Pi 类 harness 的核心差异）：**

> 任何 **model-visible** 的东西必须能从 ledger 重建。Extension 只能 **propose**，kernel **append**，PromptIR **project**。Extension 永不 rewrite PromptIR / system prompt。

### 7.1 形态：原生可执行 + stdio JSON-RPC

Extension = 子进程；wire protocol 就是 ABI。不用 `.so/.dll`（ABI / Zig 版本 / crash 带死 host / allocator 所有权），不用 WASM（与原生 + 内嵌工具链冲突，削弱语言无关性）。协议不绑定语言，runtime 有两种，由 `runtime.entry` 前缀区分（纯语法、无需探盘）：

- **编译 Zig**：`entry = "bin/<name>"`，`nulya ext build` 从 `src/main.zig` 编译出 `bin/<name><exe>`；version 含 compiler identity。
- **脚本**：`entry = "src/<file>"`（+ 可选 `runtime.interpreter`，如 `powershell` / `sh` / `python3`），**不编译**，原样冻结进 `package/`，运行时 spawn `[interpreter, <frozen entry>]`（无 interpreter 则直接执行，如 Windows `.cmd` / 带 shebang 的可执行）；version = `hash(snapshot)`**不含** compiler identity，因此跨机器、跨 zig 版本稳定（§7.4）。

`nulya ext init --script` 按宿主平台生成脚本骨架（Windows `run.ps1` + powershell / 其余 `run.sh` + sh）。脚本与编译 extension 共用 seal / integrity / store / activate / rollback / usage，区别只在"是否编译"和 hash 是否含 compiler。

### 7.2 目录与 manifest（`nulya.extension/v2`）

```
.nulya/extensions/<id>/          ← draft（可变）
├── extension.json
├── src/main.zig                 ← 有 runtime 时
└── skills/<name>/SKILL.md       ← 声明的 skill 目录
```

```json
{
  "schema": "nulya.extension/v2",
  "id": "web.search",
  "runtime": { "entry": "bin/web-search" },
  "contributes": {
    "tools": [{ "name": "web_search", "description": "…", "input": { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] } }],
    "skills": ["skills/risk-parity"],
    "system_prompts": ["prompts/finance.md"]
  },
  "permissions": { "fs": [], "network": ["https"], "process": [] }
}
```

校验（`manifest.zig`）：schema id 精确匹配；`id` 合法；**至少一种 contribution**（`NoContributions`）；有 tool 时必须有 `runtime`（`MissingRuntime`）；tool 名不能是 `shell`/`edit`、不能重复；`entry` / skill / system_prompt 路径不能逃出包目录。**manifest 是 schema 唯一真相**：绝不"启动 binary 再问它有什么"。

`tools[].input` schema 只在该 tool 被晋升进 `tools[]` 时才喂给模型；平时是可发现性元数据。

### 7.3 Wire protocol（`protocol.zig` / `invoke.zig`）

JSON-RPC 2.0，oneshot：spawn → stdin 一条 request → stdout 一条 response → exit。

```json
{ "jsonrpc": "2.0", "id": 17, "method": "tool/call", "params": { "name": "web_search", "arguments": { "query": "…" } } }
{ "jsonrpc": "2.0", "id": 17, "result": { … } }
{ "jsonrpc": "2.0", "id": 17, "error": { "code": -32000, "message": "…", "data": { "retryable": true } } }
```

- 响应 `id` 必须与请求相同，否则 invalid response。
- 只有 `tool/call` 一个 method，用专用 `ToolCallRequest` 类型；**不提前抽通用 JsonRpcRequest**，等第二个 method 真出现。
- 不做 daemon / persistent worker / streaming / host callback。spawn 一个原生 binary ≈ 毫秒，对比模型 round-trip 秒级可忽略；最高频的 shell/edit 是 in-core 内置根本不 spawn。真正的成本是某些 extension 每次调用的重初始化（浏览器 / DB 连接）——**先测量再持久化**（PLAN §3.3）。

### 7.4 生命周期：不可变版本 + 原子切换（`store.zig` / `integrity.zig` / `build_ext.zig`）

```
draft ──build──▶ versions/v-<hash>（immutable）──activate──▶ current
                                                    ▲
                                          rollback = current 指回旧版本
```

- **version id = `hash(canonical PackageSnapshot + compiler_identity + target)`，其中 `compiler_identity` 与 `target` 只对 compiled extension 非空。** 三种 implementation kind（`manifest.ImplementationKind`）决定什么进身份：`data`（无 runtime，纯 skill / system_prompt）与 `script`（`src/…` 冻结即跑、不编译）都是**纯 snapshot 身份**，`compiler_identity = target = ""`，因此跨平台稳定、**建时根本不需要 zig**；只有 `compiled`（`bin/…` 由 Zig 编出，二进制依赖编译器与 host target）才把两者算进 hash。snapshot 收 `extension.json`、有 runtime 时的 `src/**`、声明的 skills / system_prompts 目录，按 `relative_path + len + bytes` 排序 hash；`versions/`、`.zig-cache/` 不进。（seal.json 仍记录 host / compiler / target 作为诊断元数据——metadata ≠ identity。）
- 版本目录冻结 snapshot：编译 extension 得 `versions/v-…/{extension.json, package/src/**, package/skills/**, bin/<entry><exe>}` + seal（含 `binary_digest`）；**编译从 frozen `package/src/main.zig` 进行**，不读 mutable draft。脚本 extension 得 `versions/v-…/{extension.json, package/src/**, …}` + seal（`binary_digest` = null；脚本已在 `package/src/` 里被 package_digest 覆盖），运行入口 = `package/<entry>`。同源码再 build = 同 version，`already_built`。
- `current` 是普通文本文件（不是 symlink：Windows 需特权且无收益），原子 rename 切换。
- 更新 = build 新版本 → activate；rollback = `current = old`。B 挂了 A 完全不动。
- deterministic validation 是 kernel 不变量（§12）；"这个参数是否通用"属 policy，**policy hook 尚未实现**（config 能解析 `policy.hook`，无人消费；PLAN §3.12）。

### 7.5 组合在 session 开始冻结（keystone）

`SessionComposition.init()` 解析 active extensions，pin 住每个的版本，一次冻结 tools / skills / system prompts。被 pin / 晋升的 native 工具在此刻解析出**绝对 `entry_path`**（基于 pin 时的版本），运行期只按此路径 spawn，**绝不二次读 `current`**。

推论：session 中途 AI 重写出 `web.search` v2 并 activate，**当前 session 已 native 注册的仍是 v1**；v2 只能经 shell `nulya ext run` + note 告知；下一场 session native 才换。`tests/e2e.zig` 全环证明。

这不是新机制，是 §5.1 的 frozen snapshot 延伸到整个 Contribution 层。

### 7.6 工具的上下文模型：tool 拿不到 ledger

**tool 是无状态纯函数 `f(args, environment, ctx) → result`。**

| 信息类型 | 持有者 | tool 如何获得 |
|---|---|---|
| 事实性 / 持久（文件、命令输出） | 工作区文件系统 | 经 environment 直接读；fs = 共享持久记忆 |
| 语义性 / 对话（"决定用方案 B"） | ledger（模型上下文） | **不给 tool**；模型提炼进 `args` |

不给 ledger 的四条理由：模型是上下文路由器；大对话每次 spawn 序列化开销爆炸；最小权限；`args → result` 纯函数才可复现。

**当前 tool 实际拿到的：** in-core builtin 拿 `ToolContext{ environment, fs, cwd }`；extension 子进程只拿 **JSON-RPC request + 净化后的 env + cwd**（`environment.runExtensionImpl`），没有别的。一个恒定大小的显式 `ctx_header`（os / dialect / scratch / 预算 / 权限描述，经 env var 或 `_ctx` 注入）属 PLAN。

tool↔tool 共享知识只走两条路：**模型中转**（大结果落盘留指针，指针流动）与**磁盘制品**（`.nulya/cache/`）。禁止 tool 直接互调 / 共享内存态。

> **凡"真的需要对话 / ledger"的东西，就不是 tool，而是 subagent。**（subagent 未实现，见 PLAN §3.2）

### 7.7 Skill（`skill.zig` / `extension/skills.zig`）

- 直接兼容 Agent Skills：`<name>/{SKILL.md, scripts/, references/, assets/}`，frontmatter 至少 `name` + `description`。
- 渐进披露：session 开头 system block 里放 `<available_skills>` 摘要（name + description + `load:` 命令）；模型经 shell `nulya skill load <ref>` 拉完整 `SKILL.md`。`ref` 是 pinned 引用，隐藏物理路径。
- 不做第三个 builtin。当前 skill 只有 extension 一个来源，`SkillRegistry` 直接吃 `list/get`，**不抽 SkillProvider**（第二个来源出现再抽）。

Tool 是"能执行的能力"，Skill 是"要遵循的方法 / 知识"；不同 registry，互不侵占模型工具面。

---

## 8. Execution Environment（`environment.zig`）

```
Environment { runShell(cmd, dialect) / runExtension(entry, request_json) / dialect() }
```

只有 `local` backend。`sandbox` / `remote` 在 config 里能解析，运行期直接报 `UnsupportedEnvironmentBackend`（PLAN §3.8）。ACP 不是 Environment（那是 editor→agent 的通信协议，方向相反，归前端层）。

---

## 9. Authority（诚实版）

**明确不假装 `manifest.permissions` 是安全边界。** AI 生成的原生 binary = 任意机器码；`"network": []` 在没有 OS 强制时拦不住 `curl`。当前：

- extension 与 shell 共享同一个 session authority（≈ 当前用户全权限）。明说，不给虚假安全感。
- **env 净化**：子进程 env 过 `isSecretKey` denylist（大小写不敏感子串：`SECRET / TOKEN / PASSWORD / API_KEY / ACCESS_KEY / PRIVATE_KEY / CREDENTIAL / SSH_AUTH_SOCK …`）。非 secret 变量（PATH / HOME）照传，命令才能工作。边界是"无明显 secret 泄漏"，**不是**完全不继承、也不是 fs 隔离。
- 不变量：`extension_permissions ⊆ session_authority`；注册成 extension 不获得 shell 没有的权限。
- OS 强制（sandbox）见 PLAN §3.8。

### 9.5 配置链（`config.zig` / `default.toml`）

```
@embedFile default.toml
  ↓ merge   system   /etc/nulya/config.toml | %ProgramData%\nulya\config.toml
  ↓ merge   user     ~/.config/nulya/config.toml | %AppData%\nulya\config.toml
  ↓ overlay project  .nulya/config.toml   ← 不可信输入，过 mergeProject 只能收窄
```

标量 set 即胜，列表按 key 合并。project 层**可以更严不能更松**：可 pin 工具、选 profile、调严 policy、调小 K；**不可**关 policy hook、把 backend 从 sandbox 降级 local、注入 `api_key_env` 名字外泄 host env（单测覆盖）。这与 §9 的 `extension_permissions ⊆ session_authority` 是同一个不变量的两面：checkout 一个 repo 不该能拓宽机器权限。

承载：`provider.profiles[]{name, kind=openai|scripted, model, base_url, api_key_env, api_key?, effort?}` · `registry{max_tools, pinned_native_tools, weights{uses_recent, uses_total, last_used, success_rate}}` · `policy.hook`（解析、未消费）· `environment{backend, shell}` · `compaction{…}`（解析、未消费）· `extensions.paths`。

secret 不入文件：config 只持 `api_key_env` 名字，真值留 host env，绝不下传子进程。config 在 session 开始解析成 effective 值一次；磁盘改动下一场生效。

---

## 10. 内嵌 Zig 工具链（`toolchain.zig`）

- 宿主平台那一份 Zig（pinned 0.16.0）`@embedFile` 进二进制，首次需要时解压到 `~/.local/share/nulya/toolchains/zig/<ver>/`（`XDG_DATA_HOME` 优先；Windows: `%LOCALAPPDATA%\nulya\`）。一份宿主 Zig 可交叉编译所有 target。
- 代价 +50–90MB；换来零网络、零 hash 校验、零版本漂移。
- 内嵌由 `-Dembed-toolchain -Dzig-archive=<path>` 门控；日常 `zig build test` 不嵌，e2e 用 `NULYA_TEST_ZIG` 指向宿主 zig。
- AI 不直接 `zig build`，走 `nulya ext build`（nulya 统一 zig 版本 / optimize=ReleaseSafe / target / cache）→ 可复现构建。`nulya toolchain zig <args>` 供 scratch。

---

## 11. Compaction 与 generation

**现状：无 compaction。** **generation == ledger 文件**（§3.4）：一个文件只 append、只一个 generation，所以前缀不变量是文件系统性质，没有会 bump generation 的事件，`prompt.currentGeneration()` 已删除（`Request.generation` 处直接传 0）。`compaction.*` config 键能解析但无人消费。compaction = 开新文件（`--parent` 指向旧文件与切分点）见 PLAN §3.4。

---

## 12. 质量门

**现状 = deterministic validation**：manifest schema（§7.2）· seal / integrity 校验（load 时对照 hash）· 协议往返（响应 id 匹配）· 权限形状。这些是 kernel 不变量。

**尚未有 Verify 门**：`nulya ext test` 未实现；`nulya ext init` 的模板会生成 `tests/*.json` 真实验收用例（`templates.zig`），但目前无人跑它。**门通过 ≠ 正确**，只是"没有明显坏"——对模型和用户都要说清。Validate / Verify 分层与 Seal-then-Verify 见 PLAN §3.5.4。

---

## 13. Provider（`provider.zig` / `providers/openai.zig`）

```
Model { ptr, vtable { name, modelName, capabilities, stream(request, sink) } }
Request { prompt_ir, tools, generation, options{max_output_tokens?, effort?} }
StreamEvent: started | text_delta | thinking_delta | thinking_signature | tool_use_start | tool_use_input_delta | usage | done(StopReason)
TurnCollector → ModelTurn { text, calls, usage, stop_reason }
ProviderCapabilities { parallel_tool_calls, deferred_tools, explicit_cache_breakpoints, cached_token_metrics, thinking_replay, vision, tool_result_images }
```

- Provider 在 generation 稳定的块边界放 / 声明 cache breakpoint（tools 之后、system 之后、最后一条稳定消息之后）。
- 已实现：`openai`（chat/completions，流式，读 `usage.prompt_tokens_details.cached_tokens` / `prompt_cache_hit_tokens` 进 `Usage.cache_read_tokens`）与 `scripted`（demo / 测试）。**Anthropic provider 未实现**（PLAN §3.9）。
- Provider 只能优化序列化，不能破坏 §1 的块前缀不变量。

---

## 14. CLI 表面（`cli.zig`；都不是 LLM tool，经 shell 调用）

```
nulya ext init [--script] <id> [tool] | build <path>
          | run <id> [tool] (<json-args> | --arg k=v …)
          | activate <id> <version> | rollback <id> <version> | deactivate <id>
          | list | inspect <id> | api [protocol|permissions|examples]
nulya session new [--model p] [--parent <id>:<seq>]      ← 冻结 composition + 写 header，打印 session id
          | append <id> <text|--file f>                  ← 把一条 user turn 投进 inbox（下一 step 边界进 ledger）
          | step <id> [--max-steps N]                    ← 跑到本 turn 结束或预算耗尽；stdout = 本次 append 的事件 JSONL
          | events <id> [--since N] [--follow]           ← 只读 tail 原始事件行（follow 轮询）
          | cancel <id>                                  ← 写 cancel 标记，下一 step 边界消化
nulya skill list | load <pinned-ref>
nulya toolchain zig <args…>
nulya                       ← 无参数：固定 prompt demo（现经 durable session 路径跑，§3.4）
```

- `nulya ext api`：协议 / 权限 / 示例由当前二进制自己生成——模型永远查本机，不查训练记忆里的旧 API。
- `nulya session *` 是**唯一**的 session 驱动面：没有 `setTools / setModel / replaceHistory`，换 composition = `session new`。每个子命令是对 durable session 文件（§3.4）的一次独立进程调用，其中**只有 `step` 写主文件**：`append` / `cancel` 投递到 `<id>.inbox/` / `<id>.cancel`（所以正在跑的 `step` 会在它的下一个 step 边界拿到 mid-run 的 append 或 cancel），`events` 是只读 tail（不解析、不重编码——文件本身就是 wire format）。`step` 的预算 `min(--max-steps, session.max_steps_ceiling)` **由 kernel 在 `AgentSession.run` 强制**，driver 只能调低不能调高；`--max-steps` 必须是正整数。session 就是它的文件，没有 `close`。
- `nulya ext activate` 在 `NULYA_SESSION`（相对 workspace 的 session 文件路径）存在时，向该 session 的 inbox 投一条 capability_note（§5.3）。
- 离线时 provider 回落到确定性的 scripted stand-in（`NULYA_SCRIPTED_MODE=finish|loop`，测试用）。

（`ext find` / `ext test` 未实现。）

---

## 15. 分界：frozen core / learnable / non-goals

### 15.1 FROZEN CORE（v0.1，不再改语义；只往外挂能力）

```
Ledger append-only 语义                          ledger.zig
AgentSession 编排 + interrupted-batch repair     session.zig
cancellation 语义（step 边界消化）               loop.zig / session.zig
shell / edit 永久 builtin                         tools/
immutable package + 内容寻址版本                  extension/store.zig, integrity.zig
build / activate / rollback / integrity           extension/build_ext.zig, store.zig
extension JSON-RPC tool/call                      extension/protocol.zig, invoke.zig
SessionComposition 版本冻结（pin + auto 同一路径） composition.zig
ToolExecutor / Binding（builtin/extension 同构）   tool.zig, extension/tools.zig
skills + 渐进披露 catalog                          skill.zig, extension/skills.zig
system prompts 投影                                prompt.zig, composition.zig
durable append-only usage journal                  tool_stats.zig
ranking policy（纯函数）                           tool_selection.zig
session-boundary 自动晋升                          promotion.zig → composition.zig
```

**可自生长（内核之上皆可学习）：** grep / glob / git / web-search / browser / pdf / excel / db / github / docker / lsp / … 全是 extension，不进 kernel。

### 15.2 三层：kernel 是 primitives，policy 是 interpretation

Kernel 只提供 primitives（`activate(version)` · `rollback(version)` · usage facts · frozen composition）；**Evolution Policy** 在其上消费 primitives 产出判断（retain / promote / rollback）。当前 `tool_selection.rank()` 就是第一代 Evolution Policy（§5.5）。**Facts are durable; policy is replaceable.**

### 15.3 Non-goals（永不做成 core subsystem，属 Agent / Policy 层）

GapDetector · WorkflowMiner · ToolSynthesisManager · AutoRefactor · RewardModel · AutoPromptOptimizer · SkillPopularityEngine。kernel 不 hard-code "shell 重复 3 次 → 造工具"这类启发式。

每当想往 core 塞东西，问一句：**这是 substrate 还是 intelligence？** 若属 intelligence，放到 kernel 之上。

> **Nulya does not make capability evolution intelligent in the kernel.
> It makes capability evolution safe, observable, reversible, and learnable.**

---

## 16. 里程碑与实现状态

> **Nulya v0.1 自带两个工具。第三个工具由 Nulya 自己创造。**

`tests/e2e.zig`（真实 built binary，无 mock）证明：一个只暴露 shell + edit 的 session，由 deterministic 模型经这两个 builtin 跑 `nulya ext init/build/activate/run` 亲手造出新扩展并记录 usage，全程该工具不进 native 面；下一个 session 排名这份 usage 后把它自动晋升为 native 工具并按冻结版本执行；mid-session activate v2 后 session native 仍 v1 / CLI live v2 / 新 session native v2。

**已落地 / 未落地的一句话清单在 [CLAUDE.md](../CLAUDE.md)「现状一句话」；去向在 [PLAN.md](PLAN.md) §1 路线图。** 开发历史（底座 7 组提交等）见 `history/v0.1.md`。

> 到这一步，项目最大的风险已不是"缺东西"，而是"**继续觉得还缺东西**"。后续都是往这个稳定核心外挂能力，不是继续改 kernel。

---

## 17. 已否决的替代方案（简表；理由已在各节）

| 方案 | 否决理由 | 节 |
|---|---|---|
| 动态 promotion / eviction 改 `tools[]` | 每次都是全量 cache miss | §5.4 |
| `.so/.dll` 动态链接 extension | ABI / 版本 / crash 带死 host / allocator | §7.1 |
| WASM in-process | 与原生 + 内嵌工具链冲突，削弱语言无关性 | §7.1 |
| 纯 patch 式 edit | fuzzy 上下文 apply 失败多一轮 round-trip | §6.2 |
| 给 tool 传 ledger（或 ledger 文件路径） | 开销 × N、路由塞进 tool、毁最小权限与可复现 | §7.6 |
| ACP 作为 Environment backend | 方向相反：ACP 是 client→agent，Environment 是 agent→世界 | §8 |
| 按需下载 Zig + hash 校验 | 网络 / 漂移 / 失败处理整套复杂度；内嵌净简化 | §10 |
| 启动 binary 询问其 tools（describe()） | source / manifest / runtime 三份状态漂移 | §7.2 |
| per-command 输出过滤子系统 | accretion；统一 `emit` + 自动落盘兜底 | base-tools.md |
| Pi 式 lifecycle event 洪流 / extension 直接改 system prompt | 破坏 Ledger→PromptIR 纯投影 = 破坏全部 cache 不变量 | §7 |
