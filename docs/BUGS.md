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

4. 为什么报错信息也在 composer 呢，现在看不全报错，帮我先排查下为什么会报错，然后再调整这个报错位置？这个报错应该放对话记录那边吧？

**两件事，都已处理。**

**① 报错本身不是 nulya 的 bug**：`chatgpt.com` 在这台机器上连不通——`getent hosts chatgpt.com` 给的是 `198.18.0.43`（fake-IP 段，说明有一层 tun 代理在接管解析），而对它的 **TCP connect 直接超时**（`curl --connect-timeout 8` 报 `Connection timed out`，`time_connect=0`）。同一时刻 `api.openai.com` / `api.anthropic.com` / `auth.openai.com` 都正常（分别 401 / 404 / 405），所以不是断网，是代理对 `chatgpt.com` 这条规则的落点是死的。codex provider 打的正是 `chatgpt.com/backend-api/codex/responses`（`providers/codex.zig`），于是 `wire.zig` 的 stall watchdog 在 `RetryPolicy.stall_timeout_ms`（默认 120 s）到期时把它折成 `Transport`，`isTransient` 判它可重试 → `model request failed (Transport); retry 1/5 in 1s`。**修法在代理侧**，内核照它该做的做了。

**② 位置确实错了（已修，TUI 层）**：`snapshot.error` 原来只画在输入框下面那一行的活动区，而那一行有一行、还要分给 model / cost / chips，所以任何真实错误都被切成 `error: model request failed (Transp`——最该读全的那句话是屏幕上唯一读不全的。现在它是 transcript 末尾的 `ErrorNotice`（`render/cards/ErrorNotice.tsx`）：`✗` + 原文，按 `wrapWords` 自己换行、续行挂在文字列下（`ui/Fact` 同一个理由——OpenTUI 对超宽 flex 行是压缩不是换行）。**它不是 item**：没有 ledger 事件、replay 不会重现，所以和 CompositionCard 一样待在 item 列表外面（一个在顶一个在底），不必参与 `seq` 排序或 `dropInFlight`；生命周期一个字没变，仍是下一个 `model started` 清掉。状态栏只留 `error · see transcript`（滚上去了也知道有这么回事）。docs/tui.md §4.2 / §4.5 已同步。

5. 这个流量统计能不能放在状态提示那边呢, 就和tcode一样, 在工作的时候会定期更新下tok数就可以了, 不需要一直显示在下面

**已改（TUI 层，tui.md §4.4b / §4.5 / §11 T42）。** `↑… ↓… cache …%` 从输入框下面那一行搬到上面那一行的尾段（`· 12s · esc to cancel · ↑12.4k ↓3.1k cache 89%`），跑完随整行消失。理由是那一行的分工：下面是"这一场是什么"（读一次就信），上面是"此刻在发生什么"（每秒再读一遍）——一个**会变的总数**属于后者。共用短语 `state/session.usageLabel`，`/usage` 仍是全部账，`ctx N%` 留在原处（它不是总数，是警告）。

6. 为啥下面自己会出现 evolution mode 呢, 我都没启用 evolution 吧, 而且点击就打开了 /ext 的窗口是为啥

**两件事。** 点它开 `/ext` 是设计（T31：那一格就是 `/ext` 的鼠标那一半，`◈` 表示"这一场戴着的、会改变模型自我认知的包"）。**它为什么亮着**才是问题：`~/.nulya/extensions/evolution/current` 指着一个**旧版本**——那份 manifest 早于 `activation: "on_request"`（DESIGN §7.2.1），所以 discovery 仍把它当 `always`，它的 identity system prompt 就进了这台机器上的每一场 session。这是第 1 条的余烬：那次修的是"以后不会再被后台自动打开"，已经开着的由人决定（harness 不替人关）。**根因在 7**：本机装过一次之后，升级二进制从来不会更新自带扩展，所以那份 manifest 一直是旧的。修完 7 之后，开屏那趟 sync 会把 `evolution` 重新 build 成 `on_request` 的那一版并把 `current` 指过去，于是 activate 只剩"登记"，`◈` 自己就消失了。

