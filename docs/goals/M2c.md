# Goal · M2c：模型主动的 handoff + 第一个 driver `/goal`

> 这是一份**执行契约**，不是设计文档。设计在 [PLAN.md](../PLAN.md) §0.1 #4、§1（M2c）、§3.4.1、§3.6；现状在 [DESIGN.md](../DESIGN.md) §11 / §14；地图和 physics 在 [CLAUDE.md](../../CLAUDE.md)。
> **每次 compaction 后先重读本文件**，尤其是 §6 进度区。
> 本文件的决策来自 2026-08-17 的设计对话（记录在 §3），已定的不要重开；认为错了就写进 §6 BLOCKED 并停下，不要自行改方向。

## 0. 目标（一句话）

把 M2 剩下的最后一块欠账收掉：**模型能在阶段边界主动提议 handoff（一个随仓库带的 tool），一个随仓库带的 `/goal` driver 看到提议就走 `extensions/compact` 那**同一条** fork 路径继续下一阶段**——`--pin`（DESIGN §5.1/§14）从此有第一个真实 consumer，`session new --parent` 仍只在一处被调用，内核零改动（除 scripted provider 多一档测试模式）。

## 1. 范围

**做（按顺序，每步测试全绿再进下一步；每个子项一个 commit `M2c-x: …`）：**

