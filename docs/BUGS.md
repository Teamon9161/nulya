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

**② agent 的 tool 也一直在，是屏幕在说谎（已修，T42 ⑤）。** 状态行与 Welcome 卡的 `tools 1+N` 只数持久 pin（config 的 `pinned_native_tools` ∪ `tui-state.json` 的 `session_pins`），而 `handoff` / `agent` 是 `[extensions] session_with` 的成员、在 `session new` 那一刻才 `--pin` 进去。实测：开屏写 `tools 1+5`、tools 行里没有 agent，而上一场 session 的 header 里 `native_tools` **明明有四个 `ext:agent/*`**。修法两处：`plannedPins` 认第三个来源（从 `ext list` 读 active 版本的 model-facing tool，不 build），以及 `PinState` 多一档 `composed`（标签 `with the package`）——`/ext` 的 tools pane 从此给它们画 `[x]`、`agent` 那行整个是 on，按 Enter 不写任何列表而是点名 `[extensions] session_with`。现在开屏那行是 `shell ⚡read … ⚡handoff ⚡agent`。

**③ 那一行同时暴露了第 7 条的后果**：`materialize` / `list` / `run` 本该是 `audience: "driver"`（不上模型面），本机 agent 还是旧 manifest 所以四个全上去了。**已在本机执行** `nulya ext seed --user --force`（5 个 replaced、3 个 up to date）+ `ext sync --user --activate`（5 built → current）：agent 到 `v-debf629c`（模型面只剩 `⚡agent`，另三个进了 `/ext` 那行折起来的 driver tools）、std 到 `v-9b172a2a`（有 `edit`，下次启动 `adoptStdEditPin` 会把 `ext:std/edit` 补进 pin 列表）、evolution 到 `v-a0d760f4` 且是 `on-request`——**第 6 条的 `◈ evolution` 也随之消失**（activate 从此只是登记）。

10. 但是以后会不会还是出现一样的情况, 然后用户不知道怎么修呢, 这就是个隐患

**已消（T42 ⑥）。** 分三种情况说：① **新机器全自动**——第一次 seed 就写下 `.seed` 记录，之后每个新二进制认得出"这是我自己的副本、没人动过"，直接刷新，什么都不问；② **你编辑过的 draft** 会停下来，这是对的（不能替人覆盖），但它现在**在 `/ext` 里持久可见**：id 列表那一列写 `differs`，详情面写清两种可能与代价（旧源码留在它自己那个冻结版本的 `package/` 里，build 过的东西一个都丢不了），**`s` 一键做完 `seed --force` → `build` → `activate`**；③ **记录出现之前的老 store**（就是你这台）是一次性的，走同一条 `s`。开屏 notice 从"给你一条命令"改成"指 `/ext`"——一条六秒后消失的新闻不该是一个持久状态的唯一去处。

11. agent tool现在不支持指定模型启动

**已加（`extensions/agent`，内核零改动；DESIGN §7.8、tui.md T43 ⑥）。** `agent{name, task, model?}`：值与定义文件的 `model:` 逐字同形（`<profile>` 或 `<profile>/<model-id>`），**一处解析**（`defs.parseModelRef`——一个参数和一个 frontmatter 字段说的是同一件事，两个 parser 就是两套语法）。优先级由近及远：**这次调用 > 定义 > 继承发起它的那一场**，而且取的是**一对**（profile 与 id 从两个来源拼起来，会点名一个那个 profile 根本不服务的模型）。为什么让模型自己挑：定义说的是"这个 persona 一般跑在什么上"，调用者知道定义不知道的那件事——**这一件活值多少**（宽搜配便宜的、严审配贵的）。`agent{session, …}`（追问）给 `model` 是 `-32602` 而不是静默忽略：那一场的身份创建时就冻死了（physics #2），而 append-only 正是追问便宜的原因。解析不出当场报错并指 `nulya config show`；profile 名对不上就把内核那句拒绝原样递上来，只多一句"这是你给的 `model` 参数、可以不带它重试"。

12. tui有启动agent的展示,但是只有下拉展开的内容, 能不能有个地方点击调转过去了, 类似tcode那种做法, 这样才知道agent做到哪一步了, 这个而能纯粹在agent extention的 tui中实现吗, 还是需要额外的拓展能力

