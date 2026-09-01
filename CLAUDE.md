# Nulya — 给 AI 协作者的入口

Nulya 是一个用 Zig 写的极小 agent harness：**不可变内核 + 可自演化的能力层**。
内核只暴露**一个**内置工具（`shell`），其余能力由 agent 自己制造成 extension。
工具进模型工具面只有两条路：`surface:"manual"` 由 **pin** 在 session 边界加入，
`surface:"auto"`（缺省）随 membership 加入——成员来自包级 `apply:"auto"`（激活即每场常驻）、config `[extensions] with` 或 `--with`；
`surface:"internal"` 永不上模型面（只被 `ext run` 调用）。usage journal 只是证据，内核不读它排序。
内核不负责"聪明地进化"，只负责让进化 **安全、可观测、可回退、可学习**。

## 先读什么

| 文件 | 是什么 | 什么时候读 |
|---|---|---|
| 本文件 | 地图 + physics + 模块表 + 现状 | 每次开始 |
| [docs/DESIGN.md](docs/DESIGN.md) | **现状**：已实现的架构、不变量、数据格式；与代码同步 | 改代码前 |
| [docs/PLAN.md](docs/PLAN.md) | **计划**：方向修正、路线图、尚未实现的设计 | 讨论方向 / 做新功能前 |
| [docs/base-tools.md](docs/base-tools.md) | shell / `emit` 的输出纪律（已实现；`edit` 那节现在归 `extensions/std`） | 改 `tools/` 或 `emit.zig` 时 |
| [docs/agents-and-review.md](docs/agents-and-review.md) | 审阅门的设计（未实现）；subagent 那半已由 `extensions/agent` 落地 | 做审阅门时 |
| [docs/tui.md](docs/tui.md) | `tui/`（Bun + OpenTUI 前端）的契约、里程碑与实施日志（§11） | 做 TUI / 改 `session step` 时 |
| `docs/history/` | 考古：拆分前的完整 DESIGN、v0.1 开发历史 | 不用读 |

**铁律：DESIGN.md 只写已落地的东西；PLAN.md 写将来。**
改了内核语义，同一个 commit 更新 DESIGN.md；把计划写进 DESIGN.md 是 bug（AI 会把它当现状）。

## 八条 physics（所有代码都在其上运行，任何 extension / driver 都改不了）

1. **Ledger 只能 append。** `ledger.zig` 唯一写口是 `append`；纠正 = 再 append 一条。
2. **Session composition 在 `init` 冻结。** tools / skills / system prompts / extension 版本整场不变；中途 activate 新版本只影响 CLI 路径与下一场 session。
3. **model-visible 状态只经 append 改变。** extension 只 *propose*，kernel *append*，PromptIR *project*；没有任何东西能 rewrite system prompt / messages。
4. **换 composition = 换 session。** 不存在 `setTools` / `setSystemPrompt` 之类的动词。
5. **Extension version 内容寻址、不可变。** `activate` = 原子改 `current` 指针（回滚就是 activate 旧版本，没有第二个动词）；旧版本永远保留。
6. **Authority 不隐式增长。** `extension ⊆ shell ⊆ session`；secret 形状的 host env 永不下传给子进程。
7. **Cancellation 只有一个 kernel 语义。** 在 step 边界消化，ledger 永远处于合法状态（assistant-with-calls 后必有一条匹配的 tool_results）。
8. **智能不进内核。** "该不该造工具 / 什么值得留下 / 何时该继续" 是 agent 或可替换 policy 的事，kernel 只存 facts、给 primitives。

## 现状（2026-09）

**内核**：durable ledger（一文件 = 一 generation；header 冻结 composition + 模型身份 + inline prompts，其后是 `seq` JSONL；单写者由 `<id>.lock` 排他 advisory 锁强制，别的进程经 inbox 投递、写者在 step 边界排干、按 `origin` 去重做到 exactly-once）→ PromptIR 纯投影 → 一次 step（批量 tool call、串行执行、**一条** tool_results 回传、可取消、每个 call 可过 gate）。六种事件：`user_text` / `assistant` / `tool_results` / `capability_note` / `task_finished` / `model_rebind`。

