# Goal · ext-review-2：`activation` 收口、manifest 瘦身、CLI 人体工学（2026-08-23 第二轮评审落地）

> 这是一份**执行契约**，不是设计文档。来源是 2026-08-23 下午对 extension 参数面的第二轮评审（第一轮是 [ext-review.md](ext-review.md)，已落地）。地图和 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §5 / §7 / §14。
> 本文件的决策已定，不要重开；认为错了就写进 §6 自己那一节的 `BLOCKED:` 并停下，不要自行改方向。
> **三条 lane：K 与 C 并行在各自的 worktree 里跑，M 在两者合并之后跑。** §5 的文件归属表是为了合并时少冲突——不是你的文件就别动（需要时在 §6 写一句"需要 X 改 Y"）。

## 0. 评审结论（一段）

内核 physics 与 2×2（成员 × 工具面，各有"每一场 / 本场"两档）都完好。概念债集中在一个字段：**`activation`** 让 `activate` 一词两义（改 `current` 指针 / 进此后每一场）、带一条"缺省按形状"的隐规则、而且承诺已经漏了——pin 蕴含成员之后，config 里一条 `pinned_native_tools = ["ext:plan/propose"]` 就把 `on_request` 的 `plan` 带进每一场，内核照办，TUI 只能绕着走（`standingPinsOf`）。根因是 `current` 一个指针承担了"`<id>` 指哪个版本"与"要不要进每一场"两件事，而第二件事被交给了**包作者**。按 physics #6 与 pin 的先例，**reach 该是人的决定**。

其余：两种 wire 并存（plain 已能服务每个 consumer）、三处只写不读的字段（`permissions`、driver tool 上的 `timeout_ms`、`policy.deny/ask`）、`commands[].action` 字符串小语言、`ext run` 的位置参数歧义、`contributes.ui` 名义前端无关实际绑死 TUI。

**一处评审修正**：评审里说"extension 没有诚实的机器事实通道、`<ext-note>` 让 kernel prompt 那句不准"。细读 `tui/src/extnote.ts` 之后这个判断不成立——四种 sentinel（`<ext-note>` / approval note / plan 评论 / ask 答案）装的都是**人**在屏幕上的输入，由包替人组装，仍是 user 在说话。今天没有一个 consumer 需要"机器事实"事件，所以**不建** `session note` 事件（建了就是"只写不读"）。留下的只有一条规则，写进 DESIGN §3.1：**稍后到达的机器事实 = inbox 事件（`task_finished` 先例）；下一个这样的 consumer 出现时加事件种类，不加 sentinel。**

## 1. Lane K · `activation` 删除 + `[extensions] with` + `session new --bare`（opus）

### 1.1 已定决策

