# Goal · tui-plugin：extension 长出前端面——声明层（commands / policy / render）+ 代码层（TUI plugin host）

> 这是一份**执行契约**，不是设计文档。现状在 [DESIGN.md](../DESIGN.md) §7.2.1（manifest 的声明字段：`readonly` / `audience` / `timeout_ms` / `activation`——kernel 解析、冻结、validate 点名坏值、**不 enforce**）/ §4（gate：allow / deny+note 一个语义）/ §9（trust gate 与 authority 诚实版）/ §11（handoff / fork）；TUI 契约在 [tui.md](../tui.md)（§4.4 slash、§5.7 approvals、§5.8 handoff 面板、§5.10 agent 的 readonly 天花板）；physics 在 [CLAUDE.md](../../CLAUDE.md)。
> **一个内核 track（U1，只有 manifest 字段）+ 一个 TUI track（U2–U4）**。铁律照常：改了内核语义同一个 commit 更新 DESIGN §7.2.1；TUI 改动记 tui.md §11（取下一个空的 T 编号，不进 DESIGN）。
> physics 定位一句话：内核只多几个**声明位**（包自己才答得出的事实：我给人提供哪些入口、戴上我意味着什么权限立场、我的 tool 怎么画、我有没有一段前端代码）——kernel 照旧一个字节都不 enforce，消费者全是 driver。"要不要显示一个计划面板"是前端的事，"计划本身"永远在 ledger 里。
> 本文件的决策来自 2026-08-20 的设计对话（pi / DeepSeek Harness 调研 + tcode plan 能力对照），已定的不要重开；认为错了写进 §6 BLOCKED 并停下。**每次 compaction 后先重读本文件，尤其 §6。**

## 0. 目标（一句话）

让一个 extension 包自己说出它的前端面：**声明层**（manifest：slash command、戴上后的收窄 policy、per-tool 渲染提示）任何 driver 都能消费、是降级地板；**代码层**（`contributes.tui` 指向包内一个 TS 模块，TUI 过 trust 门后加载进进程，拿一个窄的、版本化的、行渲染的宿主 API）承载真交互——计划评审面板（transcript 保持可见、面板占 composer 区）、实时 progress widget、askUser 式提问；写路径被"人已有的动词"收束、显示被 scoping 收束、审批/贴 key 等 trusted zones 宿主独占。验收物是两个真实 consumer：`extensions/plan`（tcode plan 模式的 nulya 分解）与 `extensions/ask`（tcode ask_user 的等价物）。

## 1. 决策（D1–D13，已定）