1. **M2c-a · `extensions/compact` 加"给定 brief 就只 fork"的路径。** `compact` tool 的 input 增加可选 `brief_file`（string，workspace 相对路径或绝对路径）。给了 `brief_file`：**跳过**七步里的 2–4（不 append 请求、不 step 旧 session、旧文件**零改动**），fork 点 = 旧 ledger 当前 tail 的 seq（用 `session events <old>` 读最后一行的 `seq`；旧 session 一行事件都没有 → JSON-RPC error，不 fork），brief = 文件内容；文件读不到 / 为空 → error，不 fork。返回形状不变（`summary_bytes` = brief 字节数）。同时给**两条路径**（摘要与 brief_file）都在 carried 文本末尾**由代码**追加一段父指针 footer（PLAN §3.4.1"brief 的一条硬约定"）：形如 `---\nParent session: <old-id> (forked at seq N). The full transcript is still on disk: nulya session events <old-id>` ——措辞可调，**必须含父 id 与 `nulya session events <old-id>`**。`request_marker` / `summary_marker` 两个字符串不变、不加第三个 marker（TUI 折叠零改动）。更新 `extension.json` 的 input schema 与 tool description、`main.zig` 顶部注释（七步说明加"brief_file 分支"）。
2. **M2c-b · `extensions/handoff/`（仓库顶层，与 `compact` / `evolution` 同层）。** compiled extension（理由见 §3 D1），contribute 一个 tool `handoff`，input：`done`（必填：上一阶段的**结论**——做了什么、改了哪些文件、拍板了什么）/ `next_task`（必填：下一阶段要做什么 + 什么算完成）/ `keep`（必填：下一阶段必须原样带走的事实——路径、符号、命令、id、测试结果）/ `drop`（可选：有意丢掉的过程细节）。description 里说清：**只在一个阶段真正做完、且剩余工作不再需要本阶段过程细节时调用；调用一次；返回后不要再调任何工具、直接结束本轮**。行为：① 校验四节（必填三节 trim 后非空）；缺 → JSON-RPC error `-32602`，message 列出缺哪几节，**不落盘**；② 读 `NULYA_SESSION`（`session step` 给子进程加的，值是 session 文件路径，stem 是 id）；没有 → error（"handoff must be called from inside a session"），不落盘；③ 渲染成 markdown（`# Handoff` + 四节标题 + 正文；开头一行 `session: <id>`），写到 workspace 的 `.nulya/handoffs/<session-id>-<n>.md`（`<n>` 由实现定：per-session 计数或时间戳；要求同一 session 内单调、不覆盖、人可读；**不是** ledger seq——tool 拿不到 ledger）；④ 返回 result `{recorded: "<相对路径>", message: "handoff recorded — do not call any more tools; end this turn now."}`。`timeout_ms` 不声明（缺省 30 s 足够）。`permissions`：`fs: [".nulya/handoffs"]`（形状按 manifest 现有 permissions 写法）。加 `README.md`（三段：是什么、为什么是 tool 不是文本约定、怎么被 driver 消费）——或把这些写进 `main.zig` 顶部注释，二选一，别两处。
3. **M2c-c · scripted provider 加 `handoff` 档。** `launch.ScriptedProvider.Mode` 加 `handoff`（`NULYA_SCRIPTED_MODE=handoff`）：transcript 里已有 `tool_results` → 文本 `handoff proposed` + `end_turn`；任一 user turn 以 `<nulya:context-summary>` 开头（= 这是 fork 出来的子 session）→ 文本 `done` + `end_turn`；否则发**一个** `handoff` call，参数是三节齐全的固定 brief（`next_task` 里放一个可断言的哨兵字符串，如 `PHASE-2-SENTINEL`）。三档现状注释（`launch.zig` §44 附近）与 DESIGN §13 那行 `finish|loop|truncate` 一起更新。
4. **M2c-d · `drivers/goal.sh` + `drivers/goal.ps1`（仓库顶层新目录 `drivers/`）。** 第一个 driver，PLAN §3.6 那段伪码的落地，两份脚本各 ≤ 60 行、语义逐行对齐、**都不解析 JSON**（理由见 §3 D4）。用法：`goal.sh [--profile P] [--max-iterations N] [--handoff <id>[@v]] [--compact <id>[@v]] (<goal text> | --file <path>)`；`nulya` 二进制取 `$NULYA` 环境变量，缺省 PATH 上的 `nulya`。流程：
   - 没给 `--handoff` / `--compact` 就自己 `nulya ext build <repo>/extensions/handoff|compact`（repo = 脚本自身所在目录的上一级；build 内容寻址、重复无害），从 stdout 取 version（看 `cli/ext.zig` 打印格式 / e2e `extractVersion`）。
   - `id=$(nulya session new [--profile P] --with handoff@<v> --pin ext:handoff/handoff)`；stdout 打一行 `session <id>`。
   - `nulya session append $id "<goal 文本 + 固定前言>"`。前言（英文，脚本内常量）：说明有 `handoff` tool；按阶段工作（goal 文本自己给了阶段计划就按它的，否则 explore → design → implement → verify）；**一个阶段做完且剩余工作不再需要本阶段过程细节时才调 `handoff`，调完结束本轮**；琐碎目标不要 handoff。
   - loop（≤ N 次，缺省 50）：`out=$(nulya session step $id --max-steps 1)`；然后**先看文件**：`.nulya/handoffs/<id>-*.md` 里有 loop 开始后新出现的 → `new=$(nulya ext run compact@<v> compact --arg session=$id --arg brief_file=<那个文件>)` → 从输出里正则取 `"session":"(s-[^"]+)"` → stdout 打 `handoff <id> -> <new>` → `id=$new` → 继续；否则 `out` 里有 `"calls":[]` 的 assistant 行（模型结束了本轮）→ stdout 打 `done <id>` + 一行提示 `evaluate: nulya session outcome <id> <success|partial|failure>` → exit 0；否则继续。
   - 预算用尽 → stderr 一句 + exit 3。任何 `nulya` 子命令失败 → 立即 exit（`set -e` / `$ErrorActionPreference='Stop'`）。
   - **不做**：context 大小守卫、brief 长度阈值、自动 outcome、并发多 goal——都是 PLAN §3.4.1 列的将来 policy，脚本注释里点一句即可。
   - **4b · M2c-d2 · driver 透传 `--stream`（2026-08-17 追加，用户要求 TUI 跑 `/goal` 时看得到实时 token 流）。** 两份脚本改成 `nulya session step $id --max-steps 1 --stream`，把 step 的 stdout **逐行原样透传到 driver 自己的 stderr**（sh：`| tee "$log" >&2`；ps1：`| Tee-Object -FilePath $log | ForEach-Object { [Console]::Error.WriteLine($_) }`），driver 的 **stdout 只留控制行**（`session` / `handoff` / `done` / `evaluate`，一行都不多）。信号改为：handoff = 新文件（不变）；本轮结束 = `$log` 里有 `"stopped":"end_turn"`（`{"stream":"run","event":"done",…}` 行）；`$log` 里出现 `"stream":"run","event":"error"` → stderr 已经有那一行了，直接 `exit 1`（POSIX sh 的 `set -e` 管不到管道左侧、ps1 同理，所以要显式 grep）。行数上限放宽到各 ≤ 70。人在终端跑：stdout 干净、stderr 是流（想安静就 `2>/dev/null`）；TUI 跑：spawn 后 stderr 喂给它已有的 `--stream` 解析器（token delta / tool begin-end / usage 全都在），stdout 控制行用来开 tab、handoff 时切 tab——**不需要** tui.md §5.6 / 开放问题 4 里的 `<id>.live` sidecar，内核零改动。e2e（§1.5 第四条）加断言：driver **stdout 恰好**只有那几行控制行（没有以 `{` 开头的行）；driver **stderr** 含 `"stream":"model"` 与 `"stream":"run"` 的行。tui.md T10 占位按此写（按平台选脚本：`win32` → `powershell -NoProfile -ExecutionPolicy Bypass -File drivers/goal.ps1`，否则 `sh drivers/goal.sh`；stderr → stream parser，stdout → tab 控制）。