- **K1 · manifest 删 `activation`。** 删 `Activation` enum、`Manifest.activation`、`activationOf`、`InvalidActivation` 与对应单测。老 manifest 里写了这个键的：`parse` 当未知键**忽略**（不是错），`ext build` / `ext sync` 对这样的 draft 在 stderr 打一行 `note: "activation" is no longer read; a package joins every session only when [extensions] with in config names it`。`extensions/evolution` / `extensions/plan` 的 manifest 删掉这个键；`extensions/plan/README.md` 与 `src/main.zig` 顶部注释里提到 on_request 的句子改写。
- **K2 · `activate` 只做一件事：`current = v`。** `ext run <id>`、`session new --with <id>`（不带版本）、pin 蕴含成员都从 `current` 读，这不变。`ext activate --user` 在 session 内的那句 stderr 警告改为 `note: activating <id>@<v> in the user store from inside session <sid>: <id> now means this version for every workspace on this machine`，**删掉** "and its system prompt enters every future session" 那半句（不再成立）。capability_note 投递规则不变（`ext run <id>` 确实从此跑新版本）。
- **K3 · 每场成员 = config `[extensions] with = ["guide", …]`。** `config.Extensions` 加 `with: []const []const u8`；`merge` 读它；**`mergeProject` 也读**（与 `pinned_native_tools` 同一条理由：它只在选本机已持有、已信任的包，不像 `paths` 那样决定哪些目录可以供出代码；项目级常驻 house-style prompt 正是它的用例）。`cli/session.zig` 像 `pinRefs` 对 pins 那样：config 的 `with` 在前、argv `--with` 在后，交给既有的 `composition.unionWith`（同 id 后者胜）。**discovery 整个删除**：`composition.resolveActiveExtensions`（"所有有 `current` 的包都是成员"）消失；fresh 路的成员 = `with`（config ∪ argv）∪ pin 蕴含（按 `current`）。frozen 路零改动。`ActiveExtensionBroken` 保留名字，语义改为"`--with <id>`（不带版本）解析到的 `current` 版本坏了"，`reportBrokenActive` 那行 stderr 点名照打、文案改指 `nulya ext activate <id> <older>` / `--with <id>@<version>`。
- **K4 · `nulya config show [--json]` 投影 `extensions.with`**（与 pins 同一个理由：不投影，模型只能去 cat 三层 config）。文本形式在 `registry:` 块旁边加 `extensions:\n  with  …`；JSON 形式 `extensions.with` 数组。
- **K5 · `ext list`**：第二列语义就是 `current`，`(inactive)` 改 `(no current)`；删 `on-request` 标记；**加一个 `[with]` 标记**——该 id 在合并后 config 的 `[extensions] with` 里（`RootSearch.open` 已经 load 过 config，走 `rootSpecs` 同一条路拿到 `cfg.extensions.with`）。`[tools skills prompt]` 与 `(shadowed)` 不变。
- **K6 · `session new --bare`**：不读 config 的 `pinned_native_tools` 与 `[extensions] with`，composition 只来自 argv（`--with` / `--pin` / `--prompt`）+ pin 蕴含。`max_tools` 仍读 config（它是天花板不是选择）。header 不记这个 flag（resume 读 header 冻的成员与 pins，本来就不重推）。usage 行、DESIGN §14 同步。
- **K7 · `extensions/agent` 委派出的子场一律 `--bare`**：定义的 `pins` 就是它的全部工具面（四个 builtin 定义已经各自写全），`agents` 非空时照旧加 `--with agent@<self> --pin ext:agent/agent`。`render` 回的参数对象多一个 `bare: true`，TUI 的 `/agent <name>` 走 `render` 的参数所以自动跟上（`tui/src/nulya/cli.ts` 的 `sessionNew`/`SessionExtras` 加 `bare`）。`list` 的 warnings 不加新项；定义没写 `pins` = 只有 shell，写进 agent 包的文档注释与 DESIGN §7.8。
- **K8 · TUI 跟随**（内核改了语义，前端只是把新语义画出来）：
  - `extensions.autoActivatable` 删除——activate 永远安全；`App.syncStores` 的 `--activate` 不再判断 prompt；开屏"发现 active 的 mode 包就点名"那段删（不再有这种状态）。
  - `/ext` 的 `mode` 列保留，语义改成"贡献 system prompt"（戴上它 = 每场付它的 prompt）。Enter 的后果：activate（`current`）+ standing pins（model-audience tools，`tui-state.json` 的 `session_pins`，不变）+ **standing with**——包贡献了 skills / system_prompts / commands / ui 任一时写进 `tui-state.json` 新键 `session_with`，`session new` 时逐个 `--with`；再按 Enter 两者都撤。`standingPinsOf` 的 on_request 特判删掉（它就是 `pinsOf`）。一行说明文案按新后果改。
  - `WithPicker`（裸 `/with`）列出**有 `current` 且贡献 system prompt** 的包（从前是 on_request 的）。
  - `tui.toml [extensions] session_with`（缺省 handoff / agent）语义不变：TUI 对它开的顶层 tab 额外 `--with` + `--pin`。子场由 K7 的 `--bare` 排除，所以 `App` 里凡是为了"只顶层"而写的判断可以删（grep `top-level` / `leaf`）。
  - `nulya/files.ts` 的 `Contributions.activation` 与 `activationOf` 镜像删除；`pins.ts` / `plugins/host.ts` / `ExtView.tsx` 里引用 `activation` 的分支删。
  - `/ext` 读 `nulya config show --json` 的 `extensions.with` 画一个 `[with]` 状态（与 config pins 同一读法）。
