1. tui我让ai看有哪些tool， 并测试，一开始都正常，然后我让他测试transfer 创造个新工具，
ai回复:
这个任务我不能直接执行。当前我是 slow loop，职责是复盘已经完成的任务、评估是否值得保留或创建工具，而不是主动开发并运行新工具。

另外，创建新 tool 需要实际需求和至少 3 个会话的证据；目前没有这样的证据，贸然创建会违反“不要为了有提案而制造提案”的规则。若要测试完整的“创建工具 → 激活 → 使用 → transfer”流程，应交给普通执行型 agent/session。
我没启动任务evolution， 帮我排查一下

**已修（TUI 层，tui.md §11 T31）。2026-08-25 之后这个失败模式已经不可能出现，修它的不是那道守卫，见本条末尾。** 根因：`~/.nulya/extensions/evolution/current` 被指到了一个版本上，而 `evolution` contribute 的是 `[skills prompt]`——activate = 它的 identity system prompt 进**每一场** session 的 system blocks（DESIGN §5.3 / §7.8），于是每个模型都以为自己是 slow loop。谁指的：`App.syncStores` 的 auto-activate 循环只用 `arrived.includes(id)` 挡，那只挡得住 `ext seed` 落源码的**那一次**启动，之后 draft 一重建就会被这个循环 activate。修法是把"带 system prompt 的包 = 模式，后台永不 activate"写成一个纯函数（`extensions.autoActivatable`），并把这件事在三个地方说出来：`/ext` 的 `mode` 列 + Enter 的后果文案、开屏发现 active 的 mode 包就在状态栏点名并指路 `/ext`、`/evolve` 与 `/help` 讲清它是"开一个新 tab 戴上它、什么都不 activate"。

**后续（2026-08-26）**：真正让这个 bug 不可能再发生的**不是** T31 那道守卫，而是 2026-08-25 的 ext-syntax——`activation` 与 fresh 路的 discovery 一起删掉之后，**activate 不再蕴含成员关系**。`evolution` 今天是 `apply: "manual"`，与 `plan` 同形：把 `current` 指向它，它进不了任何一场 session，prompt 只在有人 `/evolve` 戴上的那一场里生效。守卫因此在结构性修复之后又存活了很久，而它最后拦住的只有 `guide`（只贡献一行 skill catalog），代价是"装了 nulya，guide 却不生效"。守卫已于 2026-08-26 删除（tui.md T60），换成把「哪些包从此进每一场 session」在开屏说出来（`warnUserScope` 那条先例）。

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

17. 我试着用nulya做任务, 然后又直接卡死了,状态那个也不转了, 前端模型回应还之前缩成一团, 我记得之前也遇到一次, 现在又是什么原因, 能根治吗, 包括渲染经常闪烁也是, 总是在遇到同样的问题, 是opentui的一些bug? 能否根治呢, 而且卡死是最恶劣的（补充：按 ctrl+c 还是可以退出的）

**两个 bug，同一场撞见，都已修（TUI 层，tui.md §11 T75；内核零改动）。**

**① 卡死：OpenTUI 渲染调度的死等（`ui/watchdog.ts`）。** 「Ctrl+C 能退」是定性证据：raw mode 下那是应用自己处理的按键，能退 = Bun 事件循环、键盘、90ms spinner 定时器全活着；那场 session 的 ledger（`tui/.nulya/sessions/s-…840504`）最后一批 tool_results 落盘正常 = 内核也活着；死的只有画屏幕。机制在 `@opentui/core` 0.5.3（0.5.9 逐字节相同，升级无用）：native 帧因终端 backpressure 被 SKIP 时 renderer 停在 `feed.idle()` 上等，等待期间 `requestRender()` 第一行就把一切渲染请求静默丢弃——无超时无重试；而 `idle()` 的 resolve 依赖「变空闲那一刻恰好有人调 `resolveIdleIfNeeded()`」，空闲判定读的是 native 线程写的共享内存 refcount，释放不带 JS 事件——lost wakeup，feed 已空闲、promise 永远挂着。屏幕于是永远停在最后一帧（`preparing write · 2m 52s` 的钟随帧走，帧停钟停）。触发负载正是当时的形状：模型流式吐一整个文件的 write 参数 + shimmer 每 90ms 要一帧。修法：`loop()` 入口不查那些标志，公开的 `intermediateRender()` 能强制一帧——watchdog 监听 `renderer.on("frame")`，`Activity.moving` 在场而两秒无帧就 nudge 一次（每 stall 窗口一次），lost wakeup 当场解冻，真 backpressure 则这帧再被 SKIP、无损失。

