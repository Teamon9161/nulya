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

术语：**ledger** = 会话事件日志；**step** = 一次 model 请求-响应；**PromptIR** = provider 无关的 prompt turn 投影；**composition** = 一场 session 冻结的能力面；**capability / tool id** = 稳定逻辑身份（`ext:<id>/<tool>`、`builtin.shell`），与具体 implementation version 分开。

---

## 0. 三条硬约束

1. **Ledger 从 API 层就不可变。** 会话是 append-only 事件日志，没有任何"改历史"的接口。目的：把 prompt-cache 命中率变成**可断言的不变式**。
2. **尽量少与模型交互。** 同一 turn 内多个 tool call 全部完成后合成**一条** user turn 回传，绝不一个工具一次请求。batch 的核心是不增加 round-trip，不要求并发。
3. **单文件可执行、离线可跑。** Zig 工具链 `@embedFile` 进二进制，拷一个文件过去就能编译 / 运行 extension。

三条都由 kernel 保证，不下放给"让 AI 自己实现"。

---

## 1. 缓存不变量：PromptIR turn 级前缀

不对完整 HTTP request bytes 做断言（`{"messages":[A,B]}` 不可能是 `{"messages":[A,B,C]}` 的逐字节前缀）。kernel 保证的是 provider 无关的逻辑前缀：

```
Ledger ──projection──▶ PromptIR { system_blocks, turns }
                            └──▶ provider serializer / cache policy
```

> **`PromptIR[N].turns` 是 `PromptIR[N+1].turns` 的前缀。**（`prompt.zig` `isStablePrefix`，单测断言）

`turns` 是 ledger 事件的纯函数，一个事件一个 turn，四种（`user_text` / `assistant{reasoning, text, calls: []prompt.ToolCall{id, tool, args_json}}` / `tool_results: []prompt.ToolResult{call_id, ok, output}` / `capability_note`）——**turn 不拆散**：三个 wire 全都要 turn 级结构（assistant 的文本与 calls 同属一条 message、一批结果是一个 turn），拆成字符串块只会让每个 provider 把刚被丢掉的边界再推一遍。`reasoning` 是 assistant turn 的**字段**（没有就是 `""`，只有声明 `thinking_replay` 的 provider 才序列化，且永远排在该 turn 的 text / calls 之前）。`assistant.usage` / `assistant.stop_reason` / 结果的 `spill_path` / 事件的 inbox `origin` **在类型里根本没有字段**——"不投影"因此是类型的事实，不是要靠人记住的纪律（§3.1、§3.4）。call / result 因此是 PromptIR **自己的**类型（`prompt.ToolCall` / `prompt.ToolResult`，字符串仍借 ledger 的）而不是复用 `ledger.*`：两者回答的问题不同——ledger 记**模型产出了什么**，PromptIR 记**什么可以发给 provider**，两者只在被 `max_tokens` 切断的那一 turn 上分岔（§4）。`turns` 只借 ledger 事件的 slice、自己只拥有那个数组，所以 PromptIR 不会活得比它投影自的 ledger 更久（每个调用方都是 step 前投影、step 后丢掉）。`system_blocks` 来自冻结的 composition（§7.5），整场不变。Provider 负责把这个前缀映射到自家 cache 机制（§13）。

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
        │  tool_stats     usage facts（只记不判）│
        └────┬──────────┬───────────┬──────────┘
          shell       edit      Extensions（子进程，JSON-RPC stdio）
       (builtin)   (builtin)    ← 经 shell `nulya ext run …`，或被 pin 成 native
```

**Core 是 headless、以 ledger 为中心的引擎。** 目前唯一的"前端"是 `main.zig` 的 demo（固定 prompt，最多 4 步）和 `cli.zig`（不经模型）。交互式前端 / TUI / ACP / subagent 见 PLAN §3.2、§3.11。

---

## 3. Ledger（`ledger.zig`）

### 3.1 数据模型（当前 alphabet，仅 4 种）

```
user_text        []const u8
assistant        { reasoning, text, calls: []ToolCall{id, tool, args_json}, usage?, stop_reason }
tool_results     []ToolResultEntry{call_id, ok, output, spill_path?}   ← 一条事件 = 一整批
capability_note  { id, version, text }                                  ← 中途新增能力的宣告（§5.3）
```

事件字母表**可加不可改**：现有四种保留原字段。`seq` 是文件落盘时的 envelope 字段（§3.4），不属于事件负载。

**`calls[].args_json` 是模型实际产出的那些字节**，包括被 `max_tokens` 切断时的半截 JSON 前缀——ledger 记事实，不记"应该是什么"。把它变成可发给 provider 的东西是投影的事（`prompt.ToolCall`，§4）。

**`assistant.reasoning` 是不透明字段，不是第五种事件。** 它是 provider 原样吐出的本轮 reasoning item 的 JSON 数组（Anthropic 的带 signature 的 `thinking` / `redacted_thinking` block、Responses 的带 `encrypted_content` 的 `reasoning` item），没有则为 `""`。它是本轮的**事实**（模型确实产出了这段、且下一步要原样带回），不是模型可见文本：kernel 从不解析它，作为 assistant turn 的 `reasoning` 字段交回 provider，provider 只在自己认得（`ProviderCapabilities.thinking_replay`）时按原样回放到**同一个模型**——它天然 model-locked，而 session 的 `model_identity` 已冻结（§3.4），所以别的模型永远看不到它。为什么必须有它：Anthropic 一方端点在 thinking 开着时**拒绝**丢了 thinking block 的 tool-use turn（400，而 Opus 5 默认开、Fable 5 只能开），Responses 端点不带则模型每一步重推上一步的计划——前者是正确性，后者是质量与 token；两者都不是 kernel 该替 provider 决定的，kernel 只负责把这个事实存住、按序交回。落盘时只在非空才写 `reasoning` 字段（老行形状不变，老行读回为 `""`）。

**`assistant.usage` 与 `reasoning` 同地位：本轮的事实，不投影。** `?Usage{input_tokens, output_tokens, cache_read_tokens, cache_write_tokens}`（`ledger.Usage`；`provider.Usage` 就是它的 re-export，provider 本来就 import ledger——一个 struct 贯穿到底，loop 不做转换），由 `loop.zig` 从 `ModelTurn.usage` 写入。落盘只在**非空**时写 `usage` 对象：provider 什么都没报（scripted 替身、流中途取消）时整条不写，老行读回 `null`——"没记录"与"花了 0"是两个不同的事实。**`prompt.Turn` 里没有它的字段**：模型不读自己的账单；它是给慢速回路与前端的成本证据（`session events` / `--stream` 的 ledger 行天然带上，`session list --json` 按它求和）。provider 阶段就被取消的 step 没有 assistant 事件可挂，其 usage 不落盘——诚实接受，不为它造新事件。

**`assistant.stop_reason` 同地位：模型为什么停，是本轮的事实，不投影。** `StopReason{end_turn, tool_use, max_tokens, other}` 声明在 `ledger.zig`（`provider.StopReason` 就是它的 re-export，与 `Usage` 同一手法——一个 enum 贯穿到底），由 `loop.zig` 从 `ModelTurn.stop_reason` 原样写入。**落盘只写 shape 说不出来的那两个**：`end_turn` / `tool_use` 就是 `calls` 空 / 非空，读回时按 `calls.len` 推导，所以正常结束的行与这个字段存在之前逐字节相同；`max_tokens` / `other` 推不出来，才写 `"stop_reason":"<tag>"`。`max_tokens` 是承重的那个（§4）：被切断的 text-only 回复与正常结束的回复 shape 完全一样，而后果要跨进程。老行里的 `"truncated":true` 仍读得回来（= `max_tokens`，它当年唯一的含义），但**永不再写**；不认识的 tag 是 `CorruptLedger`，不是静默默认值。

### 3.2 API（硬性）

唯一写口 `append(event)`（deep copy，调用方之后可释放一切 slice）；读只有 `view()` / `len()`。没有 edit / delete / reorder。"纠正" = 再 append。快照落在 ledger 自己的 arena 里——append-only 加整体释放就是一个生命周期，所以事件负载不需要每种形状各自的 clone/free 链；一次失败的 append 弹掉内存那一条、字节留在 arena 到 `deinit`（append-only 的内存本来就随历史增长）。

`Ledger` 有两种后端：`init(alloc)` 纯内存（测试与不落盘路径）；`createDurable` / `openDurable` 加一个 session 文件后端（§3.4），此时每条 `append` 在返回前把事件作为一行 JSONL 落盘，落盘失败会回滚内存那一条，内存与文件永不背离。`view()` / `len()` 语义两种后端一致。

### 3.3 派生视图

UI / trajectory / metrics 是 ledger 的投影，不持久化 mutable 状态。**证据走 ledger 之外的 journal**，本节这两条都是 append-only JSONL、都在 workspace 的 `.nulya/` 下（第三条 `trusted-stores.jsonl` 记的不是证据而是一次授权，因此在 **user** 层，§9），共用同一套文件纪律（`journals/journal.zig`：一行一条；**多写者**——每个 `session step` / `ext run` / `session outcome` 进程都写同一个文件，所以 append 全程持有旁车 `<journal>.lock` 的排他 lease（阻塞式，临界区只有一次 stat + 一次写），两个 append 不可能落到同一 offset；append 前修残尾；**读端不拿锁、忽略最后一个 `\n` 之后的残尾**（被打断或正在进行的那次 append），完整但畸形的行仍是 consumer 的显式错误——宽恕的是被打断的写、不是坏 journal，所以 `session list` 不会在一次 crash 后到下一次写之前一直失败；文件不存在 = 还没有事实；schema 各自持有；目录不存在意味着什么由各 journal 自己定——workspace journal 当 host fault，user 层的 trust journal 当"还没有记过"）**与同一个时钟**（`journal.rfc3339Now`：三条 journal 的 `at` 与 session header 的 `created` 是同一个格式的同一个函数，所以它们读得进同一条时间轴）：

| journal | 一行 | 谁写 | 为什么不是 ledger 事件 |
|---|---|---|---|
| `.nulya/tool-usage.jsonl`（§5.5） | `{"v":1,"at":"<RFC3339 UTC>","session":"s-…"?,"tool_id":…,"ok":…,"duration_ms":N?}` | session 每个**真的执行过 tool 的** completed step；`nulya ext run` | 纯 CLI 调用没有对话，塞进 ledger 会污染 prompt 前缀 |
| `.nulya/session-outcomes.jsonl` | `{"v":1,"session":"s-…","verdict":"success\|partial\|failure","note":…?,"at":"<RFC3339 UTC>","source":"agent"?,"by":"s-…"?,"seq":N?}` | 人或 agent 经 `nulya session outcome`（§14） | session 尾往往没有下一个 step 来排干 inbox；verdict 是**关于**这场 session 的判断、不是其中一轮；不给 `prompt.zig` 开"存了但不投影"的事件种类 |

原则相同：**persist facts, derive stats**。outcome 的三条语义：**没有行 = unknown ≠ failure**；同一 session 可多行，**最后一条作数**（纠正也是 append，`outcome.latestFor`）；三个可选列说明**谁在评**与**评的是什么**，且**只在非默认时写**——所以人评整场的行与这三列存在之前逐字节相同，schema 版本不动：

- **`source` 缺省 = 人**（`human`）。`agent` = 这条是从某个 session 自己的 shell 里写的（`nulya session outcome` 认 `NULYA_SESSION`，§5.3）——模型正是这样够得着这个命令的，于是"被评的那场自己评自己"从此是记下来的事实而不是慢速回路要猜的事。不认识的 `source` 是显式错误、**绝不当成人评**（与未知 verdict 同一条纪律）：把别人的判断读成人的判断，正是这一列要防的那件事。
- **`by`** = 写这条的那个 session（只与 `source:"agent"` 同现），所以 `by == session` 一眼可见是自评。
- **`seq` 可选** = 对**某一轮 assistant turn** 的判断（PLAN §3.7.8）。`latestFor` **只看整场行**：一条 turn 级的纠正永远不会悄悄变成这场 session 的成绩。

`session outcome` 不碰 session 文件、不拿 `<id>.lock`，所以正在被 `step` 的 session 也能当场评；`--seq` 同理**不去核对**这个 seq 在不在这场里——为一个读者自己能派生的事实换掉"对活着的 session 也安全"这条性质不划算。

### 3.4 Durable session 文件（generation == 文件）

一场 session = 一个 JSONL 文件 `.nulya/sessions/<id>.jsonl`：第一行是冻结的 header，之后每行一个 `{"seq":n,…}` 事件（seq 从 1 单调递增）。

```jsonl
{"kind":"header","v":1,"session":"s-…","parent":{"session":"s-…","seq":41}|null,"model":"openai","model_identity":{"provider":"openai","model":"gpt-4o-mini","base_url":"https://…","api_key_env":"OPENAI_API_KEY"},"created":"…","nulya":{"version":"0.0.0","kernel_hash":"f49f…"},"composition":{"active":[{"id":"web.search","version":"v-…"}],"native_tools":["ext:web.search/web_search"]}}
{"seq":1,"origin":"msg-….json","kind":"user_text","text":"…"}
{"seq":2,"kind":"assistant","reasoning":"[{\"type\":\"thinking\",…}]","text":"…","calls":[{"id":"…","tool":"…","args":"…"}],"usage":{"input_tokens":1200,"output_tokens":80,"cache_read_tokens":1100,"cache_write_tokens":0},"stop_reason":"max_tokens"}
{"seq":3,"kind":"tool_results","results":[{"call_id":"…","ok":true,"output":"…","spill_path":null}]}
{"seq":4,"origin":"note-….json","kind":"capability_note","id":"…","version":"…","text":"…"}
```

（`origin` 只出现在经 inbox 排干进来的事件行上，是投递去重列，绝不投影给模型；见"单写者"条。`reasoning` 只在该 turn 有 reasoning 时出现，值是 provider 数组转义成的一个 JSON 字符串——ledger 只存不解析；`usage` 只在 provider 报了成本时出现；`stop_reason` 只在 shape 说不出来时出现（`max_tokens` / `other`，见 §3.1、§4）。三者都不投影。）

- **一个文件 = 一个 generation = 一个 cache scope。** 文件只 append，所以 PromptIR 的 turn 前缀不变量（§1）成了文件系统性质。没有会 bump generation 的事件（§11）。
- **header 的 JSON 形状就是 `ledger.Header` 结构体**（`std.json` 类型化编解码，`OwnedHeader = std.json.Parsed(Header)`）；读端忽略未知字段，所以新写者多出的字段不破坏旧读者；**但 `v` 不同就拒绝**（`ledger.format_version` = 1，别的值一律 `UnsupportedLedgerVersion`）——多出的字段不改变已有字段的含义，换了版本号则正是在宣告"改了"，把未来格式当 v1 读只会读出一个像是对的答案。`session step` / `session new --parent` 把它翻成"这个文件由更新的 nulya 写的，本二进制读 ledger v1"并退出 1，`session list` 跳过该文件（它本来就跳过读不了的）。事件行保持平铺的 `kind` 形状（driver 读起来方便），解码经 `WireEvent`。
- **composition + 模型身份冻结进 header。** header 的 `composition.active` 记录本场**每个成员 extension** 的具体版本——activate 来的**和** `session new --with` 带进来的（§14），键名 `active` 是 v1 wire 遗留（那时成员只能来自 activate），下次升 header schema 版本时一起改名；`native_tools` 是被选为 native 的 tool 稳定 id（两根轴分开：冻结版本 ≠ 进模型工具面）。还有创建时**解析后的模型身份** `model_identity`（`provider` / 具体 `model` / `base_url` / `api_key_env`——`model` 字段本身只是 profile 别名，供显示与 effort 查询）。任何进程 `openDurable` 重开时都用 header 重建 composition（`composition.initFrozen`：读那些冻结版本、把 `native_tools` 当 pin），**绝不重扫 `current`、绝不重排 usage journal**——每个 `session step` 进程都看到**同一** composition，中途 `activate` 也移不动它（§5.1、§7.5、physics #2）。replay 时模型看到的一切 = header + events 的纯函数。header 还记 `nulya{version, kernel_hash}`（build 的版本串 + kernel system prompt 与两个 builtin 定义的 hash，`composition.kernelHash`）——**纯 provenance**：这两样是**二进制的**编译期常量却进了本场冻结的 model-visible 状态（§5.1、§7.5），升级 nulya 就会在既有 session 底下换掉它们，而 header 原本无从指认；记下来只是让它可见，resume 时对不上就在 stderr 警告一行照跑（不拒绝、不改任何东西），空 stamp = 这个字段之前写的老 header = unknown，永不警告。
- **模型身份创建时冻结、resume 不可变（physics #2/#5）。** 模型解析**只有一处决定**：`launch.resolveDescriptor(prov, env, profile)` 在**创建**时把 profile 解析成 `model_identity`，运行用的 handle 也**只从这个 descriptor** 构建（`launch.buildFromDescriptor`）——所以"实际跑的" == "header 冻结的"，不存在 fork。`resolveDescriptor` 是 **credential-aware** 的：openai profile 若 `api_key_env` 在环境里解析不出 credential，创建时就冻结成 scripted（因为那正是会跑的东西）；此后 config 改动**永不**改变已有 session 的模型。resume 时 `session step` 用 header 的 `model_identity` 重建**恰好那个**模型，只从 `api_key_env` 重解 credential——**不存密钥**，也**没有静默 fallback**：openai session 的密钥不在了就 `MissingCredential` 显式拒跑。**durable credential 只以 `api_key_env` 引用**；inline `api_key` 无法在 resume 时从环境恢复（否则又让 session 依赖 mutable config），因此不参与 durable openai 身份。`provider==""` 的旧 header 当 scripted 处理。
- **resume。** `openDurable` 读回 header + 每条完整事件行；被截断的**最后一行**（写到一半崩溃）丢弃并把文件截回最后一条完整行，坏的**中间**行或乱序 `seq` 则是硬错误（`CorruptLedger`）。崩在 assistant-with-calls 之后（合法但未闭合的 batch）由 `completeInterruptedToolBatch` 在下一步补齐（§4）。
- **单写者租约 + inbox 目录 + cancel 标记。** session 文件**只有一个写者**：`createDurable` / `openDurable` 打开时**原子获取兄弟 `<id>.lock` 上的排他 advisory 锁**（`lock_nonblocking`），第二个写者的打开立刻 `SessionBusy` 失败，而不是去抢同一 offset；锁随句柄生命周期持有、进程崩溃时由 OS 释放（无 stale 锁）。锁挂在专用 `<id>.lock` 上、**不挂在 session 文件本身**——Windows 上文件自身的锁是强制性的会挡住读者，锁 sidecar 则让 `readHeader` / `session events` 的读永不被挡。其他任何进程都不写主文件，只往兄弟路径投递：跨进程**事件**（`ext activate` 在 `NULYA_SESSION` 存在时的 `capability_note`，§5.3；driver 的 `session append` 的 `user_text`）一事件一文件写进 `<id>.inbox/`（`ledger.depositEvent`：先写 `.tmp` 再 rename，排干端永不读到半个文件），由写者在 step 边界（`prepareStep`）按文件名序排干进主文件；**cancel 请求**是 `<id>.cancel` 标记（`session.requestCancel`），同样在 step 边界消费。
- **inbox 应用 exactly-once（投递 at-least-once）。** 每条排干进来的事件把它的 inbox 文件名作为 `origin` 落到 ledger 行上，`Ledger.origins` 集合是这一列、replay 时重建。若"append 进 ledger 成功 → 删 inbox 文件"之间崩溃，文件残留，下一次排干发现 `origin` 已在 ledger 里就只删不再 append——因此重复投递（同名文件再现）与崩溃都不会重复应用。`capability_note` 额外按内容（id+version）去重，任何名字下再宣告同一版本都是 no-op。单写者由 `<id>.lock` 租约独家保证——`persist` 不再做长度核对：那既非并发原语（租约已挡住第二写者），也非完整完整性检查（同尺寸覆写发现不了），ledger corruption 由 replay / seq / JSON 校验负责。读者（`session events`）只读原始行、不打开写句柄。排干只在 step 边界发生，任何投递事件绝不插进一条 batch 中间（§4 的 batch 不变量成立）。`parent` 是 fork / compaction 的机制（compaction 本身未实现，见 PLAN §3.4）。

---

## 4. Agent loop：一次 step（`loop.zig`）

```
freeze ToolSetSnapshot（本 step 不可变）
  ↓