**做了，在宿主层，不是插件层（tui.md T43 ⑤）。** 委派卡从此是它自己的 `SubSessionCard`：头行下面一行 **`↗ open <id> in a tab`**（点它、或 browse 模式 `Enter`，走同一个入口 `state/navigate.ts`），note 说那个后台任务此刻在怎么样——`s-1/t1 · running 42s`，报告落进 ledger 后变成 `· exit 0 · 41.8s`，重开一场照样显示（用的是后台 `shell` 卡那一套读法，两个 consumer 了才抽出 `backgroundNote`）。**顺带修好一个静默失效**：`task_finished` 认领"是哪张卡起的这个任务"只认内核那句 `[background task X started]`，而 `agent` 的回执是自己的句子——所以委派卡从来不会变成 done。两种回执现在由 `startedTaskOf` 一处读。

**能不能纯在 agent extension 的 tui plugin 里做：不能，而且不该。** 契约版本 1 的 `CardRenderer` 只返回 `Line[]`，`onKey` **明确写着不会被调用**（卡片没有自己的焦点，browse 模式持有卡片上的键），也没有点击回调；`actions.openTab` 有，但只够从一条 `/命令` 或一个 panel 触发。进度更根本：子场是**后台任务**在驱动，它的 `--stream` 根本不经过这个前端，而 `observe.onStream` / `onEvent` 只给前端自己驱动的 step 和 front tab 的事件。要让插件做得给 API 加"卡片激活回调"和"跨 session 观测"两样，而第一个 consumer 就是宿主自己——正是"第二个 consumer 出现之前不抽 abstraction"要拦的事。跳转本来就是宿主的手势（T3 起 `Enter` 就能开），缺的只是屏幕上没有一个东西说得出这件事。

13. 有时候模型在输出内容, 然后渲染的那个内容会疯狂闪烁

**已修（tui.md T43 ①）。** 元凶是流式末尾那个 `▍` 光标：它拼进的是 markdown 的 **content**，所以参与解析。每个 delta 都在重新解析一份多一个字形的文档，而那个字形在**块边界**上会改变答案——文本以换行结尾时它独占一行（+1），下一个 delta 收回（−1），一个开头的 ``` 干脆把它吞进未闭合的 code block。逐 chunk 抓帧实测：三个 delta 内 **7 → 6 → 7** 行。transcript 是 sticky-bottom 的 scrollbox，每一次高度回缩就是整屏重排。删掉之后同一段输出的行数**只增不减**（同一份探针，回缩计数 0）。它本来也该走了：T38 之后"正在发生什么"是输入框上面一整行自己的事（spinner + 扫光），transcript 里不该再有会动的东西。

14. 我在想那个thinking干脆像tcode那样默认隐藏吧, 然后就是探索的调用我觉得也是默认隐藏比较好…不过我的偏好是最好extention中可以配置什么不收进去

**两半都做了（tui.md T43 ②④）。**

**thinking 默认 `hidden`。** 一张折叠的 reasoning 卡仍然要花掉一个头行、一个 glyph、一个 fold 记号，**每一次回答都花，就花在回答正上方**；而它既不是模型说的也不是它做的，是 provider 的草稿纸（留在 ledger 里为的是回放）。"它正在想"这件事，输入框上面那一行本来就在说。`transcript.thinking = "collapsed"` 把卡要回来。实现上有个坑：hidden 不能只让卡返回 `null`——画不出东西的 item 仍占着 `gapBefore` 给它的那一行空白，所以它**离开 item 列表**。

**探索调用折成一行**：`⋯ read ×3 · grep ×2 · shell ▸`，展开就是原来那些卡各自照旧。**进不去的比进得去的重要**：还在跑的（那正是唯一值得看的一行——于是效果自然是"跑的时候看得见，跑完了收起来"）· 失败的（成功才沉默，一条静静包含失败的摘要行是这个功能唯一比没有更糟的形态）· 被取消的 · 回执型的（后台任务 / 子场）· `edit` 的 diff · 演化动作 · `checklist`/`markdown` · 包用代码画的卡。

**"extension 中可以配置什么不收进去"——就是已有的 `render` 声明位**（DESIGN §7.2.1 的 `contributes.tools[].render`，开放词表、kernel 只解析不强制）。规则一句话：**声明了画法 = 有身体值得看 = 不收**。所以不加 manifest 字段，`std` 想让 `write` 跳出摘要就给它一个 `render` 声明，不必等前端认识这个词。人这一侧的总开关是 `tui.toml` 的 `run_summary = false`（回到一次调用一行）。

15. 现在模型回答的md渲染和上面没有间隔一行, 会感觉挤在一起

**已修（tui.md T43 ③）。** `gapBefore` 有一条 `thinking → assistant = 0`（"thinking 与它后面那句话是同一个 beat"）。道理在，但屏幕上那是**两张卡贴在一起**：一个带 glyph 与 fold 记号的头行，紧接着一段 markdown。实测帧：

```
  ⋯ reasoning (opaque)
