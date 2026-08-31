# Goal · compact / handoff 处理迁入 extension

> 这是一份**执行契约**，不是现状文档。现状在 [tui.md](../tui.md) §5.8 / §11 T40–T41 / T106，plugin 契约在 [`tui/plugin-api.d.ts`](../../tui/plugin-api.d.ts)，extension 与 session/fork 事实在 [DESIGN.md](../DESIGN.md) §7 / §11，physics 在 [CLAUDE.md](../../CLAUDE.md)。
>
> 本 goal 只改变 TUI 与 extension 的职责边界；**内核零改动**。实现完成后再更新 `tui.md`，不要把计划写进 DESIGN。

## 0. 一句话

让 `extensions/handoff` 只负责在 ledger 中产生“阶段结束”的信号，让 `extensions/compact` 的 TUI plugin 自己提供 `/compact`、识别实时 handoff、显示 follow/dismiss 面板、调用自己的 internal tool 创建 continuation 并打开 child；TUI host 只保留通用的 plugin、session、tab 原语，不再认识 `compact` / `handoff` 的包名、tool 名、marker 或 workflow。

## 1. 为什么要迁

当前底层 fork 已经在 `extensions/compact/src/main.zig`，但 package policy 仍散在宿主中：

- `tui/src/commands.ts` 把 `/compact` 注册为 built-in；
- `tui/src/ui/App.tsx` 的 `compactNow` / `forkHere` / `checkHandoff` / `followProposal` 决定何时 compact、何时自动 follow、如何换 tab；
- `tui/src/handoff.ts` 知道 handoff tool 名、参数与 accepted call 的形状；
- `tui/src/compact.ts` 知道 compact 包路径、tool 名、marker 与结果协议；
- `CompactionCard` 和 `/sessions` 标题知道 `<nulya:context-summary>`；
- `PluginActions.compact` 是一个按某个具体 package 命名的宿主动词；
- `extensions/plan/tui/plan.ts` 依赖这个专用宿主动词。

这会带来三个重复答案：包定义协议，TUI 再解释一次；extension 新版本若改变行为，旧宿主仍按旧规则处理；headless driver、TUI 与未来前端各自重写 handoff/compact policy。

迁移后的不变量是：

> package-specific facts and workflow live with the package; the host only exposes generic acts a person or trusted plugin can already perform.

## 2. 最终边界（已定）

### D1 · compact plugin 是 UI workflow 的唯一 owner

新增 `extensions/compact/tui/compact.ts`，并在 compact manifest 的 `contributes.ui.tui` 中声明。它负责：

1. 注册 `/compact [focus]`；
2. 观察实时 ledger event，关联 assistant 的 `handoff` call 与成功的 tool result；
3. 显示 handoff preview panel；
4. follow 时以 `brief_seq` 调自己的 `compact` internal tool；
5. 手工 `/compact` 时以 `focus` 调同一个 internal tool；
6. 解析 tool 返回的 `{session,parent}`；
7. 打开 continuation child；
8. 渲染 compact request / context summary 这两类机器 turn。

`extensions/handoff` 不 fork、不调 compact、不持久化 UI 状态。它继续只校验 brief 并返回；accepted call 就是 durable signal。

### D2 · replay 永远没有 workflow 副作用

plugin 只对明确标成 `live` 的 event 执行 panel/fork policy。历史 hydrate/replay 只画 ledger，不弹旧 proposal，不自动 fork。

`PluginObserve.onEvent` 当前类型注释写“live and replay”，实现却只从 driver/follower 的 `onLine` 投递；这次不继续靠偶然行为。宿主 API 增加明确来源：

```ts
onEvent(cb: (event, session, source: "live" | "replay") => void): Unsubscribe
```

本 goal 可以先只投递 `live`，但第三个参数必须真实；将来若补 replay，compact plugin 的 guard 不需要改。已有两参数 callback 在 TypeScript 中继续兼容。

### D3 · compact child 打开新 tab，父 tab 保留

compact 完成后调用现有通用动作 `api.actions.openTab(child)`，不原位 `replace` 父 tab。

理由：

- 旧 transcript 立即可见，不需要回 `/sessions` 找；
- `openTab` 打开的 session 默认 `driven:false`，summary 留在 inbox，用户第一次明确输入时才排干；
- host 不需要知道这个 child 是谁创建的，也不需要 `created/driven` 特判；
- parent/child 关系仍由 kernel header 与 `/sessions` tree 表达。

