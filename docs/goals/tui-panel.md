# Goal · tui-panel:extension 管理面板(pin 插拔)+ composer 基础(@文件 / 粘贴 / slash skill)

> 这是一份**执行契约**,不是设计文档。TUI 的现状与既有契约在 [tui.md](../tui.md)(§4.4 composer、§5.3 `/ext`、§9 里程碑表);内核事实在 [DESIGN.md](../DESIGN.md) §5.1(pin)/ §7.5(composition 冻结)/ §9(authority);physics 在 [CLAUDE.md](../../CLAUDE.md)。
> **参考实现是 tcode-tui**(本机 `~/code/rust/tcode/crates/tcode-tui/`,§4 列了每个机制的出处文件):交互形状、常量、评分函数**能抄就抄**,与它有意识分歧的地方都在 §3 记了理由。
> 每个 T 落地 = `bun test` 绿(在 `tui/` 下跑,不能在仓库根)→ commit → 更新 [tui.md](../tui.md) §9 表与 §11 实施日志 → 本文件 §6 记一行。**内核零改动**是本契约的硬边界:需要动 `src/` 就是 BLOCKED,写进 §6 停下。

## 0. 目标(一句话)

四个里程碑:**T12** 把 `/ext` 从"看"升级成"管"——extension 整体与**单个 tool** 的插拔,改动在下一场 session 生效;**T13** composer 的 `@` 文件补全;**T14** 长文本粘贴折叠(图片随 vision 内核 track,不在本契约);**T15** skill 作为 slash command 触发。全部是前端 + 既有内核动词的组合,`src/` 一字不动。

## 1. 内核事实(设计必须绕着走的,都已存在、别重新发明)