collectTurn(PromptIR, tool_defs)  →  assistant turn（可能含多个 tool_use）；瞬态线路故障按 §13 原样重发，ledger 不动
  ↓ append assistant
串行执行 A, B, C
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
- `AgentSession.run(max_steps)`：预算 = `min(max_steps, session.max_steps_ceiling)`（天花板 50），由 kernel 强制；turn 结束、预算耗尽、任一 step 取消、或**连续 `max_truncated_streak`（2）个 step 被 `max_tokens` 截断**即停。

**Truncation（`stop_reason == max_tokens`，模型这一步被输出上限切断）：** 与 cancellation 正交——那是宿主控制，这是模型停止原因（`StepOutcome.stop_reason`）。被截断的回复**不是一个完成的 turn**：它说了的文本与 reasoning 是事实、照记；它开了头的 call 不是模型的本意，参数还可能是半截 JSON——原样回放进 provider 的 `input`（anthropic 用 `writeRaw`）会让这场 session 之后每一步都 400。所以：calls **照记原样**（连半截 JSON 一起，ledger 存的是事实），**一个都不执行**，而"可回放"由**投影**保证——`prompt.projectWithSystem` 在这一 turn 上把不是完整 JSON 值的 `args_json` 换成 `{}`（`std.json.validate`，只对 `stop_reason == max_tokens` 的 turn 做，别的 turn 上同样的字节是模型自己的输出、一字不动）。两条性质因此同时成立：行还说得出模型产出了什么，而没有任何发不出去的东西到得了 wire。用一条 marker 批次关掉（`not executed: the reply hit its output cap (max_tokens) …`，文本同时告诉模型发生了什么、怎么绕过——写短、或一步一步来），返回 `stop_reason = .max_tokens`。没有 call 的截断回复只是 text-only assistant，`run` 因 `lastAssistantDone` 停下，driver 见 `stopped: max_tokens`（TUI 提示"发一条消息继续"——裸再 step 会让 assistant 结尾成 prefill，thinking 开着时 provider 拒绝）。有 call 的截断回复 `run` 会再走一步让模型看到 marker 重试；连续两次即停（`max_truncated_streak`：**只有可重试的、带 call 的截断走得到这个上限**，text-only 那种当场就停），避免装不下上限的东西反复重试、每次计费整个前缀。（tcode 同一问题的做法：keep + 关闭 dangling call + 追加一条 note + 最多重试两次；这里 note 的内容放进 marker result 里，不给 kernel 加"kernel 对模型说话"的事件种类。）内核默认不设 `max_output_tokens`（anthropic 必填故给 32k），调大上限是 config / provider 层的事。

**截断是落盘的事实，不只是运行时的：** assistant 事件带 `stop_reason`（`ledger.Event.assistant`，与 `usage` 同地位——不投影、只在 shape 说不出来时写进行，见 §3.1）。理由不是 provenance 而是**上面那条保护跨不过进程边界**：`run` 是在**走完一步之后**才看 `lastAssistantDone`，所以第二次 `nulya session step <id>`（没有新消息）会无条件先走一步，把那条 assistant turn 当 prefill 发出去——正是这里要躲的 400。进程 2 手上只有 ledger，进程 1 的运行时状态随它一起没了，而一条被切断的 text-only 回复与正常 `end_turn` 逐字节相同：`calls` 空、shape 一样。所以 `lastStopReason()` 本身就是一次 ledger 读（最后一条 assistant 事件的 `stop_reason`，没有就 `end_turn`），跑过这一步的进程与只是 resume 的进程给出同一个答案。所以 `AgentSession.step` 在 `prepareStep` **之后**（新排干的 inbox 事件正是让它重新可 step 的输入）查 `lastAssistantTruncated()`，是就以 `error.TruncatedTurnNeedsInput` 失败、什么都不 append；`session step` 把它翻译成 "the last reply was cut off at its output cap; append a message before stepping again" 并非零退出。**这不是新的 kernel policy**，是让 `run` 里本来就有的那个判断活过进程边界；追加任何东西（用户消息、排干的 inbox 事件）就自然解除。

不变量：**一条 assistant tool-call batch ↔ 恰好一条匹配的 tool_results batch。** `session.recordCompletedToolStats` 直接按这个形状读 suffix 并 assert。**PromptIR 永远可回放，ledger 存事实**：`prompt.ToolCall.args_json` 一定是完整 JSON 值，`ledger.ToolCall.args_json` 是模型写出来的那些字节。

**输出纪律**（`emit.zig`，细节见 [base-tools.md](base-tools.md)）：每个 tool 结果过 head/tail 字节预算（UTF-8 边界截断），超限落盘留指针；每 step 另有聚合预算 `StepOutputLimiter`——预算约束的是**正文**，不约束可见性：装不下的结果保留 prefix + 一条**完整**的落盘指针 footer（footer 是每个结果的保底、不计入预算；比 footer 还短的结果直接保留原文、不落盘），所以 batch 里的执行顺序不决定模型能看到哪个结果，一个 step 的可见工具文本 ≤ `max_bytes` + 每 call 一条 footer。落盘在 `.nulya/scratch/<session-id>/tool-output/`：文件名由 ledger seq + call index 决定（session 内 replay 一致），session id 这一层让并发 session（fork 的父子、compact driver 与 observer）不会写同一个文件。

---

## 5. 工具面与缓存（核心决策）

### 5.1 对话内 `tools[]` 冻结

session 开始时一次选定，整场冻结（`composition.zig` `SessionComposition.init`）：

