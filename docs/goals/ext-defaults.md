# Goal · ext-defaults：安装时默认值回来，落在 `activate` 而不是 composition（2026-09-04）

> 这是一份**执行契约 + 落地记录**。地图与 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §5.1 / §7.2.1。
> 前史两轮：[ext-syntax.md](ext-syntax.md)（引入包级 `apply` 与 `tools[].recommended`）与
> [core-review.md](core-review.md) §1.4 / Lane C（连同 pin 家族一起删掉）。本轮**恢复表达力，但换一个落点**。

## 0. 结论（一段）

Lane C 砍掉**两根轴**是对的，砍掉 `apply` / `recommended` 是**记账错误**：它们不是第二根轴，是
同一根轴（成员表）的**安装时默认值**。删掉它们不减少内核状态——它们的读者本来就该在壳层——
只是把"装了就生效"这句话转嫁成每台机器上的一次手工配置。

本轮的形状：**manifest 说得出"装我的人多半想要什么"，`ext activate` 读它、把那句话写进成员表，
人看得见、改得掉、删得掉。** 内核的 composition 解析路径里没有这两个字段的名字，一个都没有。

## 1. 已定决策

### A · 两个键回来，身份是 **driver 声明**（DESIGN §7.2.1 三层听众的第二层）

- **`apply: "auto" | "manual"`**（顶层，缺省 `manual`，闭合词表，别的词是 `InvalidApply`）：
  "把我装上的人，多半想让我进每一场。"
- **`tools[].recommended: ?bool`**（缺省 **null = 没说**，读作 true；只对 `surface:"manual"` 有意义，
  写在 `auto` / `internal` 上是 `InvalidRecommended`）："这个 manual 工具装上就该开"
  / `false` = "这是附赠品，要的人自己点名"。
- 纪律与 `tools[].readonly` / `contributes.policy` **逐条相同**：kernel parse + validate 闭合词表 +
  冻进版本的 manifest，**一个字节都不据此行动**。它们不在 `composition.zig` 里有任何读者。

### B · 唯一的读者：`ext activate`（`cli/ext.zig`，壳层）

`nulya ext activate <id> <version>` 在移动指针**之后**多做一件事——把这次启用记进
**user 配置的 `[extensions] with`**：

| manifest 说 | 写进成员表的那一行 |
|---|---|
| `apply: "auto"` | `<id>`（裸 id：带它全部 `auto` 工具、prompts、skills） |
| 有 `recommended ≠ false` 的 manual 工具 | `<id>:a,b`（选上那些工具） |
| `apply: "manual"` 且无 recommended manual 工具 | **不写**，照旧只打今天那行提示 |

`nulya ext deactivate <id>` 对称：撤指针，同时把那一行从成员表里拿掉。

- **写法**：按行做外科手术，只碰 `[extensions] with` 那一个键，保住注释与排版；写完**读回来核对**，
  对不上就把原字节放回去。语义与前端那份逐条相同（`tui/src/face.ts` 的 `setMembers` /
  `writeUserMembers`），Zig 侧是它的同形实现，落在 `cli/`——**内核不写配置**。
- **打印**：写了什么就说什么（哪个文件、哪一行、占几个槽），一行。

### C · 边界

| 情况 | 行为 |
|---|---|
| `ext seed` / `ext sync --activate` | **只移指针，绝不写配置。** 批量路径一次十个包，静默常驻是灾难；改成末尾一行"这几个声明了 `apply:auto`，接受就跑这条命令"。 |
| workspace 层 activate | 不写。project 层配置只能收窄（§9.5），在那里加成员没有意义。 |
| 写进去会越过 `max_tools` | **整批不写**，一行说明差几个槽。先例：`tui/src/extensions.ts` 的 `selectInstalled`。 |
| 配置解析不了 | 拒绝，原样退回，不替人格式化他自己的文件。 |
| 那一行已经在（人自己写过、或改过选择） | 不动。安装默认值只在**没有答案**时给答案，永不覆盖人的答案。 |
| `ext activate --no-with` | 只移指针的逃生口（脚本 / CI / 不想被写配置的人）。 |

### D · 不做