- **K9 · 文档**：DESIGN §5.1（成员解析三条路 → 两条：`with` 与 header；pin 蕴含那段删 `on_request` 句）、§7.2.1（删 `activation` 整段、`ext list` 那句；"三层"叙述不动——M 会重写这一节的其它字段，K 只删 activation 相关句子）、§7.5（"discovery 只捡 always 的包"整段删，改写成"成员只有 `with` 一条来路"）、§7.8 表格（evolution / plan / ask / guide 行的"怎么进 session"列）、§9.5（config 键表加 `[extensions] with`，project 层可写）、§14（`session new --bare`、`ext list` 列、`config show`）；CLAUDE.md 现状段里 `activation` 那一条改写成一句"已删、每场成员 = config `with`"，模块表 `composition.zig` / `config.zig` 行同步；PLAN §3.7.9 "activate = 常驻" 改写；guide `SKILL.md`（"A package that has these is registered by activation…"、"A mode is …" 两段）；`ext api permissions` 里 activation 那句删（整段 M 重写，K 只删句）；tui.md §11 加一条 T 记录。BUGS.md 不改（历史）。
- **K10 · 测试**：manifest 单测删 activation 条；`tests/e2e/ext_cli.zig:32` 改写成"built + activated 的 prompt 包不进任何 session，直到 config `[extensions] with` 或 `--with` 点名"；新增 ① `--bare`（config 有 pin，`--bare` 的场工具面只有 shell）② config `with` 进成员、project 层也认 ③ `--with <id>` 撞坏 `current` 是 `ActiveExtensionBroken` + 点名行。凡是依赖"activate → 下一场自动成员"的既有 e2e（activate 后 skill 进 catalog / system prompt 进 blocks 那类）改成显式 `--with` 或 config `with`；**pin 流程不用改**（pin 蕴含成员）。TUI bun tests 同步。

### 1.2 不做

- 不改 header schema（`active` 键名照旧）。
- 不改 `pinned_native_tools` 的名字。
- 不给 agent 定义加 `with:` frontmatter（等真实需要）。
- 不碰 M 的字段（`permissions` / `policy` / `commands` / `ui`）。

## 2. Lane C · `--zig` 模板走 plain + `ext run` 形状 + `sync --seed` + 两处文案（sonnet）

### 2.1 已定决策

- **C1 · `ext init --zig` 的模板也用 `plain` wire。** `templates.zig` 的 `main_zig` 改成：读 stdin 为一个 JSON object（`std.json.parseFromSlice(std.json.Value, …)`），取 `name` 字段（缺省 `world`），打印一行文本到 stdout，退出码 0；注释里示范错误路径 = 打印到 stderr + `std.process.exit(1)`。`manifestJson` 加 `"wire": "plain"`，tool input 与脚本模板一样声明可选 `name`。`example_test_json` 的 `request` 形状改成 plain（`{"arguments": {...}}`，`expect` 是 stdout 文本）——它只被 `ext init` 写进 `tests/example.json`，没有别的读者（`grep example_test_json`）。模板顶部注释说清"`plain` 是两种 wire 里默认的那种，`nulya ext api protocol` 有另一种"。
- **C2 · `ext run <id>[@<v>] <tool> [<json> | --arg k=v …] [--timeout-ms N]`：tool 必填，json 可省（= `{}`）。** 删"不给 tool 就用第一个 tool"的缺省与 `has_explicit_tool` 那段位置推断；`ext run <id>` 没有 tool → usage + exit 1；`cli/ext.zig:941` 那条"the last argument must be a JSON object"文案保留给真的给了坏 JSON 的情形。`common.zig` 的 `ext_usage` 行、DESIGN §14 命令表、guide `SKILL.md` 里的 `ext run` 用法同步。先 grep 仓库里所有 `ext run` 的调用方（`tui/src/nulya/cli.ts:771`、`extensions/*/src/*.zig`、`drivers/goal.*`、docs、e2e）——都带 tool 名的不用动，不带的改。
- **C3 · `ext sync --seed`**：等价于先 `ext seed [--user]`（不 `--force`，走 `cli/ext_seed.zig` 的同一实现）再 sync；`--dry-run` 两步都 dry 且两步的计划都打印。usage 行 + DESIGN §7.2 / §14 + guide `SKILL.md` 的"least-effort install"那段同步。
- **C4 · `cli/session.zig` 对 `PinNamesUnknownExtension` 的文案**改成 `names an extension no store root holds — never built on this machine, or a typo (see \`nulya ext list\`)`（它现在的意思就是这个；"有但无 current"是 `WithVersionNotFound`，另一条文案已经对）。
- **C5 · e2e**：`tests/e2e/script_wire.zig` 加 ① `ext init --zig` → `ext build`（e2e 本来就编译 bundled extension，zig 在）→ `ext run <id>@<v> <tool> --arg name=zig` 打回含 `zig` 的一行、退出码 0；② `ext run <id>@<v> <tool>`（无 json）跑通 = `{}`；③ `ext run <id>@<v>`（无 tool）→ exit 1 + usage；`tests/e2e/ext_cli.zig` 加 ④ `ext sync --seed --dry-run` 在空 root 上列出 seed 计划且不建目录。

