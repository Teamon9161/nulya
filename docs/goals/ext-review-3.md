# Goal · ext-review-3：一种 wire + 两轮评审的收尾（2026-08-23 拍板）

> 这是一份**执行契约**（2026-08-23 拍板）：§1–§3 的决策已定，不要重开；认为错了就写进 §6 自己那一节的 `BLOCKED:` 并停下。按 [ext-review-2.md](ext-review-2.md) 同一套方式跑（契约 → lane → 审 diff → 合并）。**S 在 worktree 里与 W 并行，两者文件不重叠；R 在两者合并之后跑。**地图与 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §7。
> 来源：2026-08-23 两轮 extension 评审（[ext-review.md](ext-review.md)、[ext-review-2.md](ext-review-2.md)）落地后剩下的三件事。

## 0. 为什么还有一批

ext-review-2 把概念收成了：`activate` 一个意思、成员 × 工具面的 2×2、manifest 三层各说一次、`ext init` 缺省 plain。**还剩的不是概念，是两套并存的东西**：

1. **两种 wire 并存**。`plain` 今天已经能服务每一个 consumer（模型面、`ext run`、TUI 解析 JSON 的 driver tool、错误文本），但六个自带编译包仍说 `jsonrpc`，于是仓库里同时活着两份契约、三份互相复制的 `rpc.zig`（`std` 217 行 / `agent` 156 / `plan` 140）与三处内联信封（`handoff` / `compact` / `ask`）、内核里 `protocol.zig`（313 行）+ `invoke.invokeJsonRpc` 一整条路。一个要写扩展的 AI 打开 `nulya ext api protocol` 看到的是两节，而它只需要一节。
2. **三轮 lane 各自改过 model-facing 文本**（`nulya help` / `ext api` 三个 topic / guide `SKILL.md` / kernel prompt），没有人从头到尾读过一遍——漂移最容易藏在这里。
3. 几件小的：测试 scratch 目录不清理、一个撞名的 state 键、两处残句。

## 1. Lane W · 一种 wire（opus）

### 1.1 什么叫"迁到 plain"

一个 tool 被调用时，进程边界上只有三样东西：stdin、stdout、退出码。两种 wire 的区别只是这三样东西里装什么：

```
                jsonrpc（今天自带包用的）                       plain（今天 ext init 缺省的）
stdin   {"jsonrpc":"2.0","id":"call","method":"tool/call",     {"path":"a.txt"}            ← 参数对象本身
         "params":{"name":"read","arguments":{"path":"a.txt"}}}  env: NULYA_TOOL=read        ← tool 名在 env
stdout  {"jsonrpc":"2.0","id":"call","result":"<文件内容>"}       <文件内容>                   ← 原文就是结果
失败    {"jsonrpc":"2.0","id":"call","error":{"code":-32602,     stderr: missing `path`      ← 消息写 stderr
         "message":"missing `path`"}}                            exit 1                      ← 退出码就是成败
```

模型最终看到的字节**一样**：成功是结果原文，失败是一句话（今天是 `extension error [-32602]: missing \`path\``，plain 是 `exit 1` + 那句话）。`ext run` 打印的也一样（driver tool 打 JSON 到 stdout，TUI 照样 `JSON.parse`）。所以"迁"= 每个包删掉**读信封、回 id、拼信封**那一半代码，manifest 加一行 `"wire": "plain"`；tool 逻辑本身一个字不动。

### 1.2 为什么弃用 jsonrpc——不是复杂，是多余

- jsonrpc 比 plain **多**的三样东西今天都没有读者：`id`（oneshot 进程，每次只有一个请求，回显它只是仪式）、`error.code`（到模型那里只是一个数字）、`error.data.retryable`（内核从不读）。
- 它**少**的东西没有：plain 的 stdout 可以是 JSON（driver tool）、也可以是文本（模型面）。
- 留它的唯一理由是将来 persistent runtime / streaming 需要**分帧**——那是"先测量再做"的事（PLAN §3.3），到时候按实测需要设计一种帧，不必今天养着一种没人用其特性的。
- 代价是实打实的：AI 要读两份契约、`ext init --zig` 模板与自带包形状不一致（"示范代码"与"真实代码"两套）、内核多 ~300 行只为一种 wire、三份 `rpc.zig` 互相复制漂移。

