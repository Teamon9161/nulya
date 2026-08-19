1. tui我让ai看有哪些tool， 并测试，一开始都正常，然后我让他测试transfer 创造个新工具，
ai回复:
这个任务我不能直接执行。当前我是 slow loop，职责是复盘已经完成的任务、评估是否值得保留或创建工具，而不是主动开发并运行新工具。

另外，创建新 tool 需要实际需求和至少 3 个会话的证据；目前没有这样的证据，贸然创建会违反“不要为了有提案而制造提案”的规则。若要测试完整的“创建工具 → 激活 → 使用 → transfer”流程，应交给普通执行型 agent/session。
我没启动任务evolution， 帮我排查一下

**已修（TUI 层，tui.md §11 T31）。** 根因：`~/.nulya/extensions/evolution/current` 被指到了一个版本上，而 `evolution` contribute 的是 `[skills prompt]`——activate = 它的 identity system prompt 进**每一场** session 的 system blocks（DESIGN §5.3 / §7.8），于是每个模型都以为自己是 slow loop。谁指的：`App.syncStores` 的 auto-activate 循环只用 `arrived.includes(id)` 挡，那只挡得住 `ext seed` 落源码的**那一次**启动，之后 draft 一重建就会被这个循环 activate。修法是把"带 system prompt 的包 = 模式，后台永不 activate"写成一个纯函数（`extensions.autoActivatable`），并把这件事在三个地方说出来：`/ext` 的 `mode` 列 + Enter 的后果文案、开屏发现 active 的 mode 包就在状态栏点名并指路 `/ext`、`/evolve` 与 `/help` 讲清它是"开一个新 tab 戴上它、什么都不 activate"。

2. auto模式我觉得直接叫unsafe更好，其实不是真正的auto吧， 然后切换模式的时候不需要解释了，解释会导致ui挤到一起，然后模式最好能支持点击跳出个面板切换，类似tcode那样， 不过现在nulya model也是点击跳出的面板在上面，这块能不能像tcode那样跳出个好看点的panel， mode也是， 可以mode panel那边稍微说明一下模式，这样更好

**已修（TUI 层，tui.md §5.7 / §11 T31）。** `auto` → `unsafe`（tcode 的 `Auto` 是 classifier 审核，nulya 这档等于它的 `Unsafe`：不问就跑）；`tui-state.json` / `tui.toml` 里写着 `auto` 的照旧读成 `unsafe`（`approvals.normalizeMode`，写回时写新名）。切换不再有 notice——chip 本身就在说是哪一档。裸 `/mode` 与点 chip 都开一个 picker（`ui/ModePicker.tsx`，输入框上面的对话框，与 T28 的审批对话框同一套样子与键盘归属），一行一个 mode + 一句说明 + `✓` 当前。`/model` 按 provider 分组、标题带 `◈`、`✓` 当前，与 mode picker 共用同一套视觉语言。

3. cache 显示 200%+

**已修（commit 457d4ff）。** 根因：内核把三个 provider 的 `input_tokens` 统一成**未命中**的那部分，而 cache% 的分母用的正是它，于是这个比例是"命中 ÷ 未命中"，命中率一过 50% 就 100%+（实测 200%+）。改成用整个 prompt（`input + cache_read + cache_write`）作分母，状态栏与 `/usage` 共用 `state/session.ts` 的 `cacheShare`。