### 2.2 不做

- 不改 jsonrpc 任何字节；不迁移自带包（下一批）。
- 不碰 `ext api` 的文本（M 的）。

## 3. Lane M · manifest 瘦身：`permissions` / `policy` / `commands` / `ui` / driver `timeout_ms` + `ext api manifest`（opus，K 与 C 合并之后）

### 3.1 已定决策

- **M1 · 删 `permissions`。** `Permissions` struct、`Manifest.permissions`、parse 那段、`ext api` 文本、DESIGN §7.2.1 / §9 里"声明零读者"那段改成一句"M7 沙箱来时再定形状"、PLAN §3.8 措辞。老 manifest 写了的：parse 当未知键忽略。
- **M2 · `policy` 只剩 `readonly: ?bool`。** 删 `deny` / `ask` / `InvalidPolicyEntry` / `PolicyAllowNotPermitted`（只剩一个 bool，"包只能收窄"由形状保证，`allow` 与 `deny` 同是未知键）。`policyContributes` = `readonly != null`。TUI `approvals.ts` 的 `poolPolicy` 只剩 `readonlyBy`、`withPolicy` 删；`files.ts` 的 `PackagePolicy`。
- **M3 · `commands[].action` 改成对象：** `{"with": true}` / `{"run": "<tool>"}` / `{"skill": "<ref>"}`——恰一个键，否则 `InvalidCommandAction`（形状 validate）；`run` 的包内引用检查保留（`UnknownCommandTool`）；其它键 = reader 的事（warn-and-skip，与今天的 unknown verb 同）。字符串形式（`"with"` / `"wear"` / `"run x"` / `"skill x"`）认一个版本期：parse 读成等价对象，`ext build` 在 stderr 提一句。`extensions/ask` manifest 改；TUI `packageCommands.ts` 的 `parseAction` 改读对象（字符串旧形也认）；`files.ts` 的 `commandsOf`。
- **M4 · TUI 自动 `/<id>`：** 每个有 `current` 且贡献 system prompt 的包自动得到 `/<id>` = with，不需要 manifest 写 `commands`；包自己声明的同名 `commands` 条目优先（更具体的声明）；内建名永不被夺走（既有规则）。于是 `extensions/plan` 的 `commands` 条目删掉（它贡献 prompt）；`ask` 的留着（它是 tool 包，不贡献 prompt，`/ask` 仍要自己声明）。
- **M5 · driver tool 的 `timeout_ms` 删**：`extensions/agent` 的 `render` / `list` / `run`、`extensions/compact`。`agent` tool 自己的 120000 留着（它上模型面）。`ext api` 文本里把 `timeout_ms` 的说明改成"只对上了模型面的 tool 有意义"。
- **M6 · `contributes.ui` 按宿主键：** `"ui": { "tui": { "entry": "tui/plan.ts", "api": 1 } }`。`Ui` 变成 `[]const UiHost{host, entry, api}`；宿主名是开放词表（`[a-z0-9-]+`，否则 `InvalidUiHost`），每个条目 validate safe path + `api >= 1`，`build_ext.validateUi` 对每个条目查文件存在。老的平铺 `{entry, api}` 认一个版本期（parse 读成 `tui` 那一条）+ build stderr 提一句。`ask` / `plan` manifest 改；TUI `plugins/host.ts` 读 `ui.tui`（没有 `tui` 条目 = 这个包对这个前端没有插件，跳过不警告）；`files.ts` 的 `uiOf`。`tui/plugin-api.d.ts` 顶部那段 "declares `contributes.ui = {entry, api}`" 改写。
- **M7 · `ext api manifest`**：`permissions` topic 改名 `manifest`（`permissions` 保留为别名一个版本期，打同一段）；整段重写：三层叙述不变（内核强制 / driver 声明 / 前端声明，每层纪律说一次），删 activation / permissions / policy.deny/ask，commands 对象形式，ui 按宿主，`timeout_ms` 只对模型面。`common.zig` 的 `ext_usage` 那行 `api [protocol|manifest|examples]`。
- **M8 · 文档**：DESIGN §7.2.1（整节按新形状重写，含示例 JSON；"三处 readonly 并排"那段保留）、§7.8 表格（plan / ask 行）、§9、§14（ext api）；CLAUDE.md 模块表 `manifest.zig` 行与现状段（tui-plugin 那条里 `commands[].action` / `policy` / `ui` 的描述）；`goals/tui-plugin.md` 末尾加一条 "2026-08-23 形状变更"；tui.md §11 一条 T 记录；guide `SKILL.md`（`ext api permissions` → `manifest`）。
- **M9 · 测试**：manifest.zig 单测（round-trip 那几条按新形状重写，加字符串旧形兼容与 `InvalidCommandAction` / `InvalidUiHost`）；`build_ext` 的 validateUi；e2e 若有 commands / policy / ui 的；TUI bun tests（`packageCommands` / `approvals` / `files` / `host`）。