代价是连续 compact 会增加 tab；这是可见、可关闭的真实 lineage，比把父场藏起来更诚实。本 goal 不做 episode 合并视图。

### D4 · handoff 默认总是询问，不再借 permission `unsafe` 决定自动 follow

permission mode 回答“tool call 是否需要批准”，handoff follow 回答“是否切换 conversation episode”，不是同一政策。compact plugin 默认显示 panel：Enter follow，Esc dismiss。

本 goal 不提供 auto-follow。将来若真实需要，由 compact package 自己增加显式偏好/命令并写入 `api.state`；不得重新读取宿主 permission mode。

### D5 · host 不保留 `compact` 专用 action

最终删除：

```ts
PluginActions.compact(...)
```

compact plugin 用自己的：

```ts
api.actions.extRun("compact", args)
api.actions.openTab(result.session)
```

这条路径天然锁定到该 plugin 自己的冻结 package/version，并受现有 `guardTool` 约束。

### D6 · 跨包 consumer 使用通用的 package tool 调用

`extensions/plan` 当前在 approve 后调用 `api.actions.compact({briefFile})`。删除专用 action 前，plugin API 增加通用动作：

```ts
extRunPackage(
  ref: string,              // id 或 id@version
  tool: string,
  args: Record<string, unknown>,
): Promise<ExtRunResult>
```

规则：

- 无 version 时解析 store 当前版本；无 current 明确拒绝；
- 只能调用目标 manifest 声明且 `surface:"internal"` 的 tool；
- 目标 package/version 必须已 build 且 trusted；
- 不允许借此注册别人的 card、panel 或 command；显示 scoping 规则不变；
- 这是 driver-side `ext run` 的通用投影，不增加 extension runtime 已有 authority。

`plan` approve 迁为：先跑自己 `approve` 产出 brief file，再 `extRunPackage("compact", "compact", {session, brief_file})`，最后 `openTab(child)`。

compact package本身仍调用更窄的 `extRun`，不用跨包面。

### D7 · 机器 user turn 的显示由 package 注册

新增一个窄的、通用的 user-turn renderer 注册面，而不是让 host 继续硬编码 marker：

```ts
api.registerUserTurn({
  id: string,
  match(text: string): boolean,
  render(view, width): Line[],
  sessionTitle?(text: string): string | null,
})
```

约束：

- matcher 只接收普通 `user_text` 内容，不能改 ledger 或 PromptIR；
- host 仍提供 card frame、fold、theme 与错误边界；
- session title formatter 只改变 `/sessions` 展示，不改变 kernel `first_user_text`；
- 一个 turn 多个 matcher 命中时，按 plugin load 顺序首个胜出并 warning；
- renderer 必须声明稳定 `id`，同包同 id 后注册者覆盖；
- plugins disabled / package UI 加载失败时，退化成普通 user card和原始 session title，数据仍完整。

compact plugin 用它识别 request/summary marker、画现在的 `CompactionCard`，并把 summary session title 格式化为 `continued · …`。最终 host 不导入 marker 常量。

### D8 · 宿主只投影通用 session 状态

`SessionView` 增加只读字段：

```ts
role: "driver" | "observer"
status: "idle" | "stepping" | "canceling"
```

compact command/panel 在 `driver + idle` 时才执行；否则由 package 给出自己的提示。真正的 writer authority仍由 kernel lease / `SessionBusy` 决定，这两个字段只是当前 TUI attachment 的投影。

## 3. 实施顺序

### M1 · 扩充 plugin API 的通用最小面

改动：

- `tui/plugin-api.d.ts`
  - `onEvent` 增加 `source`；
  - `SessionView` 增加 `role/status`；
  - 增加 `extRunPackage`；
  - 增加 `registerUserTurn` 及对应 view/renderer 类型；
  - 删除动作留到 M4，M1 暂时保留 deprecated `compact`，让迁移可分步全绿。
- `tui/src/plugins/host.ts`
  - 投递真实 event source；
  - 实现 package tool resolve/validate/run；
  - 保存 user-turn renderer registry；
  - 保持插件异常隔离、trusted-zone 和 revision 规则。
- `tui/src/ui/Transcript.tsx` / card registry
  - 在普通 UserCard 前查询 plugin user-turn renderer；
  - renderer throw 仍落现有 ErrorBoundary。