5. **M2c-e · e2e。** 放 `tests/e2e/`（按现有文件划分：compact / handoff 归 `extension.zig` 的 bundled 段，driver 归 `session.zig`），全部在没有 `NULYA_TEST_ZIG` / `NULYA_REPO` 时 skip 而不是红：
   - `bundled compact: brief_file forks at the tail without touching the parent — the parent file is byte-identical, the child queues the brief plus a parent pointer, and an empty parent or a missing file is refused`
   - `bundled handoff: a brief missing sections is refused and nothing is written; a full brief is recorded under .nulya/handoffs/<session>-* and answers "end this turn"; outside a session it is refused`（`ext run` 时经 env 注入 `NULYA_SESSION` 来模拟在 session 内）
   - `bundled handoff: a session that pins ext:handoff/handoff exposes it natively and the scripted provider's handoff call executes the frozen version`（复用 `script extension … pinned native` 那条的骨架，验 `--pin` 与 `--with` 一起工作）
   - `session cli: drivers/goal runs the bundled driver — the model hands off, the driver forks through compact, and the goal completes in the child`：跑真实的 `drivers/goal.ps1` / `goal.sh`（按平台），`NULYA_SCRIPTED_MODE=handoff`，`--profile scripted`；断言：exit 0；stdout 有 `session <p>`、`handoff <p> -> <c>`、`done <c>` 三行；`<c>` header 的 `parent` = `<p>:<p 的 tail seq>`；`<p>` 文件在 handoff 之后**没有再长**（fork 前后字节相同——对照 driver 输出时机可用 `session events` 行数）；`<c>` 的第一条事件是 `user_text`、以 `<nulya:context-summary>` 开头、含哨兵字符串与 `nulya session events <p>`；`.nulya/handoffs/<p>-*.md` 存在且含哨兵；`session list --json` 里 `<c>.root == <p>`。
6. **M2c-f · 文档同步（每个子项完成时，不是最后一起）**：DESIGN §11 加一段 handoff（bundled `extensions/handoff` + compact 的 `brief_file` 分支 + 父指针 footer + `drivers/goal` 是第一个 driver、`--pin` 的第一个 consumer；明说"内核零改动"）；§13 scripted 四档；§14 核对无 CLI 变化。PLAN：§1 M2c 标 ✅ 指向 DESIGN §11，把 §3 里三处偏离（D1 compiled、D3 footer 由代码写、D4 driver 是脚本对而非 extension）作为"落地时的修正"写进去；§3.4 "仍未做"删 handoff 一条；§3.4.1 与 §3.6 标 ✅ 已落地（保留设计文字，删"待做"措辞）；§4 开放问题里 handoff 守卫阈值一条保留但改成"等 /goal 有真实使用证据"。CLAUDE.md：「现状一句话」compaction 一条补 handoff + `drivers/goal`；「还没有」删 handoff / `/goal`；模块表 `launch.zig` 一行补 `handoff` 档。tui.md：§10/§11 加 T10 占位（`/goal` = spawn `drivers/goal.*` + observer 跟随子 session；**本轮不做 TUI 代码**）。`tests/e2e.zig` 头注释。
7. **真实跑一次**：在本仓库、真实 provider（`nulya config show` 看哪个 profile 有 credential；都没有就写明跳过）上用 `drivers/goal.*` 跑一个两阶段小目标（例：阶段 1 读 `docs/base-tools.md` 归纳 shell 的输出纪律并 handoff；阶段 2 在 brief 基础上写一段 ≤10 行的对照说明到 `.nulya/scratch/`），把 driver stdout、生成的 handoff 文件原文、子 session 首条 turn 贴进 §6。**这一步只读仓库、只往 `.nulya/` 写**；跑不了就在 §6 写明原因。