1. **composition 在 `session new` 冻结,中途不能变**(physics #2/#4)。一切"插拔"都只影响**下一场**;面板的每个改动都要像 `/ext` 现在的 drift line 一样,把"这场冻结的 vs 下一场会是的"说成一句话。
2. **pin 的合成是 union**:`registry.pinned_native_tools`(config)∪ `session new --pin`(argv,`cli/session.zig` `pinRefs`)。语义是"config 说这个 workspace 永远要,`--pin` 说这一场要"——**只能加,不能减**。注意这条只约束 `session new` 组装工具面的那一刻:面板管理的是**下一场**,config 与 argv 都是它写的,所以增删都自由;唯一不存在的是"不动 config 的前提下给某一场做减法"(见 D2)。
3. **config 层**:user 层 `~/.nulya/config.toml`(`NULYA_HOME` 可重定位)是 trusted 层;合并结果由 `nulya config show --json` 投影(`registry.max_tools` / `pinned_native_tools`)。投影是**合并后**的,不带每层来源——面板要知道某个 pin 是不是 user 层写的,就直接读 user config 文件比对(它本来就是面板唯一会写的文件)。
4. **`max_tools` 含 builtin**(缺省 8:shell + edit 占 2)。超配额是内核在 `session new` 时拒(`composition.zig`),面板只显示配额(`tools 2+5/8`)并把内核的拒绝原样转述,不自己预判。
5. **"整体开关"有两根轴**:membership(`ext activate|deactivate [--user]` = 之后每场;`session new --with` = 只这一场)管 skills / system prompts 进不进 composition;**pins** 管 tools 进不进模型工具面。std 这类 tools-only 包,"开关"≈ pins 全开全关;evolution / guide 这类 data 包,"开关"= activate / deactivate / `--with`。面板把两根轴分开呈现,不合成一个假的总开关。
6. **每个 extension 声明了哪些 tool**,冻结 manifest 里就有;TUI 的 `files.ts` 已经直读 store 解析 `contributes.tools`(T8 起),不需要新内核面。usage 计数 join `.nulya/tool-usage.jsonl`(`/ext` 的 UsageTable 已在读)。
7. **ledger 没有 image 内容块**,三个 provider 的序列化也没有。真 vision 是**内核 track**,**已立项、另立契约**(ledger 内容块 + PromptIR + 三 provider 序列化 + `[[models]]` 目录的能力标注与壳层门,见 §5);因此本契约的 T14 **只做文本粘贴**,图片粘贴是 vision 落地后的 TUI 后续里程碑——不先造"cannot see images yet"占位再返工。
8. **skill 的内核面**:`nulya skill list`(TSV:`ref\tname\tdescription`,列的是 **activate 了的** extension 的 catalog)与 `nulya skill load <name>`(打印 body)。skill 本来就是渐进披露的 prompt——谁触发都一样,用户经 TUI 触发和模型经 shell 触发是同一个东西(这翻案了 `commands.ts` 头注释与 tui.md §4.4 的"nulya 没有 skill slash",理由见 D8)。
9. **中途改动如何(不)通知在跑的 session**:`ext activate` 只在**环境里有 `NULYA_SESSION`** 且激活真生效时,才往那场 session 的 inbox 投 capability_note(`cli/ext.zig` `depositSessionNote`)——TUI spawn 的 activate 默认不带这个变量,**不会**通知;`ext deactivate` 从不投 note;pin 改动完全不经内核。这不是缺口:本场工具面冻结(#1),pin/deactivate 的改动对本场**没有可行动信息**,下一场的 prompt 自然呈现新工具面。唯一值得通知的是 activate(模型中途就能经 shell `ext run <id>@<v>` 用上新版本),T12 用现成机制补上(见该节)。

## 2. 范围(按序;T12 独立,T13→T14 同在 composer 串行,T15 最小可最后)

### T12 · `/ext` 的 pin 面板(管理插拔)

`/ext` 加第四个 pane **tools**(现有 extensions / versions / usage 之外):

- **每个 tool 一行**:`[x] ext:std/read · always` / `[x] ext:std/grep · this TUI` / `[ ] ext:std/append`,行尾带 usage 计数(join tool-usage journal)。列出的 tool 来自每个**有 current 版本**的 extension 的冻结 manifest(`files.ts` 现成)。
- **三态与归属**(D2):
  - `always` = user config 的 `pinned_native_tools` 里有它。toggle off = 从 user config 移除该项(managed 写回,D3);
  - `this TUI` = 记在 `tui-state.json` 的 `session_pins`,本 TUI 起的每场 `session new` 都自动带 `--pin`;toggle off = 从 state 删;
  - off → toggle on 先进 `this TUI`(试用零成本),`A` 键升格为 `always`(写 config);
  - pin 在合并结果里、但不在 user config 文件里(project / system 层写的)→ 只读显示 `from another config layer`,指路文件,不试图编辑。
- **extension 行的整体动作**:`Space` = 该包全部 tools 一起 toggle;`d` = `ext deactivate`(membership 轴,先确认,与现有 `a`(activate)/`r`(rollback)/`p`(prune)并排;`cli.ts` 加 `extDeactivate`)。
- **通知在跑的 session**(内核事实 #9):面板 spawn `ext activate` 时,给子进程 env 带 `NULYA_SESSION=<当前跟随 session 的文件路径>`,借内核现成的 capability_note 让模型在下个 step 边界得知新版本可用——零内核改动(副作用:`--user` 时内核会多一行"acting from inside session"的 stderr 提示,TUI 吞掉即可)。deactivate 与 pin 改动**不补任何通知**,也不 `session append` 注释:本场无可行动信息,往 ledger 塞 UI 旁白是噪音。
- **配额行**:`tools 2+N/8`(读 `config show --json` 的 `max_tools`);超了不拦,`session new` 失败时把内核的 stderr 原样贴出(内核事实 #4)。
- **生效提示**:面板底部一句常驻:`changes apply to the NEXT session — this one froze its tools at start`(drift line 的姊妹句)。
- **完成标准**:`bun test` 纯策略测试 ≥ 6 条(三态 toggle → 下一场 argv 的 `--pin` 列表;config 写回 round-trip 保注释;another-layer pin 只读;配额行);真跑一遍:面板关掉 `ext:std/grep` → `/new` → 新场 CompositionCard 的 native tools 里没有它。

### T13 · composer 的 `@` 文件补全

- **触发与 token 规则照抄 tcode**(`composer.rs`):`@` 前一字符非字母数字下划线才触发(email 免疫);token 字符表同 `reference_token_char`;含空格路径 `@"..."`;已知引用在输入框里 accent 高亮(`input_spans` / `known_reference_marker` 的逻辑)。
- **索引**:git 仓库用 `git ls-files --cached --others --exclude-standard`(gitignore 语义白得)+ 从文件路径推目录集合;非 git 仓库退化为小型 walk(prune 名单硬编码借 std 的 `walk.zig` 那张表);上限 **20_000** 条(tcode `MAX_INDEX_ENTRIES`)。启动时后台建一次,composer 里 `@` 激活时若索引老于 30s 就后台刷新——不追求实时,追求不卡输入。
- **评分照抄 tcode**(`reference_score` / `reference_match_order`):basename 前缀 0 < path 前缀 1 < 子序列 10+gaps;根目录文件优先;并列按路径字典序。菜单显示 basename(冲突时带路径),`↑↓` 选、`Tab`/`Enter` 上屏成 `@path`。
- **提交语义(与 tcode 的有意识分歧,D5)**:`@path` 原样进 append 的文本,**不注入文件内容**。tcode 的 `expand_references` 会把内容展开成独立 block;nulya 不这么做——ledger 不该塞进文件快照,模型有 read(freshness 还会去重),路径本身就是模型需要的全部。
- **完成标准**:`bun test`(评分表与 tcode 三条测试同形、边界 / quoted / email、索引解析 git ls-files 输出);真用:`@comp` 补出 `src/composition.zig`,上屏高亮。

### T14 · 粘贴:长文本折叠(图片随 vision track,不在本契约)

- **文本**:bracketed paste 事件(OpenTUI 若不透出 paste 事件,先探明——探不到就是 BLOCKED 记 §6,不做按键洪流启发式)。阈值照 tcode:**> 1000 字符或 > 15 行**(`PASTE_FOLD_LINES` / `PASTE_FOLD_CHARS`)→ 折叠成 `[Pasted text #N]` 占位(accent 高亮,attachment 存 composer state,可 `Backspace` 整体删除);提交时占位展开回原文。短粘贴原样入框(现状不变)。
- **图片**:**移出本契约**(内核事实 #7)。vision 内核 track 已立项;等 `session append` 长出图片面后,图片粘贴作为后续里程碑直接做真的(剪贴板探测命令与占位形状到时照抄 tcode `input.rs`,出处已在 §4)。本契约不造占位。
- **完成标准**:`bun test`(折叠阈值边界同 tcode 测试、占位插入 / 删除 / 提交展开);本机(Linux)手测长文本粘贴折叠与展开一条通。

### T15 · skill 作为 slash command

- **补全**:`/` 菜单在内建命令后接 skills(启动时 `nulya skill list` 缓存,`/ext` 里 activate/deactivate 之后失效重取);描述截 100 字符(tcode `clip_description` 同)。
- **分发**:`/xyz [args]` 不在 `commands.ts` 表里 → 查 skill 表;命中 → `nulya skill load <name>` 拿 body,包一层 sentinel 后作为**普通 user turn** append(照 tcode `wrap_skill_echo` 的设计:`<user-skill name="…" args="…">\n<body>\n</user-skill>`,sentinel 让 transcript 与 replay 都能把它折回一行 `/name args`——live 和回放共用一个 `parseSkillEcho`,格式只有一处知道)。skill 没命中 → 原样发给模型(现状)。
- **transcript**:skill echo 卡片默认折叠为 `/name args · N lines`(卡片折叠机制现成)。
- **修订两处旧文本**:`commands.ts` 头注释与 tui.md §4.4 的"nulya 没有 skill slash"——决策翻案,理由 D8。
- **完成标准**:`bun test`(wrap / parse round-trip、补全合并、未命中 passthrough);真用:activate guide 后 `/guide` 出现在补全,Enter 后 ledger 里 user_text 是包装后的 body、transcript 折叠成一行。

## 3. 已定决策(不要重开;认为错了写 §6 BLOCKED 停下)

- **D1 · 一切改动在 session 边界生效,面板永远双栏叙事**("这场冻结的 / 下一场会是的")。这不是限制,是把 physics #2 变成 UI 语言;`/ext` 的 drift line 是先例。
- **D2 · pin 三态:`always`(user config)/ `this TUI`(tui-state.json → `--pin`)/ off。** union 语义下会话级关不掉 config pin——面板对这个不对称**明说**而不是绕过;如果"会话级减 pin"被真实使用证明需要,最小内核动词是 `session new --no-pin`,**本契约不做**,记 §6 等证据。
- **D3 · 面板只写 user config,且只写一个 key。** 读:`Bun.TOML.parse` 整文件 + `config show --json` 合并结果双对照;写:只替换/追加 `pinned_native_tools = [...]` 这一行(section 缺失就追加 `[registry]`),不整文件重序列化——用户手写的注释与排版必须活下来。写后重读校验,不一致就回滚并报错。
- **D4 · 两根轴分开呈现**(membership vs pins),不造合成的总开关;tools-only 包的"整体开关"是 pins 批量,data 包的是 activate/deactivate。
- **D5 · `@` 不注入文件内容**(分歧于 tcode 的 `expand_references`)。先纠正一个事实:tcode **也有** freshness 去重(`fs/read.rs`),它注入是为了**省一轮往返**——这是真实收益,承认它。nulya 仍不注入,理由是 nulya 自己的:① append-only ledger + 长寿 session(fork / compact 谱系)意味着注入的快照**永久**留在前缀里,每步付费且会陈旧;② 今天 `user_text` 是纯文本,注入需要内容块结构,本身就是内核改动,与 D9 冲突;③ 路径原文保持单一真相——模型 read 到的是**当下**内容,freshness 去重使重复 read 便宜。代价是每个引用文件多一轮往返;若真实使用证明这一轮很疼,记 §6 再议,候选方案到时再评(不预设)。
- **D6 · 能照抄 tcode 的都照抄**:评分函数、边界规则、折叠阈值、占位形状(`[Image #N]` / `[Pasted text #N]`)、skill echo 的 sentinel 设计与 100 字符描述截断。数字与函数形状对着 §4 的出处抄,不重新发明。
- **D7 · 图片整体移出本契约**;vision 是内核 track,**已立项、另立契约**(§5)。原方案的"落盘 + 占位"半步取消:内核面确定要长出来,先造占位再返工不值。
- **D8 · slash skill 是用户触发的 prompt 糖,不是前端智能。** 前端不选择、不改写、不自动触发任何 skill;它只是把"模型经 shell 跑 `nulya skill load`"这条已有路径的触发者换成人,省一轮往返。原"nulya 没有 skill slash"的判断把"谁触发"误当成了"谁判断"。
- **D9 · 内核零改动;凡判断尽量借内核**(`config show --json` / `ext list` / `skill list` / 冻结 manifest 直读——最后者已是 T8 先例)。

## 4. 参考(先读这些,再动手)

- **tcode-tui**(本机 `~/code/rust/tcode/crates/`):
  - `tcode-tui/src/composer.rs` —— `@` 引用的全部纯函数(`reference_boundary` / `reference_token_char` / `reference_score` / `reference_match_order` / `input_spans` / `known_reference_marker`)、折叠阈值(`PASTE_FOLD_LINES=15` / `PASTE_FOLD_CHARS=1000`)、占位 token 识别;文件底部的测试就是 T13/T14 的测试清单。
  - `tcode-tui/src/app/commands.rs` —— slash 分发的兜底顺序(内建 → registry → `dispatch_skill` → passthrough)、skills 进补全菜单(`clip_description` 100)。
  - `tcode-tools/src/skills/mod.rs` —— `render_skill` / `wrap_skill_echo` / `parse_skill_echo`(sentinel 的理由注释值得整段读:body 是"穿着 user message 衣服的仓库文件",授权检查不能把它当人话)。
  - `tcode-tui/src/app/input.rs` —— 剪贴板顺序(图先于文)、attachment id 与占位、OSC 52 回退。
  - `tcode-core/src/references.rs` —— `index_project`(上限 20_000、同步构建放 blocking 线程)、`parse_mentions`;`expand_references` 是 D5 分歧的对照物。
- **nulya 侧**:`tui/src/commands.ts`(表驱动补全,T15 改这里)、`tui/src/extensions.ts` + `ui/overlays/ExtView.tsx`(T12 在其上加 pane)、`tui/src/nulya/files.ts`(manifest 的 `contributes.tools` 解析现成)、`tui/src/nulya/cli.ts`(加 `extDeactivate`;`session new` 的 argv 组装处加 `--pin`)、`src/cli/session.zig` 的 `pinRefs`(union 语义的原文)、`src/config.zig`(层与路径)、DESIGN §5.1 / §7.5 / §9。
- **bun test 必须在 `tui/` 下跑**(仓库根会丢 bunfig preload,报误导性的 jsx 错)。

## 5. 不做(明确越界)

- **内核 image 支持**(ledger 内容块 + PromptIR + 三 provider 序列化 + `[[models]]` 能力标注)——**已立项**,契约另文(计划 `docs/goals/vision.md`),不是 TUI 契约的事;图片粘贴是它落地后的 TUI 后续里程碑;
- `session new --no-pin`(等 D2 的真实证据);
- `@` 注入文件内容 / `@目录` 展开(D5);
- 拖拽文件、粘贴任意文件类型(只认 image/png 与文本);
- 前端自动触发 skill、per-project 的 slash alias;
- MCP / 外部工具面板;
- 改 `src/` 任何文件。

## 6. 进度区(执行时更新)

(空)