**② 缩成一团：T73 的量宽信了一个 OpenTUI 会丢的事件（`ui/measure.ts`）。** 截图那一列正好 12 cells（六个汉字）= `AssistantTurn` 的 `room() = max(12, measured())` 下限，说明 `measured()` 停在布局前的 1。该纠正它的 `resize` 事件没来：`onLayoutResize` 只在 `_visible` 时 emit，而 scrollbox 视口剔除对不可见的孩子照样跑 `updateFromLayout()`——宽度悄悄记下、事件不发；等它进视野 `sizeChanged == false`，事件永不补发。流式追加的卡第一次布局常在视口外，正中此窗口。修法：resize 事件保留为快路径，另加 renderer `frame` 事件兜底——每画完一帧重读一次 `box.width`（相等则信号不动），帧是唯一丢不掉的触发器。永久缩团从此变成至多一帧、自愈。attach 把布局前的 0 读成 1 **保留**（试图改掉时 T73 的「同一宽度画同一张表」当场变红——每个 body 从同一个最窄起点出发，正是滚动条阈值上两个定点落进同一个的原因）。

**③ 闪烁**：两大来源已在 T43（流式末尾光标）与 T73（表格列宽缓存）修掉，本场跑的已是修复后代码；剩余是 T73 写明的滚动条阈值临界情形。再看到新的闪烁按新形状单独抓。

**后记（同日第二次冻结，活体取证修正了 ① 的诊断——tui.md T76）**：T75 落地后一小时再次冻结，这次进程留着没关。`/proc` 直读：step 子进程已消失（内核早跑完）、主线程 epoll 停着、wchar 零增长、watchdog 每 2 秒强制的帧都成功但内容一模一样——**渲染器完全健康，死的是 Solid 响应层**（信号写不再传播）。「feed 死等」对这台机器不成立：Linux 上 `useThread` 恒 false 且这个 app 不传自定义 stdout，**根本没有 feed**。真正的问题是 OpenTUI 把 `uncaughtException`/`unhandledRejection` 吞进一个永不打开的 console overlay——致命错误进程不死、屏幕不变、原因不可见；主嫌疑是 T73 的 resize 监听在布局中途同步驱动 Solid 传播。第二轮修复：measure 改为 frame 事件调度 `setTimeout(0)` 统一 flush（信号写在干净栈上）、新 `ui/crashlog.ts` 把三处被吞的错误落盘 `.nulya/tui-crash.log`、App 心跳检测图死并故意打开 console overlay（renderer 级、里面正是被吞的错误原文）。下次再冻，crash log 里就是真凶的完整栈。

**终局（同日第三次冻结，crash log 拿到完整堆栈——tui.md T77）**：冻结前人眼可见的疯狂闪烁（回复在一小栏与全宽之间翻）就是 T76 每帧量宽的**反馈振荡**——量出的宽度喂给换行、换行改内容、内容改盒宽。每翻一次重建整卡 `<text>` 行，native TextBuffer 海量创建直到分配器给出 null：`createTextBuffer` 抛错（第一个受害者是正在渲染的 ErrorNotice——连报错都渲染不了），throw 在 `setStore` 传播中逃成 unhandledRejection、被 OpenTUI 吞掉、更新队列烂在半路，transcript 冻结。**根治**：宽度改为 pane 树派生的纯数字（`BodyWidthContext`，恒预留滚动条一列——内容对宽度没有投票权），`ui/measure.ts` 整个删除；T75 的 watchdog（前提已被活体取证推翻）一并删除；crashlog 与心跳保留。三次冻结、三层假设、每层都被下一份证据修正——最后立住的是：**别测量一个会被你的输出改变的东西**。

**真·终局（同日第四次冻结，无闪烁、2 分钟即死——tui.md T78）**：native TextBuffer 池是 u16（实测 **65,534** 个 live buffer 封顶，destroy 回收正常），而 `Transcript.tsx` 一个读了 `row()` 的 IIFE 子表达式让**每个流式 delta 重建每一张可见卡**——销毁排在 nextTick，一个 tick 内的 delta burst 把重建叠着推到池顶，`createTextBuffer` 抛错、graph 毒化、冻屏。这一条同时是缩团、高 CPU、GC 压力、「resume 大 session 死得更快」的总根。修法：IIFE → 惰性 props（Card 挂载一次、原地更新），burst 瞬时占用 10,080 → 0（回归测试断言代价与 transcript 大小无关，旧代码差值 50,400）；每行卡片加 ErrorBoundary（画不出的卡 = 一行错误，不再是冻屏）。四次冻结、四层修正，最终三样留下：crash log、心跳、这一行 props 写法——以及一条教训：**JSX 里不要写读响应式值的 IIFE 子表达式**。