**不做（明确越界）：** 改 kernel（`src/` 只动 `launch.zig` 的 scripted 档 + 相应注释；`composition` / `session` / `ledger` / `loop` / `cli/*` 一字不动——需要动就是 BLOCKED）；新 CLI 动词（不加 `session transfer`、不加 `<id>.handoff` 标记文件）；TUI 代码；自动压缩触发；handoff 守卫（context 阈值 / brief 长度）；`--budget-tokens`；M6 任何内容（usage journal 不加 `version`）；subagent；对 frozen core 或已有 e2e 的"顺手重构"；push。

**可选 stretch（只在 1–7 全绿、已 commit 之后）：** 无。有想法写进 §6 "后续"，不做。

## 2. 完成标准（可机器验证；全部满足才算完成）

- `zig build test` 与 `zig build e2e` 在 **Windows（本机）** 全绿；`drivers/goal.sh` 用 `sh -n` 过语法（有 WSL/Git Bash 就跑一遍 `sh -n`，没有就写明）；代码与脚本不得 Windows-only。
- §1.5 的四条 e2e 新增并通过（名字可微调，语义不可少）；既有 e2e 全部继续通过（断言不减弱）。
- 单测：`launch.zig` scripted `handoff` 档三种分支各一例（无 tool_results → 发 handoff call；有 → end_turn；子 session → done）。
- `extensions/compact` 与 `extensions/handoff` 各自 `ext build` 两次 version 相同（内容寻址）。
- 文档：DESIGN §11/§13 与代码一致；PLAN M2c ✅；CLAUDE.md 现状与「还没有」已更新；tui.md T10 占位。
- **手动**：§6 里有一份真实 `/goal` 两阶段运行记录（或写明为何跑不了）。
- 每个子项一个或多个 commit，信息格式 `M2c-a: …` … `docs: …`；在分支 `m2c` 上；**不 push**。

## 3. 已定决策（不要重开；如认为错了，写进 §6 BLOCKED 并停下）

