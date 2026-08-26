# Goal · ext-syntax：`surface` 三个新词、缺省 `auto`、包级 `apply`、legacy 全删（2026-08-25）

> 这是一份**执行契约 + 落地记录**，不是设计文档。地图和 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §5.1 / §7.2.1 / §7.8 / §14。
> 前两轮是 [ext-review.md](ext-review.md)（surface / wire / 三层听众）与 [ext-review-2.md](ext-review-2.md)（`activation` 删除、manifest 瘦身），本轮接着它们。
> **项目 pre-release，本轮明确不要向后兼容**：旧语义的兼容代码一并删净，不打补丁。

## 0. 结论（一段）

两轮评审之后 manifest 的**结构**已经对了（三层听众、两根轴、一种 wire），剩下的是**词**和**缺省**两处不对：

1. **`surface` 的三个词是按机制命名的，不是按问题命名的。** `pin` / `with` / `driver` 各自指向一条 CLI 路径（`--pin` / `--with` / `ext run`），于是同一个词在两个位置意思不同——`--with` 是一个动词（"把这个包组合进来"），`surface: "with"` 是一个属性（"我随成员上台"），而 `pin` 既是名词又是动词。新的三个词 `auto` / `manual` / `internal` 回答的是同一个问题：**这个包已经是成员了，这个 tool 怎么到模型面前**。
2. **缺省 `pin` 是历史包袱。** 它是 `surface` 这个字段出现之前的兼容值（那时"model-facing 且可 pin"是唯一的形状）。今天它的效果是：`nulya ext init` 脚一个扩展出来、build、activate、`--with` 进一场——**模型看不见它**，还要再学会 `--pin ext:<id>/<tool>` 这条第二条路。缺省应该是 `auto`：一个人特意组合进来的包，它的 tool 就是他想用的那些。
3. **manifest 说不出"装上我意味着什么"。** `activation` 被删是对的（reach 是人的决定），但它删掉的是**否决权**（默认在每一场里，包写 `on_request` 才退出来）。反过来那一半——一个纯 system prompt 的"模式"包，装上就是要它在每一场里——今天要人在 config 再写一行 `[extensions] with`，而这一行与"装它"是同一个意图的两半。`apply: "auto" | "manual"`（缺省 `manual`）给成员那根轴一个**作者写的缺省**，而人两个方向的覆盖都还在（加：`[extensions] with`；撤：`ext deactivate`）——所以它不是 `activation` 回来了。

## 1. 已定决策

### A · `surface` 改名 + 缺省变更

- **`Surface` = `auto` | `manual` | `internal`**（原 `with` / `pin` / `driver`）。`fromString` **只认这三个**；旧词与任何别的词一样是 `InvalidSurface`。
- **缺省 `auto`**（原 `pin`）。`ToolSpec.surfaceOf()` 无字段时回 `.auto`；这是一个**缺省**不是"没说"（与 `readonly` 的 `null ≠ false` 相反：每个 tool 都有一个位置，没有让 null 表示的东西）。
- **`Audience` 整个删掉**：enum、`ToolSpec.audience`、`audienceOf`、`surfaceOf` 里的折叠、`InvalidAudience`。`audience` 从此是普通未知键。
- 消费者：`composition.zig`（`!= .with` → `!= .auto`、`fresh_pin ... != .pin` → `!= .manual`）、`cli/session.zig` 的 `PinToolNotPinnable` 文案、`cli/ext.zig` 的 `ext api manifest`、`store.zig` 的注释。
- 自带八个包：`{handoff, ask, plan}` 的 `"with"` → `"auto"`；`{plan, agent}` 的 `"driver"` → `"internal"`；`compact` 的 `"audience": "driver"` → `"surface": "internal"`；**`std` 六个 tool 各显式加 `"manual"`**（它们靠 `pinned_native_tools` 上台，缺省变了不写就不可 pin）；**`agent/agent` 也加 `"manual"`**（同一条理由：它由 driver 每次 `--pin` 决定带不带，缺省 `auto` 会让 `--with agent` 自动带上它，而那条 pin 会变成 `PinToolNotPinnable`）。
- **模板不写 `surface`**（缺省 `auto` 正是想要的）：`ext init` 脚出来的扩展 `--with` 一下就在模型面前。`ext api examples` 的走查因此从 `--pin` 改成 `--with`，`--pin` 留一条单独的、点名 `surface: "manual"` 的例子。