18. 我发现ai每个edit似乎单独是一个step, 然后改一大堆没一会就到step上限了, 还要用户手动/step, 你看下这里是不是可以优化, 探索虽然不鼓励batch广泛搜索, 但是是不是修改这种应该建议一起修改

**已修（内核一个常数 + 三处 model-facing 文本 + 一处 driver policy，commit `2f119b5`）。** 证据是那一场本身（`tui/.nulya/sessions/s-…840504-de4328.jsonl`，140 个 assistant turn）：**121 个 turn 只有一个调用**，75 次 `edit` 的执行时间合计 **1.2 秒**（中位数 12 ms），而同一场的 29 次 `shell` 是 716 秒。也就是说 step 预算几乎全花在了「为一个 12 毫秒的调用买一次 model round-trip」上，两次撞上天花板、两次要人手动接。

**它不是"提示词没写"。** `extensions/coding/prompts/coding.md` 早就写了 "Put every independent call into ONE message"，而模型对 `read`/`grep`/`shell` **确实照做了**（seq 8–20 每 turn 5–7 个调用，验证期的 shell 也是 2–3 个一批）——**只有 mutation 塌成 1**。所以真正缺的不是鼓励而是一条事实：同一个文件的多个 `edit` 批在一起安不安全。它安全，两条都成立而两处描述都没说——批次串行执行且每个 `edit` 是独立进程从磁盘现读，所以区域不重叠时后面的 `old_string` 照样匹配；freshness 门也不挡，因为 `extensions/std/src/edit.zig:159` 每次编辑后按新 hash `recordRead`。旁证：那 75 次 edit **全部**是 `{path, old_string, new_string}` 形态、一次 `target_line` 都没用（用了才会因行号漂移而必须串行）、**0 次失败**——模型有能力批，只是不知道被允许。

**四处改动。**

**① 内核天花板 50 → 500**（`src/session.zig:23`，DESIGN §4）。tcode 的 `DEFAULT_MAX_STEPS` 就是 500，它的注释写着理由：这是**失控护栏而不是预算**，要设得高到正常工作永远碰不到它，**因为一个模型感觉得到的天花板会扭曲它的工作**。50 是感觉得到的。

**② 四个内置 persona 的 `max_steps` 全部删除**，跟着内核护栏跑（tcode 的四个 builtin 同样一个都没设）。这条是本次分析里损失最大的一个，单独记在 19。

**③ 预算真的用完时，runner 先要一次报告**（`extensions/agent/src/runner.zig` 的 `wrap_up`）。见 19。

**④ 三处 model-facing 文本**：`extensions/std/extension.json` 的 `edit` 描述加上"多个 edit 可以放进一条消息，包括同一个文件的多个"以及它们为什么不会互相干扰；`coding.md` 那条批量规则把**改动**点名进去（原来 "The batch runs serially, but…" 单读像是在警告 mutation 会互相干扰，而它想说的正好相反）；`extensions/agent/extension.json` 的 `name` 列出四个自带 persona——同一场里模型第一次委派就猜了个不存在的 `investigator`，花一个 round-trip 才被错误消息告知真名。

**为什么修法主要在描述而不在内核**：批量本来就被允许，缺的是让模型知道。tool description 也是这条纪律唯一该住的地方——同一场里探索期在 seq 22 就从 7 个/turn 塌回 1 个/turn（当时还全是 read/grep，离编辑期还早），说明放在 system prompt 最前面的高频纪律会被后面几十 KB 的 tool 输出稀释，而 tool description 离决策点最近。

19. （同一场里发现的）主 agent 委派给 explore，146 秒、73 次 read/grep，报告只有一句"the delegated session ran out of its step budget before saying anything final"

**已修（`extensions/agent`，内核零改动，同一个 commit）。** 用户没报这条——它藏在 18 的转录里。子场 `s-…855560-2aebc4` 探索得**很好**：12 个 turn、每 turn 4–8 个调用、共 73 次 `grep`/`read`/`glob`，正是想要的批量探索。然后 12 步用完，**12 个 turn 的 assistant text 全是空的**，471 KB 的 ledger 换回父场 0 bit——而父场随后自己从头又探索了 30 多个 step，同一件事买了两遍。

