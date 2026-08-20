# Goal · M6a：usage fact 加可空 `version`（M6 Phase A 的 evidence 半边，只写不读）

> 这是一份**执行契约**，不是设计文档。设计背景在 [PLAN.md](../PLAN.md) §3.5（双身份、version-aware evidence）、[DESIGN.md](../DESIGN.md) §5.5（usage journal 的角色）；journal 的既有纪律在 `src/journals/tool_stats.zig` 模块头注释与 `journals/journal.zig`。地图和 physics 在 [CLAUDE.md](../../CLAUDE.md)。
> **每次 compaction 后先重读本文件**，尤其是 §6 进度区。
> 本文件的决策来自 2026-08-20 的评审对话，已定的不要重开；认为错了就写进 §6 BLOCKED 并停下，不要自行改方向。
> **前置：从 `main` 切分支 `m6a`。**

## 0. 目标（一句话）

usage journal 的每条 fact 从今天起**多记一列可空 `version`**——这个 call 执行时用的是哪个冻结的 extension 实现版本——因为 evidence 是 append-only 的、补不了课：今天不记，将来做 rollback 判断时这段历史永远是 unknown。**只写不读**：不做任何投影、不加任何读者，`aggregate` 名字与语义原样（继续按 stable `tool_id` 聚合全部历史）。这是 PLAN §3.5.2（Phase A）的 fact 半边；投影半边（`VersionStats`）等第一个 consumer。

## 1. 范围

**做（按顺序，每步测试全绿再进下一步；每个子项一个 commit `m6a-x: …`）：**

1. **m6a-a · `tool_stats.zig` 加可空 `version` 列。** `Append` / `UseEvent` / `WireEvent` 各加 `version: ?[]const u8 = null`；`encodeEvent` 只在非 null 时写这一列（与 `session` / `duration_ms` 同一条纪律），落在 `tool_id` 之后、`ok` 之前（固定列序由 encode 那条单测钉死）；`dupeEvent` / `freeEvent` 跟上。**`v` 仍是 1**（理由见 D2）。单测：roundtrip 保 `version`；固定列序含/不含 `version` 两种形状；老行（无此列）读回 `version == null`；`aggregate` 行为一字不变（不需要新断言，跑过即可）。
2. **m6a-b · session 写点带 version。** `session.zig` 的 `recordCompletedToolStats`：每个完成的 call，若 `t.definition.id` 是 `ext:<id>/<tool>` 形状，就从 `self.composition.extensions`（`[]const FrozenExtension{id, version}`，`composition.zig:106`）按 `<id>` 反查冻结版本写进 `version`；builtin（`builtin.shell`）与反查不到成员的 call（理论上不发生——有 binding 必是成员；发生了就写 null，不是错误）不写。**不给 `Binding` 加 version 字段**：版本是冻结成员关系的属性，唯一真相在 composition 的 frozen 列表里，写点正好拿着 `self.composition`，一处反查即可（D4）。测试：session 同文件已有 stats 相关测试扩断言，或新加一条内存 session 的单测——pinned ext tool 的行带正确 `version`、shell 的行没有。
3. **m6a-c · `ext run` 写点带 version。** `cli/ext.zig` 的 `extRun`（`tool_stats.append` 调用点约 :1014）：resolution 已经解析出了具体版本目录（点名 `@<version>` 或 `current`），把那个 `v-<hash>` 写进 `version`。e2e：`tests/e2e/extension.zig` 既有 usage 断言处扩——`ext run` 后 journal 行的 `version` 等于 activate 的那个版本；`tests/e2e/manufacture.zig` 的 native-pin 路同样断言；builtin `shell` 产生的行断言 `version == null`；再补一条"手写一条老格式行（无 `version`）+ 新 append 一条 → `readAll` 两条都对、老行 `version == null`"（可放单测，e2e 不必重复）。
4. **m6a-d · 文档。** DESIGN §5.5（usage journal 那节）：`version` 列的语义（"这个 call 由哪个冻结实现版本服务；null = builtin 或该行早于此列 = unknown ≠ 没有版本"）+ 为什么仍是 v1；PLAN §1 的 M6 条目把 Phase A 标成 ✅（B–E 原样留着）并注明 fact/投影拆开、投影等 consumer；PLAN §3.5.2 的 `（v:2）` 改成与落地一致的"v1 加可选列"（学 M5 的样：注明是相对原计划的修正与理由）；CLAUDE.md 模块表 `journals/tool_stats.zig` 那一行 + 现状区 usage journal 那句；本文件 §6 进度区。model-facing 文本本轮**不该有任何改动**（journal 没有 model-facing 面）——如果发现需要改，停下写 BLOCKED。