| # | 决策 | 内容与理由 |
|---|---|---|
| D1 | **两层，不是一层** | 声明层（U1/U2）：`contributes.commands` / `contributes.policy` / `ToolSpec.render`——JSON 就能写，headless driver（`drivers/goal.*`）也读得到，是没装插件时的降级地板。代码层（U3）：`contributes.tui`——交互深度（选区评论、流式面板、可折叠 progress）声明词表说不出来，避免不了。policy **必须**在声明层：权限立场不能只在有屏幕时才存在。 |
| D2 | **声明进 kernel manifest，不进 TUI sidecar** | precedent = `audience`（T34"一个 tool 是给谁的只有它的包知道"）：kernel 解析、冻结进版本、validate 管形状、不 enforce。一个 parser（T32 教训：两个 parser 就是同一个问题的两个答案）；冻结意味着"这一场当时的权限立场"事后可查；任何 driver 读得到。 |
| D3 | **policy 只许收窄，永不 `allow`** | 包能替人放行 = authority 隐式增长（physics #6；`mergeProject` 只能收窄的同款纪律）。形状：`{"readonly"?: bool, "deny"?: [...], "ask"?: [...]}`，条目与 `[approvals]` 同形（tool id / 名字 / `shell:<前缀>`）。生效条件：**该包是本场冻结 composition 的成员**（activate 的 always 包 = 每场；on_request / `--with` 戴的 = 那一场）。`readonly: true` 与 agent 天花板同位：三张表之前、不可上诉，拒绝走 gate `deny <note>` 模型读得到。`deny`/`ask` 条目并进对应表。 |
| D4 | **in-process 代码不是新 authority；新风险只有 UI 欺骗** | extension runtime 本来就在这台机器跑任意代码（`ext run`），trust 门（DESIGN §9）就是这个决定的边界，不设第二道门。要防的是画假审批框、截 `/provider` 的 key 粘贴：**trusted zones 宿主独占**（审批对话框、mode picker、`/provider` 的 key 输入永远宿主画、宿主收键盘）；插件面板带宿主画的归属标记（`◈ <pkg>` 机制现成），焦点在谁那里看输入框边框色（T26 信号复用）。 |
| D5 | **写路径 = 人已有的动词，仅此** | 插件改变世界只有：`append`（sentinel 包裹，`approvalnote.ts`/`midtask.ts` 先例）、`ext run`（driver tool）、开 tab、改 draft 的 `--with`。**没有**直接答 gate、没有写 session 文件、没有第二份真相。三类状态各归各位：模型该看见的 → ledger（计划=tool call 参数、评论=user turn、todo=tool 调用）；纯视图态（选区、光标、草稿）→ 插件内存，进程死了就该没了；偏好 → `tui-state.json` 按包 id 命名空间的槽。**重放一致性由构造保证**：面板只是 ledger+stream 的透镜。 |
| D6 | **计划评审不是全屏 overlay，是 composer 区的面板** | 评审时必须看得见 transcript 的上下文与模型的话。面板住 ApprovalPanel / handoff 面板那个位置（输入框上方/替换 composer 焦点），开着时拿键盘（`Ctrl+C` 除外，与 T28 同规），`Esc` 收起。**v1 不提供全屏 overlay 注册面**——第一个 consumer 用不上，没有 consumer 不建面（工作约定）。 |
| D7 | **propose / ask 类 tool 一律 handoff 形状，不阻塞** | tool 立刻返回"记录了，收尾吧"（`-32602` 纪律照 handoff），评审/回答发生在 turn 之间，答案作为下一条 user turn append。理由：不把 step 进程押在人的评审延迟上（extension timeout 天花板 600s）；headless driver 跑到这里不会卡死（问题在 ledger 里，人用任何前端都能答）；append-only 正好命中前缀缓存——每轮评论只付一轮增量。 |
| D8 | **命令来源 = activated 且 trusted 的包**；内建先到先得 | slash 表合并顺序：内建 → 包 commands → skill（T15 现序插入一层）。同名：内建永不被夺走（`commands.ts` 现有纪律）；包与包之间按 store roots"首个持有者胜"，输的 warn 点名。`wear` 动词在 draft tab 上就是改 draft 的 `--with`（D11 懒创建语义现成），版本走 `extensions.sessionMember` 那条 build-if-needed 路。 |
| D9 | **渲染契约是"行"，不是组件** | 插件的 card / panel / widget 都实现同一个小接口：`render(width) -> Line[]`（Line = 带 theme token 的 span 列表：`fg/muted/dim/faint/accent.*/ok/err/warn`）+ 可选 `onKey(key)`。宿主负责 CardFrame（glyph、头行、折叠）、布局、焦点、主题映射（NO_COLOR 白拿）。**刻意不暴露 OpenTUI/Solid**：没有单实例问题、没有版本 skew、AI 写起来是纯函数。够不够由 U4 的两个 consumer 验证；不够再议（§5）。 |
| D10 | **`contributes.tui = {entry, api}`，api 版本 warn-and-skip** | entry 是包内路径（build 时与 `system_prompts` 同款存在性检查），随版本冻结。TUI 只加载 **trusted 且是本场成员（或 activated）** 的包的 entry；`api` 主版本不认识 → 警告一句、跳过 UI 部分，包的其余贡献照常（agent 定义 warn-and-skip 同款纪律）。加载失败（语法错、抛异常）同待遇：一个坏插件不许拖死前端。 |
| D11 | **card renderer 只许注册本包的 tool** | 能重画别人的调用就是显示层欺骗（与 D4 同源）。command / panel / widget 天然带包归属标记。 |
| D12 | **render 提示是地板词表，reader 决定认不认识** | `ToolSpec.render`（如 `"checklist"`）kernel 只管是字符串、**值原样保留**（词表会长大，与封闭的 `audience` 不同——unknown 是 reader 的选择：退回普通 ExtToolCard 并 debug 一句，不是 build 拒绝；"absent is null, the reading is the reader's" 同款）。v1 词表：`checklist` | `markdown`。`panel: true`（ToolSpec 可选 bool）= 该 tool 最新一次调用的渲染同时投影成常驻 widget——没装代码插件的前端拿这个当 progress 的降级显示。 |
| D13 | **ask = 第二个 consumer，验证面板注册面的普适性** | `extensions/ask` 一个 tool `ask{question, options[], free_text?}`（handoff 形状），插件面板列选项（数字键/↑↓/Enter），答案 sentinel 包裹 append。tcode ask_user 的"模型半路问人、人选一个、答案回到对话"就此等价；headless 下问题躺在 ledger 里，人打字就是答。 |

