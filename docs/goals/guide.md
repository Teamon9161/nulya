# Goal · Guide：harness 的自描述入口（模型怎么知道 Nulya 能做什么、去哪看）

> 这是一份**执行契约**，不是设计文档。设计背景在 [PLAN.md](../PLAN.md) §0（"可进化层全在 AI 的原生媒介里"）、§3.7.1（动机陷阱：不靠喊话）、§3.7.9（mode = data extension + `--with`）、§3.10（`nulya src`）；现状在 [DESIGN.md](../DESIGN.md) §5.3 / §7.5 / §7.6 / §14；地图和 physics 在 [CLAUDE.md](../../CLAUDE.md)。
> **每次 compaction 后先重读本文件**，尤其是 §6 进度区。
> 本文件的决策来自 2026-08-17 的设计对话（记录在 §3），已定的不要重开；认为错了就写进 §6 BLOCKED 并停下，不要自行改方向。
> **前置：从已经合并了 M2c 的 `main` 切分支**（`git log --oneline | head` 里应看到 `M2c-*` 与 `docs/goals/M2c.md`）。

## 0. 目标（一句话）

Nulya 的自描述面早就都在（`nulya src` 打印内核源码、`nulya ext api` 打印真实协议、`nulya config show`、`nulya skill list|load`），缺的是**入口**：一场只有 shell + edit 的 session 里，模型不知道这些命令存在、不知道二进制在哪（M5 evolution 报告里模型自己撞到过 "nulya not on PATH"）、不知道自己可以写 extension / skill / driver。本契约补三层入口——**kernel prompt 一句事实陈述**、**`nulya help` + 刷新 CLI 自描述文本**、**一个随仓库带的 guide skill（data extension）**——全部是"告诉它能做什么、去哪看"，**没有一个字是"你应该去进化"**（PLAN §3.7.1）。

## 1. 范围

**做（按顺序，每步测试全绿再进下一步；每个子项一个 commit `guide-x: …`）：**

