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
| [docs/PLAN.md](docs/PLAN.md) | **计划**：方向修正、路线图、尚未实现的设计（演化层、session CLI、driver、慢速回路） | 讨论方向 / 做新功能前 |
| [docs/base-tools.md](docs/base-tools.md) | shell / edit / `emit` 的输出纪律（已实现，含"later hardening"标注） | 改 `tools/` 或 `emit.zig` 时 |
| [docs/agents-and-review.md](docs/agents-and-review.md) | subagent 原语 + 审阅门设计——**全部未实现**，归属 PLAN | 做 subagent 时 |
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

- **已跑通**（`tests/e2e.zig` 真实二进制全环）：durable ledger 文件（header 冻结 composition + `seq` JSONL）→ PromptIR → 一次 step（批量 tool call、**一条** tool_results 回传、串行执行、可取消）→ shell / edit → `nulya ext init|build|activate|run|rollback` → usage journal → 下一场 session 边界自动晋升为 native 工具并按冻结版本执行；`createDurable/openDurable` 让 session 落盘、任意进程 resume 出块级相等的 PromptIR、跨进程 capability-note 经 inbox 在 step 边界排干。
- **也跑通**：`nulya session new|append|step|events|cancel|close`（`step --max-steps` 由 kernel 强制；stdout 事件 JSONL；cancel 标记在 step 边界消化）；bare `nulya` demo 现走 durable session 路径；**脚本 extension**（`runtime.entry` 前缀区分 `bin/` 编译 vs `src/` 脚本 + `interpreter?`；脚本不编译、version 不含 compiler；`ext init --script` / `ext run --arg k=v`）。
- **还没有**：fork / compaction（header 有 `parent` 字段但流程未接）；交互式前端 / TUI；subagent（= session 自调用，缺第一个 consumer）；policy hook（config 能解析 `policy.hook`，无人消费）；sandbox / remote environment；Anthropic provider（只有 OpenAI `chat/completions`）；`session new` 的 `--system-file/--skill/--pin`、`--budget-tokens`；persistent extension runtime。这些的去向都在 PLAN.md。

## 模块表（`src/`，扣掉同文件测试约 6k 行）

