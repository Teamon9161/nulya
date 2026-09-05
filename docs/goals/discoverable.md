# Goal · discoverable：每一个可配置面都有地方查，而查不花每一场的注意力（2026-09-05）

> 这是一份**执行契约**。地图与 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §7.2.1 / §7.5 / §7.7 / §5.6。
> [mcp.md](mcp.md) 决策 F 与本文是同一件事的两半：那边说"guide 是索引不是容器"，这边给索引补上它今天缺的表达力。
> 前置：[ext-defaults.md](ext-defaults.md) 也改 `manifest.zig`，**本轮排在它之后**。

## 0. 结论（一段）

立一条不变量：**每一个用户可见的可配置面，都必须能从 `nulya help` 出发、在有限跳内、
不读本仓库源码地到达一份与代码同源的说明。** 拿它扫今天的盘面，两处不通（`tui.toml`、
agent 定义的 frontmatter 方言）。补法不是往 `guide` 里抄内容——那会造出一个冻结快照的第二写者，
而且必腐；补法是给 **skill 补上它缺的那一档 surface**，让一个包能带"手册"而不占每一场的注意力，
然后让每条路由的终点都是一条**与代码同源的命令**。

**为什么现在做而不是等第二个 consumer**：这个 harness 的论点是能力由 agent 自己造，
所以衡量表达力的人口**不是我们自带的那十个包**，是用户和模型将来写的包。用自带包数 consumer
是量错了对象。何况仓库里**已经有一个 consumer 在等**：`agent`（§2.2）。

## 1. 已定决策

### A · 不变量（写进 CLAUDE.md 工作约定）

> **每一个用户可见的可配置面，都必须能从 `nulya help` 出发、在有限跳内、不读本仓库源码地
> 到达一份与代码同源的说明。**

两个限定词都承重：**有限跳**（不是"理论上可达"），**与代码同源**（不是一份抄本——抄本会腐，
而腐掉的说明比没有说明更贵）。这条是 §7.5 那句"三层都只指路不复制"的推广：那句话管的是
kernel 自己的三层，这条管**所有**面，包括包和 driver 的。

review 时的用法：**新增任何一个可配置面，同时说出它的那条链**。说不出 = 这个面还没做完。

### B · `contributes.skills[].surface`：`auto` | `reference`

条目今天只能是字符串；改成**字符串或对象**——`contributes.system_prompts` 已经是这个形状
（`["a.md", {"path": "b.md", "position": "late"}]`），不是新语法：

```json
"skills": ["skills/how-to-work", { "path": "skills/setup", "surface": "reference" }]
```

| 值 | 语义 |
|---|---|
| `auto`（缺省） | 今天的行为：这个包是成员时，进 `<available_skills>` |
| `reference` | **永不**进 `<available_skills>`（是不是成员都不进）；**永远**在 `nulya skill list` 与 `skill load <ref>` 里 |

- **闭合词表、内核强制**（`InvalidSkillSurface`），理由与 `tools[].surface` / `runtime.runs_on` 逐条相同：
  一个想写 `reference` 的错字若被读成缺省，那份手册就回到了每一场的 prompt 里。
- **为什么不叫 `manual`**：`tools[].surface` 的 `manual` 意思是"要在成员那一行点名才上面"。
  skill 没有"点名进 catalog"这个动作，借这个词会让人以为两边语义对称。
- **`auto` 是同一个词同一个意思**（随成员自动上面），所以借得。
- 落点：`extension/manifest.zig` 解析 + validate，`extension/skills.zig` 在 `appendFromManifest`
  里带上这一档，`composition.zig` 建 catalog 时过滤，`skill.zig` 的 `catalogText` 不变。
  **`listActive` 不过滤**——索引就是要看见全部。

### C · 两个问题就此解耦

在此之前，"这个包是不是成员"与"它的 skill 进不进 catalog"是**同一个开关**，于是唯一的
"别广播这份手册"的手段是不当成员——那是 workaround，而且对必须当成员的包（`agent`）无解。

之后：**是否成员由工具面决定，skill 进不进 catalog 由 `surface` 决定。** 两个独立的问题两个答案。

### D · `nulya skill list` 说清两件它今天没说的事

1. **作用域**：它列的是本机所有 `current` 指到的包（`extension/skills.zig` 的 `listActive`），
   **不是**你这一场戴着的那些。今天 guide 写 "the catalog"、`nulya help` 写
   "one line per skill available here"，两处都读不出这个区别——而整条"配一个我没戴的包"的路
   就架在它上面。两处都改。
2. **哪些是手册**：输出多一列区分 `reference`。索引说不出"这是方法"还是"这是手册"，就不是索引。