- **不给 composition 加第三个成员来源。** `resolveApplyAutoExtensions` 不回来，`Options.apply_auto`
  不回来，`current` 的 `apply=` 列不回来，`Store.Active.standing` / `Roots.ActiveEntry.standing` 不回来。
- 不加"永不进"的第三个词（`apply: "never"`）：`manual` 已经是"只有点名才进"。
- 不为旧 store 造迁移：pre-release，重跑一次 `ext activate` 就是修法。

### E · 这一版顺手消灭的那个旧问题

ext-syntax.md §5.2 记着 `apply:auto` 当年的真实缺陷：包被激活之后，篡改它冻结的
`extension.json` 能**悄悄关掉一段常驻 system prompt**，任何一环都不报错。当时的修法是把状态复制进
`current` 多加一列——而**那一列正是 core-review §1.4 给 `apply` 定罪的成本**。

本轮不需要那一列：manifest 只在 `activate` 里、在 `.sealed` 校验**之后**被读一次；此后成员表是唯一
真相，而成员表是人自己文件里的一行文本。事后篡改冻结的 manifest 改不动它，也骗不了任何人——
composition 解析成员时走的仍是今天那条 `.sealed` 路。**问题连同它的解药一起消失。**

## 2. 防再次删除的五道闸（按硬度排序）

上一次它被删，不是因为有人反对这个语义，是因为**在内核里它看起来像个只写不读的字段**，
而 CLAUDE.md 明写"一个字段只写不读……是该删或该收的信号"。所以护栏的第一条不是文档，是读者。

1. **e2e 钉子（唯一机器执行的一道）** —— 三条，守机制不守细节：
   `activate` 一个 `apply:"auto"` 的包 → 下一场 fresh session 带着它的 prompt；
   一个 `recommended:false` 的 manual 工具 → 不在写出的选择里，同包别的在；
   `ext seed` → 配置文件一个字节不变。删掉字段 = 三条红，不需要任何人读文档。
2. **`manifest.zig` 的字段文档写出具名读者** —— driver 声明那一段（`readonly` / `policy` 的邻居）
   写明：*read once at activation time by the CLI's activate path and the front end's install path;
   never by the kernel*。有具名读者的字段不再符合"只写不读"的删除信号。**不写文档指针**（源码不引用 docs）。
3. **DESIGN §7.2.1 那句话补上后半句。** 今天的原文是
   「**manifest 说不出"我进哪一场 session"**……**没有任何 manifest 字段能决定 reach**」——
   本轮**不推翻它**，reach 仍只由成员表决定；但要补上
   「……**说得出"装我的人多半想要什么"**：`apply` / `recommended` 是安装时默认值，读它们的是
   `ext activate`，写下的结果是成员表里人看得见的一行。」
   缺了这半句，下一个评审员读到的就是一条自相矛盾的现状，删除是他的正当推论。
4. **DESIGN §17 加一行**（那张表就是为"别再提一遍"存在的）：

   | 方案 | 否决理由 | 节 |
   |---|---|---|
   | 删掉包的安装默认值，让人手写 `[extensions] with` | 默认值不是第二根轴，是同一根轴的安装时默认；删它不减内核状态（读者在壳层），只把表达转嫁成每台机器的手工配置 | §5.1 |

5. **修正 core-review.md §1.4。** 那一条现在还原样主张 `apply` / `recommended` 属于"词汇表巴洛克化"，
   **它就是下一次删除的授权书**。在它下面补一条 `2026-09-04 修正`：两根轴该砍，把同一根轴上的
   安装默认值一并砍掉是记账错误；恢复形态是 driver 声明 + 壳层读者。

> 五道闸只有第 1 道挡得住不读文档的人。所以 e2e 那三条是本轮的**验收下限**，不是加分项。

## 3. 同一 commit 内必须同步的

`docs/DESIGN.md` §5.1 / §7.2.1 / §17 · `docs/goals/core-review.md` §1.4 修正 ·
`CLAUDE.md`（模块表 `extension/manifest.zig` 那一行 + 现状段）·
`extensions/guide/skills/guide/SKILL.md`（用户可见语法改了就必须同步，CLAUDE.md 工作约定）·
`cli/ext.zig` 内嵌的 `ext api manifest` 文本 · `tui/src/extensions.ts` 的 `selectableToolsOf` 认
`recommended`（今天它只能一股脑拿走全部 manual 工具，正是这个键缺席的代价）。