**不弃用也行**——今天"两种 wire、plain 缺省"已经能用。但按"核心足够简单、方便 AI 了解和扩展"这把尺子，一种 wire 是终态。

### 1.3 已定决策

- **W1 · 六个自带编译包迁 plain**：`std` / `agent` / `plan` / `handoff` / `compact` / `ask`。每个包：`main` 读 stdin 为参数对象、按 `NULYA_TOOL` 分发（多 tool 的包）、结果写 stdout（文本或 JSON，与今天 `result` 的内容逐字节相同）、失败 = 消息写 stderr + `exit 1`；删 `rpc.zig` 的信封那一半（`readRequest` / `writeResponse` / id），`Outcome` 可以留作内部类型；manifest 加 `"wire": "plain"`。**退出码不做词表**（不区分 -32602 / -32000——消息本身已经说清，一个数字没有读者）。
- **W2 · e2e 断言**：`tests/e2e/std.zig:102`、`std_fs.zig:66`、`std_search.zig:218-225` 五处从 `extension error [-32000]: …` 改为 plain 的失败文本（`exit 1` + 消息）；其余自带包的 e2e 若有同类断言一并改。TUI 若有按前缀识别失败文本的地方（grep `extension error`）同步——今天 grep 为零。
- **W3 · jsonrpc 降级**：`protocol.zig` 顶部把 plain 写成**唯一推荐**、jsonrpc 标 `deprecated`（认一个版本期，给仓库外写的扩展）；`ext api protocol` 随之（它打的就是这个文件）；`ext api examples` 不再提 jsonrpc。**下一个版本**删 `protocol.zig` 的 `ToolCallRequest` / `decodeResponse`、`invoke.invokeJsonRpc`、`manifest.Wire.jsonrpc`——那一步单独一条 lane，等一个版本期过去。
- **W4 · 文档**：DESIGN §7.1 / §7.3（两种 wire → 一种 + 一段"jsonrpc 为什么退场"）、§7.8 表格的 kind 列、CLAUDE.md 现状段与模块表 `protocol.zig` / `invoke.zig` 行、guide `SKILL.md`、各包 `main.zig` 顶部"Why compiled Zig"那段（理由从"要解析 JSON-RPC"改成真正的理由：regex / walker / 解析 `session step` 的 JSONL）。
- **不做**：persistent runtime；streaming；改 `plain` 契约的任何字节。

## 2. Lane R · model-facing 文本一致性复读（sonnet，在 W 之后）

- **R1**：一个读者按模型会走的顺序从头读一遍——kernel prompt（`composition.zig` 常量）→ `nulya help` → `nulya ext api protocol` / `manifest` / `examples` → `extensions/guide/skills/guide/SKILL.md`——对照 DESIGN §5.1 / §7.1 / §7.2.1 / §14 **今天**的语义，列出每一处矛盾或过时（重点：`activation` / `permissions` / `policy.deny` 残留、`commands[].action` 对象形式、`ui` 按宿主、`--bare`、`[extensions] with`、`ext run` 形状、一种 wire），逐处修正。
- **R2**：`nulya help` 仍一屏（e2e 有行数预算）；model-facing 文本**零文档引用**的 e2e 仍绿。
- **R3**：同一遍也读 TUI 的 `/help` 文案与 `Welcome.tips`，对照 tui.md T48–T50。
- **R4**：DESIGN / CLAUDE.md / PLAN 里 grep `on_request` / `activation` / `permissions` / `PolicyAllowNotPermitted` / `jsonrpc`，历史叙述加一句"（已删，ext-review-2/3）"或删；`docs/goals/ext-review.md` 与 `ext-review-2.md` 是历史契约，不改。

