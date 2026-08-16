# Nulya — 给 AI 协作者的入口

Nulya 是一个用 Zig 写的极小 agent harness：**不可变内核 + 可自演化的能力层**。
内核只暴露两个内置工具（`shell`、`edit`），其余能力由 agent 自己制造成 extension、
经 usage 统计在 session 边界晋升进模型工具面。内核不负责"聪明地进化"，只负责让进化
**安全、可观测、可回退、可学习**。

## 先读什么

| 文件 | 是什么 | 什么时候读 |
|---|---|---|
| 本文件 | 地图 + physics + 模块表 + 现状 | 每次开始 |
| [docs/DESIGN.md](docs/DESIGN.md) | **现状**：已实现的架构、不变量、数据格式；与代码同步 | 改代码前 |
| [docs/PLAN.md](docs/PLAN.md) | **计划**：方向修正、路线图、尚未实现的设计（演化层、driver / `/goal`、handoff、subagent、慢速回路） | 讨论方向 / 做新功能前 |
| [docs/base-tools.md](docs/base-tools.md) | shell / edit / `emit` 的输出纪律（已实现，含"later hardening"标注） | 改 `tools/` 或 `emit.zig` 时 |
| [docs/agents-and-review.md](docs/agents-and-review.md) | subagent 原语 + 审阅门设计——**全部未实现**，归属 PLAN | 做 subagent 时 |
| [docs/tui.md](docs/tui.md) | `tui/`（Bun + OpenTUI 前端）的设计契约 + 里程碑 + 实施日志（§11）——**T0–T7 已落地**；内核改动只有 `session step --stream`（DESIGN §14）与 `session new --parent` 的父校验 / 身份继承（DESIGN §11） | 做 TUI / 改 `session step` 时 |
| `docs/history/` | 考古：拆分前的完整 DESIGN、v0.1 开发历史 | 不用读 |

**铁律：DESIGN.md 只写已落地的东西；PLAN.md 写将来。**
改了内核语义，同一个 commit 更新 DESIGN.md；把计划写进 DESIGN.md 是 bug（AI 会把它当现状）。

## 八条 physics（所有代码都在其上运行，任何 extension / driver 都改不了）

1. **Ledger 只能 append。** `ledger.zig` 唯一写口是 `append`；纠正 = 再 append 一条。
2. **Session composition 在 `init` 冻结。** tools / skills / system prompts / extension 版本整场不变；中途 activate 新版本只影响 CLI 路径与下一场 session。
3. **model-visible 状态只经 append 改变。** extension 只 *propose*，kernel *append*，PromptIR *project*；没有任何东西能 rewrite system prompt / messages。
4. **换 composition = 换 session。** 不存在 `setTools` / `setSystemPrompt` 之类的动词。
5. **Extension version 内容寻址、不可变。** `activate` / `rollback` = 原子改 `current` 指针；旧版本永远保留。
6. **Authority 不隐式增长。** `extension ⊆ shell ⊆ session`；secret 形状的 host env 永不下传给子进程。
7. **Cancellation 只有一个 kernel 语义。** 在 step 边界消化，ledger 永远处于合法状态（assistant-with-calls 后必有一条匹配的 tool_results）。
8. **智能不进内核。** "该不该造工具 / 什么值得留下 / 何时该继续" 是 agent 或可替换 policy 的事，kernel 只存 facts、给 primitives。

## 现状一句话（2026-08）