- **D1 · `handoff` 是 compiled extension，不是 script。** PLAN §3.4.1 写的是"script extension、免 zig"，落地改为 compiled，理由与 `extensions/compact/src/main.zig` 顶部记录的完全相同：tool 收到的是 JSON-RPC 请求、要回同一个 `id`、要校验四节——`sh` 没有 JSON 读取器，一个 manifest 只有一个 `interpreter`（随仓库带的东西没法 ps1 + sh 各一份还保持一个 version），两份实现同一个 tool 更糟。PLAN §0.1 #3 给 Zig 留的正是这种情况。这是对 §3.4.1 措辞的修正，落地时写进 PLAN。
- **D2 · fork 只在一处：`extensions/compact`。** handoff tool **只 propose、不 fork**（不调 `session new`）；`/goal` 拿到 brief 后调 `compact` 的 `brief_file` 分支。`session new --parent` 在整个仓库里仍只被 `extensions/compact/src/main.zig` 调用。brief 沿用 `<nulya:context-summary>` marker（不加第三个 marker；TUI 折叠零改动）。
- **D3 · 父指针 footer 由 compact 的代码追加，不靠模型记得写。** 两条路径都加。这是 propose→append 的正统用法（driver 经 `session append` 投一条 user turn），不是 tool 改 model-visible 状态。
- **D4 · `/goal` 是脚本对（`drivers/goal.sh` + `drivers/goal.ps1`），不是 extension。** 两条硬约束逼出来的：① 一个 driver 一跑几十分钟，而 `ext run` 对 extension tool 强制 manifest `timeout_ms`（上限 `tool.Timeouts.extension_max_ms` = 600 s）——driver 不是 tool call，不该被塞进那个形状；② script extension 一个 manifest 一个 interpreter，跨平台就得两个 extension。所以按 PLAN §0.1 #4 "`/goal` 是 20 行 shell" 的本意落地为脚本对，**信号走文件不走 JSON**：handoff tool 落盘的 `.nulya/handoffs/<session>-*.md` 就是"提议"，driver 每步之后看有没有新文件；transcript 只 grep `"calls":[]`（既有 e2e 的做法）。两份脚本因此都不需要 JSON 解析——这也是它们能各 ≤ 60 行的原因。
- **D5 · fork 时机 = handoff 出现的那一步之后立即 fork。** 不再 step 父 session 让模型"收尾"：父 ledger 停在 assistant-with-calls + tool_results，合法（physics §7）；省一次请求。
- **D6 · brief 分节 = `done` / `next_task` / `keep` / `drop?`。** 前三节必填、非空即合法（不设长度阈值——那是将来的 driver policy）。
- **D7 · 内核零改动**（`launch.zig` 的 scripted 档除外——它是离线替身、测试用，DESIGN §13 已列三档）。发现必须改 `composition` / `session` / `cli/*` 才能落地 → BLOCKED，不要动。
- **D8 · model-facing 文本里不引用文档。** tool `description`、input schema 的 `description`、tool 返回的 `message`、driver append 进 session 的前言——这些是模型看到的字，只写行为与用法，**不出现 `DESIGN §x` / `PLAN §x` / 文件名之类的引用**（模型读不到 docs，extension 还可能装到别的 workspace；每场都在付这些 token）。文档引用只待在代码注释与 docs 里。`extensions/compact/extension.json` 现有的 `(fork, DESIGN §11)` 也按此删掉。

## 4. 参考（先读这些，再动手）

- `extensions/compact/src/main.zig`（全文，特别是顶部注释与 `compact()` 七步）、`extensions/compact/extension.json`、`extensions/compact/src/compact_prompt.md`。
- `tests/e2e/extension.zig` 的 `bundled compact` 与 `script extension … pinned native` 两条；`tests/e2e/session.zig` 的 `a shell-script driver runs a goal loop` 一条（ps1/sh 双脚本 + 按平台选择的骨架直接复用）。
- `src/launch.zig` `ScriptedProvider`（§44–118）；`src/cli/ext.zig` `ext run` 的 args / timeout / 输出（`invocation.output` 是 tool 的 result JSON）；`src/cli/common.zig` `envSessionId`（`NULYA_SESSION` 是路径、stem 是 id）；`src/extension/build/templates.zig`（compiled 模板与 manifest 写法）。
- DESIGN §7（extension 布局 / 权限形状 / `NULYA_EXE`）、§11、§13、§14；PLAN §3.4.1、§3.6。
- 本仓库 `nulya` 不在 PATH 上：用 `./zig-out/bin/nulya.exe`（`zig build` 后），或 `NULYA=./zig-out/bin/nulya.exe`。

## 5. 工作方式

- 分支 `m2c`（从 `main` 切）。每个子项完成：`zig build test` + `zig build e2e` 全绿 → commit。
- 代码注释英文，docs 中文；测试与模块同文件；`zig fmt`。
- 每完成一个子项，在 §6 记一行（commit hash + 一句话 + 有无偏离）。
- 卡住 / 需要改内核 / 发现契约自相矛盾 → §6 写 `BLOCKED: …`，停下等人，不要绕。

## 6. 进度区（执行时更新）