### E · 两处破口，各自补上

#### E1 · `agent` 定义的 frontmatter 方言（**今天的 consumer**）

`extensions/agent` 的 `agent` 工具是 `surface: "auto"`——它**必须**当成员。而 `defs.zig` 从
`.nulya/agents/<name>.md` 的 front matter 里解析 `description` / `runner` / `model` /
`permissions` / `with`（外加 `agents` 别名），**这套方言今天不在任何模型够得着的地方**：
不在 tool description 里（那里只说文件在哪）、包不贡献 skill、`nulya src` 只嵌 `src/**` 不含 `extensions/**`。
**要写一个 agent 定义，今天只能读本仓库源码**——A 那条不变量当场破。

补法：`extensions/agent` 加一个 **`reference` skill**（怎么写一个定义、五个键各是什么、
五种 runner、`model:` 的 `@档位` 写法）。它是成员，所以没有 `reference` 这一档就补不了——
**这就是 B 今天的 consumer**。

#### E2 · `tui.toml`（driver 那一类）

driver 不是 extension，贡献不了 skill；也**不该**为它造一个"什么都装"的包。分两半：

1. **`nulya-tui --settings-help`**：打印 `/settings` 已经知道的那张表（键 / 词表 / 缺省），
   **同一份源**（T94 的那张表在 TS 里只有一处）。这是"与代码同源"的那一端。
2. **`extensions/tui`**：一个 data 包（与 `guide` / `coding` / `evolution` 同形），
   **只贡献一个 `reference` skill，thin，只路由**到上面那条命令与 `tui.toml` 的两层路径。
   于是**不管 TUI 在不在驱动这一场**，`nulya skill list` 都枚举得到它——ground 补不了这一半
   （它只在 TUI 真在驱动时才说得出话）。**版本脱节被"只路由不复制"消解**：那张表不在包里。

**guide 不写 TUI 两个字**，只写一句机制：a driver may name a command that prints its own settings;
ask that command. guide 永远不需要知道什么是 TUI。

### F · ground 报出"谁在驱动"（锦上添花，不是必需）

`ground` 的 `render` 今天 `input.properties` 是空的，而**调它的就是 driver 本人**
（`session new` 之前的那次 `ext run ground render`）。加两个**可选**字段
（driver 名 + 它的帮助命令），driver 用已有的 `ext run --arg` 报进来，
ground 在"环境"那段多一行。**内核零改动**，改的是 `ground` 这个包自己的 schema。

守 ground 自己那条纪律：**没人报就什么都不写，绝不猜**（`Answer` 的 `missing` 一档，
"答不上来永远不是错误"）。

它把 E2 的三跳（`skill list` → `skill load` → 命令）压成一跳，但**替代不了 E2**：
TUI 没在驱动的那些场里，只有 E2 答得出。

### G · 不做

- **不把别的包的正文合进 `guide` 的 SKILL.md**（[mcp.md](mcp.md) 决策 F 的四条理由：
  冻结快照的第二写者 · 合出来的东西没有版本身份 · 抄本必腐 · 内核要认识 `guide` 这个名字）。
- **不给 skill 加第三档**。今天要回答的只有"随成员上面"与"只在索引里"两件事。
- **不给 `<available_skills>` 加分组 / 折叠 / 排序 policy**。那是 intelligence，且没有证据。
- **不给 driver 造 manifest 里的一等公民字段**。driver 想被查到就带一个 data 包，与所有人同一条路。

## 2. 验收

`zig build test` + e2e（挂 `tests/e2e_ext.zig`）：

1. 一个包同时贡献 `auto` 与 `reference` 两个 skill，当成员开一场：`<available_skills>`
   **只有前者**；`nulya skill list` **两个都在**且标得出哪个是 reference；`skill load` 两个都拉得到。
2. `surface` 写一个不认识的词 → **build 拒绝**并点名（`InvalidSkillSurface`），不是静默落缺省。
3. 一个**非成员**包的 `reference` skill 仍在 `nulya skill list` 里（`listActive` 不过滤）。
4. `extensions/agent` 的定义手册：`skill list` 里有它、`skill load` 拉得到、**它不在
   任何一场的 `<available_skills>` 里**（E1 的守门测试）。
5. `nulya-tui --settings-help` 打得出每一个 `tui.toml` 键（`bun test`；断言的是**键的集合**
   与它的来源同源，不是具体文案）。

> 第 2 与第 4 条是本轮的**验收下限**：一个静默落缺省的错字，代价正是这一轮要消灭的东西。

## 3. 同一 commit 内必须同步的

