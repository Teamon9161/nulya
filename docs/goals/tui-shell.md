# TUI shell — 宿主宪章、扩展 UI 的自由度模型、app 化方向

状态：**§1–§4 定稿，§5.4 的 S1、§5.3b 的 S1c 与 §5.3c 的 S1d 已落地**（pane 骨架 = tui.md T68，sessions 侧边栏 = T69，每 tab 一个 workspace = T71，sub-agent pane = T72）；**S2 / S3 待议**。
（2026-08-27 与 Fable 的设计讨论记录；实施日志在 tui.md §11，本文只写宪章与方向。）
这份文档回答三个问题：宿主该拥有什么（§1 宪章）、扩展前端的自由度怎么给才不打架（§2–§4）、
以及"把鼠标优先的 app 模式带进终端"这个大方向怎么切核心与扩展（§5）。
背景：tui.md 记到 T66，大量 policy 长在宿主里而 physics 保护不到它（CLAUDE.md 2026-08-27
"driver 成了第二个内核"那条批评）；同时预期将来复用 tcode app 作为另一个前端，
所以**押注协议边界与 surface 契约，不押注 Bun 宿主本身**。

## 0. 一句话总纲

"高自由度但不打架"不靠包之间的礼貌，靠两条结构性规则：**屏幕的每一块有唯一属主**；
**键盘焦点有单一仲裁者（宿主）**。自由不是画布自由（人人可画任何地方、靠 folklore 维持秩序），
是**槽位内的自由**（宿主拥有布局与导航，包在被授予的格子里为所欲为）。
冲突在结构上不可能发生，而不是被劝阻。细节爆炸是"包间协商"模型的产物：
所有做对了的系统都取消了协商——包只陈述事实，宿主用笨的确定性函数算布局，人有最终否决权。

## 1. 宿主宪章（host charter）

内核小是靠一把写下来的尺子在 review 时反复量（"删掉它哪条 physics 失效"）。宿主的尺子是这张表：
**宿主只许拥有四类东西，此外的每个新功能必须先回答"为什么它不能是包的 plugin"。**

1. **Trusted zone**：审批对话框、mode picker、贴 key、trust 问句、kill 开关——凡是被包仿冒即安全事故的。
2. **进程与会话 plumbing**：spawn `session step`、解析 `--stream`、tab / pane 生命周期。
3. **纯 ledger / journal 投影**：transcript、tasks、sessions——必须在包行为不端时仍然诚实的画面。
4. **Plugin loader 与布局仲裁**（§5 之后：window manager 本体）。

推论一（chrome 原则）：**凡是包行为的投影或权力的授予点，宿主独占**——`/ext`、`/provider`、
审批框、trust 问句。让包能画它们等于让被审计者装修审计室（浏览器的设置页不是网页）。
推论二：今天往 Bun 宿主里加的每一分 policy，将来都是别的前端（tcode app）复用不到的沉没成本。

## 2. 自由度三层

| 层 | 是什么 | 自由度 | 能不能打架 | 现状 |
|---|---|---|---|---|
| T0 声明式 | manifest：`commands[]`、`tools[].ui{render,panel}`、`policy` | 低 | 结构上不可能 | ✅ 已有 |
| T1 数据渲染 | `render(width)->Line[]` + theme token（卡片 / 面板内容） | 中 | 不碰事件循环、宿主排版，不可能 | ✅ 已有 |
| T2 独占面 | 包拥有的整页 / 整 pane：自己的 onKey、点击回调、完整内容区 | 高 | 靠属主 + 焦点规则约束 | ❌ 缺（tui.md T43 已点名缺 onKey 与点击回调） |

T2 只以**整面**为单位授予；包拿到键盘的唯一方式是人把焦点给它；Esc / Ctrl+C / trusted-zone
对话框永远属于宿主。**T0/T1 是数据契约、任何宿主都消费得起（可迁移到 tcode app）；
T2 是 per-host 代码，天然稀少**——所以能下推到 T0/T1 的都下推。