- **M2c-a** `d084eb0` — `extensions/compact` 加 `brief_file` 分支：给了就跳过步骤 2–4（旧文件 md5 前后相同，实测），fork 点 = `session events <old>` 最后一行的 `seq`；brief 读不到/为空 → `-32602`，父无事件 → `-32001`，两者都不 fork；两条路径的 carried 文本末尾由代码追加父指针 footer（含父 id 与 `nulya session events <old>`）。`extension.json` 的 schema/description 与 `main.zig` 顶部注释同步。无偏离。
- **D8 应用** `52cd6f4` — 删掉 `extensions/compact/extension.json` tool description 里的 `(fork, DESIGN §11)`；此后所有 model-facing 文本（handoff 的 description / schema description / 返回 message、driver 前言）都只写行为与用法，文档引用只留在代码注释与 docs 里。
- **M2c-b** `42b3419` — `extensions/handoff/`（compiled，`bin/handoff`）：四节校验（缺 → `-32602` 一次列全缺的节、**不落盘**）；`NULYA_SESSION` 缺失 → `-32000` 且不落盘（检查在建目录之前）；落盘 `.nulya/handoffs/<id>-<n>.md`（`n` 从 1 起，`createFile{.exclusive}` 取第一个空位——单调、不覆盖、并发安全），返回 `{recorded, message}`。文档三段写进 `main.zig` 顶部注释（不加 README）。实测两次 `ext build` version 相同（`v-3e81022b2a3612cf7c804217`）。无偏离。
- **M2c-c** `ed6ae0d` — `ScriptedProvider.Mode` 加第四档 `handoff`（三分支按契约顺序：有 `tool_results` → `handoff proposed` + end_turn；转录里有 `<nulya:context-summary>` 开头的 user turn → `done` + end_turn；否则发一个带 `PHASE-2-SENTINEL` 的完整三节 `handoff` call）。`launch.zig` 顶部注释改成四档 + DESIGN §13 那行同步。单测一条覆盖三分支（`the scripted handoff mode plays a two-phase goal`）。marker 常量按值复制而非 import——scripted 是离线替身，不该依赖 `extensions/compact`。无偏离。
- **M2c-d** `ff71b26` — `drivers/goal.sh`（59 行）+ `drivers/goal.ps1`（60 行），逐行对齐、都不解析 JSON。实测两边都跑通（scripted `handoff` 档：`session <p>` / `handoff <p> -> <c>` / `done <c>`，exit 0；`loop` 档 exit 3；缺 goal exit 2；`--file` 生效）。两处落地时改的细节：① 取新 session id 必须取**第一个** `"session":"s-…"`（compact 先写 `session` 再写 `parent`）——初版 sh 用贪婪 `sed` 取到了**父** id，于是每轮都 fork 回自己、跑满 50 轮，实跑发现并改成 `grep -o | head -1 | cut`；② ps1 里 `Write-Error` 在 `$ErrorActionPreference='Stop'` 下是终止性错误、会吃掉 `exit <n>` 并打出堆栈，三处诊断改成 `[Console]::Error.WriteLine` + `exit`，退出码这才与 sh 一致；native exe 的非零退出在 PowerShell 里不抛，所以 `session new` 后加了一句显式空值检查（sh 那边 `set -e` 已覆盖）。
- **M2c-d2** `d16284f` — 按 §1.4b：两份脚本改走 `session step --max-steps 1 --stream`，逐行原样透传到 driver 自己的 **stderr**（sh `| tee "$log" >&2`；ps1 `| Tee-Object -FilePath $log | ForEach-Object { [Console]::Error.WriteLine($_) }`，`$log` = `.nulya/goal-last-step.jsonl`，每轮覆盖），**stdout 只剩控制行**；结束信号从 grep `"calls":[]` 换成协议自己的 `"stopped":"end_turn"`，`"stream":"run","event":"error"` 显式 `exit 1`（管道左侧的失败 `set -e` / `$ErrorActionPreference` 都看不见）。行数 67 / 70（≤ 70）。**手测发现并修掉一个真 bug**：PowerShell 5.1 用控制台代码页解码 native 命令的 stdout、再按同一编码写出去，于是模型产出的每个非 ASCII 字节到达 spawner 时都被毁掉（em dash `e2 80 94` → `e2 80 3f`）——加一行 `[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)`，实测两平台 stderr 里的 em dash 都是 `e2 80 94`。（`Tee-Object -FilePath` 在 5.1 无 `-Encoding`，所以 `$log` 落盘是 UTF-16LE；它只被 driver 自己读回，不是交付物。）
- **M2c-e** `0eeee3f` — 四条 e2e 全绿（`tests/e2e/extension.zig` 三条 + `tests/e2e/session.zig` 一条），无 `NULYA_TEST_ZIG` / `NULYA_REPO` / `NULYA_EXE` 时 skip。driver 那条跑真实脚本（按平台选 ps1/sh），并按 §1.4b 加了两条断言：driver stdout **没有**以 `{` 开头的行；stderr 含 `"stream":"model"` 与 `"stream":"run"`。driver 的 spawn env 显式设 `NULYA_HOME` 指向测试 home，否则第一次 `ext build` 的信任记录会写进开发者真实的 `~/.nulya`。既有 e2e 断言一条未减。`tests/e2e.zig` 头注释同步（属 M2c-f）。
- **M2c-f** `fbd2de0` — DESIGN §11 加了一整段 handoff（bundled `extensions/handoff` + `brief_file` 分支 + 父指针 footer + `drivers/goal.*` 是第一个 driver 与 `--pin` 的第一个 consumer + 两个流两个受众，明说内核零改动）；§13 四档 scripted（M2c-c 时已改）；§14 核对：**无 CLI 变化**（`--pin` / `--with` / `--stream` / `--parent` 都是既有条目，一条没动）。PLAN：§1 M2c 标 ✅ 并把 D1/D3/D4 写成"落地时改了三处措辞"；§3.2 的"尚未落地"删掉 `--pin`；§3.4 "仍未做"删 handoff 一条；§3.4.1 / §3.6 标 ✅（设计文字保留，"待做"改成落地形状与差异）；§4 handoff 守卫阈值改成"第一版 driver 故意没做，等真实使用证据"。CLAUDE.md 现状加一条 M2c、「还没有」删 handoff / `/goal`、模块表 `launch.zig` 补第四档。tui.md：§9 加 T10 行、§10.4 的 `<id>.live` sidecar 划掉（driver 的 stderr 就是它）、§11 追加 T10 占位小节。