1. builtin `shell`、`edit`：永远在，位置最前。
2. **pin 的 native 工具**（稳定 id `ext:<ext-id>/<tool>`），两个来源同义、并集去重：`registry.pinned_native_tools`（config，project 层也可以加——只花自己的槽，§9.5）与 `session new --pin`（driver，按场）。pin 是决定：解析不到 → **硬失败** `PinNamesUnknownExtension` / `PinToolNotDeclared` / `InvalidStableToolId`，总数越过 `max_tools`（含 builtin，默认 8）→ `ToolBudgetExceeded`。

只有这两档。**usage 自己绝不改 `tools[]`**——journal 是证据，晋升是有人写下一条 pin（§5.5）。

第 1 档（两个 builtin 的定义）与 kernel system prompt（§7.5）都是**二进制的编译期常量**，不由 header 冻结——所以它们的 hash 与 build 版本串一起记进 header 的 `nulya` stamp（§3.4），换了二进制 resume 时会警告。

### 5.2 位置稳定

选入的 native 工具在 `tools[]` 里按稳定 id 排序（`registry.snapshotWith`），不因刚调用过就前移。同一 snapshot 内 `name` 与 `id` 都唯一；`shell` / `edit` 名字保留，extension 不能占用（manifest 校验）。

### 5.3 中途新增能力 = append 一条 `capability_note`

agent 在对话中经 shell `nulya ext build/activate` 造出新 extension 后：

- **不改 `tools[]`**。
- CLI 子进程（`nulya ext activate`）在 `NULYA_SESSION` 命名了 session 文件时，把一条 `capability_note` **投递**进该 session 的 inbox 目录（`<stem>.inbox/`，一事件一文件；文本确定性，列出 tools + `nulya ext run <id> <tool> '<json>'` 用法 + skills + `nulya skill load <ref>`）。它绝不直接写 session 文件——那是单写者（§3.4）。
- `session.prepareStep` 每步在 step 边界（补齐残尾之后、下一次 model 调用之前）**排干** inbox（`ledger.drainInbox`，机制通用于任何事件）：对 ledger 尚未宣告的 `id@version` append 一条 `capability_note`（note 文本由 `extension/notes.zig` 生成）。排干只在 step 边界发生，note 因此绝不插进一条 batch 中间。
- 前缀不动，缓存继续命中；模型下一 step 经 shell 调用。
- 下一场 session **若被 pin** 才进 `tools[]`（§5.1 第 2 档）；没人 pin 就一直是 CLI 形式。

> **晋升 = 下一场的 pin，对话中途只追加 note。**

（纯内存 session（`Ledger.init`）没有 inbox 可排；投递/排干只对 durable session 生效。）

### 5.4 为什么不做动态 promotion / eviction

每次中途 activate / evict 都改 `tools[]` = 全量 cache miss，与头号诉求正面冲突。§5.1–5.3 让能力照常增长而零缓存代价：中途只 append note，工具面的改变一律等下一场——那时改的是一条 pin，而下一场本来就是新前缀。

### 5.5 Usage journal（evidence）

```
.nulya/tool-usage.jsonl   每行 {"v":1,"at":"2026-08-17T09:31:07Z","session":"s-1786-3f",
                                "tool_id":"ext:web.search/web_search","ok":true,"duration_ms":812}
        └─ projection ─▶ ToolStats { uses_total, successes, last_used_seq }   (journals/tool_stats.zig)
        └─ 读者：人、或 evolution session（PLAN §3.7）——内核里没有读者
```

- 写入点：session 每个 completed step 后按 suffix 形状记一次（`session.recordCompletedToolStats`；模型幻觉的名字不记）；CLI `nulya ext run` 成功进入 invocation 后记一次。**被 `max_tokens` 截断的 step 不记**——它的 tool_results 是 loop 自己写的 marker（没有任何 executor 跑过，§4），记下去等于让 tool 为模型的输出上限背一次失败，直接污染 evolution 读的 `success_rate`。stats 是**执行之后的观测**，"host 认为这一步完成了" 不等于 "tool 跑过了"。**`tool_id` 跨实现版本累计**（无 `version` 字段）。
- `ok` 之外的三列是让这堆调用变成慢速回路读得懂的证据：**`at`** 把一次调用放上时间轴（`append` 自己盖，没有调用方能忘）；**`session`** 让它 join 到 `session-outcomes.jsonl`（这次调用服务的那场 session 成了吗）——durable session 是文件 stem，`nulya ext run` 从 `NULYA_SESSION` 认（§5.3），所以**未 pin 的 extension tool 走 CLI 那条路也认得出场次**；**`duration_ms`** 是 `ok` 说不出的成本维度（能用但要一分钟的 tool 与能用的 tool 不是同一个事实），只由 loop 在 executor 两端用**单调时钟**量（不进 ledger：耗时是 journal 的事实，不是对话的事实；也不出 `AgentSession.step()` 的返回值），所以 `nulya ext run` 那条路没有这一列。
- **三列都是可选、`v` 仍是 1**：加宽之前写下的每一行原样读回，缺的列是 null = "没记录"，绝不是 0；内存 session 没有 id、`ext run` 没量耗时，也照样缺。完整的行读端仍然严格。
- reader：`v` 未知精确报错（`UnsupportedStatsVersion`）；坏行 / 残尾容忍；同一 `v` 下未知列忽略。
- **内核不读这条 journal。** 没有排序、没有权重、没有自动补位：`journals/tool_stats.zig` 只负责把 facts 老老实实写下来、读回来。

> **内核只存 facts；晋升是内核之外做的决定**——一个人，或 evolution session（PLAN §3.7），读完 journal 写下一条 pin（`registry.pinned_native_tools` 或 `session new --pin`），下一场生效。它有真实成本（一个 `max_tools` 槽 + 每场的前缀 token），所以该有人为它负责，而不是由一个公式代劳。**Activation**（当前 implementation 是哪个 version）与 **Promotion**（逻辑能力在不在 native 面上）仍是两条独立状态轴：前者是 `current` 指针，后者是一条 pin，永不合并成一个分数。

version-aware evidence / lineage / verify 见 PLAN §3.5。

---

## 6. 两个内置工具（`tools/`）

### 6.1 shell

单一工具，schema 恒定 `{ command, cwd?, timeout_ms? }`；系统提示告知 `shell_dialect = bash | powershell`（由 Environment 决定，§8）。所有 `nulya …` CLI 都经它调用 → 模型工具面极小。读文件也交给 shell（`cat` / `rg` / `sed`）：读本就要一个 round-trip，native read 不省，故不单列。

**超时是内核常量，不是 config**（`tool.Timeouts`，base-tools.md §3）：默认 120s、上限 600s，模型给的 `timeout_ms` 夹进 `[1, 600000]`（非正整数当场教学式拒绝，不替它换个数）。到点 `kill` 子进程，并把**被杀前已捕获的输出**连同 `[timed out after <n> ms; process killed, output above is partial]` 一起返回（`ok=false`、`[exit 1]`）——超时不是丢弃。实现上 `child.wait` 仍是唯一的取消点，只是和一个 sleep 任务放进 `std.Io.Select` 赛跑（与 §13 stall watchdog 同一个形状）；io 给不出两个并发单元就裸跑（没有假超时，只是没有守卫）。

**杀的是整棵进程树**（`environment.Tree`，超时与取消同一条路径）：只杀直接子进程不够——`bash -lc "a; b"` 会为最后一条命令 fork，Windows 的 Git Bash `bin\bash.exe` 更是个 launcher、真正的 shell 是**孙进程**；活下来的那个还攥着管道写端，drain 就永远等不到 EOF，于是"超时"只给结果贴了个标签、并没有真的把这一步放出来。所以 POSIX 让子进程自成 process group（`pgid = 0`，exec 前设好）、`killAll` 对负 pid 发信号；Windows 让子进程挂起启动、先塞进一个 job object 再 resume，`killAll` 终止整个 job。

两边同一条规则，且**只在终止时成立**：**超时 / 取消杀整棵树，正常返回不杀**。Windows 的 job **不带任何 limit**——尤其不带 `KILL_ON_JOB_CLOSE`：那会让句柄一关就杀光这条命令启动的一切，既与 POSIX（只在超时 / 取消时发信号）不一致，也毁掉一个正当用法——一次 shell 调用里 `some-server >/dev/null 2>&1 &`、下一次调用再用它。错误路径本来就由调用方的 `killAll` 兜底，所以这个 flag 什么也没多买。**但后台进程必须重定向 stdio**，否则它继承着管道写端、而 drain 要把两个管道读到 EOF，这次调用就一直等到它退出为止（这是 drain 一贯的行为，不是树引入的）。

OS 不给 job（老 Windows 的嵌套限制、或 nulya 自己跑在受限 job 里）就降级成只杀直接子进程并在 stderr 说一句——**不因此让 spawn 失败**。extension 的 oneshot 调用走同一个 `Tree`、同一张表的 30s（§7.3）。

### 6.2 edit

精确匹配 + 优质报错：`old_string` 唯一匹配替换 / `replace_all`，原子写。不做 fuzzy patch（apply 失败多一轮 round-trip，违反 §0.2）。apply 失败要给可操作的上下文，让模型一轮纠正。

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

### 7.2 Store roots：搜索顺序（首个 active 持有者胜）

extension 装在**多个 store root** 里，按固定顺序搜索（`extension/roots.zig` 的 `Roots`）：

| # | root | 谁写 | 备注 |
|---|---|---|---|
| ① | workspace `.nulya/extensions` | 默认 | 一个 checkout 自己的能力 |
| ② | user `<NULYA_HOME \| ~/.nulya>/extensions` | `--user` | 造一次、每个 workspace 都有 |
| ③ | `extensions.paths`（**只认 trusted 层**，§9.5） | operator | project 层写了也忽略 |

- **同一个 id 在多个 root → 首个持有 active 版本（有 `current`）的 root 胜**（workspace 遮蔽 user）。"持有"看 `current` 不看目录：一个只有 `<id>/` 目录、没有 `current` 的 root（draft、或已 `deactivate` 的副本）**不参与遮蔽**——否则在 workspace `deactivate` 会静默藏起 user 那份而不是让它生效。同一定义贯穿 `Roots.listActive`（composition / `skill list`）、`Roots.firstActive`（`ext run`、`--with` 不带版本、`ext deactivate` 的落点）与 `ext list` 的 `(shadowed)` 标记；`ext deactivate` 作用于生效的那份，若因此让后面 root 的副本顶上来会打印一行 note。
- **frozen 版本按 root 顺序找**（`initFrozen`、`skill load` 的 frozen ref、`ext run <id>@<version>` 的 entry）：version 是内容寻址的，integrity 照验，所以顺序只决定"在哪找到"，从不决定"跑什么"。精确地说：data / script 版本的 id 就是 snapshot 的 hash，任意 root 的副本**严格**同字节；compiled 版本的 id 是 `snapshot + compiler + target` 的 hash，二进制 digest 只进 seal 不进 id，所以"两个 root 各自编出的同 id 副本同字节"是**可复现构建不变量**（同源、同编译器、同 target），不是数学保证——不为此重构 build identity，只是别把它当定理。
- **`--user` 从 session 里跑会说一句。** `ext activate|rollback --user` 在 `NULYA_SESSION` 存在时（= 模型经 `shell` 调的），动手前往 **stderr** 打一行 `note: activating <id>@<version> in the user store from inside session <sid>: it becomes active for every workspace on this machine`，该版本若声明了 system_prompts 再接 ` and its system prompt enters every future session`。**照做，不拦**：模型有权这么做，在内核的外壳里长出一条 policy 才是错的；不许的是**悄悄**这么做。不带 `--user`、或不在 session 里，一个字不说。
- **写端的落点：`activate` / `rollback` 作用于该 id 生效中的那个 root**（`Roots.firstActive`）：在那里激活才真的生效；在被遮蔽的 root 里激活会"成功"却改变不了任何 session 看到的东西。所以要激活的版本若不在生效 root 里 → 明确失败（并指出它建在哪个 root、可用 `--user` 显式打到 user store）；只有当该 id **在任何 root 都没有 active 副本**时才按 `firstWithVersion` 找首个持有该 built 版本的 root。操作完成后重新算一次 `firstActive`：只有生效的 `{root, version}` 真的是目标时才向 live session 投 capability_note（§5.3），否则打印 `note: not in effect — <id>@<v> in <root> shadows it`（`--user` 显式打进被遮蔽的 root 时会遇到）。`deactivate` 同样作用于生效的那份。
- **每个 `<id>/` 的变更都在 `<root>/<id>/.lock` 下进行**（`Store.lease`：build 写 `versions/<v>`、activate / rollback 改 `current`、deactivate 删 `current`；阻塞式排他 advisory 锁，与 session 的 `<id>.lock` 同一原语）——user store 被这台机器上的每个 workspace 共写，两个进程同时 build / activate 同一个 id 不能互相撕对方的目录树或共用一个 `.current.tmp`。读端不拿锁：`current` 是原子 rename，版本目录靠 seal 校验。
- **header 不记 root**（`active` 仍是 `{id, version}`）：记了就等于把一台机器的目录布局冻进会话，而那与"跑的是哪份字节"无关。
- 不存在的 root 是**缺席**不是错误（多数机器没有 user store）；写端（`ext init --user` / `ext build --user`）需要时才创建。
- **为什么 project 层不能加 root**：一个 root 决定"这台机器上哪些目录可以供出 `current`"，即哪些代码可以被跑起来——checkout 能加就是拓宽权限，正是 §9.5 "只能收窄"禁止的事。同一条理由的另一面是 **workspace root 自己就在 checkout 里**，所以它有一道一次性的 trust gate（§9）：随 clone 到达的 store 要被人信任一次（`nulya ext trust`）才进 composition，本机 `ext build` 建出来的则自动可信。只读投影不过门。