## 3. 五条"不打架"规则

1. **唯一属主。** 卡片归发起那次 tool call 的包（card renderer 只许画本包 tool——已有规则）；
   widget 只压过**同包**的投影（已有）。一句话：**升级自己的投影可以，触碰别人的不行。**
   不存在"全局装饰别人输出"的 API，永远不加。
2. **共享区域要么声明式合并、要么排队。** 状态 chip：包只声明、宿主画；panel：宿主排队
   （"trusted zone 在场时 open 只排队"——已有）；notice：单行队列（已有）。
   **任何共享条带都不给包直接画的笔。**
3. **命名冲突用 store roots 的老规则。** slash 链已是 内建 → 包 → skill、内建名永不被夺走；
   撞名 = 首个持有者胜 + 标 `shadowed`。一个规则处处用。
4. **降级即对话。** `ask` 立了先例（没插件时问题就在 ledger 的 tool 卡里、打字即答）。
   升成法条：**任何 T2 面必须有 T0/T1 降级**——UI 是增强、ledger 是真相。
   这条同时保住 replay、别的前端、以及 chip 被藏掉时的信息完整。
5. **排位是人的决定，不给包 priority 旋钮。** 给包一个用来抢位置的旋钮，旋钮本身就是打架
   （VS Code priority 数字军备竞赛）。默认 = 无聊的稳定序（戴上顺序或 id 字典序，挑一个），
   覆盖 = 人在 `tui.toml` 重排 / 隐藏 / 钉住。这是 `activation` 删除的同一个刀法：reach 归人。

## 4. Composer 区的具体语法（chip 模型，抄浏览器工具栏不抄 VS Code）

- **区域词表封闭、宿主定义**：`above`（输入框上方整行栈：审批框 > queue lane > 包 panel，
  按**种类**排不按包排）、`below-left`、`below-right`（chip 条带）。
  包声明"我要一个 below-right 的 chip"，不声明坐标、不声明第几个。
- **原子是受约束的 Chip，不是自由绘制**：`{glyph, text ≤ 12 字符, state token}`，宿主画。
  交互只有一种：点击 / Enter 打开这个包自己的 panel 或 T2 面。自由度全部住在点开之后。
- **每包每区域至多一个 chip**：N 个戴着的包 = 最多 N 个格子，上界天然有界。想展示三样东西？放进自己的 panel。
- **顺序**：稳定默认 + `tui.toml [ui] chips = [...]` 人的覆盖；没有 priority 字段（§3.5）。
- **溢出：截断 + `+k` 折叠，绝不换行**。宽度不够从队尾收进一个 `+k` 格子，点开是 picker。
  换行 = composer 高度随 chip 数抖动（T43 删流式光标偿还的正是这类债）。
  `above` 区是整行栈、垂直增长良定义，但同理每种类至多一个在场。
- **chip 是糖不是真相**：背后状态必须在某个诚实的地方本来就可见（ledger 卡、panel、`/ext`）。

泛化 checklist（任何"稀缺像素给谁"的问题过同五关）：
**原子统一化 → 每包一格 → 无聊稳定序 + 人覆盖 → 溢出折叠不换行 → 自由藏在点开之后。**
过不了的需求（"我要横跨整条"、"我要在别人前面"）不是布局问题，是这个包想要不属于它的 reach，答案是拒绝。

## 5. App 化方向：鼠标优先 + pane 平铺（Hyprland 式），核心 vs 扩展怎么切

动机（2026-08-27，用户）：不必像 claude code CLI 那样以"终端感"优先——完全可以把 app 的
交互模式带进终端：默认开首页 / 对话页，侧边栏按钮展开 session 列表点击切换，右侧同时开
终端 pane / 图片预览等；tcode 的 app 支持 Hyprland 式灵活分屏，体验很好，TUI 没理由不能有。