**根因是两件事叠在一起**：`explore.md` 的 `max_steps: 12` 撞上「模型看不见自己的预算」。persona 正文里没有一个字提到有上限（**也不该有**——那正是 18 ① 说的"感觉得到的天花板会扭曲工作"），所以模型按"探索到足够为止"的节奏走，不知道第 12 步之后没有然后了；而 `runner.zig` 看到 `stopped == "budget"` 就打一句罐头话，把整轮的发现连同最后一条非空 assistant text 一起丢掉。

**修法两条，都在 driver 层（physics #8）**：内置 persona 不再自带步数上限（一个 persona 尺寸的预算看着谨慎，实际是在调查中途把它砍断，而砍下来的东西全留在调用者永远读不到的 session 里）；预算真的用完且一个字都没说时，runner **发一条消息进去要报告**（"你的步数用完了，现在只用文字答、别再调工具，说清你确实查明了什么、哪些没来得及"）再驱动一轮，每个 task 只做一次，第二次还空才照实说。这条消息由 runner 发、不经 `main.deliver`，所以**不占 `max_exchanges`**——它不是谁说的一轮话，是 harness 去收已经付过钱的东西；走 `runners.send`，所以五个 arm（nulya / codex / claude / pi / ext）一份实现全覆盖。离线替身是新的 scripted 模式 `wrapup`（`launch.zig`：一直调工具永不收尾，直到看见那句话才用文字回答），e2e `tests/e2e/agent.zig` **验证过它在旧代码上会红**。

20. 显示 preparing editing 的时候是在做啥, 总感觉这也消耗了不少时间, 理论上zig edit应该很快吧

**不是 bug，是在等模型吐字，跟 Zig 无关。** `ui/WorkingStatus.tsx:95` 的 `preparing <tool>` 表示这个 call 已经开始从流里出来、但还没走到 `running`——也就是**模型还在逐 token 生成调用参数**，对 `edit` 就是 `old_string` + `new_string` 两段代码。数据对得上：那 75 个 edit turn 的 output token 中位数是 120，而 `edit` 本身执行时间中位数 12 ms、75 次合计 1.2 秒；`running edit` 那一瞬间快到看不见。**这也是 18 那条批量修法省下的第二样东西**：一条消息里连续吐五个 edit 的参数，比五次「生成参数 → 等 12 ms → 重新起一轮」快得多。

21. 模型报告的时候, 报告实时增加, 但是渲染的时候会闪烁

**已修（TUI 层，tui.md §11 T80；内核零改动）——正是 17 ③ 说的"再看到新的闪烁按新形状单独抓"。** 两个来源，一个是我们的，一个是 OpenTUI 自己写明的语义。

**① 我们这边（一轮跳一次）**：`render/cards/AssistantTurn.tsx` 用 `isPlainProse(text)` 在两条渲染路之间选——纯散文走 `hardWrapLines` + 一行一个 `<text>`（稳定：追加只改最后一行），出现任何结构（`#`、`- `、`1. `、fence、`|`）就整个交给 `<markdown>`。这个判断**每个 delta 重算一次**，而一份报告几乎一定在中途冒出第一个 bullet；那一刻 `<Show>` 把整个正文子树拆掉重建成另一种渲染，在 sticky-bottom 的 scrollbox 里就是整屏重排。判断是单调的（一旦出现结构就不会变回去），所以一轮只跳一次——不是持续闪的那一半。

**② OpenTUI 那边（持续闪的那一半）**：`Markdown.d.ts` 自己写着 `streaming: true` 的语义是「**尾部那个 block 保持不稳定**」，只有它前面的 block 稳定复用（`parseMarkdownIncremental` 的 `stableTokenCount`）。所以一段长报告在遇到第一个空行之前，**整篇就是那一个尾部 block**，每个 delta 重排一次。

**修法（用户提的，比我原来的好）**：我本来打算在最后一个**已闭合**的块边界自己切一刀，前半交给 `<markdown>`、尾部走 `hardWrapLines`。用户问的是「不能每隔多久重新渲染一次吗」——他是对的：切块是在这里养第二个 markdown parser，去对付一个形状其实是**频率**的问题。所以改成 `render/cards/AssistantTurn.tsx` 的 `sampled()`，`transcript.stream_interval_ms` 缺省 100 ms（`0` = 从前的行为），**只采样 markdown 那一支**——散文那一支本来就在追加下稳定，加时钟只会拿走它已有的顺滑。

**顺序是踩出来的**：第一版在 `streaming` 转 false 的同一次更新里 flush 最终文本，屏幕停在两个 delta 之前——探针查明 **OpenTUI 一旦 `streaming` 变 false 就不再接受 content 更新**（既有行为，把采样关掉也一样）。所以 `sampled` 返回 `{text, done}`，`done` 用 `queueMicrotask` 故意晚一次更新，卡片的 `streaming` prop 从 `!done()` 来：**先把内容交过去，下一拍再收尾**。回归测试 `test/sampled.test.tsx` 四条，其中"收尾当场 flush"那条正是抓到这个顺序问题的。