**不做（明确越界）：**

- `VersionStats` / `LogicalToolStats` 投影（PLAN 把它归在 Phase A，这里**刻意拆出去**：投影等第一个 consumer，"第二个 consumer 出现之前不抽 abstraction"）；`aggregate` 不改。
- M6 的 B–E（`VersionCreatedFact` / Verify / `ext test` / `EvaluationEvidence` / policy 比较）。
- journal `v` 升 2（见 D2）。
- 给 `Binding` / `ToolDefinition` / ledger / prompt / loop 加 version 字段——ledger 与 PromptIR 一个字节都不动（version 是 journal 的列，不是 ledger 事件的字段）。
- outcome journal / trust journal 的任何改动。
- TUI 改动：`tui/src/nulya/files.ts` 的读端是 `JSON.parse` 按字段取值，天然容忍新列且 `v` 仍是 1，**零改动**；`/usage` 面板显示 version 等真实需要。改了 `tui/` 就是越界。
- 对既有 e2e / 单测的顺手重构；push。

## 2. 完成标准（可机器验证；全部满足才算完成）

- `zig build test` 与 `zig build e2e` 在 **Windows（本机）** 全绿；代码不得 Windows-only。
- 老行兼容有测试钉死：无 `version` 的 v1 行读回 `version == null`；带未知列的 v1 行仍被忽略地读过（既有测试不减弱）。
- 写端形状有测试钉死：`encodeEvent` 固定列序两种形状；session 路（pinned ext tool 带 version、builtin 不带）与 `ext run` 路（version == activate 的版本）各有断言。
- 既有测试全部继续通过，断言不减弱；`tui/` 零 diff。
- 文档四处（DESIGN §5.5、PLAN §1 + §3.5.2、CLAUDE.md）与代码同 commit 或紧随的 `docs:` commit。
- 每个子项一个或多个 commit，信息格式 `m6a-a: …` … `docs: …`；在分支 `m6a` 上；**不 push**。

## 3. 已定决策（不要重开；如认为错了，写进 §6 BLOCKED 并停下）

- **D1 · 列名 `version`，值是冻结实现版本 id（`v-<hash>`），可空。** null 的含义随行龄不同但都诚实：老行 = 过去没记（unknown）；新行 = 这个 call 没有实现版本（builtin）。两者都不是 0、不是 ""。
- **D2 · 仍是 `v:1`，不升 v2——这是相对 PLAN §3.5.2 字面（`v:2`）的一处已定修正。** journal 的既有纪律是"加可选列、reader 忽略未知字段、老 reader 不坏"（`at` / `session` / `duration_ms` 三个先例都是这么进来的，模块头注释写明"a newer writer at the same `v` never breaks an older reader"）；升 v2 会让所有老读者（老二进制、TUI 的 `files.ts`）对新行报 `UnsupportedStatsVersion`，零收益。`v` 留给真正的格式断裂。PLAN 文字同步改（m6a-d）。
- **D3 · 只写 fact，不做投影。** `VersionStats` 从 Phase A 拆出去等第一个 consumer；本轮内核（与 TUI）新增读者数为零。
- **D4 · version 的唯一真相是 composition 的 frozen 成员列表。** session 写点从 `FrozenExtension` 反查，不把 version 复制进 `Binding`（一个 fact 两处存放是该收的信号）；`ext run` 写点用它自己刚解析出的版本。两个写点、零新 plumbing。
- **D5 · core 语义零改动。** 本轮动的只有 `journals/tool_stats.zig`、`session.zig` 的 `recordCompletedToolStats`、`cli/ext.zig` 的 `extRun` 三处；需要动 `ledger` / `prompt` / `loop` / `composition` / `store` 的语义才能落地 → BLOCKED。
- **D6 · model-facing 文本零文档引用**（沿用各 goal 的 D8）；本轮预期 model-facing 文本零改动。

## 4. 参考（先读这些，再动手）

- `src/journals/tool_stats.zig` 全文（模块头注释是这份 journal 的宪法；`encodeEvent` 的列序测试、"a line written before the added columns reads back with them absent" 是要照着扩的两条）；`src/journals/journal.zig`（文件层，不动）。
- `src/session.zig:409`（`recordCompletedToolStats`——写点一；`self.composition` 在手）；`src/composition.zig:106`（`FrozenExtension{id, version}`）与 `:176`（`extensions` 列表）。
- `src/cli/ext.zig:1002-1018`（`extRun` 的 stats append——写点二；上文 resolution 已有具体版本）。
- `tests/e2e/extension.zig` / `tests/e2e/manufacture.zig` 里现有的 `tool_stats.readAll` 断言（扩它们，别新起炉灶）；`tests/e2e/support.zig`。
- PLAN §3.5.1–3.5.2（双身份、identity rule——`tool_id` 仍然永不带版本，version 是旁边一列）；DESIGN §5.5；CLAUDE.md 模块表 `journals/tool_stats.zig` 行。
- 本仓库 `nulya` 不在 PATH 上：`./zig-out/bin/nulya.exe`（`zig build` 后）。Zig 0.16（新 `std.Io`）。