`docs/DESIGN.md` §7.2.1（manifest 三层听众那张表 + skills 那一行）/ §7.7 / §7.8（自带扩展表加
`tui` 一行、`agent` 那行加 skill）· `CLAUDE.md`（工作约定加 A 那条不变量；模块表
`extension/manifest.zig`、`skill.zig` 两行）· `extensions/guide/skills/guide/SKILL.md`
（D 的两句 + E2 的机制一句，**不提 mcp、不提 tui**）· `src/cli/common.zig` 的 `skill_usage` 那行
（D1）· `cli/ext.zig` 内嵌的 `ext api manifest` 文本 · `docs/tui.md` §7（`--settings-help` 与
`extensions/tui`）· `docs/PLAN.md`（若 §3 有对应占位则删）。

## 4. 落地记录（2026-09-05，内核那半）

- **A · 不变量** ✅ 进 `CLAUDE.md` 工作约定，紧挨着「substrate 还是 intelligence」那条。
- **B · `contributes.skills[].surface`** ✅ `manifest.SkillSurface{auto,reference}` + `SkillSpec{path,surface}`
  + `surfaceOf()` + `InvalidSkillSurface`；条目「字符串或对象」照 `SystemPromptSpec` 的形状写（`dupSkills`
  是 `dupSystemPrompts` 的同形）。落到模型面的那一步只有一处：`SkillDescriptor.reference` 一个字段，
  `SkillSetSnapshot.catalogText` 一处过滤；`listActive` 不过滤。全是 `reference` 的一场**没有** catalog 块，
  而不是一个空标题（`listed` 先数一遍）。`m.skills` 的五个既有消费者（`integrity` 三处、`skills.zig` 三处）
  改成读 `spec.path`，没有第二处语义。
- **落地时偏离契约一处**：§1 B 写的是「`composition.zig` 建 catalog 时过滤，`skill.zig` 的 `catalogText`
  不变」。实际反过来——过滤在 `catalogText` 里，`composition.zig` 一个字未改。理由：`catalogText` 是
  `<available_skills>` 的**唯一**产地，规则放在那里只有一处；放在 composition 则 snapshot 与它印出来的
  东西开始不一致（快照里少了那条 skill，而 `skill load` 仍然要拿得到它），并且下一个建 catalog 的调用点
  会把同一条规则抄第二遍。
- **C · 解耦** ✅ 只是 B 的推论，没有单独的代码。
- **D · `skill list` 说清两件事** ✅ `nulya help` 那行从「the skill catalog: one line per skill available
  here」改成「every skill on this machine, worn this session or not」；输出多一列，值就是 manifest 的那两个词
  （`cli/skill.zig` 的 `surfaceWord`，词表只有一处）。第四列是**追加**，既有的三列位置不变，所以按 tab 切前三个
  字段的读者（`tui/src/nulya/cli.ts`）不受影响。
- **E1 · `agent` 的定义手册** ✅ `extensions/agent/skills/writing-an-agent/`，标 `reference`。内容是
  `defs.zig` 真正解析的那套方言：`name` / `description` / `permissions` / `runner` / `model` / `runner_model`
  / `max_steps` / `max_exchanges` / `with` / `agents`，三层查找顺序，隐式档位那条，以及「写坏了会怎样」。
  在此之前这套方言**只存在于本仓库源码里**——A 那条不变量当场就是破的。
- **`ext api manifest`** ✅ 多说 `skills` 条目的两种形状（那段文本是 `cli/ext.zig` 内嵌的，与 manifest 同一个 commit 改）。

验收：`zig build test` 623/627（4 skip）· `zig build e2e` 181/188（7 skip），两条都 exit 0。
新增三处钉子：`manifest.zig` 一条（两种形状 + 错字 + 逃逸 + 重复 + 类型）· `skill.zig` 一条（catalog 过滤
与「只剩手册就没有块」）· `bundled.zig` 一条（**每一个**自带 manifest 都 parse + validate，且 `agent` 的手册
是 `reference`——有人把它改回 `auto` 就红）· e2e 两处（`ext_cli` 的封闭词表多一个 `InvalidSkillSurface` 案例；
`extension.zig` 一条走完 build → 成员 composition 的 catalog → `skill list` → `skill load`）。

### 还没做的（本轮**故意**留下）

- **E2 · `tui.toml` 那条断链**（`nulya-tui --settings-help` + `extensions/tui` 的 thin `reference` skill）。
  排在 ACP adapter 之后：两者都动 `tui/`，并发改是白痛苦。**A 那条不变量在这一处仍然是破的**，
  E2 落地之前不要说它成立。
- **F · ground 报出「谁在驱动」**。它是 E2 的锦上添花（三跳压成一跳），不能替代 E2，所以跟着 E2 一起做。