### B · 包级 `apply`

- **manifest 顶层**新增可选 `apply: "auto" | "manual"`（缺省 `manual`），闭合词表，别的词是 `InvalidApply`。顶层而不是 `contributes` 下：它不是一项贡献，是作者对"装上我"的解释。随 manifest 一起冻结（它就在 manifest 里）。
- **`composition.resolveFreshExtensions` 的第三个成员来源**（`resolveApplyAutoExtensions`），**排在最前**所以点名的能覆盖它（`unionWith` 后者胜）。
- **两段式读**，这是本条的核心设计：`Roots.listActive` 拿到每个有 `current` 的 id（首个持有者胜）→ 对每个**只读一次冻结的 `extension.json`**（新的 `Store.readVersionDeclaration`：parse + validate，**不查 seal / 不重算 digest / 不查声明路径**）问 `apply` → 只有答 `auto` 的才走一次普通 `.sealed` 解析真正进 composition。理由：一屋子普通包的代价是每个一次小文件读；而**一个坏包不会因为这台机器"持有"它就让每一场 session 起不来**，那正是当年 discovery 被删的原因。
- **失败纪律**：说了 `auto` 而 `current` 解析不出来 → `ActiveExtensionBroken` 硬失败，stderr 点名版本 + 两条出路（`ext activate <id> <older>` / **`ext deactivate <id>`**，后者是这一层特有的修法）。**manifest 都读不出来 → 跳过**（什么都没主张过，也没人点名）。
- **`session new --bare` 关掉整层**（`composition.Options.apply_auto = false`）。
- **header schema 一个字节不变**：header 记的是解析后的成员，`apply:auto` 进来的与 `--with` 进来的逐字节同形；resume 路径零改动。
- **投影**：`ext list` 的 `[tools skills prompt]` 括号里多一个 `standing`；`ext inspect` 打的就是 manifest 原文，`apply` 自动在里面。
- **`ext activate`** 对 `apply:auto` 的包在 stderr 多说一句后果 + 指 `ext deactivate`（只在这份拷贝**真的生效**时说，与 capability note 的投递条件同一判据）。先例是 `activate --user` 的跨 workspace 提示：不拦，但不许悄悄发生。
- **`ext sync --activate` 永不激活一个 `apply:auto` 且当前无 `current` 的包**：`--activate` 是一次对一整个目录的批量便利，而"打开一个模式"不是批量决定（T31 那个 bug 的同一条理由）。被跳过的在自己那一行说明并给出显式命令。已经有 `current` 的不属于这一档（它已经常驻，移指针改的是版本不是 reach）。
- **trust gate 不变**：`apply:auto` 不绕过任何门。

### C · legacy 全删

- 删 `Manifest.legacy_activation` / `legacy_permissions` / `legacy_command_action` / `legacy_ui` / `legacy_wire` 五个字段与它们的解析；删 `build_ext.noteLegacyShapes` 与调用点。`activation` / `permissions` / `runtime.wire` 从此就是普通未知键，**build 一个字都不说**。
- 删 `commands[].action` 的字符串小语言（→ `WrongType`）；删 `contributes.ui` 的平铺形 `{entry, api}`（→ `WrongType`，读成"一个叫 `entry` 的宿主"）。
- `ext api` 的 `permissions` 旧 topic 名删掉，只留 `manifest`。
- 理由（写进 DESIGN §7.2.1 文末）：一个版本期的成本是**每个读 manifest 的人同时装两种形状**，而收益的对象不存在——仓库外还没有人写过 extension，仓库内的八个自带包与两个模板每次一起改。这是 §7.3 删掉 jsonrpc 那条路时的同一把尺子。