### 步骤 7 · 真实运行（deepseek，两阶段，2026-08-17）

**先说一处没做的事：仓库根目录跑不了，我没有代为解除。** 在 `C:\code\zig\nulya` 直接跑 `drivers/goal.ps1`，`session new` 被 **workspace store 的 trust gate**（DESIGN §9）硬拒：

```
the extension store C:\code\zig\nulya\.nulya\extensions came with this checkout and is not trusted on this machine; it holds:
  compact (3 built version(s), none active) / demo / evolution / handoff (1 built version(s), none active)
review it (`nulya ext list`, `nulya ext inspect <id>`), then `nulya ext trust` to allow it — or delete the store
session new failed: the workspace extension store is not trusted (see the lines above)
```

这是门在正常工作（那些版本是更早建的，`~/.nulya/trusted-stores.jsonl` 里没有本机记录）。解法是 `nulya ext trust`——**一次授权，写进 user 层**，既超出本步"只往 `.nulya/` 写"的范围，也是该由人按下的那个按钮，所以我没有替你按。**改为在 `.nulya/scratch/m2c-run/`（空 store → `ext build` 出生即可信）跑，仓库只被读**。要在仓库根目录跑，先自己 `./zig-out/bin/nulya.exe ext trust`。

**driver stdout（exit 0，`--profile deepseek --max-iterations 12`）：**

```
session s-1786972293255-fd097b
handoff s-1786972293255-fd097b -> s-1786972304901-31c619
done s-1786972304901-31c619
evaluate: …/nulya.exe session outcome s-1786972304901-31c619 <success|partial|failure>
```

stdout 里以 `{` 开头的行 **0** 条；stderr 里 `"stream":"model"` **1929** 行（含 `thinking_delta`，DeepSeek 的 reasoning 实时可见）、`"stream":"run"` 5 行。两个流的分工在真实 provider 上成立。

**父 session（`s-…fd097b`）**：header `composition` = `{active:[handoff@v-3e81022b2a3612cf7c804217], native_tools:["ext:handoff/handoff"]}`；5 条事件——`user_text`（前言+目标）→ `assistant[shell]` → `tool_results`（读到 `docs/base-tools.md`）→ `assistant[handoff]` → `tool_results`（`{"recorded":".nulya/handoffs/…-1.md",…}`），**之后再没长过**。