1. **guide-a · `nulya help`。** `cli.zig` 加 `help` 动词（也认 `--help` / `-h`），打印 `common.usage`；未知命令的提示改成 `unknown command '<x>'; run 'nulya help'`。刷新 `common.usage` 文本，使之与 DESIGN §14 的命令表**逐动词对齐**（现在缺 `session outcome|list`、`session new` 的 `--profile/--model/--parent/--with/--pin`、`step` 的 `--max-steps/--effort/--stream`、`ext init --script`、`ext deactivate`、`--user`、`ext trust` 说明、`skill` 的 ref 形状）；每行一句话，整屏 ≤ 40 行；bare `nulya ext` / `nulya skill` / `nulya session` 无子命令时打印**各自动词族**那几行（现在 ext/skill 已经这么做，检查 session/config/src 一致）。bare `nulya`（无参数）**仍跑 demo**（e2e / 文档都依赖，不动）。同时刷新 `nulya ext api permissions|examples`：`permissions` 去掉 "v0.1 honest version" 与 `DESIGN §9` 引用，改成今天的事实（extension 与 shell 同权、secret 形状的 env 不下传、`manifest.permissions` 目前是声明、trust gate 是 store 级授权、超时上限）；`examples` 覆盖 `ext init --script` → `build` → `run <id>@<v> … --arg k=v` → `activate` → `session new --with / --pin` → `session outcome` 一整条路，以及 `--user` 与 `ext trust` 各一句。**这些文本模型会读到，遵守 D8：只写行为与用法，不引用 DESIGN / PLAN / 文件名。**
2. **guide-b · kernel prompt 加一句事实性入口。** `composition.zig` 的 `kernel_system_prompt` 在现有第二句之后加：说明 harness 的可执行文件由环境变量 `NULYA_EXE` 指出（安装后也叫 `nulya`）；**Nulya 是可扩展的——extension（你自己写的 tool，脚本或编译）、skill、system prompt、session driver 都可以在任务需要时由你来写**；`nulya help` 列出能做什么，`nulya src` 打印 harness 自己的源码。措辞英文、**新增 ≤ 60 词**、陈述句、没有 "should / remember / try to improve"。这会改 `kernel_hash`：老 session resume 时 stderr 警告一行（纯 provenance，DESIGN §3.4/§14 已定义），不需要迁移。单测：`composition` 里已有的 kernel prompt / `kernelHash` 测试补断言（含 `NULYA_EXE`、`nulya help`、`nulya src` 三个字面量；hash 随文本变）。DESIGN §7.5 或 §5.3 附近记一句"kernel prompt 说了什么、为什么只说这些"。
3. **guide-c · `extensions/guide/`（仓库顶层，与 `evolution` 同层）。** data extension，`extension.json` 只 contribute `skills:["skills/guide"]`（**不**贡献 system prompt——那是每步都付的前缀；skill 是渐进披露，catalog 一行、内容按需 `skill load`）。`skills/guide/SKILL.md` frontmatter `name: guide`，`description` ≤ 200 字符、一句话说清"何时 load"（配置 Nulya、写 / 装 / 回滚 extension、写 skill 或 driver、读内核源码时）。正文英文、**≤ 250 行**、以**指路 + 最短配方**为主，真相在 `nulya help` / `ext api` / `src` / `config show` 里，不复制文档（这样才不易过期）。分节固定：
   - **What Nulya is**（≤ 8 行：kernel = 一个 durable session 文件 + 一次 step + 两个 builtin；其余全是 extension / skill / driver；composition 在 session 开始冻结；ledger 只 append）。
   - **Finding your way**：`nulya help`、`NULYA_EXE`（两种 dialect 各一行怎么引用）、`nulya src` = 树 / `nulya src <path>` / `--tests`、`nulya ext api [protocol|permissions|examples]`、`nulya config show [--json]`、`nulya session list [--json]`、`nulya skill list|load`。
   - **Configuring**：四层合并（default → system → user → project，project 只能收窄）、`config show` 打印的路径就是文件在哪、`[[provider.profiles]]` 与 `[[models]]` 两张表、`registry.pinned_native_tools`、`session new --profile/--model`。
   - **Building an extension**：脚本优先（`ext init --script <id> <tool>`，`run.sh` / `run.ps1` / 任意可执行 + `interpreter`）；manifest 五个部位（`runtime.entry/interpreter`、`contributes.tools[]{name,description,input,timeout_ms?}`、`skills`、`system_prompts`、`permissions`）；`ext build <path>`（内容寻址 version、按 manifest id 落 store、draft 可在任意路径）；先 `ext run <id>@<v> <tool> --arg k=v` 试；`activate` / `rollback` / `deactivate`；`--user` = 所有 workspace；随 checkout 到达的 store 要 `ext trust` 一次；**tool 怎么进模型工具面**（只有 pin：config 或 `session new --pin ext:<id>/<tool>`；`--with` 只是成员不是 native；mid-session activate → CLI 立即可用、native 下一场）；什么时候该编译（要解析 JSON、要在两种 dialect 上一致——`extensions/compact` 与 `extensions/handoff` 是参照）；JSON-RPC 契约看 `ext api protocol`；tool 拿不到对话、只拿 args + 净化 env + cwd；`timeout_ms` 上限 10 分钟。
   - **Skills, prompts, modes**：SKILL.md frontmatter；`system_prompts` 进每场 system blocks（所以慎 activate，按场就 `--with`）；mode = data extension + `--with`（`evolution` 是例子）。
   - **Sessions and drivers**：`session new|append|step|events|cancel|outcome|list` 各一句；只有 `step` 写文件；`--parent` = fork（compaction / handoff 都是它）；`step --stream` 的行协议给前端；driver = 任何脚本按 `session *` 编排（`drivers/goal.*` 是第一个，handoff 是模型侧的提议 tool）——**在 nulya 仓库 checkout 里**才读得到这些参照，别的 workspace 只说形状。
   - **Evidence**：`.nulya/tool-usage.jsonl`、`.nulya/session-outcomes.jsonl`、`session outcome <id> <verdict>`；这些是 evolution mode 读的东西。
   - **Etiquette**：输出纪律（别 `cat` 整个 ledger，用 `session list --json`、`head -c`、聚合）；不要手改 `.nulya/sessions/*.jsonl`；scratch 在 `.nulya/scratch/<session>/`；`nulya` 不在 PATH 就用 `NULYA_EXE`。
   用法（写进 SKILL.md 开头一段与 README 都不需要——`nulya help` 的最后一行指路即可）：`nulya ext build extensions/guide --user && nulya ext activate --user guide <v>` 一次 → 每场 session 的 `<available_skills>` 多一行；更新 = 改 → 重 build → activate，旧版本留着。**不 activate 到本仓库的 workspace store**（那会随 checkout 走、又要过 trust gate；用户自己决定装到 user 层）。