7. 现在有个问题是 agent ext 其实是有更新的, 但是我本机 build 过了它不会自动更新, 所以导致改过的 audience 在我本机上不生效, 也不会自动 rebuild, 这个怎么处理好呢

**已修（壳层，新 `src/cli/ext_seed.zig`；DESIGN §7.2 / §7.8、tui.md §11 T42）。** 根因是 `ext seed` 的旧规则"该 root 已有 draft 的 id 一律不动"——理由正当（可能带着别人的编辑），后果是**升级二进制永远不会更新已装上的自带扩展**：这台机器上 `agent` 的三个 `audience: "driver"` 没生效（四个 tool 全在模型面上）、`std` 还没有 `edit`、`evolution` 还是 `always`。判据不能是内容 hash（自演化每轮都改），也不能是问一句（那一步跑在开屏之前的后台），所以改成**一条记录**：seed 写 draft 时在 `<root>/<id>/.seed` 记下自己写的那棵树的 digest；下次四种答案——没有 → seed · 与本二进制逐字节相同 → up to date（顺手补记录，老 store 的补课机会）· 记录仍描述盘上这棵树 → 这是 harness 自己的副本、没人动过 → **自动刷新** · 记录对不上或没有记录 → 有人动过 → **原样留着并点名**，`--force` 是唯一覆盖入口。刷新过的 draft 对随后的 `ext sync` 就是普通的"变了的 draft"，照常 build + `--activate`。**这台机器上的老 store 没有记录**，所以第一次会看到 `… differ from this build`，跑一次 `nulya ext seed --user --force` 就都接上了（已核对：本机六个 draft 与仓库的差异全是版本漂移，没有本地编辑）。

8. 小细节: 点击 unsafe 打开模式窗口, 再点一下没法关闭

**已修（TUI 层，T42）。** `toggleModePicker`：屏幕上其它每一个"点开"都能点回去（`openOverlay` 本来就是 `overlay.toggle`，折叠卡头行也是），只有这个对话框的入口是单向的。`/mode` 那条命令仍是"打开"（打两次 `/mode` 不是收起的意思）。

9. bun run start 了, 发现还是默认没有启用 agent 的 tool, 为什么呢, 然后 ask 和 plan 也没 build, 这个是正常的吗

**两问，一个是真 bug，一个是误读。**

**① `ask` / `plan` 其实已经 build 并 active 了**（`nulya ext list` 里两行都在，`plan` 标 `on-request`）——开屏那趟后台 sync 干的，只是它跑在后台、`/ext` 开得早就会看到还没有。这是正常的。

**② agent 的 tool 也一直在，是屏幕在说谎（已修，T42 ⑤）。** 状态行与 Welcome 卡的 `tools 1+N` 只数持久 pin（config 的 `pinned_native_tools` ∪ `tui-state.json` 的 `session_pins`），而 `handoff` / `agent` 是 `[extensions] session_with` 的成员、在 `session new` 那一刻才 `--pin` 进去。实测：开屏写 `tools 1+5`、tools 行里没有 agent，而上一场 session 的 header 里 `native_tools` **明明有四个 `ext:agent/*`**。修法是 `plannedPins` 认第三个来源（从 `ext list` 读 active 版本的 model-facing tool，不 build），`/ext` 详情面也多一行说"这个包每一场都在"。现在开屏那行是 `shell ⚡read … ⚡handoff ⚡agent ⚡materialize ⚡list ⚡run`。

**③ 那一行同时暴露了第 7 条的后果**：`materialize` / `list` / `run` 本该是 `audience: "driver"`（不上模型面），本机 agent 还是旧 manifest 所以四个全上去了。跑一次 `nulya ext seed --user --force && nulya ext sync --user --activate` 之后就只剩 `⚡agent`。