- **已跑通**（`tests/e2e.zig` 真实二进制全环）：durable ledger 文件（header 冻结 composition + `seq` JSONL）→ PromptIR → 一次 step（批量 tool call、**一条** tool_results 回传、串行执行、可取消）→ shell / edit → `nulya ext init|build|activate|run|rollback` → usage journal → 下一场 session 边界自动晋升为 native 工具并按冻结版本执行；`createDurable/openDurable` 让 session 落盘、任意进程 resume 出 turn 级相等的 PromptIR、跨进程 capability-note 经 inbox 在 step 边界排干。**durable correctness（M2.1）**：单写者由 `<id>.lock` 排他 advisory 锁强制（第二写者 `SessionBusy`，读者不挡）；inbox 事件带 `origin` 投递去重列 → 应用 exactly-once（崩溃/重投不重复）；模型身份创建时**单处** credential-aware 解析（`resolveDescriptor`）并冻结进 header `model_identity`，运行 handle 只从该 descriptor 建（跑的 == 冻结的），resume 只重解 credential、无静默 fallback（缺密钥即 `MissingCredential`；durable credential 只经 `api_key_env`，inline `api_key` 不参与）。
- **也跑通**：`nulya session new|append|step|events|cancel`（只有 `step` 写 session 文件：`append` 投 inbox、`cancel` 写标记、`events` 只读 tail；`step --max-steps` 由 kernel 夹到 `session.max_steps_ceiling`；cancel 标记由 kernel 在 step 边界消费，mid-run 也停得下来；`new --profile P [--model ID]` 选 profile 与它服务的 model id，`step --effort E` 是每步的 generation option）；`nulya config show [--json]`（有效 profiles + credential 可用性 + `[[models]]` 目录的投影，供选择器与 agent 自查，无 secret）；bare `nulya` demo 现走 durable session 路径；**脚本 extension**（`runtime.entry` 前缀区分 `bin/` 编译 vs `src/` 脚本 + `interpreter?`；脚本不编译、data/script version 不含 compiler+target（`manifest.ImplementationKind`，纯 skill/prompt 建时免 zig）；`ext init --script` / `ext run --arg k=v`）；**`nulya src`（M3）**：build.zig 把整个 `src/**` `@embedFile` 进二进制，`nulya src [path]` 打印真实源码（AI 读内核零 API 漂移），默认剥 top-level `test` 块、`--tests` 原样；`ext api` 协议 topic 成为 `nulya src extension/protocol.zig` 的特例。
- **也跑通（M4）**：四个 provider——`openai`（chat/completions）、`anthropic`（Messages，两个 `cache_control` breakpoint：冻结 system 尾 + 最后一条 message 的最后一块，后者随 append 前移）、`codex`（ChatGPT 订阅的 responses 端点，OAuth 走 `~/.codex/auth.json`、401 自动 refresh 回写，prompt cache key 由 **durable session id** 派生 → 跨 `session step` 进程同域）、`scripted`；三个真实 provider 的 POST + SSE + `reasoning` item 序列化收进共享的 `providers/wire.zig`。`zig build integration`（唯一联网、无 `NULYA_INTEGRATION_PROFILE` 即 skip）在 deepseek 的 openai 口 / anthropic 口 / codex 上实测：连续四步 `cache_read` 单调不减且 ≥ 上一步 input 的 90%。
- **也跑通（TUI，仓库顶层 `tui/`，不在内核范围）**：内核侧为它加的只有 `session step --stream`（`loop.StepContext.observer` 纯观测钩子 + 行协议，DESIGN §14；不带 `--stream` 一字未变）和下一条的 fork 原语。前端是 Bun + OpenTUI 的 driver 客户端——transcript 卡片与折叠、`tui.toml` 设定与 keymap 覆盖、`/sessions` `/ext` `/usage` `/settings` `/help` `/compact [focus]`、`/model` 选择器（读 `nulya config show --json`；↑↓ 模型、←→ effort、Enter 开新场；上次选择记在 `tui-state.json`；无可用 key 时开屏即选择器）、`/effort`、sub-session tab、observer 模式（`<id>.lock` 探针 + 内核 `SessionBusy` 双信号）、`bun build --compile` 单文件；**M5 的四个面也已消费（T8，内核零改动）**：`/sessions` 改读 `session list --json`（含 verdict / usage / composition）、`/outcome <verdict> [note]`、`/evolve` 与 `/mode <id>[@<v>]`（`ext build` → `session new --with`，**不 activate**）、token 计数以 ledger `assistant.usage` 为准（重开一场也看得见成本）、`/ext` 认多 store root 与 `shadowed`。现状与实施日志在 [docs/tui.md](docs/tui.md) §11，**不进 DESIGN.md**（DESIGN 是内核的现状）。
- **也跑通（compaction）**：内核只提供 **fork 原语**——`session new --parent <id>:<seq>` 校验父存在，且不点名模型时继承父 header 的冻结身份（composition 仍现解，让 fork 这个 session 边界自然吸收 promotion 与新版本）。压缩本身**不在内核**：何时压是 policy、压成什么是模型的判断，两者由 driver 用 `session append` + `session step` + `session new --parent` 组合出来，第一个 consumer 是 TUI 的 `/compact`（摘要在**旧 session 内部**生成以命中最大的缓存前缀，不开子 session）。DESIGN §11 / tui.md §11 T7。
- **也跑通（M5，慢速回路的 substrate）**：**outcome journal**（`.nulya/session-outcomes.jsonl` + `nulya session outcome <id> <success|partial|failure> [--note] [--seq N]`——第二条 journal 而不是 ledger 事件；**没有行 = unknown ≠ failure**，最后一条作数；只写 journal、不拿 `<id>.lock`，所以正在 `step` 的场也能当场评；**记 `source`**：缺省 = 人，`NULYA_SESSION` 在环境里就是 `agent` + `by:<那场 id>`（`by == session` = 自评，是主张不是 ground truth），`--seq N` 是对某一轮的判断、不参与 `latestFor`）· **per-step usage** 落进 `assistant.usage`（`ledger.Usage`，**不投影**，与 `reasoning` 同地位；provider 没报就整条不写，老行读回 null）· **多 store root**（`store.Roots`：workspace `.nulya/extensions` → user `~/.nulya/extensions` → `extensions.paths`（**只认 trusted 层**），**首个持有者胜**，`ext list` 标 `(shadowed)` 并按冻结 manifest 标 `[tools skills prompt]`（`prompt` = 这个包 activate 后会进每一场 session 的 system blocks）；`activate|rollback --user` 在 session 里跑会往 stderr 说一句它跨出了本 workspace（照做不拦）；frozen 版本按 root 顺序找——内容寻址故等价；header 不记 root；写端 `ext init|build|activate|rollback|deactivate --user`）· **`ext build <path>` 按 manifest id 落 store**（`<root>/<id>/versions/<v>`，draft 可以待在仓库任意路径；store 内 draft 与从前字节等价）· **`session new --with <id>[@<version>]`**（可重复；composition membership **不是** native pin：skills 进 catalog、system_prompts 进 system blocks；没 `@version` 就取 `current`，没有就 exit 1；fork 不继承）· **`nulya session list [--json]`**（`.nulya/sessions/` 的只读投影：composition（含每个冻结版本贡献的 `system_prompts`）/ parent / 事件数 / usage 求和 / **episode**（沿 `parent` 链算出的 `root` + 同 root 求和的 `episode_usage`，只在投影里连接，journal 不动）/ 最新 verdict（含 `source`/`by`））+ `session new` 开始写 header `created` · **`extensions/evolution/`**（仓库顶层、与 `src/` `tui/` 同级的 data extension：identity system prompt + skill；**不 activate**，用 `nulya ext build extensions/evolution` 拿到 version 再 `session new --with evolution@<v>`）· **M5.1 收尾**：两条 journal 的 append 持 `<journal>.lock`、读端忽略残尾；`<root>/<id>/.lock` 包住 build / activate / rollback / deactivate；`ext activate|rollback` 落到该 id **生效中**的 root（版本不在那就失败指路，只在真生效时投 capability_note）；`ext run <id>@<version>` 点名 built 版本（`--with` 带进来的 runtime tool 的调用形式）；**`max_tokens` 进 loop lifecycle**：截断的 turn 记 calls 但 torn 参数换 `{}`（assistant 事件永远可回放）、不执行、marker 批次告诉模型，`run` 连续两次截断即停，`--stream` 报 `stopped: max_tokens`。
- **也跑通（review 修补）**：assistant 事件记的是 provider 的 **`stop_reason`**（`ledger.StopReason`，取代 `truncated: bool`——落盘只写 shape 说不出来的 `max_tokens`/`other`，`lastStopReason()` 因此是一次 ledger 读而不是活在进程里的字段）· header 记 **`nulya{version, kernel_hash}`**（build 版本串 + kernel prompt 与两个 builtin 定义的 hash；**纯 provenance**，resume 对不上只在 stderr 警告一行照跑，空 stamp = 老 session = 不警告）· **shell 超时**（`{command, cwd?, timeout_ms?}`，默认 120s / 上限 600s，`tool.Timeouts` 一张表也管 extension 的 30s；超时与取消都杀**整棵进程树**（`environment.Tree`）并把已捕获的输出连同 `[timed out after …]` 一起返回，`ok=false`）。
- **还没有**：自动压缩触发（未实现，也没有对应的 config 键——何时压是 driver 的 policy）；沿 parent 链呈现连续对话；**模型主动的 handoff**（阶段边界上由模型调一个随仓库带、driver 按需 pin 的 `handoff` script extension 提议，driver 走同一条 fork 路径；不给极简 / 交互模式，不是 std tool——PLAN §3.4.1）与它的第一个 driver `/goal` 脚本（PLAN §3.6）；subagent（= session 自调用，缺第一个 consumer）；policy hook（未实现，也没有对应的 config 键）；sandbox / remote environment；first-party Anthropic key 上的实测（cache_control 采纳、thinking-on tool 循环——integration 第三条已写好等 key）；`session new --pin`（第一个 consumer 就是 `/goal` 带入 `handoff`；`--system-file/--skill` 已被 `--with` 吸收）、`--budget-tokens`；persistent extension runtime。这些的去向都在 PLAN.md。