## 2. 不做

- 不改 header schema（`composition.active` 的键名照旧）。
- 不改 `pinned_native_tools` / `[extensions] with` 的名字或语义。
- **不碰 `tui/`**（前端跟随由主会话另行安排，见 §4 的遗留项）。
- 不给 `apply` 加第三个词（`never` 之类）：`manual` 已经是"只有点名才进"，而"永远不进"没有 consumer。
- 不为 `apply:auto` 造第二种 header 记法或第二种 resume 路径。

## 3. 落地记录（2026-08-25）

- **A · surface 三个词 + 缺省 auto** ✅ `manifest.zig`：`Surface{auto,manual,internal}`、`surfaceOf` 缺省 `.auto`、`Audience` / `ToolSpec.audience` / `audienceOf` / `InvalidAudience` 删除。`composition.zig` 两处判断 + 模块注释 + `Options` 文档；`cli/session.zig` 的 `PinToolNotPinnable` 文案改指 `--with`（tool 是 `auto`）/ `ext run`（tool 是 `internal`）。八个自带包按 §1 A 更新（含 `std` 六个与 `agent/agent` 的显式 `manual`）。模板不写 `surface`。
- **A · 一处新推论** ✅ `composition.isFullMember`：`surface:"auto"` 只对**完全成员**展开——被人点名的（`opts.with`）或自己声明 `apply:"auto"` 的；pin 蕴含进来的那个成员**不是**完全成员（那条 pin 要的是一个 tool）。从前这个判断写成"遍历 `opts.with`"，现在多了第二种完全成员，所以抽成一个具名判据、`resolveFreshBindings` 改成遍历 `resolved` 一次。
- **B · `apply`** ✅ `manifest.Apply` + `Manifest.apply`（顶层，as written）+ `applyOf()` + `InvalidApply`；`Store.readVersionDeclaration`（无 integrity 的声明读）；`composition.resolveApplyAutoExtensions` + `reportBrokenApplyAuto` + `Options.apply_auto`；`cli/session.zig` 的 `--bare` 关掉它；`cli/ext.zig` 的 `contributionMarker` 加 `standing`、`noteStandingMembership`（activate）、`declaresStandingMembership`（sync 跳过）。
- **C · legacy 全删** ✅ 五个 `legacy_*` 字段、`legacyWire`、`noteLegacyShapes` 与 `build_ext.zig` 里 `builtin` 的最后一个用处；`dupAction` 的字符串分支、`dupUi` 的平铺分支；`ext api` 的 `permissions` 别名。
- **D · 测试** ✅ `manifest.zig` 单测重写（surface 三词 + 旧词被拒 + apply 两词 + 退役键是普通未知键）；`composition.zig` 单测按新词改名与改值，`writeToolExtension` 这个**pin 夹具**显式写 `manual`；e2e：`support.fixtureManifestJson` / `gate_pin.buildScriptPackage` / `extension.scaffoldAndBuildScript` / `script_wire` 的 `elsewhere` 四个 pin 夹具显式写 `manual`，`script_wire` 的 wire 走查与 `extension.zig` 的 handoff / plan 走查改成 `--with`（那些包的 tool 是 `auto`），退役键的 e2e 从"build 说一句"改成"build 什么都不说"。新增 `tests/e2e/ext_cli.zig` 的四条 apply 覆盖。
- **E · 文档** ✅ DESIGN §5.1（成员三条来路 + `apply` 语义与立场 + resolver 的两段式代价 + 更新后的表 + `--bare` + header 不变）· §7.2.1（`surface` 三词与缺省、顶层 `apply`、validate 清单、删掉 `audience` 段、新增文末"曾经有、为什么退场"表）· §7.8（八个包的 surface 现状）· §14（`ext api` 三个 topic、`--pin` / `--with` 两条、mode 三种投放）；`extensions/guide/skills/guide/SKILL.md`（surface 三词、`apply`、两根轴那段、mode 那条、最短配方多一行 `--with`）；`cli/ext.zig` 的 `ext api manifest` / `examples` 内嵌文本。**CLAUDE.md 由主会话统一更新**（本 lane 不动）。