## 5. 工作方式

- 分支 `m6a`（从 `main` 切）。每个子项完成：`zig build test` + `zig build e2e` 全绿 → commit。
- 代码注释英文，docs 中文；测试与模块同文件；`zig fmt`（只 fmt 自己改的文件）。
- 每完成一个子项，在 §6 记一行（commit hash + 一句话 + 有无偏离）。
- 卡住 / 需要改 core / 发现契约自相矛盾 → §6 写 `BLOCKED: …`，停下等人，不要绕。

## 6. 进度区（执行时更新）

分支 `m6a`（从 `main` = `164a1b7` 切）。未 push。

- `9c7b88a` · docs: M6a 执行契约（本文件进分支）。无偏离。
- `89fbcb7` · **m6a-a**：`tool_stats.zig` 的 `Append`/`UseEvent`/`WireEvent` 各加 `version: ?[]const u8 = null`，`encodeEvent` 只在非 null 时写、列位在 `tool_id` 之后 `ok` 之前，`dupeEvent`/`freeEvent` 跟上；`v` 仍是 1（D2）。单测：roundtrip 保 `version`、固定列序两种形状（带 / 不带）、老行读回 null。无偏离。
- `3673674` · **m6a-b**：`session.recordCompletedToolStats` 每条 fact 带 `version`，由新的私有 `AgentSession.frozenVersionOf` 从 `self.composition.extensions` 反查（`Binding` 未加字段，D4）；builtin 与反查不到写 null。已有的 "completed step records stable ids…" 单测扩成三个 call（ext / builtin / 幻觉名）并断言 `v-frozen` 与 builtin 的 null，测试名相应加长。无偏离。
- `e58c271` · **m6a-c**：`cli/ext.zig` 的 `extRun` 用 `resolved.version`（同一次解析，第二处不可能不一致）。e2e：`extension.zig` 的 `ext run` 那条跨 v1/v2 断言"一个 `tool_id`、两个 `version`"，失败调用那条也断言版本；`manufacture.zig` 断言 `ext:demo/greet` 行 == 模型自己 build 的版本、`builtin.shell` 行 `version == null`。单测补一条"老行 + 新行同处一册且 `aggregate` 不变"。**一处顺手**：`zig fmt` 把 `cli/ext.zig` 里一张与本轮无关的错误表重排了，已手工还原，最终 diff 只有那 5 行。
- **文档（m6a-d）**：DESIGN §5.5（列的语义 + 双身份 + 两个写点 + 为什么仍是 v1 + 只写不读）与 §3 表格那一行的 shape；PLAN §1 的 M6 条目（Phase A ✅、注明 fact/投影拆开与 v1 修正）与 §3.5.2（加一段"相对本节原文的两处修正"）；CLAUDE.md 模块表 `journals/tool_stats.zig` 行 + 现状区新增一条。model-facing 文本零改动（如契约所料）。

**测试**：`zig build test` 全绿。`zig build e2e` = **71 pass / 1 fail**，唯一那条失败是 `e2e.extension` 的 `bundled agent: a follow-up resumes the same delegated session …`（`expected 1, found 0`，数 `task_finished` 的时序断言）——**本轮开工前在干净的 `main` 上验过，同一条、同一处先已失败**，与 usage journal 无关（本轮四个子项每一步都复跑过，失败集合始终是这一条，未新增）。
**后记（合并时排查）**：实际失败断言是 ⑤ 的 `refused.code`（`extension.zig:2663`）而非 `task_finished` 计数；根因是 Windows 嵌套 spawn 链的句柄继承让委派的回执阻塞到子 agent 跑完（实测 15.5 s ≈ 任务全程），"还在跑就拒绝"那道门到场时任务已 `done`。已在 main 上修（supervisor 启动清扫杂散 pipe 句柄 + `runnerRunning` 补 `starting` 窗口，DESIGN §8/§14），与本契约无关。

**BLOCKED**：无。越界项一个未碰：`tui/` 零 diff；`ledger` / `prompt` / `loop` / `composition` / `store` 未改；`aggregate` 未改；无 `VersionStats` 投影；M6 B–E 未做。