**工具面**：唯一 builtin 是 `shell`（前台带超时、`background:true` 起活得过 step 进程的任务）。其余能力都是 extension——内容寻址的不可变版本 + `current` 指针，`activate` 只移指针。上模型面两条路：`surface:"auto"` 随 membership 上，`surface:"manual"` 要 pin，`internal` 永不上。成员来自包级 `apply:"auto"`、config `[extensions] with`、`--with`、以及 pin 蕴含。

**自带扩展**（顶层 `extensions/`，十个，随二进制分发，`ext seed` 落盘）：`std`（六个文件 tool）· `agent`（委派；五种 runner：nulya / codex / claude / pi / `ext:<id>` 外置）· `compact`（fork 压缩）· `handoff` · `plan` · `ask` · `ground`（开场把「这一场在哪」写成 per-session prompt）· `coding`（工作纪律）· `evolution` · `guide`（自描述 skill）。

**Provider**：`openai` / `anthropic`（两个 cache_control breakpoint）/ `codex`（ChatGPT 订阅 OAuth）/ `scripted`（离线替身，九档）。三个真实 provider 的 prompt cache 命中由 `zig build integration` 实测。

**执行环境**：`--env local | wsl[:distro] | remote:{wsl,ssh,exec}`。`wsl` 只搬 `shell` 的命令；`remote:` 那族把整个工作区搬到别的机器——shell、extension（`ext build --target` + `ext push` 送过去）、spill、后台任务都在那边跑，报告被取回来翻成 inbox 事件。远端那个常驻进程就是 `nulya remote serve`，同一个二进制。

**Driver 面**（都不是 LLM tool，经 shell 调用）：`session new|append|step|events|cancel|rebind|outcome|list|prune` · `task run|list|status|wait|kill|retarget` · `ext *` · `config show|refresh` · `journal append|read` · `src` · `skill list|load` · `remote serve|check|ls`。`session step --stream` 是行协议，`--gate` 是每个 tool call 的一票否决。TUI（顶层 `tui/`，Bun + OpenTUI）是第一个完整 driver；`drivers/goal.{sh,ps1}` 是最小的那个（各 ≤ 70 行、都不解析 JSON）。

**三条 journal**（append-only，持 `<file>.lock` 写、读端忽略残尾）：`tool-usage`（证据，内核零读者）· `session-outcomes`（评判，没有行 = unknown ≠ failure）· `trusted-stores`（授权，user 层）。

细节看 [docs/DESIGN.md](docs/DESIGN.md)，TUI 看 [docs/tui.md](docs/tui.md)，每个功能的契约与实施日志在 `docs/goals/`。里程碑流水归档在 [docs/history/2026-08-changelog.md](docs/history/2026-08-changelog.md)——**不必读**。

### 没做的

自动压缩触发（何时压是 driver 的 policy，所以内核里没有、也不会有对应的 config 键）；沿 parent 链把 fork 出来的对话呈现成连续的一条（`session list --json` 的 `root` 已经算好，前端还没连）；handoff 的 driver 守卫（context 阈值 / brief 长度——`drivers/goal.*` 故意一条都没做，等真实使用证据）；TUI 的 `/goal`；policy hook；反应式扩展行为的 watcher 协议（**内核批次钩子已明确拒绝，别再想它**）；sandbox（`permissions` 那组字段已经删掉了，形状等它自己定）；first-party Anthropic key 上的实测；`session new --budget-tokens`；persistent extension runtime。去向都在 [docs/PLAN.md](docs/PLAN.md)。

## 模块表（`src/`，扣掉同文件测试约 6k 行）

