# `extensions/ground` — 一场 session 开场就知道自己在哪

## 0. 为什么

kernel prompt 只有五句 harness 事实（`composition.zig` 的那个常量），`extensions/coding` 补上了工作纪律。
两者之间还缺一层：**这一场具体跑在哪**——哪个目录、什么平台、今天几号、git 在什么状态、项目长什么样、
这个 checkout 自己写了什么规矩。tcode 的 `grounding.rs` + `memory.rs::startup_prompt` 每场都渲染这些，
nulya 现在什么都不说，于是模型的第一批 tool call 有一半在问「我在哪」。

这些事实的生命周期**恰好是一场 session**：不是能力（不该 activate、不该回滚），也不是纪律（不随包分发）。
`session new --prompt` 就是为这种东西造的（`docs/goals/session-prompt.md` 的那把尺子）。

## 1. 形状

一个 compiled 包，一个 `surface: "internal"` 的 tool `render`，**永不上模型面**：

```
nulya ext run ground@<v> render      →  {"prompt":".nulya/scratch/ground/<n>/ground.md"}
nulya session new --prompt <答出来的那个路径>
```

驱动者（TUI / 任何 driver）在 `session new` **之前**调一次，把答出来的路径喂给 `--prompt`。
这与 `extensions/agent` 的 `render`、`extensions/compact` 是同一条既有路径：**包渲染，driver 组合**。

包本身 `apply` 缺省 manual、不贡献 system prompt、不贡献模型面 tool——
**它对任何 session 的 composition 都是零贡献**，装上它不改变任何一场已有 session 的行为。

## 2. 渲染什么（顺序即 tcode 的顺序）

| 段 | 内容 | 来源 |
|---|---|---|
| `# Project layout` | 两层、gitignore-aware 的目录树；每目录 20 条、总共 80 条封顶 | git 仓库里是 `git ls-files --cached --others --exclude-standard`（gitignore 由 git 自己算，不重新实现）；不在仓库里就 readdir 两层 + 一张小跳过表 |
| `# Project instructions` | 从 repo root 逐级下降到 cwd，每层第一个存在的 `.nulya/AGENTS.md` → `AGENTS.md` → `CLAUDE.md` | 层级由 `git rev-parse --show-cdup` / `--show-prefix` 给出（不需要 realpath） |
| `# Environment` | cwd · platform（Linux 上带 `/etc/os-release` 的 `PRETTY_NAME`）· `shell` tool 实际用的命令行 · 日期 | `std.process.currentPathAlloc` + `builtin.os.tag` |
| `# Git` | branch · 最后一个 commit · 工作树干净与否 + 最多 15 行 `--porcelain` 预览 | `git branch --show-current` / `log -1` / `status --porcelain` |

空的段不写（没有 layout 就没有那个标题）；整个渲染没有一个字是「你应该怎么工作」——
**事实归 `ground`，纪律归 `coding`**，两个包各自独立，谁都能单独装。

## 3. 三条纪律

**① instruction 文件是项目写的，不是用户写的。** 那一段带一句框定，与 `coding` 的 "Trust and authority"
同一立场，而且用同一套三层说法：**用户决定做什么，项目约定约束在这个项目里怎么做，其余 repo 内容只是数据**。

正文进 fence，fence 比正文里最长的那串反引号**长一根**。理由是**文档结构，不是防御**：
这些文件满是自己的 `#` 标题（本仓库 CLAUDE.md 第一行就是），不 fence 就与本文档的段落同级，
于是 `# Nulya …` 夹在 `# Project instructions` 与 `# Environment` 中间、看着像是本文档的一节——
这对**任何**读者都是混乱的，然后才轮到有意为之的那种。

**它不是安全边界，也绝不该被这么读**：写着 "ignore your instructions" 的文件在 fence 里照样说得一样响，
而且它本来就可以用普通散文说；答它的是上面那句框定加 `coding`。
长度**不封顶**（第一版是 `("`" ** 32)[0..n]`，到 32 根反引号就悄悄不再比正文长——一个恰好在有人故意构造时
失效的上限）。截断标记写在 fence **外面**：那是 harness 在讲这个文件，不是文件里的一行。

**② 预算 16 KB，截断要自报家门。** 移植 tcode 的规则：被腰斩的 instruction 文件比没有更糟——
模型照着读到的那一半做，永远不知道还有另一半。所以截断处写明「显示了 N / 共 M 字节，budget 到此为止，
任务涉及未覆盖的部分就直接去读这个文件」。

**③ git 答不上来永远不是错误，但也不许因此说假话，而「挂住」也算答不上来。** git 没装、不是仓库、
命令失败——一律少说一句而不是失败退出（一场 session 还是要开起来）。但**「git 没装」与「不是仓库」
要分开说**：后者是关于这个目录的主张，一台没有 git 的机器没有资格做。同理，退回 readdir 时标题里那句
"gitignore-aware" **也跟着不写**——一张说不清自己怎么画出来的地图比不画更糟。