## 3. Lane S · 小件（sonnet，最先做）

- **S1** · `tui/test/isolate.ts` 的 scratch `NULYA_HOME`（`mkdtempSync`）退出时 `rmSync(..., {recursive, force})`——今天 `%TEMP%` 里已堆 786 个 `nulya-*`。
- **S2** · `tui-state.json` 的 `session_with`（K8 新加，`/ext` 写的常驻清单）与 `tui.toml [extensions] session_with`（TUI 恒带的 `handoff` / `agent`，按精确版本）**撞名**。改 state 键为 `standing_with`，读旧名一个版本期；`tui_state.ts` 那段"Not to be confused with…"注释随之消失。
- **S3** · 残句：tui.md §7 提到已删的 `autoActivatable`（只动 tui.md——DESIGN / CLAUDE.md 的残留归 R4，免得与 W4 撞文件）。

## 4. 验收

```bash
zig build test
zig build e2e
zig build && cd tui && bun test && bun run typecheck
```

## 5. 顺序

**S ∥ W，然后 R**。S 只碰 `tui/` 与 tui.md，W 只碰 `extensions/`、`src/extension/{protocol,invoke}.zig`、`tests/e2e/`、DESIGN §7、CLAUDE.md、guide——不重叠，所以并行；R 放最后，对**最终**状态做一遍一致性复读，而不是对中间状态。

## 6. 进度（拍板后各 lane 在自己那节追加）

### Lane S

**完成**（sonnet，worktree，与 Lane W 并行）。三件小事，只碰 `tui/**` 与 `docs/tui.md`，内核零改动。

- **S1**：`tui/test/isolate.ts:22-33` — scratch `NULYA_HOME` 现在在 `process.on("exit", …)` 里 `rmSync(scratchHome, {recursive:true, force:true})`（`try/catch` 吞掉失败，best effort）。文件顶部解释隔离理由的注释未动。
- **S2**：`tui/src/state/tui_state.ts` 的 STATE 键 `session_with` 改名 `standing_with`（interface 字段 `:84`、`loadTuiState` 读两个键名一个版本期只写新名 `:131-143`、导出函数改名 `sessionWith`→`standingWithIds` / `rememberSessionWith`→`rememberStandingWith` `:194-201`，避开 `tui/src/extensions.ts` 的谓词 `standingWith`）；"Not to be confused with…" 澄清注释删除。调用点全部跟上：`tui/src/ui/overlays/ExtView.tsx`（import + 4 处调用 + 2 处注释）、`tui/src/ui/App.tsx`（import + 1 处调用）、`tui/test/overlays.test.tsx`（import + 2 处调用 + 1 处历史叙述性注释同步改名）、`tui/src/extensions.ts`（1 处注释）。`tui.toml` 的 `[extensions] session_with`（`state/settings.ts`）与它在 `pins.ts`/`handoff.ts`/`App.tsx`/`ExtView.tsx` 里的其余引用**一字未动**——grep 过每一处，确认是那个人写的设定而不是这个 state 键。`docs/tui.md` §11 里 K8/T1/T48/T50 历史日志对 state 那半的旧称呼也**没有**回填改名（与 `auto`→`unsafe` 那条同一先例：历史条目描述的是当时的名字）。
- **S3**：`docs/tui.md` §7 两处 `autoActivatable` 残留都改了——TOML 样例里 `auto_activate` 那行内联注释（原 `**带 system prompt 的包除外**，T31`，现在说 `activate 只是移指针，T50`）与它下面那段散文（重写：activate 今天只移 `current` 指针、不改变 composition；进不进 session 是 `/ext` Enter 的 standing pins / standing with 两半决定，对模式包 Enter 永不写 standing with，T48/T50）。§11 里其余 8 处 `autoActivatable` 提及全在历史日志段落（T34/T37/T41/T46/T48 等），描述的是它存在时的行为，按惯例不改。
- **旁及发现，未动**：同一段 TOML 样例里 `handoff = true` 那一行（`docs/tui.md:412`）与代码不符——T34 起 `[extensions] handoff` 已经是列表键 `session_with = ["handoff", "agent"]`，旧布尔键只在读的时候认（`withPackage`）。与 S3 认领的 `autoActivatable` 残留是两回事，超出这条任务的范围，留着给下一次经过这段文档的人（不是 Lane R 的 model-facing 文本复读范围，也不是 DESIGN/CLAUDE 残留）。

