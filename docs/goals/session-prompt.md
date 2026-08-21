# Goal · session-prompt：`session new --prompt <file>`——header 冻结的 per-session system prompt，agent persona 去材料化

> 这是一份**执行契约**，不是设计文档。设计背景：[PLAN.md](../PLAN.md) §3.2（`--system-file` 被 `--with` 吸收的历史与 2026-08-21 的修正）、[DESIGN.md](../DESIGN.md) §3 / §5 / §14、tui.md §5.10（T32 材料化——本契约要拆掉的东西）。地图和 physics 在 [CLAUDE.md](../../CLAUDE.md)。
> **每次 compaction 后先重读本文件**，尤其是 §6 进度区。
> 本文件的决策来自 2026-08-21 的评审对话，已定的不要重开；认为错了就写进 §6 BLOCKED 并停下，不要自行改方向。
> **前置：见 §5 第一条——工作树里有与本契约无关的未提交改动，先 checkpoint。**

## 0. 目标（一句话）

`session new` 长一个可重复的 `--prompt <file>`：创建时读字节、**冻进 header**（`ledger.FrozenComposition`），resume 从 header 读回、**不经 store**。它是 PLAN §3.2 原始设计里被 `--with` 吸收掉的 `--system-file` 的正确形式（吸收对"制品"成立、对"参数"不成立——D2）。第一个 consumer 是 `extensions/agent`：persona 不再材料化成 `agent-<name>` data extension——`/ext` 的派生包污染从**源头**消失（不是被藏起来），且 persona session 的 resume 不再与 `ext prune` 耦合。

## 1. 范围

**做（按顺序，每步测试全绿再进下一步；每个子项一个或多个 commit `sp-x: …`）：**

1. **sp-a · ledger：header 冻结形状。** `FrozenComposition` 加 `prompts: []const InlinePrompt = &.{}`；`pub const InlinePrompt = struct { source: []const u8 = "", text: []const u8 = "" }`。header `v` **仍是 1**（D3）。单测：header roundtrip 保 `prompts`；老 header（无此字段）读回空 slice；newer-writer 容忍不减弱（`ledger.zig:1112` 的既有测试样式）。
2. **sp-b · composition：两条路。** `Options` 加 `prompts: []const ledger.InlinePrompt = &.{}`（fresh 路）；`buildSystemPrompts` 在 extension 块之后、`skills:catalog` 之前追加（D5），`source` 原样进 `SystemBlock.source`（D4）；`SessionComposition` 把 prompts 存进自己的 arena 供 header 写入；resume 路（frozen request）从 header 的 `prompts` 读、**不查 store**。单测：fresh 带两个 prompts 的块顺序（kernel → ext → inline 按 argv 序 → skills:catalog，`composition.zig:735` 的 catalog-last 不变量不动）；从含 prompts 的 header 重建出 byte-identical 的块。
3. **sp-c · CLI + help + 投影。** `cli/session.zig`：`session new --prompt <file>`（可重复，样式照 `--with`/`--pin` 的既有解析）；创建时读一次，缺文件 / 空文件 / 超 `prompt.max_system_prompt_bytes` → stderr 点名文件 + exit 1、**什么都不建**（D8，缺凭据硬失败的同一纪律）；`source` = basename 去扩展名。`nulya help` 的 session 块加一行。`session list --json` 的 composition 投影加 `prompts`（**只投 source 与字节数，不投正文**）。e2e：① `--prompt` 的场 PromptIR 含块且顺序对；② 跨进程 resume 的 system blocks byte-identical；③ 一个无成员、只有 `--prompt` 的场，把 store root 目录整个删掉后照样 resume（自证不经 store）。
4. **sp-d · extensions/agent 去材料化。** `materialize` 改名 **`render`**：定义正文 → `.nulya/scratch/agents/agent-<name>.md`（覆盖写；内容由定义决定，并发写同内容无害）+ 返回 driver 需要的整组 `session new` 参数（prompt 文件路径、派生 `--with` 列表、pins、model、max_steps、readonly）；pins 预验证（`main.zig:255+`）**原样保留**。`agent` tool 的 spawn 改 `--prompt <rendered>`，不再 `ext build`、不再 `--with agent-<name>@v`；四道门 / 追问形态 / readonly runner / 委派白名单 / depth 兜底全部不动——唯一改的是"冻结 header 必须戴着 `agent-*`"那道门与 `wornPersona`（`defs.zig:452`）：改读 header `composition.prompts[].source` 的 `agent-` 前缀（:481 的剥前缀逻辑原样搬）。`defs.writeDraft` 与 manifest 渲染删除。e2e `tests/e2e/extension.zig` bundled-agent 各条更新：子场 header `prompts` 含 `agent-explore`、members 不含 `agent-*`；**store 里不再新增 `agent-*` 包**（断言）。
5. **sp-e · TUI。** `tui/src/agents.ts` 的 materialize 调用点改调 `render` 并用返回参数拼 `session new --prompt …`；`tabs.ts` / `App.tsx` 跟随；凡 TS 侧从 composition members 的 `agent-` 前缀推 persona 的地方改读 `prompts` 投影；`/ext` 零改动（污染源头消失）。`bun test` **必须在 `tui/` 下跑**；`pwsh` 那条 plugin 测试本机恒红（fixture 要 powershell，干净 HEAD 同样红），不是你弄坏的。
6. **sp-f · 文档。** DESIGN §3（header 形状；"everything the model sees is a pure function of this header plus the appended events" 因 inline prompt 的字节真的住进 header 而**更真**）、§5（system blocks 三种来源：kernel / extension / inline）、§14（CLI 表 + `session list` 投影）；PLAN §3.2 修正段与落地对齐；CLAUDE.md（现状 T32 条目改写 + 模块表 `ledger.zig` / `composition.zig` 行）；tui.md §5.10 / §11 追记；本文件 §6。model-facing 文本改动**只有** agent 扩展自己的 tool 描述（render 取代 materialize），零文档引用（D9）。