**判断：方向成立，而且它不与宪章冲突——tiling WM 就是槽位模型在整屏尺度上的同构**：
WM = 宿主，window = surface（T2 面），tiling 规则 = 争抢规则。鼠标这半其实已经开了头
（T28 悬停移光标 / 单击作答、T64 点击插队、SubSessionCard 可点行），跳跃在**布局**不在输入。

### 5.1 核心 vs 扩展的切法

- **核心（宿主）**：pane 树本体（split / focus / resize / tab / 平铺算法）、鼠标路由、
  trusted pane（`/ext`、`/provider`、审批）、session plumbing、pane 注册 API。
- **自带但不特殊**：transcript、sessions 侧栏、终端 pane、图片预览——作为**消费同一套公开
  pane API 的内置 surface** 实现（宿主自己当第一个 consumer，API 才诚实；`/plan` 是包的同一先例）。
- **扩展**：包的 T2 面（plan 评审、委派视图）、自定义预览器、额外工具面。

### 5.1b 边界：这不是在造终端复用器

担心（2026-08-27，用户）：这么做下去会不会自己实现出一个 ghostty / zellij / tmux？——担心成立，
所以边界写死在这里。**复用器的第一对象是任意终端程序（PTY pane）；我们的第一对象是 agent
workspace 的 surface**（transcript、sessions、包的 T2 面、agent 产物的预览）——结构化 widget，
不是 VT 字节流。复用器的复杂度大头（VT 解析、detach/reattach、任意程序的 escape 透传、
copy-mode）我们**一样都不需要**；pane 树本身（split/focus/resize 铺结构化 widget）在 OpenTUI
的布局之上是小几百行的量级。

**litmus test：一个 pane 类型如果放进 tmux、旁边没有 nulya 也照样成立，它就在边界的错误一侧。**
通用 PTY 托管明确是 non-goal：TUI 本来就活在一个终端里，用户自己的复用器 / Windows Terminal
分屏一个快捷键就有一个 shell 在旁边——claude code app 内嵌终端是因为 Electron 没有周边终端，
我们有。所以内嵌终端 pane 从 S3 **降级为"大概率永不做"**：先赌"用你自己的分屏"够用，
只有真实证据（用户反复要求、且外部分屏解决不了的具体场景）出现才重议；到那天也优先借库不自研。
图片预览留在 S3——它预览的是 agent 的产物，过得了 litmus test。

### 5.2 诚实的成本清单

- **平铺可以，浮动 / 重叠不行**（cell grid 的物理），恰好 Hyprland 主模式也是平铺。
- **内嵌终端 pane 已按 §5.1b 降级为 non-goal**（保留这行是给将来重议时的成本参考：
  PTY + VT 解析 / 终端模拟 widget，量级接近半个 tmux）。
- **图片预览依赖终端协议**（kitty graphics / sixel；OpenTUI 有 native images 支持，
  Windows Terminal 的 sixel 支持较新）——必须有降级（打不出图就给路径 + 打开系统查看器的动作）。
- **鼠标的终端税**：拖拽在部分终端笨拙；Shift+选中绕过 app 鼠标进 copy-mode 是用户习惯，别抢。
- **换来的独有优势**：SSH / 远程照常工作——这是 TUI 相对 Electron app 唯一不可替代的一点，
  也是"为什么不干脆只做 app"的答案。

### 5.3 与 tcode app 复用的关系

surface 契约设计成 host 中立（T0/T1 数据契约 + T2 面注册），则 TUI 的 WM 与 tcode app 是
**同一批 surface 的两个宿主**：WM 层各自实现（终端平铺 vs 真窗口），surface 随包走。
所以投资顺序：**先定 surface 契约（§2–§4），WM 保持薄**；tcode app 接入时摸清它
"前端 ⇄ agent 后端"的协议面，适配器厚度取决于那个协议（PLAN §3.11 / M8 的形状）。

### 5.3b 每 tab 一个 workspace（S1c）`[已落地 · tui.md T71]`