一行一个模块：它是什么 + **一条**最容易被写错的不变量。细节在各模块自己的 `//!` 头里（`nulya src <path>` 读得到），这张表只是索引。

| 文件 | 职责 | 最容易写错的那条 |
|---|---|---|
| `main.zig` `cli.zig` | 入口与 dispatch | 一个动词族一个 `cli/<verb>.zig`；共用件在 `cli/common.zig`（stdout 只放数据，拒绝与警告一律 stderr） |
| `ledger.zig` | 6 种事件、deep-copy 所有权、durable 文件（typed header + `seq` JSONL）、跨进程 inbox | 唯一写口是 `append`；一文件 = 一 generation = 一缓存域；单写者由 `<id>.lock` 独家强制；投递 id 就是 exactly-once 键；`.deposit.lock` + `<id>.lock` 两把一起才是 session 的 **lifetime 冻结**（`SessionLeases`）——投递、起后台任务、prune 在它们下面串行 |
| `prompt.zig` | `Ledger → PromptIR` 纯投影 | 一个事件一个 turn，turn 不拆散；`usage` / `stop_reason` / `origin` 在类型里**没有字段**，所以不可能被投影 |
| `loop.zig` | 一次 step：freeze → collect → 串行执行 batch → 一条 tool_results | 取消与截断都要补齐整批（marker），ledger 永远处于合法状态 |
| `session.zig` | ledger 生命周期 + step 边界（补残尾 → 消费 cancel → 排干 inbox）+ 预算 + usage 记账 | 排干在补残尾之后、模型跑之前，所以排干的事件永远不落在 tool batch 中间 |
| `composition.zig` | session 开始冻结 tools / skills / system prompts / 成员版本 | **版本冻结 ≠ pin**，但 pin 蕴含成员；成员解析失败一律硬失败并点名 |
| `registry.zig` | `ToolSetSnapshot` | builtin 固定最前，extras 按稳定 id 排序 |
| `tool.zig` | `ToolExecutor` / `ToolDefinition` / `ToolContext` | tool 拿不到 ledger（需要对话的东西是 subagent，不是 tool） |
| `tools/shell.zig` | 唯一的永久 builtin | 前台默认 120s / 上限 600s；`background:true` 不夹不缺省，回执立刻返回 |
| `emit.zig` | 输出预算、UTF-8 边界、超限落盘留指针 | 非法字节换 U+FFFD 并按 truncation 留原始字节——ledger 里的字符串必须是合法 UTF-8 |
| `environment.zig` + `environment/tree.zig` | `runShell` / `runExtension` / `startShellTask` / `putWorkspaceFile`；进程树与有界等待 | 超时与取消杀**整棵**进程树，否则孙进程攥着管道写端让 drain 等不到 EOF；子进程 env 过 secret denylist |
| `environment/remote/` | 帧协议 + `nulya remote serve` 的另一半 | 随对面持有的东西一起长的一律走**负载**不走 JSON 头 |
| `provider.zig` `providers/` | `Model` vtable + `TurnCollector`；四个 provider，wire 底座共用 | provider 只能优化序列化，不能破坏 turn 前缀不变量；`reasoning` 原样交回同一 provider |
| `config.zig` + `default.toml` | `default → system → user → project` 合并 | project 层只能收窄；`[extensions] paths` 只认 trusted 层，`with` project 层也读 |
| `extension/manifest.zig` | `nulya.extension/v2` schema | 三层听众：内核强制 / driver 声明 / 前端声明。manifest 是 schema 唯一真相，不问 binary |
| `extension/protocol.zig` `invoke.zig` | 唯一那种 wire（stdin 参数 JSON、env、stdout 即结果、退出码即 ok） | stderr 就是失败消息，所以包必须独占它 |
| `extension/store.zig` `roots.zig` `integrity.zig` | 版本目录 + `current` 记录 + 有序 root 搜索 | 首个 active 持有者胜；`current` 记录授 reach，`.sealed` 证明资格 |
| `extension/build/` | 冻结 snapshot → 编译或直接冻结 → seal；跨 root 复用 | version = hash(snapshot + compiler + target)，后两项只对 compiled 非空 |
| `extension/exec.zig` `tools.zig` `skills.zig` `notes.zig` | 执行身份解析 / tool binding / skill catalog / capability_note | 哪个文件、哪个 entry、seal 对不对，由**持有字节的那台机器**答 |
| `skill.zig` | `SkillSetSnapshot` + 渐进披露文本 | Agent Skills 兼容（`SKILL.md` frontmatter） |
| `journals/journal.zig` | 三条 journal 共用的文件层与时钟 | append 持锁并修残尾，读端不拿锁且忽略残尾；文件不存在 = 还没有事实 |
| `journals/{tool_stats,outcome,trust}.zig` | 证据 / 评判 / 授权 | 都只加可选列、不升 `v`；没有行 = unknown ≠ failure |
| `cli/task.zig` | 后台任务的 supervisor 与读者面 | supervisor 顺序承重：拿租约 → status → spawn → **deposit 后**才写 done。`status.json` 是真相，`starting`/`lost`/`unreachable` 只活在投影里 |
| `launch.zig` | session 启动共享件：模型解析、credential 顺序、scratch 路径、workspace store 的 trust gate | 门只在这一层返回 error，内核不知道 trust 存在 |
| `source.zig` `bundled.zig` | `nulya src` / `ext seed` 的数据（build.zig `@embedFile`） | 剥 test 块的是**投影**不是存储；靠 zig-fmt 第 0 列 `}` 不变量 |