**不做（明确越界）：**

- fork（`--parent`）**不继承** `--prompt`（D6）；compact / handoff 路径零改动。
- inline 文本 flag（只收文件路径）；`--with id#block` 包内选块；persona 的 store kind；任何新 config 键。
- `/ext` 显示逻辑；store 里既有 `agent-*` 包**原样留着**（D10——老 session 的 resume 冻在它们上面），不做清理 / 迁移动词。
- kernel prompt 一字不动（`kernel_hash` 不变）；`registry` / `loop` / `tool` / provider / journals 零改动。
- 对既有测试的顺手重构；push。

## 2. 完成标准（可机器验证；全部满足才算完成）

- `zig build test` 与 `zig build e2e` 在**本机（Linux）**全绿；`cd tui && bun test` 除已知恒红的 pwsh plugin 条外全绿，快照有意变更要在 §6 说明。
- resume byte-identical 有 e2e 钉死（含删 store root 那条自证）；老 header 兼容有单测钉死；既有测试断言不减弱。
- 委派产生的新 session：header `prompts` 带 persona、store 无新增 `agent-*` 版本（e2e 断言）。
- 文档与代码同 commit 或紧随的 `docs:` commit；每子项 commit `sp-x: …`；在分支 `session-prompt` 上；**不 push**。

## 3. 已定决策（不要重开；如认为错了，写进 §6 BLOCKED 并停下）

- **D1 · 冻字节，不冻引用。** per-session 内容的家是 session 文件（`ModelDescriptor` 先例；`ledger.zig:436` 那句设计意图）；store 是共享、可复用**制品**的家。冻路径会漂移；经 store 则 resume 与 prune 耦合——今天 `ext prune agent-explore` 会弄断冻在旧版 persona 上的场的 resume，本契约顺带修掉这个真问题。
- **D2 · 尺子：这段文本有没有独立于某一场 session 的生命周期。** 有（evolution / handoff / plan——装、激活、回滚有意义）→ extension；没有（persona 正文、将来任何 per-session brief）→ `--prompt`。PLAN §3.2 "被 `--with` 吸收"的论证只对前者成立。
- **D3 · header `v` 仍 1。** 可选字段纪律：老 header 读回空、unknown-field 容忍已有测试（`usage?` / `images` / `nulya` stamp 同一先例）。升 v 零收益。
- **D4 · kernel 不解释 `source`。** CLI 记 basename 去扩展名，composition 原样透传进 block source 与 header，不去重、不加前缀。`agent-<name>` 前缀是 agent 扩展**自己的**写 / 读约定（写者读者同一个包：render 写 `agent-<name>.md`，`wornPersona` 剥 `agent-` 前缀）。kernel 侧不得出现任何 `agent-` 字样。
- **D5 · 块顺序 kernel → extension → inline → skills:catalog。** inline 与成员贡献的 prompt 同是 identity 文本，故排在成员之后；skills catalog 保持最后（现有不变量）。
- **D6 · fork 不继承。** 与 `--with` 对称："composition 现解"让 fork 自然吸收当天的 pin 与版本，而 `--prompt` 是调用方的参数、fork 的发起者要就自己再传。
- **D7 · 写路径唯一实现保持。** `render` 是唯一渲染定义正文的地方（materialize 的继任者，同一个不变量换了输出形态）；TUI 的 TS 侧继续零 frontmatter 解析（T32 第三期）。
- **D8 · 创建失败什么都不建。** 与 `session new` 缺凭据同一纪律；上限复用 `prompt.max_system_prompt_bytes`，不新增常量与配置键。
- **D9 · model-facing 文本零文档引用**（沿例）；kernel prompt 与 builtin 定义零改动 → `kernel_hash` 不变。
- **D10 · 既有 `agent-*` store 包不清理。** 它们从此只是不再被新写；要消失是人工 prune / 删目录的事，不在本契约。