需求（2026-08-27，用户）：侧边栏最重要的用途是**跨目录**的对话——new 的时候能选目录，列表能看到别的项目的会话。
现状：一个 TUI 进程 = 一个 workspace（启动时的 cwd），session / store / trust / journal 全是 `.nulya/` 相对；
这正是 PLAN §4 挂着的"session 与 workspace 的关系"开放问题的前端半边。

**内核零改动**：session 本来就是"哪个目录下建的就属于哪个目录"，`nulya session *` 带着那个 cwd 跑就行；
TUI 侧 `Workspace` 已经是每个 CLI 调用的显式参数（`nulya/cli.ts`），只是被 `createTabStore(ws,…)` 收成了全局。要做的：

1. **tab = (workspace, session)**：workspace 从 store 级下放到 tab 级，所有 spawn 用本 tab 的 ws。
2. **draft tab 选目录**：默认当前 workspace；选择器是一个**极简目录浏览对话框**（2026-08-27 用户定的形状）——
   顶部一个路径输入框（可打字/粘贴，`~` 展开，Windows 盘符路径可用；边输入边把下面的列表换成该路径的内容），
   下面是列表：recent workspaces 一段（user 层记录）+ 当前路径的子目录一段，`..` 恒在子目录段首；
   **只列目录不列文件**、隐藏点目录（`..` 除外）、按名排序、含 `.nulya/` 的目录带一个"已是 workspace"的标记。
   单击/Enter 一个目录 = 进入它继续浏览；确认动作（如 Enter 在输入框、或一行 `use this directory`）= 选定。
   骨架走 `ui/Dialog.tsx` 或 overlay（按 §6 的两类面选一个，超屏要 scrollbox）；**不做**文件预览、多选、新建目录。
3. **recent workspaces 持久在 user 层**（`~/.nulya/` 下；`tui-state.json` 是 workspace 层的，装不下跨目录的事实——
   先例：`trusted-stores.jsonl` 因为同样的理由在 user 层）。
4. **侧边栏按 workspace 分组**：当前 workspace 的会话 + recent 段；选中一个 workspace 就对那个目录跑
   `session list --json`。sub-agent 过滤（T70）每组照用。
5. **无项目 session（2026-08-27 用户）**：只是问个问题、排查电脑，不需要任何项目目录也不需要 ground。
   **内核零改动**——任何目录都能当 workspace，做法是一个**专用的家 workspace** `~/.nulya/home/`
   （session / journal / scratch 都落在它的 `.nulya/` 下）。**不能直接拿 `~` 当 workspace**：
   `~/.nulya` 是 user 层，塌在一起会让 user extension store 被 trust gate 误认成未信任的
   workspace store 而拒开 session。TUI 侧三处：目录选择器**第一行是显式的 `no project` 选项**
   （在 recents 之前）；该 workspace 的 tab **跳过 `[extensions] session_prompts`**（ground 渲染的是
   项目地图与 git 状态，在这里全是空话——用户点名不要）；侧边栏这一组的标签写 `no project` 不写路径。
   其余（模型、扩展、审批、后台任务）与普通 session 完全一致。
6. **信任与开屏流程按 workspace 首次使用时走**：trust gate / `ext sync` / `.nulya/agents` 问句这些今天发生在开屏，
   改为发生在"第一个进入该 workspace 的 tab"上，拒绝显示在那个 tab 里。
7. 观察者 / `<id>.lock` / SessionBusy 语义不变（全是 per-session 文件的事实）。

### 5.3c sub-agent 视图从属于父 tab（S1d）`[已落地 · tui.md T72]`

需求（2026-08-27，用户）：从委派卡 `↗ open <id> in a tab` 开出来的 sub-agent 观察 tab 不该是 tab 条上的
平级兄弟——它从属于发起委派的那场对话。