4. **guide-d · e2e + 单测。** `tests/e2e/`（放 `source.zig` 或新开 `cli.zig`——按现有划分选）：
   - `cli help: nulya help / --help / -h print the usage with every verb family, exit 0; an unknown command points at nulya help on stderr, exit 1`（断言 usage 含 `session new`、`--with`、`--pin`、`outcome`、`list`、`ext init --script`、`ext trust`、`skill load`、`config show`、`src`、`toolchain`）。
   - `cli ext api: permissions and examples carry no document citations and cover script init → build → run → activate → --with/--pin → outcome`（断言不含 `DESIGN` / `PLAN` 字样、含上述动词）。
   - `bundled guide: ext build extensions/guide is data kind and needs no zig; session new --with guide lists the skill in the catalog and skill load returns SKILL.md verbatim; version is stable across rebuilds`（复制 `bundled evolution` 那条的骨架）。
   - `kernel prompt: a fresh session's first system block names NULYA_EXE, nulya help and nulya src`（用 `session new` + `session events` 或 composition 单测——选最短的路）。
   - 单测：`composition.zig` kernel prompt 断言（见 guide-b）。
5. **guide-e · 文档同步（每个子项完成时）**：DESIGN §14 加 `nulya help`（命令表 + `usage` 与命令表逐动词对齐这一约定）、`ext api` 三个 topic 现状；§7.5/§5.3 附近 kernel prompt 那句；CLAUDE.md「现状一句话」加一条（自描述入口：`nulya help` / kernel prompt 一句 / `extensions/guide`）+ 模块表 `cli.zig` 一行；PLAN §3.10 加一句"入口已补"、§4 开放问题加一条**打包**问题（随仓库带的 extension——compact / handoff / evolution / guide——目前只有 checkout 里才 build 得到；发布二进制要不要像 `src/**` 一样内嵌 `extensions/**` 并给 `ext build` 一个 bundled 来源，等第一个非 checkout 用户再定）；tui.md 不动（无 TUI 改动）；`tests/e2e.zig` 头注释。
6. **真实跑一次**：在本仓库、真实 provider 上起一场 `session new --with guide@<v>`，append "How do I make a shell script into a tool that appears on your tool list next session? Answer from the guide, then do it for a script that prints the date."，`step --max-steps 12`；看模型是否 `skill load` 了 guide、是否走了 `ext init --script → build → run → activate → 指出还需要 pin` 这条路而不是瞎猜；把 assistant 文本与它跑的命令列表贴进 §6（只往 `.nulya/` 写；跑不了写明原因）。