### 7.2.1 目录与 manifest（`nulya.extension/v2`）

```
<store root>/<id>/               ← draft（可变）
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
    "tools": [{ "name": "web_search", "description": "…", "input": { "type": "object", "properties": { "query": { "type": "string" } }, "required": ["query"] }, "timeout_ms": 60000 }],
    "skills": ["skills/risk-parity"],
    "system_prompts": ["prompts/finance.md"]
  },
  "permissions": { "fs": [], "network": ["https"], "process": [] }
}
```

校验（`manifest.zig`）：schema id 精确匹配；`id` 合法；**至少一种 contribution**（`NoContributions`）；有 tool 时必须有 `runtime`（`MissingRuntime`）；tool 名不能是 `shell`/`edit`、不能重复；`timeout_ms` 若写了必须是正数且 ≤ `tool.Timeouts.extension_max_ms`（600s），否则 `InvalidTimeout`；`entry` / skill / system_prompt 路径不能逃出包目录。**manifest 是 schema 唯一真相**：绝不"启动 binary 再问它有什么"。

`tools[].input` schema 只在该 tool 被 pin 进 `tools[]` 时才喂给模型；平时是可发现性元数据。

`tools[].timeout_ms?` 是**这个 tool 自己**的 wall-clock 上限（缺省 = host 的 30s，§7.3）：知道自己慢的 tool 在 manifest 里说出来，因为 manifest 就是关于一个 tool 的唯一真相。第一个用它的是随仓库带的 `extensions/compact`——它要等一次真实的 model step，30s 一定不够。

### 7.3 Wire protocol（`protocol.zig` / `invoke.zig`）

JSON-RPC 2.0，oneshot：spawn → stdin 一条 request → stdout 一条 response → exit。

```json
{ "jsonrpc": "2.0", "id": 17, "method": "tool/call", "params": { "name": "web_search", "arguments": { "query": "…" } } }
{ "jsonrpc": "2.0", "id": 17, "result": { … } }
{ "jsonrpc": "2.0", "id": 17, "error": { "code": -32000, "message": "…", "data": { "retryable": true } } }
```

- 响应 `id` 必须与请求相同，否则 invalid response。
- 一次调用的 wall-clock 上限来自 `tool.Timeouts.extension_ms`（30s，与 shell 同一张表，§6.1 / base-tools.md §3），**除非该 tool 的冻结 manifest 自己声明了 `timeout_ms`**（§7.2.1，上限 `extension_max_ms` = 600s，与 shell 的上限同值）：到点 kill，并把已捕获的 stderr 一起折成一次**失败的调用**（不是 host error、更不是取消）。native pin 的路径（`ext_tools.Binding`）与 CLI 的路径（`nulya ext run`）读的是同一个 manifest 字段，所以两边不会分岔。
- 只有 `tool/call` 一个 method，用专用 `ToolCallRequest` 类型；**不提前抽通用 JsonRpcRequest**，等第二个 method 真出现。
- 不做 daemon / persistent worker / streaming / host callback。spawn 一个原生 binary ≈ 毫秒，对比模型 round-trip 秒级可忽略；最高频的 shell/edit 是 in-core 内置根本不 spawn。真正的成本是某些 extension 每次调用的重初始化（浏览器 / DB 连接）——**先测量再持久化**（PLAN §3.3）。

### 7.4 生命周期：不可变版本 + 原子切换（`store.zig` / `integrity.zig` / `build/build_ext.zig`）

```
draft ──build──▶ versions/v-<hash>（immutable）──activate──▶ current
                                                    ▲
                                          rollback = current 指回旧版本
```

- **version id = `hash(canonical PackageSnapshot + compiler_identity + target)`，其中 `compiler_identity` 与 `target` 只对 compiled extension 非空。** 三种 implementation kind（`manifest.ImplementationKind`）决定什么进身份：`data`（无 runtime，纯 skill / system_prompt）与 `script`（`src/…` 冻结即跑、不编译）都是**纯 snapshot 身份**，`compiler_identity = target = ""`，因此跨平台稳定、**建时根本不需要 zig**；只有 `compiled`（`bin/…` 由 Zig 编出，二进制依赖编译器与 host target）才把两者算进 hash。snapshot 收 `extension.json`、有 runtime 时的 `src/**`、声明的 skills / system_prompts 目录，按 `relative_path + len + bytes` 排序 hash；`versions/`、`.zig-cache/` 不进。（seal.json 仍记录 host / compiler / target 作为诊断元数据——metadata ≠ identity。）
- **落点由 manifest id + store root 决定，不由 draft 路径决定**：`nulya ext build <path> [--user]` 把版本写进 `<store root>/<manifest.id>/versions/<v>`。root 的选择：`--user` → user root；否则 draft 若在某个 store root 之内 → 该 root（所以 `.nulya/extensions/<id>` 的 draft 建出来的位置与从前逐字节相同）；否则 → workspace root。这让 draft 可以待在任意路径（仓库里 git 管着的 `extensions/…`、`modes/…`），建出来的版本 `activate` 找得到，而不是在源码旁留下一个孤儿 `versions/`。编译进程的 cwd 就是 dest root（frozen source 与 `-femit-bin` 都在版本目录内），所以绝对路径的 user root 不需要给 `std.Io.Dir` 传绝对 sub_path。
- 版本目录冻结 snapshot：编译 extension 得 `versions/v-…/{extension.json, package/src/**, package/skills/**, bin/<entry><exe>}` + seal（含 `binary_digest`）；**编译从 frozen `package/src/main.zig` 进行**，不读 mutable draft。脚本 extension 得 `versions/v-…/{extension.json, package/src/**, …}` + seal（`binary_digest` = null；脚本已在 `package/src/` 里被 package_digest 覆盖），运行入口 = `package/<entry>`。同源码再 build = 同 version，`already_built`。
- `current` 是普通文本文件（不是 symlink：Windows 需特权且无收益），原子 rename 切换。
- 更新 = build 新版本 → activate；rollback = `current = old`。B 挂了 A 完全不动。
- deterministic validation 是 kernel 不变量（§12）；"这个参数是否通用"属 policy，**policy hook 尚未实现**——也没有对应的 config 键（PLAN §3.12）。

### 7.5 组合在 session 开始冻结（keystone）

`SessionComposition.init()` 解析 active extensions，冻住每个的版本，一次冻结 tools / skills / system prompts。被 pin 成 native 的工具在此刻解析出**绝对 `entry_path`**（基于冻结的版本），运行期只按此路径 spawn，**绝不二次读 `current`**。

**成员解析三条路，一样严。** 一个 extension 进这一场 composition 只有三种来路——discovery（`current` 指着它）、`session new --with`、resume 时 header 里冻的 `active`——三条都是**硬失败**：解析不出来就开不了这一场，绝不静默少一个能力地开场。discovery 从前是唯一的例外（`isExtensionFault` 就 `continue`），而它恰恰是意图最明确的那条：`activate` 是有人明说"这个要生效"。加重的是 §7.2 的首个 active 持有者胜——workspace 那份坏了，静默跳过会让整个 extension 消失，哪怕 user root 里有完好的 active 版本。所以 discovery 里坏掉的 active 版本返回 `ActiveExtensionBroken`，并在**内核里**往 stderr 打一行指名道姓的话（Zig 的 error 不带 payload，光一个错误名说不出是哪个包）：

```
active extension <id>@<version> is broken (<err>); run 'nulya ext deactivate <id>' or 'nulya ext rollback <id>' to recover
```

`session new` 再补一句 `session new failed: an activated extension does not validate (see the line above)` 并 exit 1。**host fault 不在此列**：cancellation / OOM / 真的 I/O 错误照原样传播，绝不被当成"坏 extension"（`store.isExtensionFault` 是这条线）。与之无关的是 `Roots.resolveVersion` 对坏 root 的跳过（§7.2）——那是内容寻址的同一版本换个 root 找同一份字节，不是"少一个能力"。

推论：session 中途 AI 重写出 `web.search` v2 并 activate，**当前 session 已 native 注册的仍是 v1**；v2 只能经 shell `nulya ext run` + note 告知；下一场 session native 才换。`tests/e2e.zig` 全环证明。

这不是新机制，是 §5.1 的 frozen snapshot 延伸到整个 Contribution 层。

**kernel system prompt 说什么、为什么只说这些。** 每场 session 的第一个 system block 是编译进二进制的常量（`composition.kernel_system_prompt`，进 `kernel_hash`，§3.4），四句话全是**事实**：① 你是 Nulya；② shell / edit 是永久 builtin，别的 extension 能力经 nulya CLI 调用；③ 那个 CLI 在哪（`NULYA_EXE` 给出本二进制路径，安装后叫 `nulya`）、`nulya help` 列出它能做什么、`nulya src` 打印本 harness 的源码，以及 **Nulya 可扩展——extension（脚本或编译的 tool）、skill、system prompt、session driver 都是模型在任务需要时可以写的东西**；④ native 暴露的 extension tool 冻在开场那个版本，中途 activate 只对 CLI 与下一场生效。第 ③ 句是 2026-08 加的**入口**：没有它，一场只有 shell + edit 的 session 不知道这些命令存在、也不知道二进制在哪（实测撞到过 "nulya not on PATH"）。
**没有一个字是"你应该进化 / 记得改进自己"**，这是刻意的：该不该造工具是判断（physics §8），判断住在 kernel 之上——mode 的 system prompt（`extensions/evolution`）或按需 load 的 skill（`extensions/guide`），而不是每场都在付 token 的前缀。同理，这句只**指路**不复制内容：真相在 `nulya help` / `ext api` / `nulya src` 里，它们与代码同源，不会漂。改这个常量会改 `kernel_hash`，老 session resume 时 stderr 警告一行照跑（§3.4），无需迁移。

### 7.6 工具的上下文模型：tool 拿不到 ledger

**tool 是无状态纯函数 `f(args, environment, ctx) → result`。**

| 信息类型 | 持有者 | tool 如何获得 |
|---|---|---|
| 事实性 / 持久（文件、命令输出） | 工作区文件系统 | 经 environment 直接读；fs = 共享持久记忆 |
| 语义性 / 对话（"决定用方案 B"） | ledger（模型上下文） | **不给 tool**；模型提炼进 `args` |

不给 ledger 的四条理由：模型是上下文路由器；大对话每次 spawn 序列化开销爆炸；最小权限；`args → result` 纯函数才可复现。

**当前 tool 实际拿到的：** in-core builtin 拿 `ToolContext{ environment, fs, cwd }`；extension 子进程只拿 **JSON-RPC request + 净化后的 env + cwd**（`environment.runExtensionImpl`），没有别的。那份净化 env 里有两个 kernel 自己放的变量，都不是 secret、也不是 model-visible 状态：**`NULYA_EXE`**（`LocalEnvironment.init` 放的**本进程可执行文件绝对路径**——子进程要调 `nulya …` 时该调的是**正在跑的这个**二进制，而不是 PATH 上碰巧有的某个副本；取不到路径就不设，建 environment 永不因此失败）与 **`NULYA_SESSION`**（只有 `session step` 会放，见 §5.3：让 shell 子进程找得到活着的 session 文件去投 capability note）。前者是 driver 型 extension（`extensions/compact`，§11）能存在的前提；两者都不是权限，`ext:… ⊆ shell ⊆ session` 不变（§9）。一个恒定大小的显式 `ctx_header`（os / dialect / scratch / 预算 / 权限描述，经 env var 或 `_ctx` 注入）属 PLAN。

tool↔tool 共享知识只走两条路：**模型中转**（大结果落盘留指针，指针流动）与**磁盘制品**（`.nulya/cache/`）。禁止 tool 直接互调 / 共享内存态。

> **凡"真的需要对话 / ledger"的东西，就不是 tool，而是 subagent。**（subagent 未实现，见 PLAN §3.2）

### 7.7 Skill（`skill.zig` / `extension/skills.zig`）

- 直接兼容 Agent Skills：`<name>/{SKILL.md, scripts/, references/, assets/}`，frontmatter 至少 `name` + `description`。
- 渐进披露：session 开头 system block 里放 `<available_skills>` 摘要（name + description + `load:` 命令）；模型经 shell `nulya skill load <ref>` 拉完整 `SKILL.md`。`ref` 是 pinned 引用，隐藏物理路径。
- 不做第三个 builtin。当前 skill 只有 extension 一个来源，`SkillRegistry` 直接吃 `list/get`，**不抽 SkillProvider**（第二个来源出现再抽）。