- `SessionsView` 的 title 计算通过 host seam 查询 formatter，不认识任何 marker。
- `App.pluginSession()` 投影当前 role/status。

M1 验收：

- 既有 plan/ask plugins 不改仍全绿；
- 两参数 `onEvent` 夹具编译通过；三参数夹具收到 `live`；
- replay 来源测试不触发写动作；
- `extRunPackage` 成功、无 current、非 internal tool、未信任版本四类测试；
- 两个 matcher 冲突、renderer throw、plugins=false 降级测试；
- `bun run typecheck`、`bun test test/plugins.test.tsx test/render.test.tsx test/overlays.test.tsx`。

### M2 · compact package长出完整 TUI plugin

新增/修改：

- `extensions/compact/extension.json`
  - 增加 `contributes.ui.tui`；
  - package command由代码层注册，不必再加 manifest command；
- `extensions/compact/tui/compact.ts`
  - `registerCommand("compact")`；
  - `registerPanel` handoff preview；
  - `registerUserTurn` request/summary renderer与 session title；
  - 实时 event correlation：assistant call `{id,tool:"handoff",args}` 暂存，匹配成功 tool result 后才形成 proposal；failed/denied/unparseable call 忽略；
  - proposal key 为 `session + call_id`；
  - follow 用 proposal 自己的 assistant seq 传 `brief_seq`；
  - command/follow 共用一个 `run(args)`：preflight → `extRun` → parse result → `openTab` → notice；
  - 同一 proposal effect 重跑、tab 切换、任务 refresh 都不得重复执行。
- package README 说明：插件是便利层；没有插件时 handoff call 与 summary 仍是普通 ledger 内容，headless driver照常可消费。

M2 验收：

1. `/compact focus` 真跑 package tool并打开 child tab；父 tab仍在。
2. child summary inbox 保持 pending，等待用户首次输入。
3. live accepted handoff 打开 panel；Enter 只 fork一次；Esc 永不 fork。
4. resume 含历史 handoff 的 session 不弹 panel、不 fork。
5. failed/denied/unparseable handoff不出现 proposal。
6. 相同 call id 在不同 session互不遮蔽。
7. `/sessions` 不显示 marker；transcript仍画 compact request/summary card。
8. plugins=false 时不 crash、不 fork，原始 ledger仍可读。

测试模块优先放 `tui/test/consumers.test.tsx`（真实 package consumer）和 `tui/test/plugins.test.tsx`（宿主面）；纯 parser/correlation 可放 package旁可被 `tsconfig` 收到的模块。

### M3 · 迁移 plan consumer

修改 `extensions/plan/tui/plan.ts`：

- 移除 `api.actions.compact({briefFile})`；
- approve tool 返回 brief 后调用：

```ts
const result = await api.actions.extRunPackage("compact", "compact", {
  session: current.id,
  brief_file: brief,
})
const forked = parseCompactResult(result)
api.actions.openTab(forked.session)
```

- compact 未安装/未激活时 panel 保留、计划不丢，notice 明确给出 build/activate 出路；
- plan README 声明对 compact package 的 driver-side 依赖。

M3 验收：原有“propose → review → approve → execution child”e2e全绿，并新增 compact 缺失时不关闭 panel、不丢 plan/brief 的测试。

### M4 · 删除宿主特判与旧 seam

在 M2/M3 全绿后一次删除：

- `commands.ts` 的 built-in `/compact`；
- `App.tsx` 的 `compactNow`、`forkHere`、`checkHandoff`、`followProposal`、handoff signals/seen/run boundary；
- host `HandoffPanel` 挂载与键盘分支；
- `PluginActions.compact` 类型、host seam和相关测试夹具；
- `tui/src/handoff.ts`；
- `tui/src/compact.ts`；
- host `CompactionCard` 特判；若无其它 consumer则删除组件；
- `SessionsView.title` 对 `compact_summary_marker` 的 import与判断；
- `App.tsx` / `plugins/host.ts` 对 `runCompact` 的 import；
- 只为旧特判存在的测试，改写成 package consumer测试，不降低覆盖。

完成时执行机械检查：

```sh
rg -n 'compact|handoff|context-summary|compact-request' tui/src
```

允许出现的位置只有：