顺手清掉的死物：`~/.nulya/config.toml` 的 `[registry] pinned_native_tools`（键已删、无人读）·
`nulya-kit` 两个 manifest 里今天没人读的 `apply`（改完就又有人读了）· kit README 那句
"installers 不编辑 Nulya config"。

## 4. 落地记录（2026-09-05）

- **A · 两个键回来** ✅ `manifest.Apply` + `Manifest.apply`（顶层，as written）+ `applyOf()` + `InvalidApply`；
  `ToolSpec.recommended` + `recommendedOf()` + `InvalidRecommended`（写在非 `manual` 工具上是 validate 错）。
  两个字段的文档里写死了**具名读者**（"read once at activation time by the CLI's activate path and a front
  end's install path; never by the kernel"）——上一次它们被删，直接原因就是在内核里看起来像只写不读的字段。
- **B · 唯一的读者** ✅ 新模块 `src/cli/members.zig`：`read` / `setMembers`（按行外科手术，括号计数跨行、
  引号内的 `]` 不算收尾）/ `add` / `remove`，每次写完读回来核对，对不上就把原字节放回去；三条单测钉住
  "别的字节都活着"、"多行数组是一个跨度"、"没有表就补一个表"。`cli/ext.zig`：`installerSpec`（manifest →
  一行成员 spec）· `recordInstallerDefault`（activate 的写入与四种说法）· `forgetMembership`（deactivate
  的对称撤销）· `takeNoWith`（`--no-with`）· `BudgetGate`（拿**内核自己的** `SessionComposition.init`
  当 `max_tools` 的裁判，不复制"哪些工具上面"的规则）。
- **C · 边界** ✅ workspace 层指针只说不写（project 层的 `with` 是整表替换，写一行会盖掉用户的列表）；
  `ext sync --activate` / `ext seed` 只移指针，末尾一行点名哪些包提了要求（`appendActivation` 因此改成
  返回"这次移了没有"）；配置读不出来就原样退回。
- **D · 前端跟随** ✅ `Contributions.recommendedTools` 投影 + `recommendedToolsOf()`；**写选择**的三处
  （`selectInstalled` 两处、`sessionMember` 的 tools）改读它，**给人勾选**的两处（`/ext` 的 `pinnable`）
  仍读 `selectableToolsOf`——这两个问题本来就不是一个问题，`recommended` 缺席时前端只能一股脑全拿。
- **E · 三颗钉子（`tests/e2e/ext_cli.zig`）** ✅ `apply:auto` 的包 activate 之后下一场 session 带着它、
  deactivate 之后不带；`recommended:false` 的工具不在写出的选择里、同包另一个在（并且模型面上确实只有一个）；
  `ext sync --user --activate` 移了指针而配置一个字节没变。**删掉任一字段，这三条变红。**
- **F · 文档** ✅ DESIGN §5.1（activate 写什么、四条边界）· §7.2.1（听众表加第四层 + 那句"没有任何 manifest
  字段能决定 reach"补上后半句）· §17（新增一行，见 §2.4）· core-review §1.4 的 2026-09-04 修正 ·
  CLAUDE.md（现状段、模块表两行）· `extensions/guide/skills/guide/SKILL.md`（Installer defaults 一节）·
  `ext api manifest` 的内嵌文本（第四类听众）。
- **G · 顺手修掉的既有断裂**（与本轮无关，但挡着验收）：`6b3632a` 给 `SessionComposition.init` 加了
  `dialect` 参数却没有改 `tests/` 里的 13 个调用点，`e2e-ext` / `e2e-core` / `e2e-std` 在本轮之前就编译不过。
  加 `support.hostDialect()`（问一个真的 LocalEnvironment，与 `background.zig` 已有的那个同源）并穿到各调用点。
- 验收：`zig build test` 620/624（4 skip）· `e2e-ext` 50/51（1 skip）· `e2e-core` 65/66（1 skip）·
  `e2e-std` 8/8 · `e2e-agent` 24/24 · `e2e-remote` 33/38（5 skip）· `tui/` `bunx tsc --noEmit` 干净、
  `bun test` 全绿。