● Heading
```

"属于后面那句话"由顺序和 dim 已经说完了；空行在这一屏的语法里就是 beat 边界，而 thinking 是一个 beat。第 14 条之后这条多半用不上——但当有人把卡要回来时，它得是对的。

16. 我让 nulya 主 agent 启动了一个 explore agent，但是 sub-agent 说无法读取文件，主 agent 则一直在等待 sub-agent 返回，但其实 sub-agent 已经完成了

**两个 bug，同一场委派上撞见，都已修（内核壳层 + `extensions/agent`）。**

**① sub-agent 什么都读不了：`ext inspect` 不认 `<id>@<version>`。** `readonly` 的委派由 `runner.zig` 机械应答内核的 gate：`shell` 一律拒，extension tool 只放行**子场冻结 manifest** 声明 `readonly: true` 的那些。那份名单由 `readonlyToolNames` 从子场 header 的每个成员算出来，问法是 `nulya ext inspect <id>@<version>`——而 `extInspect` 从来只读 `<root>/<id>/extension.json`（draft），把整个 `std@v-…` 当成目录名去找，于是恒定打印 `no such extension` + exit 1。`collectReadonly` 找不到 JSON 就当"确认不了的名字不放行"（安全的那一端），**名单恒为空**：`read` / `grep` / `glob` 全被拒，而 explore 的 persona 正是让它去读。屏幕上看到的是"这个 agent 说它不能读文件"，ledger 里是三条 `deny`。修法是让 `ext inspect` 认它本来就该认的形状：`<id>@<version>` = 那个版本的冻结 manifest（session header 记的正是这个形状），`<id>` 保持 draft 优先、**没有 draft 就退回生效中那个版本**（`ext build <path>` 填出来的 store 根本没有 draft，对着 `ext list` 里明明活着的 id 回答 "no such extension" 本身就是错的）。DESIGN §14 已同步，e2e 钉在 `bundled agent … explore` 那个用例里。**后记（2026-08-23，ext-review lane B）**：这条推导随后整个删掉了——gate 请求行自带 `tool_id` / `readonly` 两列（内核从冻结 manifest 投影），runner 读那一列就是答案，不再 spawn `ext inspect`；`ext inspect` 自己也改成只答 store（lane C）。根治的是"答题人各自从 manifest 重推冻结事实"这件事，不是那一次推导的某个坑。

**② 主 agent 永远等不到报告：`--stream` 的读行缓冲是 4096 字节。** `runner.zig` 用 `[4096]u8` 读子场 `session step --stream` 的每一行，而一条 assistant ledger 行装着整轮文本 + provider 不透明的 reasoning（实测这次是 **11225** 字节，早两步的行都在 4096 以下，所以前两步一切正常）。`Reader.takeDelimiter` 对超长行返回 `error.StreamTooLong` 且**一个字节都不消费**，而那里写的是 `catch null` —— 与 EOF 同义，循环就此退出。于是：子场把剩下的字节写进没人再读的 stdout 管道并**永久阻塞**，runner 关掉 stdin 后转去 `allocRemaining` 读它的 stderr，也**永久阻塞**；supervisor 等 runner、`task_finished` 永远不 deposit、父场的 inbox 一直是空的——"driver + idle + inbox 非空 → 再 step" 那条 policy 因此永远不触发。四个进程就这么挂着（实测 `nulya task supervise` / `ext run agent … run` / `session step --gate` 全部活着，`status.json` 停在 `running`，`output.log` 是空的）。修法三处：读行缓冲改成 `max_line_bytes = 4 MB` 的堆缓冲；超长行**跳过而不是退出**（`discardDelimiterInclusive`，少一条观测 vs 丢掉整场委派）；`max_stream_bytes` 到顶后**停止解析、绝不停止读**。三处读 session header 的地方（`runner` / `defs.wornPersona` / `main.parentIdentity`，4096 / 16K / 8192 三种猜法）合并成 `extensions/agent/src/header.zig` 一处——T44 之后 header 里冻着 persona 正文，而内核给 system prompt 的上限是 2 MB，栈上的固定缓冲在这件事上只会静默地答错。e2e：一次 12 KB 任务的委派，报告必须照常回到父场（旧代码在这里会一路挂到 `task wait` 超时）。