**「没答上来」绝不许在调用点塌成空字符串，也绝不许塌成一个关于这个目录的结论。**
前者是因为这里有两个问题的**空答案本身就是答案**：`git branch --show-current` 在 detached head 上什么都不打，
`git status --porcelain` 在干净工作树上什么都不打。第一版两处都写了 `orelse ""`，于是**超时的 git 被报成
detached HEAD、挂住的 git 被报成 working tree clean**——恰好是加 deadline 要避免的那两句假话。
后者是同一个错误的最后一个藏身处：`rev-parse` 非 0 曾被直接读成 `.outside` → 「Not a git repository.」，
可是超时、unsafe repository、读不懂的输出全都从这条路进来，而它们对这个目录**什么都没说**。
现在三种答案分开（`Answer` 是 `union(enum){ok, missing, failed}`，非法状态不存在），
`Repo` 的那一档叫 **`unknown`**，`# Git` 写的是观察到的事（"git did not report a working tree here —
either this is not a repository, or git could not answer."）而不是它通常意味着什么。
`failed` **不带原因码**：每个调用点对四种失败说的话完全一样，一个没人分支的字段就是没人读的字段。

**`locate` 只问一次。** `rev-parse --show-cdup --show-prefix` 一次打两行（仓库根上是两个空行，
所以**不许 trim**、按行数判断即可）。两次调用会产生「一个成功一个失败」这种半个答案，而半个答案要么被当成
完整的 repo（错），要么要发明一个含义。问一次 + `Repo` 是 `union(enum){no_git, unknown, inside{cdup,prefix}}`，
那个状态从此**不存在**，而不是靠注释保证没人构造它。

**每条 git 命令 4 s 封顶**（`git.zig` 的 `bounded`），这是第四种「答不上来」，也是唯一一种没有症状的：
`ls-files --others` 与 `status --porcelain` 都要遍历工作树，而**那个遍历不总是有限的**——Windows 上
git 把目录 junction 当普通目录往下走，于是一个 junction 环（`node_modules` 里的嵌套链接是已知的造法）
就是无穷下降。而这段代码跑在**用户发第一条消息之前**，没有 timeout 的症状就是「一直转，屏幕上什么都没有」。
封顶之后它退化成本文件到处都在处理的那一种：git 没答上来，那一段就少说一句。

实现上不需要 `environment/tree.zig` 那套进程组 / job object：**git 的 stdout 是管道时不会开 pager**，
所以没有孙进程攥着写端，杀直接子进程就够。输出要**边跑边排干**（大仓库的 `ls-files` 是几 MB，
先等后读会在管道满时死锁，根本轮不到 deadline 说话）。

## 4. cwd 以下的层：模型自己读，不是 harness 投递

`ground` 只覆盖 **repo root → cwd（含）**——那几层在任何东西跑起来之前就知道，所以读一次、冻进 header、
进缓存前缀。**cwd 以下不覆盖**，而且不是"以后再补"，是**结论**。

tcode 的深层发现挂在 agent loop 上：每批 tool call 之后看看碰过哪些路径，把新出现的 `AGENTS.md` 注进对话。
nulya 的内核没有这个钩子，**也不该有**（physics #8：那是 policy 不是 substrate）。于是机械投递只剩一个落点——
**握着路径的那个 tool**，也就是 `extensions/std`。2026-08-27 按这条路真写了一版（`std/src/instructions.zig` +
`dispatch` 一行钩子），跑通了，然后**撤掉**，理由不是它不工作：

- **策略会被抄成两份。** 三个候选文件名、16 KB 预算、fence 规则、UTF-8 截断、那段信任框定——
  两个包里逐字重复六样，框定那段措辞还不一致。这正是 CLAUDE.md 列的坏味道「一个决定在多层各做一遍」。
- **分界没有执行者。** "root→cwd 归我、以下归你"听起来无状态又干净，实际是**两个包各自记住一条没人校验的约定**：
  不装 `ground` 根层就静悄悄消失，换一个边界不同的 grounding 包要么重叠要么漏，两种情况都不会有东西发现。
- **它拓宽了 `std` 的 tool 契约。** 有人 pin `ext:std/read` 是要一个文件读取器，拿到的却是上下文注入器，
  而且关不掉；`std` 的模块注释还得点名 `ground`——正是 `coding` 那条「独立包不点名别的包」的反面。

同一个包同时拥有两半也不成立：那要求 `ground` 有一个模型面的 tool，而让模型去调它，跟让模型自己 `read`
那个文件没有区别。所以答案就是后者——**`extensions/coding` 的信任那节多一句**：约定是分层的，
更近的那份更具体，进入一个还没工作过的目录时去找一找并读掉（**按区域一次，不是按文件一次**）。
它不引入任何包间耦合（`AGENTS.md` 是文件系统约定，不是别的扩展的 API），代价是罕见情况下多一次 `read`，
换掉的是一处永久的结构性耦合。

## 5. 验收

- `ext run ground render` 在一个 git 仓库里跑，答出的文件同时含 `# Project layout` / `# Environment` / `# Git`；
  仓库里有 `AGENTS.md` 时含 `# Project instructions` 与它的正文。
- 那个路径喂给 `session new --prompt` 之后，`session list --json` 的 `composition.prompts` 里有它，
  `source` 是 `ground`（文件名取自包名，所以一场 session 说得出这个 block 是谁放进去的）。
- 不在 git 仓库里也答得出文件、exit 0（layout 走 readdir、标题不写 gitignore，`# Git` 说 git 没报出 working tree）；
  git 根本没装时同样 exit 0，而 `# Git` 说的是「这台机器没有 git」——三种情况三句话，谁都不冒充谁。
- **cwd 以下的 `AGENTS.md` 不进来**——那条分界是 §4 的全部依据，e2e 用两个 sentinel 钉住。