- **F · 收尾（同日第二轮）** ✅ `ext api manifest` 的 driver 声明段与 kernel 段重排（删掉旧 `audience` 那半留下的断行）；`cli/common.zig` 的一屏 usage 两行——`--bare` 改成"三张常驻表一张都不读"、`ext deactivate` 点出它同时关掉 `apply: auto`。仓库里最后一批旧词：`extensions/{handoff,ask}/src/main.zig` 与 `ask/README.md` 的 `surface: "with"` → `"auto"`、`extensions/plan/{src/main.zig,README.md}` 的 `"driver"` → `"internal"`（这三个包的 draft 因此换 version id，符合预期）；DESIGN §11 的 handoff 那条与 `drivers/goal.*` 那条不再写 `--pin ext:handoff/handoff`（它的 tool 是 `auto`，一个 flag 就够）；PLAN §3.4.1 / §1 M2c / §3.3 三处"`--pin` 的第一个真实 consumer"改成今天的真实名单（`std` 六个 + `agent/agent`）并注明修正日期。
- **G · 新增 e2e** ✅ `tests/e2e/ext_cli.zig`：`apply: auto` 的包 `current` 坏掉 → `session new` **硬失败**且 stderr 点名 id / 版本 / `apply: auto` / `ext deactivate <id>`，而同样坏掉、但没说 `apply` 的包**照旧被跳过**——这正是两段式读（`Store.readVersionDeclaration` 无 integrity，只答"你说了吗"）买来的那条性质，之前只有设计文档说，没有钉子钉住。

## 4. 遗留（本 lane 不做，交主会话）

- **`tui/` 跟随**：`tui/src/nulya/files.ts` 的 `toolSurfaceOf` 仍认 `pin` / `with` / `driver` 并把别的词折成 `pin`，所以新词下 `pinTools` / `withTools` / `driverTools` 三个投影全错（都落进 `pinTools`）；`Contributions` 也还没有 `apply`。`/ext` 的 tools pane 与 T33 的 driver 折叠都读这三个投影。
- **`--with X --pin ext:X/tool` 这个组合在 TUI 里已经是坏的，与本轮无关**：`7b1612f`（improve tui）把 `handoff` / `plan` 的 tool 改成 `surface: "with"` 时没有同步 TUI 与 e2e，于是 `tests/e2e/extension.zig` 的 handoff / plan 两条在本轮之前就是红的（实测 `git stash` 后仍红）。本轮把那两条 e2e 改成 `--with`（正确的新写法）；TUI 侧 `tui.toml [extensions] session_with` 那条路径仍会传一个会被拒的 `--pin ext:handoff/handoff`，修法是删掉那个 pin。
- ✅ 两条都已由主会话落地（tui.md T52 / T53）。**§1 A 关于 `agent/agent` 那句话被推翻了一半**：它当时写的是「`agent` 的入口 tool 加显式 `manual`，因为带不带它是 driver 每次的决定」——而 `--with` 已经把那个决定说完了（那个包对模型面的**全部**贡献就是这一个 tool），membership 之外再要一根 pin 只是同一句话说两遍。T53 把它翻成 `auto` 并删掉三处 `--pin ext:agent/agent`。留在 §1 / §3 里的原话不改：那是当时的判断，记录不因后来的修正而重写。

## 5. 本轮之后的修正（外部 review，2026-08-26）

一份外部 review 读了 §1 B 落地后的代码，指出两处。两处都不是新功能，是把这一轮已定的语义**做对**，内核 physics 一条未动。

### 5.1 `ext sync --activate` 回归字面语义 ✅

§1 B 最后一条（"`ext sync --activate` 永不激活一个 `apply:auto` 且当前无 `current` 的包"）**推翻**。守卫删掉：`--activate` 现在真正激活它动的每一个 id，`apply:auto` 的包不例外，并在 stderr 说 `ext activate` 那同一句后果 + `ext deactivate`（`cli/ext.zig` 的 `noteStandingMembership` 现在两个调用点共用；`declaresStandingMembership` 随之删除）。两条理由：