### 3.2 不做

- 不动 `readonly` / `audience` / `tools[].ui{render,panel}`。
- 不动 plugin-api 的方法面（只改顶部注释）。

## 4. 验收（每条 lane 自己跑，合并后我再跑一遍全套）

```bash
zig build test
zig build e2e
zig build            # 刷新 zig-out/bin/nulya.exe —— bun test 驱动的是它（tui 那条 memory）
cd tui && bun test
```

`zig fmt` 只跑在自己改过的 `.zig` 文件上（整目录会重写 CRLF）。本机 `zig` 是 anyzig shim：ad-hoc 命令写 `zig 0.16.0 …`。

## 5. 文件归属（合并时少冲突）

| lane | 文件 |
|---|---|
| K | `src/composition.zig`、`src/config.zig`、`src/cli/session.zig`（`createSession` / `pinRefs` / `withRefs` / `--bare`）、`src/cli/ext.zig`（`extActivate` / `extList` / `contributionMarker` / `warnUserScope`；`extApi` 里只删 activation 句）、`src/cli/config.zig`、`src/cli/common.zig`（`session_usage`）、`src/extension/manifest.zig`（只 Activation 相关）、`src/extension/build/build_ext.zig`（K1 的 stderr note）、`extensions/agent/**`、`extensions/evolution/extension.json`、`extensions/plan/{extension.json,README.md,src/main.zig 注释}`、`tui/src/{extensions.ts, nulya/files.ts（activation）, nulya/cli.ts（bare）, pins.ts, plugins/host.ts（activation 分支）, ui/App.tsx, ui/WithPicker.tsx, ui/overlays/ExtView.tsx, state/*}`、`tests/e2e/{ext_cli,extension,gate_pin,session}.zig`、docs（DESIGN §5.1 / §7.2.1 activation 段 / §7.5 / §7.8 / §9.5 / §14，CLAUDE.md，PLAN §3.7.9，tui.md，guide SKILL.md 的两段） |
| C | `src/extension/build/templates.zig`、`src/cli/ext.zig`（`extInit` / `extRun` / `extSync` / `buildArgsJson`）、`src/cli/ext_seed.zig`（若 `sync --seed` 要复用）、`src/cli/common.zig`（`ext_usage`）、`src/cli/session.zig` 的那一行文案、`tests/e2e/{script_wire,ext_cli}.zig`（新增测试）、DESIGN §7.1 / §7.2 / §14 的对应行、guide SKILL.md 的 `ext run` / install 用法 |
| M | `src/extension/manifest.zig`（Permissions / Policy / Command / Ui）、`src/extension/build/build_ext.zig`（validateUi）、`src/cli/ext.zig`（`extApi`）、`src/cli/common.zig`（`ext_usage` 的 api 行）、`extensions/{agent,compact,plan,ask}/extension.json`、`tui/src/{nulya/files.ts, packageCommands.ts, approvals.ts, plugins/host.ts, commands.ts}`、`tui/plugin-api.d.ts` 顶部注释、tests、docs（DESIGN §7.2.1 全节 / §7.8 / §9 / §14 ext api，CLAUDE.md，goals/tui-plugin.md，tui.md，guide） |

## 6. 进度（每条 lane 在自己那节追加；不要 commit）

### Lane K

（待开始）

### Lane C

（待开始）

### Lane M

（待开始，等 K + C 合并）