## 构建与测试

```bash
zig build test      # 单元测试（每个模块同文件的 test 块，由 main.zig 聚合）
zig build e2e       # 全套 e2e = 下面五组。POSIX 并行（一个 run artifact 一个进程）；Windows 串行——
                    #   Zig 0.16 spawn 无 handle allowlist，并发的兄弟测试进程互相继承 stdout 写端，
                    #   先完成的组等 EOF 超过 60s watchdog（build.zig 有注释；单组仍是迭代快路）
zig build e2e-ext   #   tests/e2e_ext.zig   extension 生命周期：build / store roots / wire / 自造
zig build e2e-core  #   tests/e2e_core.zig  内核面：durable ledger、`session *`、gate、vision、后台任务
zig build e2e-agent #   tests/e2e_agent.zig 委派：`extensions/agent` 与它的五种 runner（离线 fake）
zig build e2e-std   #   tests/e2e_std.zig   自带 `std` 扩展的六个 tool
zig build e2e -Dtest-filter="follow-up"   # 只跑名字含该子串的测试（四组 / test / integration 都认，可重复）
zig build run       # nulya demo：固定 prompt 的一场 session（无 API key 时走 scripted provider）

# 唯一联网的测试（DESIGN §13.2）。不设变量就整体 skip，不会让没 key 的机器变红。
NULYA_INTEGRATION_PROFILE=deepseek-anthropic zig build integration
```

四组共享 `.zig-cache/nulya-e2e-prebuilt` 那个"编译一次、到处复制"的缓存（`tests/e2e/support.zig`）；并发写由 store 自己的 `<id>/.lock` 排他 lease 串起来（与两个 `nulya ext build` 进程同一条路，DESIGN §7.4）。新增 e2e 文件时挑一组挂进去——**不要再回到一个二进制**（一个二进制只用得上一个核）。

Zig 0.16（新 `std.Io` API）。发布版加 `-Dembed-toolchain -Dzig-archive=<path>` 内嵌工具链。

## 工作约定