## 2. 事实（写代码前先核对；行号是 2026-08-20 的，漂了以真码为准）

**内核侧**
1. manifest 声明字段的完整先例：`src/extension/manifest.zig` —— `ToolSpec.readonly/audience/timeout_ms`（:77–118）、顶层 `activation`（:177 附近，`InvalidActivation` :284）、`validate` 的纪律（:200 起；**类型错是 parse 错、封闭词表的值错是 validate 错**）、`contributes` 解析（:317 附近 `dupStringList`）、路径安全检查（system_prompts 拒 `../`，:777 测试）。新字段照这一套长。
2. `Manifest.validate` 有 `NoContributions`（:203）——`commands` / `policy` / `tui` 算不算"贡献"要明确：**算**（一个只贡献 command 的包合法）。
3. `ext api` 的 topic 文本在 `src/cli/ext.zig`（schema / permissions / examples）——U1 同 commit 把新字段写进 schema topic，模型才发现得了这个词表。
4. testkit（`src/extension/testkit.zig`）与 e2e 的 manifest 夹具会被新字段的 exhaustive 解析波及——跟着编译器走。
5. composition **不需要动**：policy / commands / render 全是 driver 读冻结 manifest（TUI 已在读：`<root>/<id>/versions/v-*/extension.json`，tui.md §2.1 表）。

**前端侧**
6. slash 分发与补全只读 `tui/src/commands.ts` 一张表（内建 → skill → 原样发模型，`skills.ts` T15）；插入"包 commands"一层就是在这条链上加一环。
7. approvals 决策序在 `tui/src/approvals.ts`（`decide` :157：deny → always → ask → **manifest_readonly && readonly → allow**（:163，注意：现状里 readonly 主张是"信了就免问"的 allow 方向）→ allow 表 → mode）；agent 的 readonly **天花板**（相反方向：一律拒）在 delegate/gate 接线处（`delegate.test.tsx` 钉着）。D3 的 composition policy 天花板与 agent 天花板同位——执行时先找到那一处，**两个天花板一处判断**，别写第二份。
8. composer 区面板的先例齐全：`ui/ApprovalPanel.tsx`（键盘归属、rowGutter、note 字段）、handoff 面板（§5.8：`Enter` 跟 / `Esc` 收）、`ui/ModePicker.tsx` / `ui/AgentPicker.tsx`（对话框视觉语言）。U3 的 `registerPanel` 抽象自它们，**不重写它们**（现有面板照旧硬编码，第二个 consumer 出现前不回迁）。
9. `render/registry.ts` 是唯一按 tool 名 match 的 choke point——render 提示与插件 card 的分派都落这里；卡片 dispatch on `CardKind`，加 kind 而不是加 if。
10. sentinel 先例：`approvalnote.ts`（allow-note 的 append + 一次性 contract + 卡片折回）、`midtask.ts`、`skills.ts` 的 `<user-skill>`（live 与 replay 同一 parser）。U3 的 `actions.append` 定一个通用 sentinel（形如 `<ext-note pkg="<id>" kind="<k>">`，具体格式执行者照 approvalnote 定），transcript 按它折。
11. worn 包与版本解析：`extensions.sessionMember`（bundledDraftPath → `ext build` → `--with`）；draft tab 的 `--with` refs 在 `state/tabs.ts`；`◈ <id>` chip 在状态栏（T31）。
12. `tui-state.json` 只有程序写（`state/tui_state.ts`）；插件偏好槽挂它底下一个 `plugins: {"<pkg>": {...}}`。
13. **Bun 单文件的动态加载要先验证**（U3 第一件事）：`bun build --compile` 产物里 `await import(<盘上绝对路径.ts>)` 行不行；不行的 fallback = 读文件 + `Bun.Transpiler` 转译 + module wrapper（TUI 本身就是 Bun，不需要外部工具链）。验证结果记 §6。
14. e2e 判"一屏"的行数预算（`tests/e2e/cli.zig` 的 help 行数上限）——U1 若动 `ext api` / usage 文本注意别撞。