**还没目验**：机制与顺序由测试和探针钉住了，"看起来还闪不闪"要在真终端上看。`stream_interval_ms` 就是留给这次目验的旋钮——调大更稳，调 0 回到从前。
22. nulya tui 又卡住了, 之前应该会输出 crash 报告了

**已修（内核 + TUI；根因在内核）。** 一条工具输出里有**非 UTF-8 字节**，`std.json.Stringify` 就把它写成**数字数组**而不是字符串——`"output":[45,45,…]`——于是 session 文件不再是 DESIGN §3 的形状，而 TS 侧把 `output` 当字符串用的第一处（`render/runs.ts` 的 `foldsIntoRun` → `cancelMarkerOf`）当场 `output.startsWith is not a function`。

**触发它的字节**：模型在探 `shell` 到底跑的是哪个解释器，命令里带了一句 `cmd`，而 `cmd.exe` 的 banner 在中文 Windows 上是 CP936——`Microsoft Windows [\xb0\xe6\xb1\xbe …]`。同一个形状还有别的入口（`grep` 撞上二进制文件、后台任务 log 从字符中间截尾）。

**为什么是卡住而不是一行「card failed to draw」**：抛点在 `ui/Transcript.tsx` 的 `transcriptRows`，它在 **per-row `ErrorBoundary` 的上面**（那道 fence 只包一张卡）。于是 `state.applyEvent` 触发的重算一路冒到 driver 的 `for await`，driver `step.kill()` + `setError`——ledger 停在 seq 13，`rows()` 停在上一次好的值（截图里那三张卡还是 `(…)` 的未完成形态）。

**为什么没有 crash 报告**：`crashlog.ts` 只挂 `uncaughtException` / `unhandledRejection` / `render:error` 三个钩子，而这个异常**被 driver 自己 catch 了**，一个都没触发。屏幕上有消息，日志里没有栈——17 ③ 说的「子树死亡的哨兵是 crash log 自己」在这条路上是空的。

**四处修法，从根到叶**：

**① 内核（根因）**：`emit.zig` 多一条 guarantee——**返回的文本一定是合法 UTF-8**。新的 `emit.utf8Lossy` 在裁剪之前把非法字节逐个换成 U+FFFD，正文前面加一行说明换了几个，并且**当作一次 truncation**，所以原始字节照常落盘、footer 指得到。同一条纪律给 `task_finished` 的正文（`cli/task.zig`，`readLogTail` 本来就可能从字符中间开始读）；`presentation` 那一列与 `session append` 的正文则是**拒绝**而不是修复——工具输出已经发生了、只能修，而 presentation 是包自己的结构化主张、user turn 是人自己的话，两者拼不出来就等于没有。

**② TUI 的 wire 边界**：`parseEventLine` 不再无条件 `as LedgerEvent`——已知的字符串字段该是字符串（数字数组按 UTF-8 解回来）。这是「未知 **kind** 必须活下来」那条规矩的对偶：**已知字段的未知类型永远不该进渲染**。修了内核之后仍然要做，因为这之前写下的 session 还在盘上、还会被重放。

**③ 投影层要是全函数**：`transcriptRows` 包一层 try/catch，兜到「不分组的普通行」，让每张卡自己的 fence 去处理——一张读不懂的卡该赔掉一个 run summary，不是整块屏幕。

**④ 补上那条空掉的哨兵**：`crashlog.ts` 从 `ui/` 挪到 `src/`（它是进程级设施、和 UI 无关，而 `state/` 从不 import `ui/`），多一个模块级 `noteCrash`；driver / attach / tabs 六处 `setError` 收成一个 `reportFailure(state, source, error)`——**消息照旧上屏，栈进 `.nulya/tui-crash.log`**。

**测试**：`emit` 两条（合法输入零拷贝 / 修复+计数）+ e2e 一条（真子进程吐非 UTF-8 字节，断言 session 文件整体合法 UTF-8 且那条 `output` 是 JSON 字符串）+ TUI 两条（byte array 读回文本 / 读不懂的 call 只赔掉 run summary）；三条都**验证过在旧代码上会红**。

**那一场**：`tui/.nulya/sessions/s-1787918696336-f983.jsonl` 的第 13 条就地修好了（原文件留 `.bak`），可以直接续。