- **注释只写代码说不出来的东西**（契约：`docs/goals/comments.md`）。写：不变量与顺序、非显然的取舍、外部约束、格式契约。不写：复述代码、为什么没写成另一种样子、某段代码曾经是什么样、以及**任何文档指针**。**代码不引用文档，文档引用代码**——`nulya src` 的读者打不开 docs，`DESIGN §8.1` 对他是悬空指针；一条注释若离开那个 §x 就不成立，说明事实还没写出来，把事实写进去、指针删掉。模块头 **≤ 15 行**；例外是**契约模块**——一个模块的头如果就是被打印出去、由第三方照着实现的规格，它可以更长，但只写规格、不写规格的辩护（今天有三个：`extension/protocol.zig`、`environment/remote/protocol.zig`、`extensions/agent/src/external.zig`）。一条规则只说一次，在它定义的地方；重复三遍说明该抽出一个有名字的东西。设计论证归 commit message 与 `docs/goals/`，不进源文件。代码注释英文，docs 中文；测试与模块同文件（`test "..."`）。
- **不加第二个 builtin tool**（`shell` 是唯一那个；`edit` 已搬进 `extensions/std`）；**不在 session 中途改 `tools[]`**；**不给 tool ledger**（需要对话的东西是 subagent，不是 tool）。
- 新增 kernel 概念前先问一句：**这是 substrate 还是 intelligence？** 是 intelligence 就放 kernel 之上。
- **内核只长 substrate，不长便利。** 往 `src/` 加东西前问：把它删掉，八条 physics 哪一条会失效？一条都不会 → 它不是内核。落点优先级：extension / skill（agent 自己造）> `cli.zig` / `launch.zig` 这类外壳 > kernel 模块。std 能做的不手写（`std.json` 类型化编解码、`union(enum)`）；一个字段只写不读、一个动词没有语义、一个决定在多层各做一遍、一个读者拿着写句柄——都是该删或该收的信号。
- **欠答案的机制长成 inbox 事件**（`task_finished` 是先例），不长成 driver 要认的新盘面文件：靠某个目录里的文件形态传递"结果稍后到"，每个 driver（TUI / `drivers/goal.sh` / `goal.ps1` / 下一个）都要重学一遍同一份 folklore，跨平台就是两份实现。今天仓库里一个这种形状都没有，别造第一个——"模型提议、driver 决定"的回路，提议的落点是 ledger（args）或 inbox 事件。
- **不做无意义的抽象。** 通常等第二个 consumer 出现再抽；但预期中的功能大概率会用到某个抽象时，可以提前做——尺子是"这个抽象有没有可信的用途"，不是机械数 consumer。
- **测试守机制，不守细枝末节。** 测试是保障代码逻辑正确性的：测一个机制有没有生效、一条不变量有没有守住、一个边界条件对不对。不要断言无关紧要的具体数值与显然的细节（文案的措辞、界面的具体行数列宽、常量的字面值、同一机制的每一种排列组合）——这样的断言不增加正确性保障，只让每次无害改动多付一轮改测试的税。写测试前问一句：**这条断言失败时，是代码逻辑错了，还是只是某个无关紧要的细节变了？** 后者不值得写；review 时发现存量测试属于后者，删。
- 改 `§15.1 frozen core`（见 DESIGN.md）的语义要有明确理由并同步文档；往外挂能力优先于改 kernel。
- docs 之间引用设计条目用 `DESIGN §x` / `PLAN §x`（别引用 history/ 里的章节号）；**源代码里一个都不写**（上一条）。
- 改 extension / config / session 组成的**用户可见语法**时，同步检查 `extensions/guide/skills/guide/SKILL.md`：manifest 字段（如 `apply` / `surface` / `readonly` / `commands` / `ui`）、`[extensions] with` / `pinned_native_tools` / `session new --with|--pin`、`ext seed|sync|activate`、skill / system prompt / driver 的最短配方都在那份 skill 里。它是模型按需 `skill load guide` 读到的自描述入口；只改 DESIGN / CLAUDE / `ext api` 而漏掉 guide，会把下一轮 agent 带回旧语义。
