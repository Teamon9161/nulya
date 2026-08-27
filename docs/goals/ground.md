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
nulya ext run ground@<v> render      →  {"prompt":".nulya/scratch/ground/ground.md","bytes":N}
nulya session new --prompt .nulya/scratch/ground/ground.md
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

**① instruction 文件是项目写的，不是用户写的，而且它们必须进 fence。** 那一段带一句框定，
与 `coding` 的 "Trust and authority" 同一立场：项目的约定该跟，与用户当下要的东西冲突时用户说了算。
框定之外还要 fence，且 fence 比正文里最长的那串反引号还长——这些文件满是自己的 `#` 标题
（本仓库的 CLAUDE.md 第一行就是），不 fence 它们就与本文档的 `# Environment` 同级，
于是一个**随 clone 到达**的文件能伪造「项目说的」与「harness 说的」之间那条线。截断标记写在 fence **外面**：
那是 harness 在讲这个文件，不是文件里的一行。

**② 预算 16 KB，截断要自报家门。** 移植 tcode 的规则：被腰斩的 instruction 文件比没有更糟——
模型照着读到的那一半做，永远不知道还有另一半。所以截断处写明「显示了 N / 共 M 字节，budget 到此为止，
任务涉及未覆盖的部分就直接去读这个文件」。

**③ git 答不上来永远不是错误，但也不许因此说假话，而「挂住」也算答不上来。** git 没装、不是仓库、
命令失败——一律少说一句而不是失败退出（一场 session 还是要开起来）。但**「git 没装」与「不是仓库」
要分开说**：后者是关于这个目录的主张，一台没有 git 的机器没有资格做。同理，退回 readdir 时标题里那句
"gitignore-aware" **也跟着不写**——一张说不清自己怎么画出来的地图比不画更糟。

**每条 git 命令 4 s 封顶**（`git.zig` 的 `bounded`），这是第四种「答不上来」，也是唯一一种没有症状的：
`ls-files --others` 与 `status --porcelain` 都要遍历工作树，而**那个遍历不总是有限的**——Windows 上
git 把目录 junction 当普通目录往下走，于是一个 junction 环（`node_modules` 里的嵌套链接是已知的造法）
就是无穷下降。而这段代码跑在**用户发第一条消息之前**，没有 timeout 的症状就是「一直转，屏幕上什么都没有」。
封顶之后它退化成本文件到处都在处理的那一种：git 没答上来，那一段就少说一句。

实现上不需要 `environment/tree.zig` 那套进程组 / job object：**git 的 stdout 是管道时不会开 pager**，
所以没有孙进程攥着写端，杀直接子进程就够。输出要**边跑边排干**（大仓库的 `ls-files` 是几 MB，
先等后读会在管道满时死锁，根本轮不到 deadline 说话）。

## 4. 逐级发现（`root → cwd` 在这里，`cwd` 以下在 `std`）

tcode 的深层发现挂在 agent loop 上：每批 tool call 之后看看碰过哪些路径，把新出现的 `AGENTS.md` 注进对话。
nulya 的内核没有这个钩子，**也不该有**（physics #8：那是 policy 不是 substrate）。

不改内核的做法是：**发现住在已经知道路径的那个 tool 里**——也就是 `extensions/std`。
它的 `read`/`edit`/`grep`/`glob` 每次调用都拿着一个具体路径，也已经有一份 per-session 的磁盘状态
（`.nulya/scratch/<sid>/std-freshness.jsonl`），把「这一场已经交出去过哪些 instruction 文件」记在同一处即可，
新发现的内容追加在它自己那次 tool result 后面。**没有新事件、没有新盘面文件、没有 driver 要学的新 folklore。**

两个包不需要共享状态，因为分界是**无状态**的：

- `ground` 负责 **repo root → cwd（含）**——它在 `session new` 之前跑，冻进 header，进缓存前缀。
- `std` 负责 **cwd 以下**——那些目录只有真的碰到文件才知道要不要读。

零重叠、零协调。这一半**不在本轮范围内**，本轮只落地 `ground` 并把这条分界定下来。

## 5. 验收

- `ext run ground render` 在一个 git 仓库里跑，答出的文件同时含 `# Project layout` / `# Environment` / `# Git`；
  仓库里有 `AGENTS.md` 时含 `# Project instructions` 与它的正文。
- 那个路径喂给 `session new --prompt` 之后，`session list --json` 的 `composition.prompts` 里有它，
  `source` 是 `ground`（文件名取自包名，所以一场 session 说得出这个 block 是谁放进去的）。
- 不在 git 仓库里也答得出文件、exit 0（layout 走 readdir、标题不写 gitignore，`# Git` 说 not a git repository）；
  git 根本没装时同样 exit 0，而 `# Git` 说的是「这台机器没有 git」而不是「这不是仓库」。
- **cwd 以下的 `AGENTS.md` 不进来**——那条分界是 §4 的全部依据，e2e 用两个 sentinel 钉住。
