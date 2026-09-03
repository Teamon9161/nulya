# Goal · model-roles：档位挂在 profile 上，换主模型就是换整支队伍（2026-09-03）

> **执行契约**，不是设计文档。地图与 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §9.5（config chain）与 §12（委派）。
> 委派本身的既有契约在 [agent-runner.md](agent-runner.md)。
> **项目 pre-release，不要向后兼容**。

## 0. 结论（一段）

诉求是"一键切一整支队伍"：主对话跑 `gpt-5.6-sol`、explore 跑 `gpt-5.6-luna`；换成 DeepSeek 时主对话 `v4-pro`、explore `v4-flash`——一个动作，不是挨个 agent 切。

**不引入 preset 概念。** 一个"preset"若自带队伍表，委派时扩展就必须知道**当前哪个 preset 在生效**，而它能看见的只有自己的 env 和父 session 冻结的 header（profile + model id）。让 preset 名到达那里，只有塞进 header 或让内核设一个 env 两条路，两条都等于**内核为一个便利长出一个新概念**。

所以把队伍表挂在 **profile** 上，agent 定义引用**档位名**而不是绝对 id。需要旅行的东西就是今天已经在旅行的那个（父 header 的 profile）。于是：

**换主模型（`/model` 里选一行）= 换整支队伍。** 没有第二个手势，没有新的内核概念，header schema 一个字节不变。

"默认继承主模型"不是新功能，是现状（`extensions/agent/src/main.zig` 的 `parentIdentity`）；档位只是把"跟着走"从"同一个 model id"扩展成"同一个 profile 里的对应档位"。

## 1. 已定决策

### A · `[[provider.profiles]]` 新增 `roles`

```toml
[[provider.profiles]]
name = "openai"
model = "gpt-5.6-sol"
models = ["gpt-5.6-sol", "gpt-5.6-terra", "gpt-5.6-luna"]
[provider.profiles.roles]
explore = "gpt-5.6-luna"
review  = { model = "gpt-5.6-terra", effort = "high" }
cheap   = "deepseek/deepseek-v4-flash"
```

- **两种写法**：裸字符串是 `{ model = <it> }` 的简写；表形另可带 `effort`。**机制已核实**：vendor 的 `struct_mapping.setValue` 对结构体类型只收 `.table`，`tomlIntoStruct` 钩子也只在值本来就是表时才被问到——所以两种形状**不能**靠一个自定义结构体类型接住。落法是 `roles: ?toml.HashMap(toml.Value)` 然后手解一层（`.string` → `model`；`.table` → `model` + 可选 `effort`；别的类型是解析失败并点名那个档位）。约十五行，不动 vendor。
- **`[provider.profiles.roles]` 这个三段表头合法**：`table.tableAdvance` 走到 `profiles` 这个数组时不建新项、取**最后一个**元素，所以它落在它上面那个 `[[provider.profiles]]` 里（已核实 `vendor/zig-toml/src/table.zig`、`key.zig` 的 `asChain`）。
- **值的语法**：裸词 = **本 profile 的一个 model id**；带 `/` = `<profile>/<model-id>`，用来表达跨 provider 的编队。**注意它与 `defs.parseModelRef` 的裸词含义相反**（那里裸词是 profile 名）——各自在自己的位置上无歧义：一个 role 值写在某个 profile 的**里面**，裸词当然是它自己的 model id。这条要写进 `default.toml` 的注释。
- **档位名是开放词表**，内核不认识任何一个具体的词（`explore` / `review` 都不是内核词汇）。字符集与 profile 名同尺（`[A-Za-z0-9_.-]+`）。
- **合并**：profile 按 `name` 合并时，`roles` **按 key 逐条覆盖**（与 `[[models]]` 按 id 合并同一条纪律），不是整表替换。
- **只在 trusted 层**（default / system / user）。project 层今天就不能定义或改 profile（`config.zig` 的 `mergeProject`），roles 自动落在同一条边界内——一个仓库的 `.nulya/config.toml` **不能**把某个档位改指向另一个 endpoint。这是白拿的安全性质，写进 DESIGN。
- **内核不读 roles**：它与 `[[models]]` 的 `label` / `vision` 同类——config 携带、别人消费。

### B · 内部表示与投影

- `Config` 里 `ProviderProfile.roles: []const Role`（**切片不是 HashMap**：n 很小，arena 所有权简单，合并就是 `upsertProfile` / `upsertModel` 那条线性扫描的同一套）。`Role = { name, model, effort: ?[]const u8 }`。
- `config show --json`：`ProfileView` 多一个 `roles` 字段，**数组、按档位名排序**（`std.json.Stringify` 直接写结构体切片；对象键序不确定，排序过的数组才是稳定投影）。空表就是 `[]`。
- `config show`（人读的那份）：在 profile 那几行下面把档位列出来，一行一个。

### C · agent 定义引用档位：`model: @<role>`