## 3. 范围（按序 U1 → U4；每步测试全绿 + 文档同 commit，再进下一步）

### U1 · 内核：manifest 三个声明位 + `ext api`（唯一的内核步；解析冻结校验，零 enforce）

- `contributes.commands: []{name, description, action}`：`name` charset `[a-z0-9-]+`（validate 拒空与非法字符、包内去重）；`action` 是字符串，动词语法 `"wear"` | `"run <tool>"` | `"skill <ref>"`——**值原样保留**（词表会长，unknown 归 reader warn-and-skip；`run` 点名的 tool 必须是本包 manifest 声明的 tool，这条 validate 查——包内闭合的引用是形状不是词表）。
- `contributes.policy: ?{readonly: ?bool, deny: ?[]str, ask: ?[]str}`：validate 只管类型与条目非空；**没有 `allow` 字段，写了是 parse 错**（D3 的形状级保证）。
- `ToolSpec` 加 `render: ?[]const u8`（原样保留）与 `panel: ?bool`；顶层 `contributes.tui: ?{entry: str, api: u32}`——entry 与 `system_prompts` 同款路径安全 + build 时存在性检查；`api` ≥ 1。
- `NoContributions` 规则更新：有 commands / policy / tui 之一也算有贡献。
- `ext api` schema topic 补这三个字段的说明与最短示例；testkit / e2e 夹具跟上。
- **完成标准**：`zig build test` + `zig build e2e` 绿。新单测：round-trip（含全字段的 manifest parse → 各字段可读）、validate 各拒绝路径（坏 name、policy 带 allow、tui entry 越界路径、`run` 点名不存在的 tool）、缺省全 null 且老 manifest 逐字节兼容。DESIGN §7.2.1 同 commit 补三段（与 `audience` 段同格式：是什么、为什么是声明、consumer 是谁）。

### U2 · TUI：消费声明层（commands 进 slash、policy 进天花板、render 进 registry）

- **commands**：`extensions.ts` 读 activated+trusted 包的冻结 manifest 收集 commands（数据源与 `/ext` 同一条，不加进程）；`commands.ts` 的补全与分发插一层（内建 → **包** → skill）；三个动词各接现成路径：`wear` → draft `--with`（非 draft tab 上 = 开新 draft tab 并带上，notice 说明）、`run <tool>` → `ext run <id>@<冻结版本> <tool>`（余文作 args，形状由 tool 自己认）、`skill <ref>` → T15 的 `skillLoad + wrapSkillEcho` 原路。unknown 动词 warn-and-skip。同名 shadow 规则照 D8。
- **policy**：session attach 时从冻结 composition 的成员 manifest 收一次（draft 用计划中的 `--with` ∪ activated 集合预览）；`readonly: true` 并进 agent 天花板**同一处判断**（事实 #7）；`deny`/`ask` 条目并进 `approvals.decide` 的对应表（合并后传入，`decide` 本身不加参数就不加）。
- **render**：registry 认 `render: "checklist"`（tool args/result JSON 里 `items: [{text, state: "todo"|"doing"|"done"}]` 的约定形状，认不出退普通卡）与 `"markdown"`（body 走 markdown 渲染）；`panel: true` → 最新一次该 tool 调用投影成输入框上方一行可折叠 widget（WorkingStatus 旁、活动行之下；纯 ledger 投影，重放一致）。
- **完成标准**：`bun test` 绿 + 新测试：夹具包声明 command 三动词各一条走通（wear 改 draft、run 真跑、skill 折叠回显）、内建同名不被夺走、包 policy readonly 在 gate 上一律拒且 note 可读、deny/ask 条目生效、checklist 卡与 panel 投影快照、unknown render 词退回普通卡。tui.md §11 记一节（取下一个空 T 号）。