Tool 是"能执行的能力"，Skill 是"要遵循的方法 / 知识"；不同 registry，互不侵占模型工具面。

---

## 8. Execution Environment（`environment.zig`；进程树与有界等待在 `environment/tree.zig`）

```
Environment { runShell(cmd, dialect) / runExtension(entry, request_json) / dialect() }
```

只有 `local` backend。`sandbox` / `remote` 在 config 里能解析，但 `session new` / `session step` 建 environment 时（`launch.localEnvironment`，唯一一处）直接报 `UnsupportedEnvironmentBackend`——不会悄悄按 local 跑一个要求隔离的 config（PLAN §3.8）。ACP 不是 Environment（那是 editor→agent 的通信协议，方向相反，归前端层）。

---

## 9. Authority（诚实版）

**明确不假装 `manifest.permissions` 是安全边界。** AI 生成的原生 binary = 任意机器码；`"network": []` 在没有 OS 强制时拦不住 `curl`。当前：

- extension 与 shell 共享同一个 session authority（≈ 当前用户全权限）。明说，不给虚假安全感。
- **env 净化**：子进程 env 过 `isSecretKey` denylist（大小写不敏感子串：`SECRET / TOKEN / PASSWORD / API_KEY / ACCESS_KEY / PRIVATE_KEY / CREDENTIAL / SSH_AUTH_SOCK …`）。非 secret 变量（PATH / HOME）照传，命令才能工作。host env 的**来源**是 `environment.registerHostEnviron`：std 0.16 删掉了全局 environ（OS block 只交给 `main` 的 `std.process.Init` 与 test runner 的 `std.testing.environ`），`main` 启动时注册一次，所有读 host env 的层（config 链、`NULYA_*`、净化）都走 `environment.hostEnvironMap`；测试构建缺省落回 test runner 的 environ。边界是"无明显 secret 泄漏"，**不是**完全不继承、也不是 fs 隔离。kernel 往这份净化 env 里**加**两个非 secret 变量：`NULYA_EXE`（本进程可执行文件的绝对路径，`LocalEnvironment.init`）与 `NULYA_SESSION`（活着的 session 文件路径，只有 `session step` 放）——都是 provenance 型信息，不拓宽任何权限（§7.6）。
- 不变量：`extension_permissions ⊆ session_authority`；注册成 extension 不获得 shell 没有的权限。
- **workspace store 是 checkout 内容，却是第一优先 root——所以它要被信任一次（trust gate）。** §9.5 把 project 层的 `extensions.paths` 挡在门外，理由是 checkout 不该决定哪些目录供给 `current`；但 `.nulya/extensions` 本身就在 checkout 里，且首个持有者胜（§7.2）。clone 一个带 store 的 repo，从前 `session new` 会机械地把其中 active 版本合进 composition——system_prompts 进 system blocks、tools 经 CLI 可调、配合 project 层允许的 pin 还能上 native 面——中间没有任何人的确认。现在有一道门：

  - **信任的对象是 store 本身，不是它内容的 hash。** 内容 hash 是错的抽象：agent 每造一个能力、每 activate 一次新版本都会改它，一道每轮都重问的门会把自演化循环卡死——而那正是这个 harness 存在的理由，不是边角情况。要判的是**出生地**：这个 store 是在本机长出来的，还是随 checkout 到达的。
  - **本机 `ext build` 填满一个空 store = 生于本地，自动记一条信任**（`cli/ext.zig` 的 `recordBirthTrust`；只对非 `--user` 且落点是 workspace root 的成功 build，且只在 build **之前**该 store 什么都没有时）。所以 `ext init → ext build → ext activate` 这条自演化主路一句提示都没有。已经有内容的 store 走不到这条路——那恰恰是需要人看一眼的情形。
  - **"持有"的定义**：某个 `<id>/` 有 `current` 或有至少一个 built 版本——即 session 能 compose（discovery / `--with`）或 CLI 能执行（`ext run <id>@<version>`）的东西。光有 draft、或一次失败 build 在 `<id>/.lock` 周围留下的空壳，**不算持有**：它是惰性源码，直到本机把它 build 出来（而那次 build 就是记信任的时刻）。判据只有一处实现（`launch.occupiedWorkspaceStore`），所以门、`ext trust`、auto-trust 三方不可能互相矛盾。
  - **有内容却无信任记录 = 随 checkout 到达 → 硬拒。** `session new` 与 `session step` 启动时过门（`launch.ensureWorkspaceStoreTrusted`）：stderr 点名 store 绝对路径、列出它持有的 `id@version` 及 `[tools skills prompt]` 标注（与 `ext list` 同一份逻辑）、指路 `nulya ext trust`，exit 1。**硬拒而不是静默剔除该 root**——"少一个能力地开场"不是被要求的那一场，与 §7.5 对坏 active 版本的处理同一条规矩。`step` 也过门（不只创建时）：composition 冻在 header 里，但 extension 的**字节**每次 resume 都从 store 读。
  - **`nulya ext trust`** = 显式信任本 workspace 的 store：先把要信任的东西打印出来（判据是出生地，唯一诚实的做法就是真看过），再记录。store 不存在或什么都不持有 → `nothing to trust`，不记录。已信任 → `already trusted`，幂等。**没有 `untrust`**：撤销 = 手删那一行，等有人真需要再给动词。
  - **记录在 user 层**：`<NULYA_HOME | ~/.nulya>/trusted-stores.jsonl`，一行 `{"v":1,"store":"<绝对 realpath>","at":"<RFC3339>"}`（`journals/trust.zig`，与两条 workspace journal 共用 `journal.zig` 的文件纪律）。project 层记不算数——否则 checkout 自己给自己签名，与 §9.5 "只认 trusted 层"同一个理由。key 是 store 目录的 realpath（从打开的句柄解析，不是拼字符串）；重复行无害，读端只问"这个路径出现过吗"。整条 journal 读不动（完整行 malformed）就**拒**而不是答，corrupt 不该悄悄变成 trusted 或 untrusted。
  - **范围**：只门 workspace root。user root 与 `extensions.paths` 定义上可信（checkout 都碰不到，§7.2/§9.5）。**只读投影一律不门**（`ext list` / `ext inspect` / `skill list` / `skill load`）——它们正是"决定要不要信任"所需的工具，蒙着眼决定才是错的；`ext run` 也不门（人或已过门的 session 里的模型显式点名）。
  - **门在壳层，不在内核**：`composition.zig` / `session.zig` 不知道 trust 存在，`AgentSession.init` 这条库路径也不过门（trust 是 CLI 的 policy，不是 physics）。
  - 仍然诚实的剩余面：checkout 里的一个 **draft**，一旦有人在本机 `ext build` 它，就既进了 store 又带来了信任——那与 `shell` 已有的权限同级（`extension ⊆ shell ⊆ session`），门管的是"**预先建好**的版本随 clone 到达、无声进 composition"这一件事，不是"checkout 里的源码永远不可信"。

- OS 强制（sandbox）见 PLAN §3.8。

### 9.5 配置链（`config.zig` / `default.toml`）

```
@embedFile default.toml
  ↓ merge   system   /etc/nulya/config.toml | %ProgramData%\nulya\config.toml
  ↓ merge   user     ~/.nulya/config.toml（Windows：%USERPROFILE%\.nulya\config.toml；`NULYA_HOME` 整体搬走该目录）
  ↓ overlay project  .nulya/config.toml   ← 不可信输入，过 mergeProject 只能收窄
```

user 层与 workspace 的 `.nulya/` 同形、每个平台一个好找的位置；`nulya config show` 打印三条路径（JSON `paths`），前端写 key 时写的就是它读的。

标量 set 即胜，列表按 key 合并。project 层**可以更严不能更松**：可 pin 工具（pin 只花自己的 `max_tools` 槽与前缀 token，不拓宽权限）、选 profile、调小 `max_tools`、把 backend 从 local 收紧到 sandbox；**不可**把 backend 从 sandbox 降级 local、注入 `api_key_env` 名字外泄 host env、加 store root（单测覆盖）。这与 §9 的 `extension_permissions ⊆ session_authority` 是同一个不变量的两面：checkout 一个 repo 不该能拓宽机器权限。

承载：`provider.profiles[]{name, kind=openai|anthropic|codex|scripted, model, models[]?, base_url, api_key_env, api_key?, effort?}` · `provider.retry{max_retries, initial_backoff_ms, max_backoff_ms, stall_timeout_ms}`（§13 的重试策略与 stall watchdog；描述的是线路不是模型，所以全 profile 一份、只认 trusted 层）· `models[]{id, label, efforts[], default_effort?, context_window?}` · `registry{max_tools, pinned_native_tools}`（§5.1 的两档工具面；没有排序权重——内核不排序） · `environment{backend, shell}` · `extensions.paths`（**已被消费**：§7.2 的第三档 store root，**只认 trusted 层**——project 层写了直接忽略，单测覆盖）。`default.toml` 自带 `openai` / `anthropic` / `codex` / `deepseek` / `deepseek-anthropic` / `scripted` 六个 profile 与它们列出的每个 model id 的目录条目。

**两张表描述模型。** profile 说**怎么连**（kind / base_url / 哪个 env 放 key）和**它服务哪些 model id**（`model` 是默认、`models[]` 是可选列表；`ProviderProfile.defaultModel()`：`model` 非空取它，否则 `models[0]`，否则 provider 内置默认）；`[[models]]` 目录说一个 id **是什么**（label、effort 档位、context window），一个 id 不管经几个端点都只写一次。目录是纯描述：kernel 不读它；`launch` / `cli` 用它给 session 默认 effort（`Config.defaultEffort(profile, model_id)` = profile.effort ?? catalog.default_effort ?? 无），`nulya config show` 把它投影给选择器。`[[models]]` 按 `id` 合并、只认 trusted 层——project 层不能改一个 model id 的含义或让 session 静默换 effort。

**credential 的边界**：secret 不进 session 文件（header 只存 `api_key_env` 的**名字**与 profile 名，每次 step 重新解析）、不进工具子进程的 env（`environment.isSecretKey` 剥掉 `*API_KEY*` 等）、不从 project 层来（checkout 不能定义 profile）。在这三条之内，credential 可以来自两处：profile 自己的 `api_key`（**user 层文件**，`~/.nulya/config.toml`——TUI `/model` 的 `s` 写的就是它）或 `api_key_env` 指的环境变量；`launch.credentialSource` 定顺序 `config > env`（人贴进 nulya 自己文件的 key 应当生效，哪怕还留着一个过期的环境变量）。`codex` 的 credential 是 Codex CLI 的 `auth.json`（读文件判断），与 user 层 `api_key` 同类：本机用户自己的文件。resume 时 `cli/session.zig` 按 header 的 profile 名从 config 取 `api_key` 交给 `buildFromDescriptor(.inline_key)`，找不到再看 env，都没有 → `MissingCredential`，不静默降级。config 在 session 开始解析成 effective 值一次；磁盘改动下一场生效。**为什么文件里的 key 是必要而不只是方便**：模型自己 `nulya session new`（sub-agent 自调用）时它的 shell env 已被剥掉所有 key，能让子 session 跑起来的只有 kernel 自己读得到的文件。

---

## 10. 内嵌 Zig 工具链（`extension/build/toolchain.zig`）

