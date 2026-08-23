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

（待开始）

### Lane W

（待开始）

### Lane R

（待开始）