### U3 · TUI plugin host：加载 + 宿主 API v1（`nulya-tui/plugin-api` 的 `.d.ts` 是契约）

- **先做事实 #13 的验证**，结论与选型记 §6，再动手。
- **一切默认可关**（项目原则：核心极简，默认提供的都能关掉或换掉）：`tui.toml` `[extensions] plugins = true` 是代码层总开关（false = 只剩声明层，前端行为与 U2 结束时逐字节相同）；单个包关掉 = deactivate / 不 wear（加载条件本来就是成员关系，不另设第二张名单）。声明层同理：不 activate 就没有它的 command / policy / render。
- **加载**：对 trusted 且（activated 或本场 worn）的包，取冻结版本的 `contributes.tui.entry` 动态加载；`api` 主版本不符 / 加载抛错 → 一句 warn + 跳过（D10）。插件模块默认导出 `activate(api)`；每 tab 一份实例还是进程一份，执行者按最简定（建议进程一份、API 里带 tab 上下文）。
- **API v1**（`tui/plugin-api.d.ts`，同仓库 ship，英文注释；这是**唯一**契约，实现跟它走）：
  - `api.pkg: {id, version}`；
  - `api.registerCommand({name, description, run(args, ctx)})`（与声明层同名时代码版胜出——它是同一个包更有力的说法）；
  - `api.registerCard(tool, {render(view, width): Line[], onKey?})`——**tool 必须属于本包**（D11，违者注册即抛）；宿主给 CardFrame；
  - `api.registerPanel({render, onKey, onClose})` → 返回 `{open(), close()}`——composer 区、开着拿键盘（`Ctrl+C` 除外）、宿主画 `◈ <pkg>` 归属行（D4/D6）；
  - `api.registerWidget({render, onKey?})`——常驻可折叠行，位置同 U2 的 panel 投影（代码 widget 存在时压过同 tool 的声明层投影——天花板盖地板）；
  - `api.observe`：只读——`onStream(cb)`（类型化 StreamLine，含 `tool_use_input_delta`）、`onEvent(cb)`（ledger 事件）、`tasks()`、`session()`（id / 冻结 composition 投影）；
  - `api.actions`：`appendNote(kind, text)`（D5 sentinel + contract，折叠规则事实 #10）、`extRun(tool, argsJson)`（限本包 tool）、`openTab(sessionId)`、`wearNext(id)`；
  - `api.state.get/set`（tui-state 命名空间槽，事实 #12）；
  - `Line`/`Span`/theme token 类型（D9）。
- **trusted zones 断言**：审批对话框 / ModePicker / `/provider` key 输入在的时候，插件 panel 不能开、不接键盘（排队等）。
- **完成标准**：`bun test` 绿 + 新测试用一个**夹具插件**（tui/test 下的 .ts）钉住：加载与 api 版本 skip、坏插件不拖死前端、registerCard 越包抛错、panel 拿键盘与 Esc 收、widget 渲染与 NO_COLOR、appendNote 落 ledger 且 transcript 折回、observe 收到 stream 行、trusted zone 排队。`bun build --compile` 产物上手动验一次加载真实包（结果记 §6）。tui.md §11 一节 + `.d.ts` 顶部注释写清版本策略。

### U4 · 两个 consumer：`extensions/plan` 与 `extensions/ask`（全是包，内核零改动）