**验收**：`zig build`（首次 worktree，成功）；`cd tui && bun run typecheck`（干净）；`bun test` 全量 365 pass / 0 fail（一次跑干净，无超时）；针对改动最集中的四个文件（`overlays.test.tsx` `extensions.test.ts` `consumers.test.tsx` `pins.test.ts`）单独重跑时丢过一条无关的 lease 等待测试超时（`/sessions marks a session somebody else is driving as live`，与 `standing_with` 改名无关），单独重跑该测试即绿——`project-nulya-tui-test-gotchas.md` 记过的既有类别。

### Lane W

**W1 · 六个包迁 `plain`**（`zig build test` / `zig build e2e` 全绿）。每个包的 `main` 现在是同一形状：读 stdin 的参数对象 → 按 `NULYA_TOOL` 分发（单 tool 的包忽略它，因为它说不出新东西）→ 一个 `answer()` 把结果打 stdout + exit 0，或把消息打 stderr + exit 1。manifest 各加 `"wire": "plain"`。tool 逻辑一个字未动。

| 包 | 删掉的 | 行数 |
|---|---|---|
| `std` | `rpc.zig` 的 `readRequest` / `writeResponse` / `Request` / `fallback_id` / 三个码 / `Fail` / `invalidParams`；`main.zig` 的信封分发 | rpc 217 → 167，main 127 → 140（`std_options` 见下） |
| `agent` | 同上；`Outcome.json` 并进 `.text`；`failed()` 去掉 `code` 参数 | rpc 156 → 110，main 750 → 738 |
| `plan` | 同上 | rpc 140 → 94，main 277 → 268 |
| `handoff` | 内联信封（`writeResponse` / `call_id` / `Fail`）+ `readBrief` 里那两层 `params.arguments` | main 258 → 230 |
| `compact` | 同上 + `readArgs` 的两层 + `fail()` 的 `code` 参数 | main 566 → 537 |
| `ask` | 同上 + 整个 `arguments()` 辅助函数 | main 222 → 172 |

**退出码不做词表，落到了类型上。** 三个码删掉之后 `Fail{code, message}` 只剩一个 message，于是 `Outcome.failed` 直接是 `[]const u8`；`refuse` 与 `invalidParams` 变成同一个函数（都是"消息 + exit 1"），并成 `refuse`（`std` 的六个 tool 模块因此各有几处纯改名，是这条 lane 里唯一碰到 tool 逻辑文件的改动）；`agent` / `plan` 的 `Outcome.json` 与 `.text` 在 plain 上都只是"把这些字节打到 stdout"，并成 `.text`。**driver 面的字节没变**：`render` / `list` / `approve` / `compact` / `handoff` 照旧打同一个 compact JSON，`tui/src/nulya/cli.ts` 的 `JSON.parse` 与 `drivers/goal.*` 的 `grep -o '"session":"s-…'` 都不用动。

**一处新纪律，是迁移本身逼出来的：plain 上 stderr 就是失败消息，所以包必须独占 stderr。** `extensions/std` 里 vendored 的 mvzr 用 `std.log` 打了一行 `error(mvzr): missing closing parenthesis`，从前谁也看不见（jsonrpc 的 application error 分支不附 stderr），迁过来之后它挤在教学文案**上面**——一个库的调试行，出现在模型要照着改的那句话里。修法是 `extensions/std/src/main.zig` 声明一个空的 `std_options.logFn`：这个二进制没有第二种输出，refusal 该说什么已经逐句写好了。（`compact` 的 `warn()` 不受影响：它只在成功路径上说话，那时 stderr 照旧被丢弃。）