## 4. 参考（先读这些，再动手）

- `src/ledger.zig:389`（`FrozenComposition`）、`:440`（`Header`）、`:436`（"pure function of this header plus the appended events"）、`:1112`（newer-writer 容忍测试）。
- `src/composition.zig:104-142`（`Options` / `WithRef`）、`:255-292`（`Request` 两条路：fresh / frozen）、`:591-610`（`buildSystemPrompts`——今天唯一的 store 读点）、`:735`（catalog-last 不变量）。
- `src/prompt.zig:13`（`max_system_prompt_bytes`）、`:95`（`SystemPromptSnapshot`）。
- `src/cli/session.zig:132-170`（`--with` / `--pin` 可重复 flag 的解析样式）；缺凭据硬失败那段（报错纪律样板）。
- `extensions/agent/src/main.zig:106-171`（materialize——要改成 render 的）、`:255-300`（pins 预验证——保留）、`:524-560`（spawn 的 `session new` argv——改传 `--prompt` 的地方）；`extensions/agent/src/defs.zig:385-484`（`writeDraft` / `draftPath` / `wornPersona`）。
- `tests/e2e/extension.zig`（bundled-agent 各条，扩它们别新起炉灶）；`tui/src/agents.ts`、`tui/src/state/tabs.ts`、`tui/src/ui/App.tsx`。
- 本机 Linux，Zig 0.16（新 `std.Io`）；二进制 `./zig-out/bin/nulya`；`bun test` 必须 `cd tui/`。

## 5. 工作方式

- **开工第一步**：工作树带着与本契约无关的未提交改动（tui T43 等）。切分支 `session-prompt`，第一个 commit 把它们**原样落盘**（`checkpoint: pre-existing uncommitted work（与 session-prompt 无关）`——不 review、不修改、不混入自己的改动），此后每子项一个 commit。**不 push。**
- 代码注释英文，docs 中文；测试与模块同文件；`zig fmt` 只 fmt 自己改的文件。
- 每完成一个子项，在 §6 记一行（commit hash + 一句话 + 有无偏离）。
- 卡住 / 需要越界 / 发现契约自相矛盾 → §6 写 `BLOCKED: …`，停下等人，不要绕。

## 6. 进度区（执行时更新）

- **checkpoint** `5921c05` — 工作树里与本契约无关的未提交改动（tui T43 等）原样落盘；本文件（未跟踪）一并进这个 commit。
- **sp-a** `b6763ea` — `ledger.InlinePrompt` + `FrozenComposition.prompts`（默认空 slice，header `v` 仍 1）；roundtrip 测试带 prompts、老 header 读回空。无偏离。
- **sp-b** `04f8343` — `composition.Options.prompts` + `Resolved.prompts`（arena 拷贝）+ `SessionComposition.prompts`（给 header 写入）；`buildSystemPrompts` 在 ext 块之后 / catalog 之前追加；`session.createDurable` 把它写进 header。两条单测：块顺序 + 从 header 用**不存在的 store root** 重建。无偏离。
- **sp-c** `<pending>` — `session new --prompt <file>`（可重复；创建时读字节、`source` = 文件 stem、缺文件/空文件/超 2 MiB → stderr 点名 + exit 1 且**什么都不建**）；`nulya help` session 块改写（仍 51 行，e2e 的一屏预算不动，needle 表加 `--prompt`）；`session list --json` composition 多一列 `prompts`（只有 source 与字节数）。新 e2e 一条覆盖：块顺序 · 跨进程 resume byte-identical · 删掉整个 store root 后照样 resume · fork 不继承 · 两种拒绝 · 投影不泄正文。无偏离。