**不做（明确越界）：** 改 kernel 语义（只动 `composition.zig` 的那一个字符串常量与 `cli.zig` / `cli/common.zig` / `cli/ext.zig` 的文本；`ledger` / `session` / `loop` / `prompt` / `composition` 逻辑一字不动——需要动就是 BLOCKED）；给 kernel prompt 加任何"鼓励 / 提醒改进"的话；guide 贡献 system prompt；自动 build / activate guide（bootstrap 是用户的决定）；内嵌 `extensions/**` 到二进制（记进 PLAN §4，不做）；bare `nulya` 改成打 usage；`nulya src` 加 glob / 过滤参数（`nulya src | grep` 够用；便利不进内核）；TUI 代码；M6 任何内容；对已有 e2e 的顺手重构；push。

**可选 stretch：** 无。

## 2. 完成标准（可机器验证；全部满足才算完成）

- `zig build test` 与 `zig build e2e` 在 **Windows（本机）** 全绿；代码不得 Windows-only。
- §1.4 的四条 e2e 新增并通过（名字可微调，语义不可少）；既有 e2e 全部继续通过（断言不减弱）。
- `nulya help` 输出与 DESIGN §14 命令表逐动词对齐（人工核一遍，差异写进 §6）。
- `extensions/guide` 两次 `ext build` version 相同；`SKILL.md` ≤ 250 行；kernel prompt 新增 ≤ 60 词。
- 所有 model-facing 文本（kernel prompt、usage、`ext api` 三个 topic、SKILL.md）不含 `DESIGN` / `PLAN` 字样（D8；`grep -n "DESIGN\|PLAN" extensions/guide -r src/cli/common.zig src/cli/ext.zig` 只允许出现在 Zig **注释**里）。
- 文档：DESIGN §14 / §7.5 与代码一致；CLAUDE.md 现状已更新；PLAN §3.10 / §4 已更新。
- **手动**：§6 里有一份真实 session 记录（或写明为何跑不了）。
- 每个子项一个或多个 commit，信息格式 `guide-a: …` … `docs: …`；在分支 `guide` 上；**不 push**。

## 3. 已定决策（不要重开；如认为错了，写进 §6 BLOCKED 并停下）

- **D1 · 说能力，不劝进化。** kernel prompt 与 guide 都只陈述"Nulya 可扩展、你可以写 extension / skill / driver、去哪看"，不写"你应该改进自己"——PLAN §3.7.1 已论证喊话不解决动机结构，造工具的场合是 evolution mode（已有）。用户原话：可以不鼓励，但要告诉它 nulya 可以现写工具、driver 等。
- **D2 · 三层入口各司其职。** kernel prompt = 一句 bootstrap（无 skill 也知道去 `nulya help`）；`nulya help` + `ext api` = CLI 与代码同源的自描述，不会漂；guide skill = 参考手册，渐进披露、按需 load、随仓库版本化。三层都不复制文档，只指路。
- **D3 · guide 是 skill，不是 system prompt；随仓库带，不自动装。** system prompt 每步都付 token；skill 一行 catalog。用户装到 user 层（`--user`）一次即全局；更新走 build → activate；不在本仓库 workspace store 里 activate（会随 checkout 走 + 过 trust gate）。
- **D4 · 改 kernel prompt 是允许的，因为它不是 frozen core 的语义而是内容；代价 = `kernel_hash` 变一次。** DESIGN §3.4/§14 已定义这时的行为（resume 警告一行、照跑），无需迁移。**但只加事实入口这一句**，别顺手改写现有三句。
- **D5 · `nulya src` 不加 glob。** 无参数 = 全树、有 path = 文件、`--tests` 原样，够用；模型要过滤 `nulya src | grep …`。
- **D6 · bare `nulya` 仍是 demo。** `help` 是新动词，不改无参数行为（e2e 与文档依赖）。
- **D7 · D8 同 M2c：model-facing 文本零文档引用。** kernel prompt、usage、`ext api` 三个 topic、SKILL.md 全部适用；违反即改。
- **D8 · 打包问题只记不做。** 随仓库带的 extension 在非 checkout 环境拿不到，是 M8 / 发布的问题；写进 PLAN §4，等第一个非 checkout 用户。