- **那条守卫有洞，且是个堵不上的洞。** `apply` 是**版本化**字段，而守卫只看"现在有没有 `current`"：v1（`manual`，已有 `current`）→ v2（`auto`）的升级从"已经有 current"那条分支照样走进每一场 session，反向（`auto` → `manual`）也悄悄退出。代码注释里"moving the pointer changes the version, not the reach"这句话跨 `apply` 变化时是**假的**。
- **认错了对象。** `--activate` 是人打出来的一个 flag，不该变成"激活除了 `apply:auto` 以外的东西"。T31 真正要防的是**前端无人值守的后台 sync**，而有这个问题的那个前端（TUI 开屏那趟）自己带着 `extensions.autoActivatable()` 守卫——policy 在 driver，不在内核的动词里。

e2e 从"断言拒绝"改写成"断言激活 + 告知行 + `deactivate` 之后下一次 sync 把它开回来"（`tests/e2e/ext_cli.zig`）。

### 5.2 `apply:auto` discovery 不再读一个没有 integrity 的 manifest ✅

§1 B 的**两段式读**（`Store.readVersionDeclaration`：无 seal、无 re-digest 地读冻结的 `extension.json` 问 `apply`）有一个不对称的缺口：把一个**已激活的 `apply:auto` 包**的冻结 `extension.json` 篡改/损坏成 `manual`（或改成解析不出来），discovery 就静默跳过它——**corruption 能悄悄关掉一段常驻 system prompt**，任何一环都不报错；反方向（`manual` 改成 `auto`）反而会进 `.sealed` 校验被抓。

**采纳 review 的第一条路（activate 时记录），第二条（廉价 per-file digest）不可行**：`seal.json` 只有整棵树的 `package_digest`，而它唯一的锚是"重算出来的版本 id 必须等于版本目录名"（`integrity.openVersion`）——没有 Merkle 结构，单独验 `extension.json` 一个文件锚不到任何东西，往 seal 里加一列 `manifest_digest` 也只是加一个同样可被一起篡改、且谁都证明不了的数。

落点选了**扩展 `current` 文件本身**而不是旁边加一个小文件：`<id>/current` 从 `v-<hash>` 变成 `v-<hash> apply=<auto|manual>`，由 `activate` 在 `.sealed` 校验之后、**同一次原子 rename** 里写下。一个文件的好处不是省一个 inode，是**没有第二个状态要维护**：不存在"记录写了、指针没写"的崩溃窗口，不存在记录与指针不同步的陈旧类，`deactivate` 一如既往只删一个文件。

- `store.Active{version, standing}` + `Store.readCurrent`（唯一读 `current` 的地方，`activeVersion` 成了它的 wrapper）；`Roots.ActiveEntry` 多带一位 `standing`，来自 `listActive` 那次本来就要做的读——**这一层因此一个字节都没变贵**。
- `composition.resolveApplyAutoExtensions` 只信记录：`standing` 为真才走 `.sealed`。两条既有性质都保住了——没被记录的坏包（含坏 `manual` 包）**只跳过、不挡 session**；`manual` 被篡改成 `auto` **授不了 reach**（没人问它）。新增的那条：被记录的包一旦被动过，`.sealed` 当场失败 → 响亮拒绝（`reportBrokenApplyAuto` 原样复用）。
- `Store.readVersionDeclaration` 删除（三个调用点全部消失）。`ext list` 的 `standing` 那一列也改读记录（`contributionMarker` 的 `entry.standing`）：那一列答的是"这一场会不会有它"，而这个答案从此只有一个来源。
- **旧 store 的语义写明白**：没有 `apply=` 列的 `current`（这一列出现之前写的）读作**不常驻**——unknown 不是主张——修法是重跑一次 `nulya ext activate <id> <version>`。pre-release，不为它造迁移。
- e2e 新增两条（`tests/e2e/ext_cli.zig`）：已激活 `apply:auto` 包的冻结 manifest 被改成 `manual` / 改成非 JSON → `session new` 硬失败并点名 id / 版本 / `ext deactivate`；`manual` 包的冻结 manifest 被改成 `auto` → 不进 session、session 正常开。单测一条（`store.zig`）钉住记录的读写与"编辑 manifest 改不动记录、但会让 `.sealed` 失败"。