| 文件 | 职责 | 关键不变量 / 备注 |
|---|---|---|
| `main.zig` | 入口：有参数 → `cli.dispatch`；无参数 → 固定 prompt demo | 组装 config → env → provider → promotion → `AgentSession` |
| `ledger.zig` | 4 种事件（`user_text` / `assistant{text,calls}` / `tool_results[]` / `capability_note`），deep-copy 所有权 | 唯一写口 `append`；`init` 纯内存 / `createDurable`+`openDurable` 落盘（header + `seq` JSONL，一文件=一 generation） |
| `prompt.zig` | `Ledger → PromptIR{system_blocks, stable_blocks}` 纯投影 | `isStablePrefix` 是缓存不变量的可测形式；generation == 文件（`currentGeneration` 已删） |
| `loop.zig` | 一次 step：freeze snapshot → model.step → 串行执行 batch → 一条 tool_results | 取消时补齐整批（三种 marker）；`completeInterruptedToolBatch` 修复上次残尾 |
| `session.zig` | `AgentSession`：ledger 生命周期（`init` 内存 / `createDurable`+`openDurable` 落盘，resume 时 composition 从 header 冻结重建）+ 每步前排干 inbox + usage 记账 | `prepareStep` 补齐残尾后排干 `<id>.inbox`（durable session 才有） |
| `composition.zig` | session 开始冻结 tools / skills / system prompts / pinned 版本 | pin = 硬失败；auto = 跳过；`max_tools` 含 builtin |
| `registry.zig` | `ToolSetSnapshot`：builtin 固定最前，extras 按稳定 id 排序，name/id 唯一 | |
| `tool.zig` | `ToolExecutor{ptr,vtable}` / `ToolDefinition{id,name,description,input_schema}` / `ToolContext{environment,fs,cwd}` | tool 拿不到 ledger；extension 子进程只拿 request + 净化 env + cwd |
| `tools/shell.zig` `tools/edit.zig` | 两个永久 builtin | schema 恒定；`edit` = 精确匹配事务 |
| `emit.zig` | 统一输出原语：head/tail 字节预算、UTF-8 边界、超限落盘留指针 | 落盘路径确定性（按 ledger seq）以保 replay 一致 |
| `environment.zig` | `Environment{runShell, runExtension, dialect}`；`LocalEnvironment` | 子进程 env 走 `isSecretKey` denylist 净化 |
| `provider.zig` `providers/openai.zig` | `Model{ptr,vtable{stream}}` + `TurnCollector`；OpenAI chat/completions，读 `cached_tokens` | |
| `config.zig` + `default.toml` | `default → system → user → project` 合并；project 层过 `mergeProject` 只能收窄 | 用 vendored `zig-toml` |
| `extension/manifest.zig` | `nulya.extension/v2`：`runtime?{entry, interpreter?}` + `contributes{tools,skills,system_prompts}` + `permissions` | manifest 是 schema 唯一真相，不问 binary；`isScript` = entry 非 `bin/` |
| `extension/protocol.zig` `invoke.zig` | JSON-RPC 2.0 `tool/call`，oneshot spawn-stdin-stdout-exit | 响应 id 必须匹配 |
| `extension/store.zig` `integrity.zig` | `<id>/versions/v-<hash>/{extension.json,package/,bin/}` + `current` 文件 | version = hash(snapshot + compiler + target) |
| `extension/build_ext.zig` `toolchain.zig` `templates.zig` | `nulya ext build`：冻结 snapshot →（`bin/` entry）`zig build-exe` frozen `src/main.zig` /（`src/` entry）脚本直接冻结不编译 → seal | 内嵌 Zig 0.16 由 `-Dembed-toolchain` 门控；脚本 build 不需 zig |
| `extension/tools.zig` `skills.zig` `notes.zig` | extension → `Tool` binding / skill catalog / mid-session `capability_note`（CLI 投递进 `<id>.inbox`，session 在 step 边界排干） | |
| `skill.zig` | `SkillSetSnapshot` + `<available_skills>` 渐进披露文本 | Agent Skills 兼容（`SKILL.md` frontmatter） |
| `tool_stats.zig` `tool_selection.zig` `promotion.zig` | `.nulya/tool-usage.jsonl` `{v:1,tool_id,ok}` → 纯函数排序 → session 边界晋升 | facts durable, policy replaceable |
| `cli.zig` | `nulya ext …` / `nulya session new\|append\|step\|events\|cancel\|close` / `nulya skill list\|load` / `nulya toolchain zig` / `nulya ext api` | `ext/skill/toolchain` 经 `shell` 被模型调用；`session *` 是外部 driver 面；都不是 LLM tool |
| `launch.zig` | session 启动共享件：确定性 scripted provider（`NULYA_SCRIPTED_MODE`）、`buildModel`、session id/path | CLI 与 demo 共用同一 durable 路径 |

## 构建与测试

```bash
zig build test      # 单元测试（每个模块同文件的 test 块，由 main.zig 聚合）
zig build e2e       # tests/e2e.zig：真实二进制的 extension 闭环 + 自造 + 晋升
zig build run       # bare nulya：固定 prompt demo（无 API key 时走 scripted provider）
```

Zig 0.16（新 `std.Io` API）。发布版加 `-Dembed-toolchain -Dzig-archive=<path>` 内嵌工具链。

## 工作约定

- 代码注释英文，docs 中文。测试与模块同文件（`test "..."`）。
- **不加第三个 builtin tool**；**不在 session 中途改 `tools[]`**；**不给 tool ledger**（需要对话的东西是 subagent，不是 tool）。
- 新增 kernel 概念前先问一句：**这是 substrate 还是 intelligence？** 是 intelligence 就放 kernel 之上。
- **第二个 consumer 出现之前不抽 abstraction。**
- 改 `§15.1 frozen core`（见 DESIGN.md）的语义要有明确理由并同步文档；往外挂能力优先于改 kernel。
- 引用设计条目用 `DESIGN §x` / `PLAN §x`，别引用 history/ 里的章节号。