**生成的 handoff 文件**（`.nulya/handoffs/s-1786972293255-fd097b-1.md`，节选——`## Keep` 是模型自己从文档里抽的，不是模板）：

```markdown
# Handoff

session: s-1786972293255-fd097b

## Done

Phase 1 complete. Read C:/code/zig/nulya/docs/base-tools.md (a spec in Chinese for Nulya's base
tools) and extracted the output discipline that the built-in shell tool follows. No files were
written in this phase.

## Next task

Phase 2: write AT MOST 10 lines to the file base-tools-note.md in your working directory …

## Keep

The shell tool's output discipline (from §2/§3 of docs/base-tools.md):
- ALL tool output passes through one unified primitive `emit` … 1. Per-line clip: any line >
  MAX_LINE_BYTES (16384) is truncated at a UTF-8 boundary with `…[+N bytes]` … 2. Whole-output
  hard budget (128 KB, head/tail 25/75) … 3. Auto spill-to-disk … footer `[full output: <path>]`
  … 4. Spill filenames are deterministic and collision-free …
- Batch layer: StepOutputBudget caps a whole turn of N tool calls at max_step_bytes (256 KB) …

## Dropped

The document's editorial background (comparisons to the tcode project, accretion criticism,
design rationales, table of constants, future hardening items …).
```

**子 session（`s-…31c619`）**：header `parent = {"session":"s-1786972293255-fd097b","seq":5}`、`composition` 为空（fork 不继承 `--with`/`--pin`，DESIGN §11 第 3 条）。首条 turn 就是上面那份 brief，前面 `<nulya:context-summary>`、末尾是代码追加的父指针：

```
---
Parent session: s-1786972293255-fd097b (forked at seq 5). The full transcript is still on disk — read it with: nulya session events s-1786972293255-fd097b
```

子 session 只凭这条 brief（**没有**父的任何 transcript）跑完了阶段 2：`shell` 看一眼工作目录 → 写 `base-tools-note.md` → end_turn。产出（4 行，模型自己压到 10 行以内）：

```markdown
# Shell output discipline vs. naive "return everything"

- Shell output passes through a unified `emit` primitive: per-line byte ceiling (16384) with
  UTF-8-safe truncation + `…[+N bytes]`, and a whole-output budget (128 KB) that keeps head/tail
  (25/75) and cuts the middle with a marker.
- Any truncation auto-spills the FULL raw output to scratch/tool-output/ (content-hashed,
  deterministic filename) and appends a `[full output: <path>]` footer — the model never loses
  data and never predicts sizes.
- Batch layer caps a whole turn at 256 KB, spilling overflow with prefix + footer; short results
  pass verbatim; exit code, stderr, and timeout-partial markers ride along.
- A naive tool returns everything verbatim: no byte ceiling, no budget, no spill. One oversized
  result can blow the context window, silently dropping data or forcing the model to guess —
  exactly the data loss and unpredictability the discipline exists to prevent.
```

运行现场保留在 `.nulya/scratch/m2c-run/`（`out.txt` / `err.txt` / 两个 session 文件 / handoff 文件 / 产出）。

### 后续（不做，记下来）

- 仓库根目录的 store 需要一次 `nulya ext trust` 才能跑 driver / TUI——这是门的正常行为，但每个新 clone 都会撞一次；`ext trust` 的提示已经指路，暂不动。
- TUI 的 `/goal`（tui.md T10）：内核与 driver 都就绪，前端未开工。
- handoff 的 driver 守卫（context 太小时忽略提议、brief 太短退回 `/compact`）：PLAN §3.4.1 列着，等真实使用证据。
- ~~driver 每步的流日志 `.nulya/goal-last-step.jsonl` 是全局单文件，两个 goal 并发会互踩。~~ 已改（合并后在 main 上顺手改的）：`.nulya/scratch/goal-<root session id>.jsonl`——按这次 goal 的根 session 命名，handoff 换 id 后文件不变，两个 goal 各写各的；两份脚本仍 67 / 70 行、离线 `handoff` 档实跑两平台都通。