- 通用 API 文档中的历史/deprecation说明（若尚未删净则失败）；
- package inventory / 测试夹具明确引用 package id 的地方；
- 不允许在 `App.tsx`、`commands.ts`、`SessionsView.tsx`、core card registry里出现。

### M5 · 文档与完整验证

更新：

- `docs/tui.md` §5.8：handoff/compact由 package plugin消费，host只提供通用原语；
- `docs/tui.md` §11：新增实施记录，写清父 tab保留、child不自动 step、permission mode解耦；
- `docs/goals/tui-plugin.md` §6：D5/API 的增量和新的第三个真实 consumer；
- `CLAUDE.md` TUI 现状一句；
- `plugin-api.d.ts` 顶部 minor-version changelog；
- compact/plan package README。

最终验证：

```sh
cd tui
bun run typecheck
bun test
bun run compile
cd ..
zig build test
zig build e2e
```

若本 goal 最终只改 TUI 与 extension，`zig build test/e2e` 仍必须跑，因为 bundled package snapshot、seed数量与 extension e2e 可能被 manifest/UI entry变化影响。

## 4. 明确不做

1. 不把 compact/fork 语义加进 kernel；kernel只保留通用 `session new --parent`。
2. 不让 handoff tool 自己 fork；model tool call只产生信号，driver决定是否跟。
3. 不复制父 ledger到child；父 tab与parent header已经表达 lineage。
4. 不做 episode 合并 transcript。
5. 不让 plugin回答 gate或读取/修改 permission mode。
6. 不新增第二套 extension runtime协议；仍走现有 `ext run`。
7. 不用持久 `seen` 修 replay问题；live/replay边界才是主不变量。
8. 不允许 plugin renderer改写别的 package 的 tool card；`registerUserTurn` 只处理内容 sentinel，不放宽 D11。

## 5. 风险与停线条件

### R1 · `registerUserTurn.match` 运行任意 plugin代码的频率

匹配会在 transcript render与 session list刷新时发生。实现前先做最小 benchmark；若5k-event replay明显回退，改成声明 prefix而不是函数 matcher：

```ts
registerUserTurn({ prefix: "<nulya:context-summary>", ... })
```

不要靠 memo掩盖无界 matcher成本。

### R2 · plugin load时机

compact command要在 draft开屏可用，因此 compact package必须 current+trusted，且启动 plugin load完成后进入 command table。若启动后台sync尚未build完，命令可以暂时不存在，但sync完成必须触发 plugin load/command refresh；不得在 host重新加一个 built-in fallback。

### R3 · plan跨包版本选择

`extRunPackage("compact", ...)` 解析 current，而 plan session冻结的是自己的版本，不是 compact版本。调用结果与 store current必须在notice/debug信息中可查。若需要严格可重放的依赖版本，应该另立 manifest dependency设计；本 goal不偷偷冻结一个宿主选择。

### R4 · observer live event

observer follower也产生 `source:"live"`。compact plugin看到后可显示只读 proposal，但执行前必须检查 `role/status`；observer上 Enter明确拒绝“由正在驱动这场的driver处理”，不能抢writer lease。

### BLOCKED

只有以下情况停线并回到本文件记录，不得用host特判绕过：

- `extRunPackage` 无法在不绕过 trust/version守卫的情况下复用现有 `extRun`；
- user-turn renderer无法在不暴露OpenTUI/Solid组件树的情况下复现现有卡片；
- plugin command在启动sync后无法可靠刷新；
- plan consumer无法迁出 `PluginActions.compact` 且唯一替代要求kernel改动。

## 6. 完成定义

全部满足才算完成：

- `App.tsx` 不包含 compact/handoff workflow；
- TUI built-in命令表没有 `/compact`；
- plugin API没有 `PluginActions.compact`；
- core transcript/session list不认识 compact marker；
- compact plugin单独关闭时，相关UI/自动行为一起消失，但ledger和headless流程仍正确；
- resume历史handoff永不产生新session；
- handoff follow与手工compact都由同一个package函数调用同一个internal tool；
- parent tab保留，child不在无人输入时step；
- plan approve继续能创建execution child；
- 全量TypeScript、Bun测试、compiled TUI、Zig unit/e2e全绿。

## 7. 实施记录

> 执行时只在这里追加：日期、里程碑、实际改动、偏离、测试结果、下一步提醒。不要改写上面的契约来伪装偏离不存在。