- frontmatter 与 `agent` 工具的 `model` 参数**同一个语法**（`defs.zig` 已经写着"TWO CALLERS, ONE SHAPE"），第三种形状：`@explore`。
- **解析顺序**（`main.zig` 那段"nearest first"扩成四级）：调用参数 → 定义的绝对 pair → **定义的档位（在父 session 的 profile 里查）** → 继承父。
- **查不到的档位退化成继承**，不是拒绝。切到一个没写这个档的 profile 时，继承是正确且可用的行为；一个因为换了 provider 就整个开不起来的 sub-agent 才是坏的。
- **`agent list` 必须把落点说出来**（新增一列：这个档位在当前 profile 落到哪个 model，或"未定义 → 继承"）。否则拼错一个档位名就是静默继承，没人看得见。
- **pair, never a mix 不变**：档位解析出来的永远是一对 `(profile, model)`——`<profile>/<model>` 形式换 profile，裸词形式沿用父 profile。

### D · per-agent effort

- 今天委派**根本不传** `--effort`（`runner.zig` 的 step argv 只有 `--stream` / `--max-steps` / `--gate`），所以每档单独调 effort 现在无从表达。
- 档位带 `effort` 时，nulya runner 的每一轮 `session step` 补 `--effort <e>`；不带就照旧（`Config.defaultEffort` 说了算）。
- profile 级的 `effort` 今天已经自动作用于子 session（子 session 用同一个 profile），那条不动。

### E · 外置 runner 不适用

`codex` / `claude` / `pi` / `ext:` 走 `runner_model`（别人家的目录，opaque）。它们的定义写 `@role` 与今天写 `model:` 一样，由 `crossCheck` 警告并丢弃——只需把那句话扩到认得档位形状。

### F · TUI

- `/model` 的行详情里把这一档的编队说出来（`explore→luna · review→terra`）。切换后的 notice 也说一句整支队伍变成了什么。**这是"选择器"那一半**：编队不能是只有写 config 的人知道的口头知识。
- 不新增屏、不新增命令。preset 名与快捷键**不做**（见 §2）。

### G · 文档同步（同一个 commit）

- `DESIGN.md` §9.5：`roles` 的形状、合并、trusted-only、"内核不读"。
- `default.toml`：注释说明裸词/斜杠两种值的含义。
- `extensions/guide/skills/guide/SKILL.md`：agent frontmatter 多了 `@role` 这一种写法——这是**用户可见语法**，漏了它下一轮 agent 会按旧语义办事。

## 2. 不做

- **不加 `[[presets]]`**。roles 落地后，"preset" 退化成 `/model` 选中的那一行 + 拨盘，它能再省的只有几下方向键。等真觉得不够快再说。
- **不动 header schema**：冻的仍然是解析后的 `(profile, model)`，档位名**不进 header**，也不进任何 wire。一个名字冻进去，resume 时它的含义可能已经变了。
- **不给内核加动词**：没有 `nulya config roles`、没有 `session new --role`。
- **不改 `model:` 的既有两种写法**（`<profile>` / `<profile>/<model>`）。`@` 是新增的第三种。
- **不做档位的固定词表**（`explore` / `review` 不是内核词汇）。

## 3. 解析落在哪一侧（已定）

**扩展自己解析，内核不加动词。** 扩展 shell 出 `nulya config show --json`，把档位解成 `(profile, model, effort)`：身份那两个给 `session new`，effort 给每一轮 `session step`。

考虑过并否决的替代：`session new --role <name>`（在冻结身份的那一处解析）。它只解决**身份那一半**——effort 是 per-step 选项、不冻进 header，解析出的 effort 要从 `session new` 再传回给 runner，而那个回传通道不存在，造一个就是给 `session new` 的 stdout 加契约。而扩展一次解析两半都拿到。且 `--role` 删掉不会让任何一条 physics 失效，是纯便利。

**"读到哪台机器的 config"这个顾虑随 [runs-on.md](runs-on.md) 一起消失**：`agent` 包声明 `runs_on: "session"`，于是它永远跑在**持有会话的那台机器**上，读的就是人写 roles 表的那份 config chain。两件事同一轮落地，不留窗口。

## 3b. 档位名从哪来（已定）

**一个什么模型都没写的定义，骑的是它自己的名字那一档**（`defs.rungOf`）。`model: @explore` 仍然是显式写法，用来把几个 persona 放到同一档上。

为什么补这一条：原来的形状要求"先有人去 `.nulya/agents/<name>.md` 里写 `model: @explore`，才谈得上配这一档"，于是屏幕上唯一能问的问题是"这一档叫什么名字"——一个要打字的框。**没人记得自己没写过的档位名**，这个提问方向本身是错的。让 persona 名字就是档位名之后，问题反过来了：**发现的 persona 就是一张可选的表**，选一个就是"让它跑在这一行上"。

`persona 本身就是一个 role` 是这条规则的全部依据，所以它落在 `extensions/agent`（谁骑哪一档是这个包的语义），内核那张 `roles` 表一个字都没改。写了 `model:` 的定义已经自己答过了，不骑任何一档。

## 4. 验收

守机制，不守细枝末节：

- config：roles 按 key 合并（不是整表替换）；project 层写 roles 不生效；裸串与表形解析成同一个东西。
- agent：四级解析顺序；未定义的档位退化成继承（**不是**报错）；`<profile>/<model>` 形式确实换 profile；外置 runner 上的档位被警告并丢弃；**没写 `model:` 的定义按自己的名字被 staff 到**（且 `list` 的 `rung` 列报得出来）。
- effort：档位带 effort 时子 session 的 step 真的带上了 `--effort`。
- 不断言具体文案、不逐一枚举档位组合。