### 5.3 两条 design debt（**2026-08-26 两条均已落地**）

原文是"记录，不实现"。同日主会话把两条都做了，内核 physics 一条未动、freeze schema 一个字节未变。

#### prompt position ✅

`contributes.system_prompts[]` 的条目从纯路径扩成 `"path"` 或 `{"path", "position": "early"|"normal"|"late"}`。

- **落点**：`manifest.PromptPosition` + `manifest.SystemPromptSpec`（`path` + as-written 的 `position` + `positionOf()`）+ `Manifest.system_prompts` 换成 `[]const SystemPromptSpec` + `dupSystemPrompts`（string 或 object，别的是 `WrongType`）+ validate 的 `InvalidPromptPosition`（闭合词表，`surface` / `apply` 的同一条纪律）；`composition.buildSystemPrompts` 的 extension 那一段从一趟遍历变成 early / normal / late **三趟**（同一段内保持既有成员顺序，稳定性由构造保证而不靠排序函数）。裸字符串形永远合法（= `normal`），八个自带包一个字都没改。
- **作用域只有一个**：extension 那一带内部。kernel 块仍最前、inline `--prompt` 仍在全部 extension 之后、`skills:catalog` 仍最后（DESIGN §5.6）。
- **不动 freeze schema、不动 membership**：`position` 就在 manifest 里，随版本一起冻结，所以 fresh 与 frozen 两条路跑同一段代码读同一批字节。
- 消费者跟随：`integrity.zig`（三处）、`build_ext.validateSystemPrompts`、`cli/session_list.zig` 的投影、`tui/src/nulya/files.ts` 的 `promptPathList`（只取 path，TUI 只数数与显示 source）。
- 钉子：`manifest.zig` 一条单测（两种形 + 缺省 normal + 拼错的词被拒 + 路径规则与去重跨两种形仍生效 + 数字条目是 `WrongType`）；`composition.zig` 一条单测（id 序与 position 序相反 + fresh/frozen 逐块相等）；`tests/e2e/extension.zig` 一条（真实二进制建三个包，**id 排最后的写 `early`、排最前的写 `late`**，fresh 与 resume 的 blocks 逐字节相等）；`tui/test/files.test.ts` 一条（两种形都投影出 path）。

#### pin 蕴含成员的"半成员"不对称 ✅ ——**取消半成员，成员一律全员**

- **定稿规则**：成员 = 一组 (id, version)，**来源不影响权利**。每个成员贡献 manifest 说的一切（prompts、skills、全部 `surface:"auto"` tools）；模型面 = 成员的全部 auto tools ∪ 被 pin 的 manual tools，`internal` 恒不上。
- **为什么选宽的那条**：窄到底（pin 蕴含的成员连 prompt / skill 也不给）需要冻结 header 记下"这个成员是怎么进来的"——一个新的 freeze schema 字段；宽到底什么都不需要，fresh 与 frozen 两条路对所有成员读同一条规则、零新状态。
- **落点**：`composition.isFullMember` 与 `resolveFreshBindings` 里那一行 `continue` 删除；模块注释、`Options` 文档、`manifest.Surface` 文档、DESIGN §5.1 / §7.2.1、guide SKILL.md 同步。
- **今天零行为变化**：`extensions/std` 六个 tool 全 `manual`、无 prompt 无 skill；`extensions/agent` 的入口 tool 已经是 `auto` 且不再被 pin（§4 那条修正）。
- 钉子：`composition.zig` 那条原来叫"pin-implied membership does not expose a package's surface-auto tools"的单测改写成正面钉子——pin 一个 `manual` tool，同包的 `auto` tool 也在模型面。