## 模块表（`src/`，扣掉同文件测试约 6k 行）

| 文件 | 职责 | 关键不变量 / 备注 |
|---|---|---|
| `main.zig` | 入口：有参数 → `cli.dispatch`；无参数 → 固定 prompt demo | 组装 config → env → provider → promotion → `AgentSession` |
| `ledger.zig` | 4 种事件（`user_text` / `assistant{reasoning,text,calls,usage?,stop_reason}` / `tool_results[]` / `capability_note`；`reasoning` 是 provider 原样的 reasoning item 数组、不透明、kernel 不解析、只交回同一 provider 回放；`StopReason` 声明在这里、`provider.zig` re-export，落盘只写 shape 说不出来的 `max_tokens`/`other`，老行的 `truncated:true` 仍读得回但不再写），deep-copy 所有权；durable 文件（header 是 `Header` 的 `std.json` 类型化编解码 + `seq` JSONL，header 冻结 composition + `model_identity` + `nulya{version,kernel_hash}` provenance stamp）；跨进程 inbox（`depositEvent` 原子投递 / `drainInbox` 排干，事件带 `origin` 投递去重列 → 应用 exactly-once） | 唯一写口 `append`；`init` 纯内存 / `createDurable`+`openDurable` 落盘（一文件=一 generation、**一个写者**由 `<id>.lock` 排他 advisory 锁独家强制 → `SessionBusy`；ledger corruption 交给 replay/seq/JSON 校验） |
| `prompt.zig` | `Ledger → PromptIR{system_blocks, turns}` 纯投影（一个 ledger 事件一个 `Turn`，turn 不拆散；`usage` / `stop_reason` / `origin` 在类型里没有字段，所以不可能被投影） | `isStablePrefix` 仍是缓存不变量的可测形式；turns 借 ledger 的 slice，不比 ledger 活得久；generation == 文件（`currentGeneration` 已删） |
| `loop.zig` | 一次 step：freeze snapshot → `collectTurn`（每次尝试新建 collector；瞬态故障按 `StepContext.retry` 指数退避原样重发，observer 收 `modelRetry`）→ 串行执行 batch → 一条 tool_results | 取消时补齐整批（三种 marker）；`max_tokens` 截断的 turn 不执行、torn 参数换 `{}`、marker 批次关掉（`StepOutcome.stop_reason`）；`completeInterruptedToolBatch` 修复上次残尾 |
| `session.zig` | `AgentSession`：ledger 生命周期（`init` 内存 / `createDurable`+`openDurable` 落盘，resume 时 composition 从 header 冻结重建）+ step 边界（补残尾 → 消费 `<id>.cancel` → 排干 `<id>.inbox`）+ `run` 预算 + usage 记账 | `max_steps_ceiling` 由 kernel 夹；`requestCancel` 是跨进程取消的唯一入口（durable session 才有 siblings） |
| `composition.zig` | session 开始冻结 tools / skills / system prompts / pinned 版本 | pin = 硬失败；auto = 跳过；`max_tools` 含 builtin |
| `registry.zig` | `ToolSetSnapshot`：builtin 固定最前，extras 按稳定 id 排序，name/id 唯一 | |
| `tool.zig` | `ToolExecutor{ptr,vtable}` / `ToolDefinition{id,name,description,input_schema}` / `ToolContext{environment,fs,cwd}` | tool 拿不到 ledger；extension 子进程只拿 request + 净化 env + cwd |
| `tools/shell.zig` `tools/edit.zig` | 两个永久 builtin | schema 恒定（`shell` = `{command, cwd?, timeout_ms?}`：默认 120s / 上限 600s 来自 `tool.Timeouts`，超时 kill 并返回已捕获输出）；`edit` = 精确匹配事务 |
| `emit.zig` | 统一输出原语：head/tail 字节预算、UTF-8 边界、超限落盘留指针 | 落盘路径确定性（按 ledger seq）以保 replay 一致 |
| `environment.zig` | `Environment{runShell, runExtension, dialect}`；`LocalEnvironment` | 子进程 env 走 `isSecretKey` denylist 净化；`runShell` 的超时是 `child.wait` 与一个 sleep 任务在 `std.Io.Select` 里赛跑（取消点仍是 `child.wait`，io 给不出并发单元就裸跑）；超时与取消都杀**整棵进程树**（`Tree`：POSIX `pgid=0` + 负 pid 信号 / Windows 无 limit 的 job object + `TerminateJobObject`，OS 拒绝就降级只杀直接子进程），否则孙进程攥着管道写端让 drain 等不到 EOF；**正常返回不杀**，后台进程两平台一致地活下来 |
| `provider.zig` | `Model{ptr,vtable{stream}}` + `TurnCollector` + `Usage`/`StopReason`/`StreamEvent` + `RetryPolicy`/`isTransient`（provider 一次 `stream` 只试一次、把故障归类；重试循环在 loop） | provider 只能优化序列化，不能破坏 §1 turn 前缀；`reasoning_item` 是完整的 provider 形状 item，collector 原样收成 `ModelTurn.reasoning`，`thinking_delta` 只供展示 |
| `providers/wire.zig` | 三个真实 provider 共享的 wire 底座：`postSse` / `postJson`、assistant turn 的 `reasoning` 拆回逐个 item（`writeReasoningItems`）、JSON 标量；故障归类：线路故障折成 `Transport`，状态码分 `Unauthorized`/`RateLimited`/`ServerError`/`ApiError`；`Watched` stall watchdog（字节级静默超 `Post.stall_ms` 就 cancel 交换任务报 `Transport`） | SSE 行用可增长缓冲（一行能装下整个 response 对象）；`event:` 行忽略——三种方言都把事件名写在 payload 里 |
| `providers/openai.zig` | chat/completions（OpenAI / DeepSeek / 兼容端点），implicit prefix cache | 读 `cached_tokens` / `prompt_cache_hit_tokens`；DeepSeek 端点（`isDeepSeek`）：`off` → `thinking:{type:disabled}`，本轮 `reasoning_content` 收成一个 `reasoning_item` 并在带 `tool_calls` 的 assistant message 上回放（文档：不回放即 400） |
| `providers/anthropic.zig` | Messages API（含 DeepSeek `/anthropic`），**explicit cache breakpoints** | 同 role 块合并成一条 message（一批 tool_results = 一条）；usage **合并**不覆盖，否则收尾事件清零 cache 计数；thinking block 整块收进 `reasoning`、回放在 `tool_use` 之前（thinking 开着时不回放即 400） |
| `providers/codex.zig` | ChatGPT 订阅的 responses 端点 + `~/.codex/auth.json` OAuth（401 refresh 回写） | cache key = hash(session id)，跨进程稳定；`include: reasoning.encrypted_content` 要回加密 reasoning item 并回放（已实测接受） |
| `config.zig` + `default.toml` | `default → system → user → project` 合并；project 层过 `mergeProject` 只能收窄；两张表描述模型：`[[provider.profiles]]`（怎么连 + 服务哪些 `models[]`）与 `[[models]]` 目录（一个 id 是什么：label / efforts / default_effort / context_window，按 id 合并、只认 trusted 层）；`[provider.retry]`（全 profile 一份的重试策略 + `stall_timeout_ms`，trusted 层）；`Config.defaultEffort` | 用 vendored `zig-toml`；目录是纯描述，kernel 不读 |
| `extension/manifest.zig` | `nulya.extension/v2`：`runtime?{entry, interpreter?}` + `contributes{tools,skills,system_prompts}` + `permissions` | manifest 是 schema 唯一真相，不问 binary；`isScript` = entry 非 `bin/` |
| `extension/protocol.zig` `invoke.zig` | JSON-RPC 2.0 `tool/call`，oneshot spawn-stdin-stdout-exit | 响应 id 必须匹配 |
| `extension/store.zig` `integrity.zig` | `<id>/versions/v-<hash>/{extension.json,package/,bin/}` + `current` 文件 + `<id>/.lock`（`Store.lease`：build / activate / rollback / deactivate 的写者 lease）；`store.Roots` = 有序 root 搜索（首个 active 持有者胜） | version = hash(snapshot + compiler + target)，`compiler`+`target` 仅 compiled kind 非空（data/script 纯 snapshot、免 zig，见 `manifest.ImplementationKind`） |
| `extension/build_ext.zig` `toolchain.zig` `templates.zig` | `nulya ext build`：冻结 snapshot →（`bin/` entry）`zig build-exe` frozen `src/main.zig` /（`src/` entry）脚本直接冻结不编译 → seal | 内嵌 Zig 0.16 由 `-Dembed-toolchain` 门控；脚本 build 不需 zig |
| `extension/tools.zig` `skills.zig` `notes.zig` | extension → `Tool` binding / skill catalog / mid-session `capability_note` 的**文本**（投递用 `ledger.depositEvent`，排干在 `session.prepareStep`） | |
| `skill.zig` | `SkillSetSnapshot` + `<available_skills>` 渐进披露文本 | Agent Skills 兼容（`SKILL.md` frontmatter） |
| `journal.zig` | 两条 journal 共用的文件层：一行一条 append（全程持 `<journal>.lock` 排他 lease——多进程共写）、append 前修 crash 残尾、读端不拿锁且忽略残尾、文件缺失 = 还没有事实 | 只抽 IO，不抽 `Journal<T>`——schema 各自持有 |
| `tool_stats.zig` `tool_selection.zig` `promotion.zig` | `.nulya/tool-usage.jsonl` `{v:1,tool_id,ok}` → 纯函数排序 → session 边界晋升 | facts durable, policy replaceable |
| `outcome.zig` | `.nulya/session-outcomes.jsonl`：`Verdict{success,partial,failure}` + `Source{human,agent}` + `by?` / `seq?` + `append`/`readAll`/`latestFor` | 没有行 = unknown ≠ failure；同 session 可多行、最后一条作数；三个可选列只在非默认时写（人评整场 = 老行逐字节相同），未知 `source` 是错不是人评；`latestFor` 只看整场行（`seq` 行是 turn 级证据） |
| `cli.zig` | `nulya ext …（含 --user）` / `nulya session new [--parent] [--with]\|append\|step\|events\|cancel\|outcome\|list` / `nulya config show` / `nulya src [path]` / `nulya skill list\|load` / `nulya toolchain zig` / `nulya ext api`  `ext/skill/toolchain/src/config` 经 `shell` 被模型调用；`session *` 是外部 driver 面（只有 `step` 写 session 文件）；都不是 LLM tool |
| `source.zig` + `src_embed`（build.zig 生成） | `nulya src` 的数据：build.zig `@embedFile` 整个 `src/**`，`find`/`stripTests` 投影 | 默认剥 top-level `test` 块（靠 zig-fmt 第 0 列 `}` 不变量）、`--tests` 原样；测试留在文件里，剥的是投影不是存储 |
| `launch.zig` | session 启动共享件（还有 `extensionRoots`（root 顺序）与 `rfc3339Now`（header `created` / outcome `at`））：确定性 scripted provider（`NULYA_SCRIPTED_MODE`）、`resolveDescriptor(profile, model_id?)`（创建时唯一一次 credential-aware 模型解析；codex 的 credential 是 auth.json 不是 env）+ `credentialAvailable`（同一判定，供 `config show` / `session new` 的提示）+ `buildFromDescriptor`（handle 只从 descriptor 建、无静默 fallback；`cache_key` = session id）、session id/path | CLI 与 demo 共用同一 durable 路径 |