- **`extensions/plan`**（compiled 或 script，执行者按最简；`activation: "on_request"`）：
  - manifest：system prompt（计划纪律 persona）；`policy: {readonly: true}`；command `{name: "plan", action: "wear"}`；tools `propose{plan_md}`（handoff 形状，D7）与 `todo{items}`（`render: "checklist"`, `panel: true`）；`contributes.tui`。
  - tui 模块：propose 的流式 card（`tool_use_input_delta` 边到边画）；`done` 后 widget 亮 "plan ready · Enter to review"；**评审面板**（D6）：计划全文（从 ledger 读 args）、`j/k` 行移动、`v` 选区、`c` 行/选区评论（草稿在内存）、`r` = request changes → 评论拼**一条** sentinel user turn append（引文 + 评论，模型下一步读到改计划）、`a` = approve → 写 brief 文件走 `compact` 的 `brief_file` 分支 fork 到不戴 persona 的执行场（handoff 同款，复用 `compact.ts`）。执行场里 `todo` 的 checklist widget 即 progress（声明层已给降级）。
- **`extensions/ask`**（D13）：tool `ask{question, options[], free_text?}` handoff 形状；tui 模块一个 panel：选项列表（数字/↑↓/Enter、free_text 走 note 字段形状）→ 答案 sentinel append。没插件时问题在 ledger 卡片里、人照常打字——降级即对话。
- **完成标准**：`bun test` 加两条端到端（scripted / 夹具 ledger 驱动）：plan 流程"propose → 评审 → request changes 落一条 user turn → approve → fork 出执行场"离线走通；ask 流程"ask → 面板选择 → 答案落 ledger"走通；readonly 天花板在 plan 场上拒 `shell` 且 note 可读。`zig build e2e` 若加了包级 e2e 也绿。tui.md §11 一节；CLAUDE.md 现状一条（同 commit）；两个包各带 README 一段（中文）说明降级行为。

## 4. 明确不做（本 goal 内）

1. 全屏 overlay 注册面（D6；第一个 consumer 用不上）。
2. 审批对话框可插拔（trusted zone，D4）。
3. 通用 event-hook 总线（拦 tool call、改 prompt——内核有 gate 一个语义、TUI 有 approvals 一个政策点，不开第二个决定点）。
4. agent frontmatter `readonly` 与 `contributes.policy` 的归一（诱人：材料化时把 frontmatter 写成 policy——但动 T32 的读路径，等本 goal 落地后单独议）。
5. 插件间通信 / 插件依赖（dsh 的 service registry 那套；一个 consumer 都还没有）。
6. web / 其它前端的 plugin host（`.d.ts` 契约刻意不含终端专有概念，留门不施工）。

## 5. 开放问题（执行中遇到再定，记 §6）

1. D9 的行渲染对"选区高亮跨行"够不够用——U4 的评审面板是试金石；不够的最小扩展是 span 级背景 token，不是暴露组件树。
2. 声明层 command 与代码层 command 同名的胜出规则（现定：同包代码胜；跨包按 D8）。
3. `panel: true` 在多个 tool 同时声明时的排布（v1：按包序竖排，超两行折叠）。

## 6. 进度（执行者只追加，不改写上文）

> 格式：日期 · 里程碑 · 状态 / 关键决定 / 偏离 / 测试结果 / 给下一步的提醒。