## 4. 参考（先读这些，再动手）

- `src/cli.zig`（dispatch）、`src/cli/common.zig`（`usage`、`printOut/printErr`）、`src/cli/ext.zig`（`api` 三个 topic 的文本、`dispatchExt` 的 usage 分支）、`src/cli/session.zig`（无子命令时的行为）。
- `src/composition.zig` §41–86（`kernel_system_prompt`、`kernelHash`）与同文件的相关 test。
- `extensions/evolution/`（data extension 的形状：`extension.json` + `skills/<name>/SKILL.md` frontmatter）、`tests/e2e/extension.zig` 的 `bundled evolution` 一条（骨架照抄）、`tests/e2e/source.zig`（cli e2e 的写法）。
- `docs/goals/M2c.md` §3 D8 与 §6（刚落地的 handoff / goal driver 是 guide "Sessions and drivers" 一节的参照）。
- DESIGN §5.3（`NULYA_SESSION` / capability_note）、§7.6（`NULYA_EXE`）、§9（authority、trust gate）、§14（命令表——`usage` 要对齐的对象）；`docs/base-tools.md`（输出纪律，guide "Etiquette" 的来源）。
- 本仓库 `nulya` 不在 PATH 上：`./zig-out/bin/nulya.exe`（`zig build` 后），或 `NULYA=./zig-out/bin/nulya.exe`。

## 5. 工作方式

- 分支 `guide`（从含 M2c 的 `main` 切）。每个子项完成：`zig build test` + `zig build e2e` 全绿 → commit。
- 代码注释英文，docs 中文，SKILL.md / usage / kernel prompt 英文；测试与模块同文件；`zig fmt`。
- 每完成一个子项，在 §6 记一行（commit hash + 一句话 + 有无偏离）。
- 卡住 / 需要改内核逻辑 / 发现契约自相矛盾 → §6 写 `BLOCKED: …`，停下等人，不要绕。

## 6. 进度区（执行时更新）

- **guide-a** `fe9f022` — `help` / `--help` / `-h` 成为动词；未知命令 → `unknown command '<x>'; run \`nulya help\``（stderr, exit 1）。`common.usage` 拆成六个按动词族的常量再拼成一屏（**39 行**），与 DESIGN §14 命令表逐动词对齐；bare `nulya ext|skill|session|config|toolchain` 各印自己那块，`cli/session.zig` 里那份**重复的** session usage 删掉改为引用同一块（一处偏离契约字面："检查 session/config/src 一致"落地成"消除第二份文本"）。bare `nulya` 仍跑 demo、`nulya src` 无参数仍列树。`ext api permissions` 重写成今天的事实（同 shell 权限 / 净化 env + `NULYA_EXE` + `NULYA_SESSION` / tool 拿不到对话 / permissions 仅声明 / 三个超时 / store trust gate），`examples` 覆盖 script init → build → run `--arg` → activate → `--pin` → `--with` → `--user` → `ext trust` → `session outcome`。两处文本零文档引用。
- **guide-b** `4820243` — kernel prompt 在第二个字符串块之后插一句（**57 词**，≤ 60）：`NULYA_EXE` 给出可执行文件路径（安装后叫 `nulya`）、`nulya help` 列能力、`nulya src` 打印本 harness 源码、extension（脚本或编译）/ skill / system prompt / session driver 都是模型可以写的东西。既有三句一字未改，无 "should / remember / try to"。新单测 `the kernel prompt names the harness binary, the help verb and the source verb, and states extensibility without urging it`（断言三个字面量 + 四类可写物 + 四个劝诫词不出现）；既有 `kernelHash` 测试原样通过（hash 随文本变是它本来就断言的）。DESIGN §7.5 末尾加一段"kernel prompt 说什么、为什么只说这些"。