## 构建与测试

```bash
zig build test      # 单元测试（每个模块同文件的 test 块，由 main.zig 聚合）
zig build e2e       # tests/e2e.zig：真实二进制的 extension 闭环 + 自造 + 晋升
zig build run       # bare nulya：固定 prompt demo（无 API key 时走 scripted provider）

# 唯一联网的测试（DESIGN §13.2）。不设变量就整体 skip，不会让没 key 的机器变红。
NULYA_INTEGRATION_PROFILE=deepseek-anthropic zig build integration
```

Zig 0.16（新 `std.Io` API）。发布版加 `-Dembed-toolchain -Dzig-archive=<path>` 内嵌工具链。

## 工作约定

- 代码注释英文，docs 中文。测试与模块同文件（`test "..."`）。
- **不加第三个 builtin tool**；**不在 session 中途改 `tools[]`**；**不给 tool ledger**（需要对话的东西是 subagent，不是 tool）。
- 新增 kernel 概念前先问一句：**这是 substrate 还是 intelligence？** 是 intelligence 就放 kernel 之上。
- **内核只长 substrate，不长便利。** 往 `src/` 加东西前问：把它删掉，八条 physics 哪一条会失效？一条都不会 → 它不是内核。落点优先级：extension / skill（agent 自己造）> `cli.zig` / `launch.zig` 这类外壳 > kernel 模块。std 能做的不手写（`std.json` 类型化编解码、`union(enum)`）；一个字段只写不读、一个动词没有语义、一个决定在多层各做一遍、一个读者拿着写句柄——都是该删或该收的信号。
- **第二个 consumer 出现之前不抽 abstraction。**
- 改 `§15.1 frozen core`（见 DESIGN.md）的语义要有明确理由并同步文档；往外挂能力优先于改 kernel。
- 引用设计条目用 `DESIGN §x` / `PLAN §x`，别引用 history/ 里的章节号。