**2026-08-20 · U1 · 完成。**
- **关键决定**：① `contributes.tui.entry` 与 `system_prompts` 走同一条 snapshot 路径——`integrity.collectPackageSnapshot` / `collectFrozenSnapshot` / `requireDeclaredPaths` 各加一个 `if (m.tui) |t|` 分支，`build_ext.zig` 新增 `validateTui`（逐字照 `validateSystemPrompts` 的存在性检查，跳过它的 UTF-8/大小检查——那两条约束的理由是"喂给模型"，tui 模块不是）；这不是装饰，是 D10"随版本冻结"成立的前提：没有它，`tui.entry` 声明了也没有字节可冻。② `policy.allow` 键的拒绝在 `dupPolicy`（parse 阶段）用一次 `contributes.policy.get("allow") != null` 判断实现，返回新 `ParseError` 成员 `PolicyAllowNotPermitted`，不留给 `validate`——契约原文如此。③ `Command.action` 只做一个形状检查：`"run "` 前缀提取出的 tool 名必须在本包 `tools[]` 里；`"wear"` / `"skill <ref>"` / 其它任何词一律放行，不做词表校验（词表归 U2 的 reader）。④ 顺手项：`store.isExtensionFault` 改成对 `manifest.ValidateError` 反射（`cli/ext.zig` 的 `isManifestFault` 同款写法），修掉了它原来手写 switch 漏掉的 `InvalidTimeout` / `InvalidAudience` / `InvalidActivation` / `DuplicateSkillPath` 四个既有漏判，新加一条反射式钉子测试（`store.zig` "isExtensionFault covers every manifest.ValidateError member"）确保以后新增的 `ValidateError` 成员不会再漏。
- **偏离**：① 契约提到 `ext api` 的 "schema topic"，但代码里只有 `protocol` / `permissions` / `examples` 三个 topic（没有字面意义的 "schema"）——把字段说明加进了 `permissions`（那里本来就是 `readonly` / `audience` / `activation` / `timeout_ms` 语义的落点），最短示例（一段 `contributes` JSON 片段）加进了 `examples` 末尾；没有新增 CLI 动词可以演示，因为这三个字段目前只是声明。② 新增了 `error.TuiEntryFileMissing`（build 时存在性错误，与 `SystemPromptFileMissing` 同级），登记进了 `cli/ext.zig` 的 `isDraftFault`（`ext sync` 用），但**没有**登记进 `store.isExtensionFault`——它只在构建期从 `validateTui` 抛出，`openVersion` 的结构校验路径（`requireDeclaredPaths`）对同一缺失抛的是既有的 `VersionPackageMissing`，与 `SystemPromptFileMissing` 原本就不在 `isExtensionFault` 里同一先例，不是遗漏。③ 没有触碰 `cli/ext.zig` 里那份硬编码错误名单的测试（"every manifest parse/validate error is a draft fault"）——它示范性列出错误名，不是穷举钉子，新增的六个 `ValidateError` 成员没有必要补进去；真正的穷举钉子按契约要求加在了 `store.zig`。
- **测试结果**：`zig build test` 461/463（2 个跳过，与本次改动无关的既有 skip）绿；`zig build e2e` 72/72 绿；改过的五个文件（`manifest.zig` / `store.zig` / `integrity.zig` / `build/build_ext.zig` / `cli/ext.zig`）跑过 `zig fmt`（三个文件被自动改了缩进，diff 只含本次新增的代码块，无意外改动）。新增单测：`manifest.zig` 八条（round-trip 全字段、命令名字符集与去重、`run <tool>` 闭合引用校验、policy 的 allow-拒绝与空条目拒绝、tui 路径越界与 api=0、三个字段各自单独满足 `NoContributions`、老 manifest 字节兼容 + 新字段缺省 null/empty）；`store.zig` 一条反射钉子。DESIGN.md §7.2.1 同 commit 补了 JSON 示例（三个新字段）、校验规则汇总句、`render`/`panel`/`commands`/`policy`/`tui` 五段说明（各自是什么、为什么是声明不是强制、consumer 是谁），格式对齐 `audience`/`activation` 现有段落。
- **审阅修正（编排者，同日）**：U1 交付的 `isExtensionFault` 反射只盖 `ValidateError` + 手列四个 parse 错——而它自己新增的 `PolicyAllowNotPermitted` 是 **ParseError** 成员，第一天就漏在名单外（漂移重演）。改成反射 `manifest.ParseError || manifest.ValidateError` 并在循环里显式跳过 `OutOfMemory`（`Allocator.Error` 随 `ParseError` 搭车，OOM 是 host fault）；钉子测试同步走两个集合并加一条 `!isExtensionFault(error.OutOfMemory)`。
- **给下一步（U2）的提醒**：`Command.action` 在 kernel 层只保证 `run <tool>` 的引用闭合，`wear` / `skill <ref>` 完全没做语义检查——TUI 侧接这三个动词时要自己认词表、对未知动词 warn-and-skip；`contributes.tui.entry` 现在只是"存在且冻结"，U3 才会真的加载它，`api` 主版本比较（不符则 warn-and-skip）还没有任何代码；`ToolSpec.render` 的具体渲染约定（`checklist` 期待的 `items:[{text,state}]` 形状等）留给 U2 的 registry 消费者去定义，kernel 侧只保证这个字符串被原样冻结、原样读回。