- 宿主平台那一份 Zig（pinned 0.16.0）`@embedFile` 进二进制，首次需要时解压到 `~/.local/share/nulya/toolchains/zig/<ver>/`（`XDG_DATA_HOME` 优先；Windows: `%LOCALAPPDATA%\nulya\`）。一份宿主 Zig 可交叉编译所有 target。
- 代价 +50–90MB；换来零网络、零 hash 校验、零版本漂移。
- 内嵌由 `-Dembed-toolchain -Dzig-archive=<path>` 门控；日常 `zig build test` 不嵌，e2e 用 `NULYA_TEST_ZIG` 指向宿主 zig。
- **`cli.resolveZig` 按三档找编译器**：`NULYA_ZIG`（显式覆盖）→ 内嵌工具链 → **PATH 上的 `zig`**。第三档是给开发版的：一个没内嵌工具链的 build 否则在一台明明装着编译器的机器上也 `ext build` 不了任何 compiled extension。走到第三档时往 stderr 说一句 `note: using zig from PATH (<path>); set NULYA_ZIG or use an embedded build for a pinned toolchain`——**不拦，但不悄悄**：compiled version 的 id 把 compiler identity 算进 hash（§7.4），所以换一个 zig 得到的是**另一个 version**，绝不会是同一个 id 底下不同的二进制。三档都没有才报 "no zig toolchain（set NULYA_ZIG / put zig on PATH / -Dembed-toolchain）"。
- AI 不直接 `zig build`，走 `nulya ext build`（nulya 统一 optimize=ReleaseSafe / target / cache，zig 版本按上面三档定）→ 可复现构建。`nulya toolchain zig <args>` 供 scratch。

---

## 11. Compaction 与 generation

**generation == ledger 文件**（§3.4）：一个文件只 append、只一个 generation，所以前缀不变量是文件系统性质，没有会 bump generation 的事件——`prompt.currentGeneration()` 与 `Request.generation` 都已删除（一场 session 里恒定的值不是参数）。

**内核提供的是 fork，不是 compaction。** 没有"替换历史"的动词，也不会长出一个——ledger 只 append（physics §1），没有东西能 rewrite model-visible 状态（physics §3）。所以压缩不是编辑而是**分叉**：开一个新文件，header 的 `parent` 记下旧文件与切分点，摘要作为新文件的第一条 turn 进去；旧文件原封不动留在盘上。内核在这条路径上只保证三件事（`cli/session.zig` 的 `session new`，§14）：

1. **parent 必须存在。** 指向虚空的 lineage 不是 provenance——读不到父 header 就 exit 1，不建文件。
2. **不点名模型时继承父的冻结身份**（`model` profile 名 + `model_identity` 原样）。压缩是同一场对话换个文件，不该因为 `active_profile` 期间漂了就换了说话对象。`--profile` / `--model` 任一给出即按今天的 config 重新解析（分叉到别的模型是合法用法）。
3. **composition 不继承**（pin 与 `--with` 都要再传一次），照常从 config 现解。新 session 正是今天的 pin 与新 activate 版本该生效的地方（§5.1、§7.5），而 fork 就是一个 session 边界。

**何时压、压成什么，都不在内核里。** 前者是 driver 的 policy（内核没有对应的 config 键——没人消费的键就是死代码，已删），后者是模型的判断。两者都由 driver 用现成的 `session append` / `session step` / `session new --parent` 组合出来。

**第一个 consumer 是随仓库带的 `extensions/compact`**（与 `extensions/evolution/` 同层）：一个 **compiled** extension，contribute 一个 `compact{session, focus?, max_steps?}` tool，七步就是上面那条组合——找到 harness（`NULYA_EXE`，§7.6）→ 往**旧** session append 一条带 `<nulya:compact-request>` 标记的请求 → `session step` 它并**解析它打印的事件 JSONL** → 没拿到摘要就什么都不动（JSON-RPC error `-32001`，两条真实事件留在旧 ledger 里说明它为什么停）→ `session new --parent <old>:<seq>` → 往新 session append `<nulya:context-summary>` + 摘要 → 返回 `{session, parent{session,seq}, summary_bytes}`。它是 **compiled** 而不是脚本，只因为要解析 JSONL：`sh` 没有 JSON 读取器（jq 不保证有）、Windows 两者都没有，两份脚本实现同一个过程更糟（PLAN §0.1 #3 给 Zig 留的正是这种情况）。TUI 的 `/compact` 现在只做三件事：`ext build extensions/compact` → `ext run compact@<v>` → 把 tab 换到返回的 session（tui.md §11 T9）；它跑的时候持着旧 session 的写者 lease，所以那个 tab 自己翻成 observer 跟着看。内核既不知道也不关心发生过一次压缩，`src/` 为它加的只有 `NULYA_EXE` 一个变量。

**换个触发者：模型主动的 handoff（`extensions/handoff` + `drivers/goal.*`）。** `/compact` 是 driver 因为"满了"发起；handoff 是**模型**因为"一个阶段做完了、剩下的工作不再需要过程细节"发起。动作完全相同——同一条 fork 路径、同一个 `<nulya:context-summary>` marker（**没有第三个 marker**）——只有触发者、信号、brief 侧重不同。**内核零改动**：`src/` 为这一整块加的只有 `launch.ScriptedProvider` 的第四档（离线替身，§13）。

- **`extensions/handoff`**（与 `compact` / `evolution` 同层，compiled，理由同 `compact`：要读 JSON-RPC 请求、回同一个 `id`、校验分节，而一个 manifest 只有一个 interpreter，随仓库带的东西没法 ps1 + sh 各一份还共用一个 version）contribute 一个 `handoff{done, next_task, keep, drop?}` tool。**只 propose、不 fork**：它不调 `session new`，所以 `session new --parent` 在整个仓库里仍然只被 `extensions/compact/src/main.zig` 调用。它做三件事——校验三个必填节（缺 → `-32602`，一次列全缺的，**不落盘**）、认 `NULYA_SESSION`（不在 session 里 → 错误，**不落盘**）、把 brief 渲染成 markdown 写进 `.nulya/handoffs/<session>-<n>.md`（`n` 取第一个空位、exclusive create，单调、不覆盖），然后回 `{recorded, message}`，message 就是"记录好了，别再调工具，结束本轮"。**那个文件就是提议**——driver 不必解析任何 JSON 也能看见它。
- **`extensions/handoff` 默认不在任何 composition 里**，由需要它的 driver 在 `session new` 时带进来：`--with handoff@<v>` 让它成为成员、`--pin ext:handoff/handoff` 给它一个 native 槽（两根轴，§7.5）。这使 handoff 成为 **`--pin` 的第一个真实 consumer**。交互模式不给它：那时 driver 是人、人有 `/compact`，一个没人消费的 handoff 只会让 result 说"已记录"而什么都不发生。
- **`compact` 的 `brief_file` 分支**：给了这个参数就**跳过七步里的 2–4**（不 append 请求、不 step 旧 session，旧文件**逐字节不变**），fork 点 = 旧 ledger 当前 tail（`session events <old>` 的最后一行 `seq`），brief = 文件内容；父一条事件都没有、或文件读不到 / 为空 → 报错不 fork。**两条路径**都由**代码**在 carried 文本末尾追加一段父指针（`Parent session: <id> (forked at seq N) … nulya session events <id>`）——不指望模型记得写；旧 ledger 还在盘上、新 session 有 shell，于是有损压缩退化成惰性检索。
- **`drivers/goal.sh` + `drivers/goal.ps1`**（仓库顶层 `drivers/`，各 ≤ 70 行、逐行对齐）是**第一个 driver**，也是 PLAN §3.6 那段伪码的落地：`session new --with handoff@<v> --pin …` → `session append` 目标 + 一段"按阶段工作、阶段做完才调 handoff"的前言 → 循环 `session step --max-steps 1 --stream`；每步之后**先看盘**（`.nulya/handoffs/<id>-*.md` 出现了新文件 → `ext run compact@<v> compact --arg session=<id> --arg brief_file=<那个>` → 切到返回的子 id），否则看协议里的 `"stopped":"end_turn"` 收工。它**不是 extension**：一个 driver 一跑几十分钟，而 `ext run` 对 extension tool 强制 manifest 的 `timeout_ms`（上限 600s，§7.3）——driver 不是一次 tool call，不该被塞进那个形状；何况 script extension 一个 manifest 一个 interpreter，跨平台就得两个包。两份脚本都**不解析 JSON**：提议是文件、结束是协议自己的一行、只有一个正则从 compact 的结果里取新 id。
- **两个流两个受众**：driver 的 **stdout 只有控制行**（`session <id>` / `handoff <old> -> <new>` / `done <id>` / `evaluate: …`），**stderr 是 `session step --stream` 的行协议原样透传**。于是一个前端 spawn 这个脚本就能拿到实时 token delta（喂给它已有的 `--stream` 解析器）并按 stdout 开 / 切 tab，**不需要** `<id>.live` sidecar，也不需要内核长出任何东西。

---

## 12. 质量门

**现状 = deterministic validation**：manifest schema（§7.2）· seal / integrity 校验（load 时对照 hash）· 协议往返（响应 id 匹配）· 权限形状。这些是 kernel 不变量。

**尚未有 Verify 门**：`nulya ext test` 未实现；`nulya ext init` 的模板会生成 `tests/*.json` 真实验收用例（`build/templates.zig`），但目前无人跑它。**门通过 ≠ 正确**，只是"没有明显坏"——对模型和用户都要说清。Validate / Verify 分层与 Seal-then-Verify 见 PLAN §3.5.4。

---

## 13. Provider（`provider.zig` / `providers/`）

```
Model { ptr, vtable { name, modelName, capabilities, stream(request, sink) } }
Request { prompt_ir, tools, options{max_output_tokens?, effort?}, stall_ms }
StreamEvent: started | text_delta | thinking_delta | reasoning_item | tool_use_start | tool_use_input_delta | usage | done(StopReason)
TurnCollector → ModelTurn { reasoning, text, calls, usage, stop_reason }
ProviderCapabilities { thinking_replay }
```

- Provider 在 generation 稳定的 turn 边界放 / 声明 cache breakpoint（tools 之后、system 之后、最后一条稳定消息之后）。
- Provider 只能优化序列化，不能破坏 §1 的 turn 前缀不变量。
- **reasoning 回放是 provider 的事，形状是 provider 的。** `thinking_delta` 只供展示，collector 不留；`reasoning_item` 是一个**完整**的 reasoning item（provider 自家 wire 形状的一个 JSON 值），item 凑齐时才发，`TurnCollector` 原样收进 `ModelTurn.reasoning`（`[item,…]`），loop 落进 `assistant.reasoning`（§3.1）。投影出的 assistant turn 的 `reasoning` 字段只有声明 `thinking_replay` 的 provider 才序列化（`wire.writeReasoningItems` 把数组拆回一个个值，容器由 provider 决定），其余 provider 跳过。`anthropic`：`thinking` block 的文本与 signature 以 delta 到达、`content_block_stop` 时整块发出，`redacted_thinking` 到达即整块发出；回放时放在同一条 assistant message 最前、`tool_use` 之前，breakpoint 不落在 thinking block 上。`codex`：请求带 `include:["reasoning.encrypted_content"]`，`response.output_item.done` 的 `reasoning` item 只在含 `encrypted_content` 时整个发出（没有它的 item 在 `store:false` 下回放不了），回放为 `function_call` 之前的 input item。`openai`（chat/completions）：OpenAI 自家端点没有可回放的 reasoning，不发不回放；**DeepSeek 端点**（`base_url` 含 `deepseek.com`，`thinking_replay` 为真）把本轮流式到达的 `reasoning_content` 在 `[DONE]` 前拼成**一个** item `{"reasoning_content":"…"}` 发出，回放时只挂在**带 `tool_calls`** 的 assistant message 上（同名字段）——DeepSeek 文档明写：两条 user 之间若有 tool call，其间 assistant 的 `reasoning_content` 必须原样传回，否则 400；无 tool call 的轮次传回也会被忽略，所以不挂。

### 13.1 四个已实现的 provider

| id | 端点 | cache 机制 | 备注 |
|---|---|---|---|
| `openai` | chat/completions（OpenAI / DeepSeek / 任意兼容端点） | implicit prefix | 读 `prompt_tokens_details.cached_tokens` 或 `prompt_cache_hit_tokens`；effort：`off` 在 DeepSeek 发 `thinking:{type:"disabled"}`（它默认开 thinking）、别处什么都不发，其余档位是 `reasoning_effort`；`max_tokens` 不主动发（DeepSeek 的 reasoning 和答案共用这个上限） |
| `anthropic` | Messages `/v1/messages`（含 DeepSeek `/anthropic`） | **explicit breakpoints** | 读 `cache_read_input_tokens` / `cache_creation_input_tokens` |
| `codex` | `chatgpt.com/backend-api/codex/responses`（ChatGPT 订阅） | implicit prefix，按 `session_id` 分域 | OAuth 走 `~/.codex/auth.json`，401 自动 refresh 并回写 |
| `scripted` | 无 | 无 | demo / 测试用的确定性 stand-in |

**共享层 `providers/wire.zig`。** 三个真实 provider 都是「一次流式 HTTPS POST，body 是 SSE」，真正共有的东西收在这里：`postSse` / `postJson`、JSON 标量读取、`writeReasoningItems`（唯一到哪儿都一样的那段 PromptIR 序列化）。turn 结构本身不用解码——`prompt.Turn` 直接是带类型的。SSE 行用可增长缓冲累积（Codex 的 `response.completed` 一行就能装下整个 response 对象），`event:` 行一律忽略——三种方言都把事件名也写在 payload 里。各 provider 文件只剩自己的 wire shape。

**瞬态故障与重试（`provider.RetryPolicy` / `isTransient`，`loop.collectTurn`）。** 分工与 tcode 相同：**provider 每次 `stream` 只做一次尝试**并把失败归类，**loop 拥有唯一的重试循环**——连接阶段失败和流中途断掉走同一条路、同一套退避，每次重试对 observer 可见。归类在 wire 出口做：线路本身的任何故障（connect / TLS / 发送 / 收头 / body 读到一半断）由 `wire.transport` 折成一个 `error.Transport`（具体原因打到 stderr），HTTP 状态分成 `Unauthorized`（401，codex 自己 refresh 一次）/ `RateLimited`（429）/ `ServerError`（5xx，含 anthropic 529；流中途到的 `overloaded_error` 事件也算）/ `ApiError`（其余 4xx——请求本身错，重发无用），body 在终结事件之前结束是 `StreamEndedEarly`。`isTransient` = `Transport | StreamEndedEarly | RateLimited | ServerError`，其余（4xx、credential、畸形 payload、`Canceled`、OOM）当场失败。`collectTurn` 每次尝试**新建一个 `TurnCollector`**：中途断掉的尝试什么都不留下，重试也不可能重复已经流出去的事件；observer 会看到失败那次的 delta，随后收到 `modelRetry`（`RetryNotice{attempt, max_retries, delay_ms, err}`），它得自己丢掉这一轮已显示的内容。退避 `initial · 2^(n-1)`、封顶 `max`（默认 5 次、1s、30s，`config.provider.retry`，经 `StepContext.retry` 传入），睡在 `std.Io.sleep` 上所以取消照样打得断。整个循环**不碰 ledger**：同一个 request 原样再发，只有完整的 turn 才返回——这不是智能（没有任何 model-visible 的东西因它改变），只是让 loop 活过线路的抖动。没有 observer 时重试行打到 stderr（与 wire 的原因诊断挨着）。

**Stall watchdog（`wire.Watched`，`RetryPolicy.stall_timeout_ms`，默认 120s）。** 服务器接了连接却一个字节都不回，`std.http` 的读会一直阻塞到 OS 放弃 socket（可以是几十分钟），而 `<id>.cancel` 只在 step 边界消费、打不断它——所以每次 HTTP 交换跑在自己的任务里，旁边一个 watchdog 任务盯着 `Heartbeat`：**任何一行**（响应头、SSE keepalive、我们不解码的事件）都算心跳，静默超过预算就 `Select` 胜出、cancel 交换任务（`std.Io` 的取消打得断阻塞读：POSIX 用信号，Windows 用 `NtCancelIoFileEx`——所以不能用 `SO_RCVTIMEO`，Threaded 在 Windows 走 AFD overlapped）、报 `Transport`（原因 `Stalled`）→ 走上面的重试。度量的是**字节级静默**而不是"首 token 必须 N 秒内到"：tcode 那个 60s connect timeout 在 Codex 上常被慢首字节误伤，而真正的死连接靠字节级也抓得到；120s 是折中——它只防"挂半小时"，不追求秒级发现（切断一个活着的请求只是重新计费一遍 prompt 再等一遍）。io 给不出两个并发单元时交换直接裸跑（没有假 stall，只是没有守卫）；`stall_timeout_ms = 0` 关掉。`stall_ms` 由 loop 经 `Request.stall_ms` 交给 provider、provider 交给 `wire.Post`——它是 transport 参数不是 generation 参数。单测用本机一个"接了不说话"的 TCP 服务验证预算内报 `Transport`、会说话的服务不受影响。

**`anthropic` 的两个 breakpoint。** 这个 API 只在被告知处缓存，而 §1 的 turn 前缀只增不减，所以两个 `cache_control` 就覆盖全部前缀：一个在冻结 system 的最后一块（`tools` 排在 system 之前，同一个 breakpoint 一起罩住），一个在最后一条 message 的最后一个 content block——后者随 append 自动前移。连续的同 role turn 合并成一条 message，于是一批 `tool_results` 天然是一条 user message。`message_start` 与 `message_delta` 各报一次 usage，provider 内部**合并**而不是覆盖，否则收尾事件会把 cache 计数清零（§1 的可测性就没了）。first-party 用 `thinking:{adaptive}` + `output_config.effort`，兼容端点用老的 `thinking.budget_tokens`（并把 budget 加进 `max_tokens`）。thinking 开着时这个 API 要求带 `tool_use` 的 assistant message **原样**带回它前面的 `thinking` block（含 signature），否则 400——所以本轮的 thinking block 整块收进 `assistant.reasoning`、回放在该 message 最前（§3.1、上文）；这是 tool 循环在一方端点上合法的前提，不只是思路连续性。

**`codex` 的 cache key = session id。** 后端用 `session_id` header 给 prompt cache 分域（并覆盖 body 里的 `prompt_cache_key`）。Nulya 有真正的 durable session id，于是这个 key 由它确定性派生（Blake3 → UUID 形状），**跨 `nulya session step` 进程稳定**——一场对话就是一个 cache 域，不是一个进程一个。credential 不是 env 而是 Codex CLI 的 `auth.json`，所以 `resolveDescriptor` 判断 codex profile 可用性时读文件而非读 env；header 里 `api_key_env` 为空。**reasoning 回放**：`store:false` 下 CoT 是一个加密 item，请求用 `include` 要回它，落进 `assistant.reasoning`（§3.1），下一步原样带回——和 Codex CLI 自己的做法一致；后端虽接受不带的历史，但那样模型每一步都要重推上一步的计划。

### 13.2 真实端点验收（`zig build integration`）

turn 前缀不变量是 kernel 保证的；**它是否真的换来 cache 命中**取决于 provider 的序列化与 breakpoint，只能看表。`tests/integration.zig` 是唯一联网的测试，`zig build test` / `zig build e2e` 保持离线；没有 `NULYA_INTEGRATION_PROFILE`（或该 profile 无可用 credential）就整体 skip，不会让没有 key 的机器变红。

```bash
NULYA_INTEGRATION_PROFILE=deepseek-anthropic zig build integration
```

断言：连续步骤的 `cache_read` 单调不减，且从第二步起 ≥ 上一步 input 的 90%。开场 turn 特意做到几千 token——provider 对**低于最小长度的前缀根本不缓存**（OpenAI 系是 1024 token），拿玩具 transcript 去测只会得到恒为 0 的假阴性。第三条（只在 `thinking_replay` 的 provider 上跑）把 effort 强制打开、跑一个多步 tool 循环：必须走到 end-turn（一方 Anthropic 端点上不回放 thinking 就走不到）且至少一轮 assistant 带 `reasoning`——回放路径的活证据。

---

## 14. CLI 表面（`cli.zig` 只是 dispatcher，每个动词族一个 `cli/<verb>.zig`；都不是 LLM tool，经 shell 调用）

```
nulya ext init [--script] [--user] <id> [tool] | build <path> [--user]
          | run <id>[@<version>] [tool] (<json-args> | --arg k=v …)
          | activate [--user] <id> <version> | rollback [--user] <id> <version> | deactivate [--user] <id>
          | list | inspect <id> | trust | api [protocol|permissions|examples]
nulya session new [--profile P] [--model ID] [--parent <id>:<seq>] [--with <id>[@<version>]]… [--pin ext:<id>/<tool>]…
                                                         ← 冻结 composition + 模型身份、写 header，打印 session id
          | append <id> <text|--file f>                  ← 把一条 user turn 投进 inbox（下一 step 边界进 ledger）
          | step <id> [--max-steps N] [--effort E] [--stream]
                                                         ← 跑到本 turn 结束或预算耗尽；stdout = 本次 append 的事件 JSONL（`--stream` 见下）
          | events <id> [--since N] [--follow]           ← 只读 tail 原始事件行（follow 轮询）
          | cancel <id>                                  ← 写 cancel 标记，下一 step 边界消化
          | outcome <id> <success|partial|failure> [--note <text>] [--seq N]
                                                         ← 记一条 verdict 进 outcome journal（§3.3）；只写 journal
          | list [--json]                                ← `.nulya/sessions/` 的只读投影（composition / 事件数 / usage / episode / verdict）
nulya config show [--json]                               ← 有效配置链的投影：profiles（含 credential 是否可用）+ 模型目录；无 secret
nulya src [path] [--tests]                               ← 打印本二进制内嵌的 src 源码（无参数 = 列全树）
nulya skill list | load <skill-ref>
nulya toolchain zig <args…>
nulya                       ← 无参数：固定 prompt demo（现经 durable session 路径跑，§3.4）
```

- `session new --profile P [--model ID]`：`--profile` 是 config 里的 profile 名（默认 `active_profile`），`--model` 是该 profile 服务的一个 model id（默认 `ProviderProfile.defaultModel()`；接受任意 id，选择器只列目录里的）。不存在的 profile 直接拒绝（exit 1，提示 `nulya config show`）；存在但 credential 不可用的 profile 仍冻结为 scripted（离线替身，`resolveDescriptor` 的语义不变），但 stderr 明说。
- `session new --parent <id>:<seq>`：这场 session 续的是谁（fork / compaction 的新文件，§11）。**父必须存在**（读不到 header 即 exit 1，不建文件）。模型分两级继承，因为两个 flag 含义不同：`--profile` 换的是"怎么连"，所以它替掉父的 profile；`--model` 只是在一个 profile 内换 id，所以**父的 profile 仍然生效**（不会掉回 `active_profile`）；两个都不给则**原样继承父 header 的 `model_identity`**，此时不重解 credential、也不打那条降级警告（继承的身份不会降级为 scripted，缺 key 由需要它的那次 `step` 一次性报响）。composition 一律现解，不继承。`session step --effort E` 是**每次 step 的 generation option**（不是身份，§3）：不给则用 `Config.defaultEffort(header.model, header.model_identity.model)`。
- `session step` 读完 header 就核一次 `nulya.kernel_hash`（§3.4）：与本二进制不符就往 **stderr** 打一行 `warning: session <id> was created by nulya <ver> whose kernel prompt/builtins differ from this binary's; its frozen system prompt has changed`，然后照跑（stdout 在 `--stream` 下仍只有 JSON）。空 stamp 的老 session 不警告。
- `nulya config show [--json]`：外壳级投影（同 `session new` 看到的东西），供选择器与 agent 自查：`{paths{system, user, project}, active_profile, profiles[]{name, kind, base_url, api_key_env, credential: bool, credential_source: config|env|login|builtin|none, model, models[], effort?}, models[]{id, label, efforts[], default_effort?, context_window?}}`。只报 env var **名字**、来源与布尔，永不报值；`api_key` 的值不出现。

- `nulya src`：build.zig 把整个 `src/**` `@embedFile` 进二进制（源码 ~200KB，紧挨 ~90MB 工具链，恒开无 gate）；`nulya src <path>` 按 `src/` 相对路径打印（`prompt.zig`、`extension/store.zig`），**默认剥 top-level `test` 块**（读结构/契约时不付测试 token），`--tests`/`--raw` 打印原样（Zig 风格参照）。剥离靠 zig-fmt 不变量：顶层 decl 的收尾 `}` 在第 0 列，无需 tokenizer（`source.zig`）。测试留在文件里（Zig 惯例、人可读、风格参照），改的只是**投影**不是**存储**——`src/` 一字未动。
- `nulya ext api`：协议 topic 现在**打印真实 `extension/protocol.zig` 源码**（是 `nulya src` 的特例），wire ABI 与实现代码零漂移；`permissions` / `examples` 仍是短说明（策略与 CLI 用法，不随代码漂）。
- **`session new --pin ext:<id>/<tool>`（可重复）= 这一场的 native 工具面。** 与 `registry.pinned_native_tools` **同义同严**，两者取并集去重（config 在前，`--pin` 按 argv 顺序在后）：config 说"这个 workspace 一直要"，`--pin` 说"这一场要"。解析不到就 exit 1 并打出这场的 pin 列表（`PinNamesUnknownExtension` / `PinToolNotDeclared` / `InvalidStableToolId` / `ToolBudgetExceeded` 各一句），绝不静默少一个工具地开场。结果照常冻进 header 的 `native_tools`，`initFrozen` 零改动。fork（`--parent`）**不继承** pin——composition 一律现解（§11），driver 要就再传一次。这也是"晋升"的全部含义：没有别的机制会把一个工具放上模型的工具面（§5.1、§5.5）。
- **`session new --with <id>[@<version>]`（可重复）= composition membership，不是 native pin。** 把一个**已 built** 的版本 union 进这一场的 composition：它的 skills 进 catalog、system_prompts 进 system blocks、tools 可经 `nulya ext run <id>@<version>` 调用（点名冻结的版本，不依赖 `current`）；**tool 要不要占 native 槽是 `--pin` / `registry.pinned_native_tools` 的事**（两根轴分开）。同 id 覆盖 discovery 的结果（这一场说了算），重复 `--with` 同一个 id 后者胜。版本解析：给了 `@version` 就用它，没给就用该 id 的 `current`——**没有 `current` 就 exit 1，内核不猜**（"只有一个 built 版本就用它"这类聪明会让同一条命令在第二次 build 之后含义漂移）。所以一个**故意不 activate** 的包（mode / evolution，activate 了就会进每一场 session 的 system blocks）要按 `--with <id>@<version>` 带入，version 由 `ext build` 打印。落地不需要新机制：`--with` 只改 `SessionComposition.init` 的输入，结果照常冻进 header 的 `active`，所以 `initFrozen` 零改动、resume 自然重建同一份 composition。fork（`--parent`）不继承——composition 一律现解（§11），要就再传一次。
- **mode = 贡献 system_prompt 的 data extension + `--with`。** 同一个包两种投放：`activate` = 常驻（每场都有）；不 activate、只 `--with` = 按场。不为 mode 造别的机制。
- `nulya session list [--json]`：`.nulya/sessions/` 的**只读投影**，按 `created` 倒序（老 header 没有 `created`，退回按 id——id 本身时间有序）：`{sessions:[{id, created, parent, root, model, provider, model_id, nulya{version, kernel_hash}（创建它的二进制，§3.4；老 session 两项皆空）, events, composition{active:["id@version"], native_tools, system_prompts:["id@version/path"]}, usage（每条 assistant 的 `usage` 求和，§3.1）, episode_usage, first_user_text（截断）, outcome{verdict,note,at,source,by}|null}]}`。定位同 `config show`：外壳投影，不决定任何事，也不写任何东西；第一批消费者是 evolution skill（一眼看完很多场而不必逐个读 ledger）与 TUI 的 `/sessions`。一个读不动的 session 文件被跳过而不是让整条命令失败。**`session new` 从此写 header 的 `created`**（RFC3339 UTC）。三个派生列：
  - **`root` / `episode_usage` = episode 的连接，只发生在这个投影里。** `/compact` 与 handoff 用 `--parent` 分叉（§11），所以一件事常常横跨一串文件；`root` 是沿 `parent` 链在**本次列出的** session 里能走到的最老祖先（走不到的父——别的 workspace、被删掉的文件——就让这个 session 自己当 root，绝不因此让列表失败），`episode_usage` 是同 `root` 的所有 session 的 `usage` 求和。**outcome journal 不参与**：一条 verdict 永远记在被点名的那个 id 上，"按 episode 理解"是消费者的事。文本形态只在 `root != id` 时多打一列 `root <id>`。
  - **`composition.system_prompts`** = 每个冻结 active 版本的 manifest 声明的 system prompt，写成 `<id>@<version>/<path>`（§7.5）。best-effort：这台机器读不出的版本就不列（"没列"= 不知道，不是"没有"），版本内容寻址故按 `id@version` 记一次读一次。会改写每一场 system blocks 的包，应该在列表里看得见。
  - **`outcome.source` / `outcome.by`**（§3.3）：`agent` 的 verdict 是**主张**不是 ground truth，文本形态在 verdict 后面直接标 `(self)`（`by == id`）或 `(by agent)`。
- `nulya session outcome <id> <verdict> [--note …] [--seq N]`：校验 id 形状与 session 文件存在、校验 verdict（`--seq` 只校验是正整数），然后**只**往 `.nulya/session-outcomes.jsonl` append 一行（§3.3）。它**不打开 session 文件、不拿 `<id>.lock`**——verdict 是关于这场 session 的判断而不是其中一轮，所以正在跑 `step` 的 session 也能当场评；同一 session 可以评多次，最后一条作数。`NULYA_SESSION` 在环境里（即这条命令是模型经 `shell` 从某场 session 里调的）就记 `source:"agent"` + `by:<那场的 id>`；`--seq N` 把这条收窄成对第 N 轮的判断，不参与 `latestFor`。
- `nulya session *` 是**唯一**的 session 驱动面：没有 `setTools / setModel / replaceHistory`，换 composition = `session new`。每个子命令是对 durable session 文件（§3.4）的一次独立进程调用，其中**只有 `step` 写主文件**：`append` / `cancel` 投递到 `<id>.inbox/` / `<id>.cancel`（所以正在跑的 `step` 会在它的下一个 step 边界拿到 mid-run 的 append 或 cancel），`events` 是只读 tail（不解析、不重编码——文件本身就是 wire format）。`step` 的预算 `min(--max-steps, session.max_steps_ceiling)` **由 kernel 在 `AgentSession.run` 强制**，driver 只能调低不能调高；`--max-steps` 必须是正整数。session 就是它的文件，没有 `close`。**stdout 只放数据与成功输出**（新 session 的 id、事件 JSONL、`list` 的两种形态、`<id>: <verdict>`、`cancel requested for <id>`）：所有拒绝与警告——不认识的 verdict、`no such session`、`session new failed: …`、`session step failed: …`——一律走 stderr，所以一个 driver 拿到的 stdout 要么是它要的东西要么什么都没有。唯一的例外是 `--stream`，那里诊断是协议的一部分（`{"stream":"run","event":"error"}` 行，见下）。
- **`session step --stream`：纯观测的行协议**（前端唯一需要的内核改动，tui.md §2.2 → 已落地）。语义与不带 `--stream` 完全相同（同一 `AgentSession.run`、同一预算夹取、同一 cancel 消化、**同一 ledger**）；区别只是 stdout **在跑的过程中**逐行输出，而不是跑完一次性输出。
  - 机制是 `loop.StepContext.observer`（可选 `StepObserver{ptr,vtable}`）。observer **无权力**：五个回调全部返回 `void`、只拿只读视图（`stepEnd` 拿整个 `StepOutcome`），所以它不能 append、不能改 model-visible 状态、不能让一个 step 失败——带 observer 的 step 与不带的走同一条路径（physics #1/#3）。回调点：`collectTurn` 把 provider 流 **tee** 给 observer 再交给 `TurnCollector`，瞬态失败重发前一次 `modelRetry`（§13）；`execOne` 前后各一次（未被派发的尾部调用两个回调都不发）；`AgentSession.step` 在 step 边界一次（含 canceled）。
  - 行协议（一行一个 JSON，写完即 flush）：带 `stream` 字段的是瞬态观测行，不带的就是与 `session events` **同形**的 ledger 事件行（同一个 `encodeEventLine`、同一套 seq）。

    ```jsonl
    {"stream":"model","event":"started"}
    {"stream":"model","event":"text_delta","text":"…"}          # 另有 thinking_delta（展示用）
    {"stream":"model","event":"tool_use_start","index":0,"id":"call_1","name":"shell"}
    {"stream":"model","event":"tool_use_input_delta","index":0,"fragment":"{\"command\":"}
    {"stream":"model","event":"usage","input_tokens":1200,"output_tokens":80,"cache_read_tokens":1100,"cache_write_tokens":0}
    {"stream":"model","event":"done","stop":"tool_use"}
    {"stream":"model","event":"retry","attempt":1,"max_retries":5,"delay_ms":1000,"error":"Transport"}   # 瞬态失败、将重发（§13）：读者丢掉本轮自上一个 started 起的 delta
    {"stream":"tool","event":"begin","call_id":"call_1","tool":"shell"}
    {"stream":"tool","event":"end","call_id":"call_1","ok":true}
    {"seq":7,"kind":"assistant","text":"…","calls":[…]}
    {"stream":"step","event":"end","status":"completed"}          ← 被 max_tokens 截断的 step 多一列 "stop":"max_tokens"
    {"stream":"run","event":"done","steps":2,"stopped":"end_turn"}
    ```

    `reasoning_item`（不透明、只为回放）**不转发**；`stopped ∈ end_turn | budget | canceled | max_tokens`（最后一步的回复被截断即 `max_tokens`，不论 `run` 是因它停的还是因连续两次停的，§4）。每个 step 的 ledger 行在该 step 的 `step end` **之前**刷出：读者见到 `step end` 就知道这一步的事件已全。诊断（原来的 "session step failed: …" 等）在 `--stream` 下变成 `{"stream":"run","event":"error","message":"…"}` 后非零退出——**stdout 上没有非 JSON 行**。
- `nulya ext init|build|activate|rollback|deactivate` 都接受 `--user`：写端落到 user root（`~/.nulya/extensions`，需要时创建）而不是 workspace；`activate|rollback --user` **在 session 里跑**（`NULYA_SESSION` 存在）时先往 stderr 说一句这件事跨出了本 workspace（§7.2），照做不拦。不给 `--user` 时，`activate|rollback|deactivate` 都作用于**该 id 生效中的那个 root**（`Roots.firstActive`，§7.2）——版本不在那里就失败并指路，只有该 id 无 active 副本时 `activate|rollback` 才落到首个持有该 built 版本的 root；操作后按生效结果决定要不要投 capability_note、要不要打印 `not in effect`。`ext list` 打印 `id / version / root`，有版本的行按冻结 manifest 多打一列 `[tools skills prompt]`（声明了什么就打什么；读不出 manifest 就不打，绝不因此让列表失败）——`prompt` 是承重的那个：activate 了的包，它的 system_prompt 进**每一场**未来 session 的 system blocks（§7.5），从前只能手读 manifest 才看得见。被遮蔽的 active 行标 `(shadowed)`，**既无 `current` 又无任何 built 版本的目录直接跳过**（`<id>/.lock` 的 lease 在校验与编译之前就把 `<id>/` 建出来了，所以一次编译失败的 `ext build` 会留下只装着锁的空壳——那是锁的位置，不是 extension；有版本没 active 的 draft 照常列 `(inactive)`）；`ext run` / `skill list` / `skill load` / session composition 一律按 root 顺序搜索。
- `nulya ext run <id>[@<version>] [tool] <json> | --arg k=v…`：`<id>` 跑生效中的版本；`<id>@<version>` 跑**恰好那个** built 版本（active 与否无关，按 root 顺序找首个持有者）——这是 `--with <id>@<version>` 带进 session 的 runtime tool 的调用形式，也是**故意不 activate 的 driver 包**的调用形式（`nulya ext run compact@v-… compact '{"session":"s-…"}'`，§11）：composition 里冻的是那个版本，`current` 可能指向别的甚至没有，所以 CLI 形式必须能点名版本；不让 `ext run` 在 `NULYA_SESSION` 下自动读 header，否则"同 session 内 activate 后 CLI 形式立即用新 current"这条语义就变了。usage 记的仍是 version-free 的 `ext:<id>/<tool>`。
- `nulya ext activate` 在 `NULYA_SESSION`（相对 workspace 的 session 文件路径）存在时，向该 session 的 inbox 投一条 capability_note（§5.3）。
- **`nulya ext trust` = workspace store 的一次性信任（§9 的 trust gate）**：打印本 workspace store 持有的 `id@version`（带 `[tools skills prompt]` 标注）再往 `<NULYA_HOME | ~/.nulya>/trusted-stores.jsonl` 记一行。什么都不持有就 `nothing to trust`（不记录），已信任就 `already trusted`（幂等），没有 home 就 exit 1 说没地方记。没有 `untrust`。与它成对的是：`ext build`（非 `--user`、落 workspace root、build 前该 store 为空）成功后**自动**记一条——生于本地不必问；而 `session new` / `session step` 在启动时过门，持有内容却无记录就 stderr 列出它持有什么 + 指路 `ext trust` 并 exit 1。**只读投影（`ext list` / `ext inspect` / `skill list` / `skill load`）与 `ext run` 都不过门。**
- 离线时 provider 回落到确定性的 scripted stand-in（`NULYA_SCRIPTED_MODE=finish|loop|truncate|handoff`，测试用；`truncate` 每步都在 tool call 中间被 `max_tokens` 切断；`handoff` 演一次两阶段目标——第一步发一个三节齐全的 `handoff` call，已有 tool_results 时说一句就收尾，转录里出现 `<nulya:context-summary>`（= 这是 fork 出来的子 session）时直接答完，于是整条 /goal 回路离线可测，§11）。

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
store root 搜索顺序（首个 active 持有者胜）        extension/roots.zig
build / activate / rollback / integrity           extension/build/build_ext.zig, store.zig
extension JSON-RPC tool/call                      extension/protocol.zig, invoke.zig
SessionComposition 版本冻结（成员解析一律硬失败）    composition.zig
ToolExecutor / Binding（builtin/extension 同构）   tool.zig, extension/tools.zig
skills + 渐进披露 catalog                          skill.zig, extension/skills.zig
system prompts 投影                                prompt.zig, composition.zig
durable append-only usage journal                  journals/tool_stats.zig
```

**可自生长（内核之上皆可学习）：** grep / glob / git / web-search / browser / pdf / excel / db / github / docker / lsp / … 全是 extension，不进 kernel。

### 15.2 三层：kernel 是 primitives，policy 是 interpretation

Kernel 只提供 primitives（`activate(version)` · `rollback(version)` · usage facts · frozen composition · pin）；**Evolution Policy** 在其上消费 primitives 产出判断（retain / promote / rollback）。第一代 Evolution Policy 不在内核里，是 **evolution session**（`extensions/evolution`，PLAN §3.7）：它读两条 journal 与 `session list`，提议一条 pin，人或它自己写下去。**Facts are durable; policy is replaceable.**

### 15.3 Non-goals（永不做成 core subsystem，属 Agent / Policy 层）

GapDetector · WorkflowMiner · ToolSynthesisManager · AutoRefactor · RewardModel · AutoPromptOptimizer · SkillPopularityEngine。kernel 不 hard-code "shell 重复 3 次 → 造工具"这类启发式。

每当想往 core 塞东西，问一句：**这是 substrate 还是 intelligence？** 若属 intelligence，放到 kernel 之上。

> **Nulya does not make capability evolution intelligent in the kernel.
> It makes capability evolution safe, observable, reversible, and learnable.**

---

## 16. 里程碑与实现状态

> **Nulya v0.1 自带两个工具。第三个工具由 Nulya 自己创造。**

`tests/e2e/`（真实 built binary，无 mock；`tests/e2e.zig` 只是聚合器）证明：一个只暴露 shell + edit 的 session，由 deterministic 模型经这两个 builtin 跑 `nulya ext init/build/activate/run` 亲手造出新扩展并记录 usage，全程该工具不进 native 面；**光有 usage 的下一场仍然只有 shell + edit**；给了 pin（`.nulya/config.toml` 的 `registry.pinned_native_tools` 或 `session new --pin`，两种都测）的下一场才把它放上 native 面并按冻结版本执行；mid-session activate v2 后 session native 仍 v1 / CLI live v2 / 新 session native v2。

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