**答案不是嵌套 tab，是 pane**：tab 条是水平的，画不好层级（缩进在横条上没有形状）；而 pane 骨架（S1a）
正好给了从属关系一个自然的家——**sub-agent 的观察 surface 以 split pane 打开在父 tab 内部**
（宽屏 row split、窄屏 column split），关闭 = 关 pane，关父 tab = 子 pane 一起走，tab 条上只剩顶层对话。
它过得了 §5.1b 的 litmus test（观察的是本对话委派出去的子场，离开 nulya 毫无意义）。
与 T70 的列表过滤正好互补：sub-agent 会话不进 sessions 列表，它唯一的呈现处就是父 tab 内的 pane。

实现要点：

1. **pane 树分两层**：app 层一棵（sidebar | tab 内容区），tab 内容区挂**当前 tab 自己的**一棵
   （每个 tab 记住自己的布局，切 tab 换树）——sidebar 是跨 tab 的、sub-agent pane 是 tab 的，
   两层各自都小，不做一棵大树里"哪些叶子跟着 tab 走"的标记。
2. 委派卡的 `↗` 默认开 pane；保留一个显式"开成 tab"的出路（全屏细看时用），或后续做 pane→tab 提升手势。
3. sub-agent surface = 现有 observer 模式的 transcript（只读跟随、`claimsKeyboard: true` 聚焦时可滚动），
   语义一概不变。
4. **UI 细节到实现时专门过一遍**（用户点名）：子 pane 要一眼读出"我从属于谁、我是只读的"——
   头一行归属（`⤷ <agent> · <d-id> · observing`，§6.3 的 `⤷` 正是 sub-session 的记号）、
   与父 transcript 的密度一致、分界线走 `hairline` 不画重框；快照进报告后再定稿。
5. 排在 S1c 之后（同一批文件）。

**落地记录（T72）**：两棵树一个 portal（app 树的一个叶 `host:tab` 用同一个 `PaneHost` 画出前台 tab 自己的树），
焦点只多一跳（`state/panes.ts` 的 `focusThrough` 是唯一知道它们嵌套的函数），方向移动由内往外。
点 2 的「显式开成 tab」落地成 **browse 的 `t`** 而不是卡上第二行（理由与取舍见 tui.md T72 的偏离那节）；
点 4 的 `observing` 是常量（它说的是这块 pane 只读，不是那一刻的租约角色）。
子 pane **不落盘**：观察面是临时的，恢复它等于替人做一个他没做过的决定。
pane→tab 提升手势仍未做——等第一个真实需求。

### 5.4 里程碑草案（未排期）

- **S1**：宪章落进 tui.md（§1–§4 定稿）；pane 树 + 焦点 + 鼠标路由进宿主，现有屏幕
  （transcript / `/sessions` / `/ext`）改挂成 pane——行为不变，只换骨架。
- **S2**：plugin API 补 T2（page/pane 注册 + 焦点内 onKey + 点击回调 + 降级声明）+ chip 模型；
  第一批 consumer = 把 agent 委派卡与 plan 评审面板迁进各自的包（验收："两个包各有 T2 面、
  互不知情、不打架"）。
- **S1c** `[已落地 · T71]`：每 tab 一个 workspace（§5.3b）——排在 T70 反馈修整落地之后（同一批文件）。
- **S1d** `[已落地 · T72]`：sub-agent 视图从属于父 tab（§5.3c）——两层 pane 树、委派卡的 `↗` 默认开 pane。
- **S3**：utility pane：图片预览（带降级）。内嵌终端不做（§5.1b）。
- 每步的尺子：加进宿主的每样东西对着 §1 四类过一遍；API 增补要有现成 consumer。

## 6. 相关记录

- 反应式扩展行为（watcher 协议）：PLAN §3.14——driver 中立的行协议，与本文的 surface 契约互补
  （watcher 说"包何时开口"，本文说"包画在哪"）。
- 内核批次钩子已明确拒绝，理由四条：PLAN §3.14。
- "driver 是第二个内核"的原始批评与本文动机：CLAUDE.md 2026-08-27 讨论。