**W2 · e2e**：`std.zig:102` / `std_fs.zig:66` / `std_search.zig:218,222,225` 五处从 `extension error [-32000|-32602]: …` 改成 `exit 1\nstderr:\n` + 同一句文案（`invoke.invokePlain` 拼的形状），**每一句教学文案原样保留**；`extension.zig:3014,3037`（`plan propose {}` / `ask {}`）两处 `indexOf("-32602")` 改成 `startsWith("exit 1\nstderr:\n")`。`handoff` / `compact` 的 e2e 一个字没改——它们本来就 `JSON.parse` stdout。`tests/e2e.zig` 顶部那句"a string JSON-RPC `result`"随之改写。仓库里 `extension error [` 的最后一个写者只剩 `invoke.invokeJsonRpc`。

**W3 · jsonrpc 降级**：`protocol.zig` 模块注释重写——`plain` 在前、写成唯一要写的 wire（多一句"stderr 就是模型读到的消息"），jsonrpc 一节标 **DEPRECATED** 并写清它为什么退场（多的三样 `id` / `error.code` / `error.data.retryable` 一个读者都没有，少的东西没有，分帧留给真需要它的那天按用途设计）。`ext api manifest` 的 `runtime.wire` 一句、`ext api examples` 里那句"--zig scaffolds the JSON-RPC one"随之改；顺带把 `manifest.zig` 的 `Wire` 枚举文档（plain 在前、jsonrpc 标 deprecated）、`templates.zig` 顶部、`tools.zig` 那句"`definition.name` 是 JSON-RPC name"一起改准。**`ToolCallRequest` / `decodeResponse` / `invokeJsonRpc` / `Wire.jsonrpc` 一个都没删**，缺省仍读作 jsonrpc，e2e 里那些合成 fixture（`support.jsonrpc_main_zig` 等）照旧证明它能跑。

**W4 · 文档**：DESIGN §7.1（wire 段拆成"要写的只有 plain"+"jsonrpc 已 deprecated"两段）、§7.3（开头一句、plain 的 stdout 那行补一句 driver 面打 JSON、jsonrpc 小节标 DEPRECATED、末尾新增一段"为什么 jsonrpc 退场"）、§7.6（"只拿 JSON-RPC request" → "只拿这次调用的 arguments"）、§7.8（表前一句加"六个有 runtime 的都说 plain"；`agent` 的"`params.name` 分发" → "`NULYA_TOOL` 分发"）、§11（`compact` 的 `-32001`、`handoff` 的 `-32602` 与"要读 JSON-RPC 请求、回同一个 id"的理由）、§15.1 那张表一行、架构图一处；CLAUDE.md 加一条 ext-review-3 W 的现状 bullet + 改 `protocol.zig`/`invoke.zig` 那一行 + 两处旧叙述；`extensions/guide` 的 SKILL.md 那一条；`docs/goals/std.md` 的 D6（它是 `std` 的活契约，写着"错误 = JSON-RPC error … `-32602`/`-32000`"）。各包 `main.zig` 顶部的"Why compiled Zig"改成真正的理由——`std` 是 regex + gitignore walker + `edit` 的归一化回退，`agent` 是 `run` 要逐行读 `session step` 的 JSONL 并在管道上答 gate，`plan` / `handoff` / `ask` 是"把几个分节/选项当一组校验"，`compact` 本来写的就是"要解析 JSONL"、未动。

**没做 / 留给别人**：`tui/src/compact.ts:86` 与 `tui/src/nulya/cli.ts:790` 两处注释仍写着"the JSON-RPC error the CLI prints"——**行为没变**（非零退出、消息在 stdout），只是措辞过时了；本 lane 不碰 `tui/**`（Lane S 的地盘），留给 R 或 S 顺手改。`docs/goals/ext-review.md` / `ext-review-2.md` 是历史契约，未改。

### Lane R

（待开始）
