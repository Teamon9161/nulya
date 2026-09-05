# Goal · mcp：一个 server 一个生成出来的包，工具面在 build 时冻死（2026-09-05）

> 这是一份**执行契约**。地图与 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §7.2.1 / §7.3 / §7.4 / §5.1 / §9。
> 计划里的那一句是 [PLAN.md](../PLAN.md) §3.11：「MCP client：一个 extension，把 MCP tools 适配成 `tool.Tool` 进 ToolSetSnapshot（同构）」。本文把那句话的**形状**钉死。
> 前置依赖：[ext-defaults.md](ext-defaults.md)（`tools[].recommended`）——本轮 B/C 两条读它。

## 0. 结论（一段）

**一个 MCP server = 一个生成出来的 extension 包。** 生成器在 **build 时**连一次 server、跑 `tools/list`，
把每个工具的 JSON Schema **原样**写进 `contributes.tools[]`，然后走 `ext build` 封版——于是
**version = hash(工具面快照)**，server 加了工具就是重新生成一个新版本、`activate`、下一场生效。
运行时是同一个二进制的另一半：每次调用被 spawn 一次，`NULYA_TOOL` 告诉它调哪个，连 server、
`tools/call`、把结果打到 stdout、退出。**内核零改动**——现成的 oneshot wire（§7.3）一个字节都不用加。

按字面读 PLAN 那句话（"运行时连上 server 问它有什么工具"）会同时撞两条 physics：§7.2.1 的
「**manifest 是 schema 唯一真相**，绝不启动 binary 再问它有什么」与 physics #2（composition 在 init 冻结）。
本文的形状不是绕开它们，是让它们替我们干活：**工具面快照成为冻结身份**，回滚就是 activate 旧版本。

## 1. 已定决策

### A · 两半一个二进制：`generate` 与调用

`extensions/mcp/`，**compiled**（要说 JSON-RPC 分帧、跨 Windows 与 POSIX，一个 manifest 只有一个
`interpreter`——与 `handoff` 逐条同理，PLAN §0.1 #3 给 Zig 留的正是这种情况）。

| tool | surface | 干什么 |
|---|---|---|
| `mcp_add{name, command?, args?, url?, ...}` | `internal` | 连一次、`tools/list`、把一个 **draft 包**写进 `.nulya/extensions/mcp.<name>/`，然后调 `NULYA_EXE ext build` 并把 version 报出来。**它不 activate**——那是人或 `ext activate` 的动作（§7.8：没有一个包能让自己进任何一场） |
| `mcp_list` | `internal` | 本机已生成的 server 包与它们的版本 |

**两个都是 `internal`，所以 `extensions/mcp` 永远不是任何一场的成员**，模型经
`nulya ext run mcp mcp_add --arg …` 调它（`ext run` 从不需要成员资格，§7.5）。这不是省事，是本轮的
承重决定：**一个包只在它的工具真要上模型面时才当成员**，否则它的 skill 会挤进每一场的
`<available_skills>`——而"怎么配 MCP"这件事一百场里发生一次，每场都占一行描述是纯浪费。
配置说明因此走 `nulya skill list` / `skill load`（决策 F），代价为零。

**当成员的只有生成出来的 `mcp.<name>`**：它只贡献工具、不贡献 skill。

生成出来的那个包 `mcp.<name>` 的 `runtime.entry` 指向**同一个 mcp 二进制**（`bin/` 前缀，`ext build`
按 §7.4 复用匹配路径命中同一份字节），所以不为每个 server 编一次。

### B · 名字必须前缀，因为撞名是硬失败

`registry.snapshotWith`（`src/registry.zig`）对 `DuplicateToolName` 是**硬失败**，两个 server 都有
`search` 就开不了场。生成器一律写 `<name>_<tool>`（`github_create_issue`）。

**这是好事，不要绕**：撞车在 composition 冻结那一刻当场炸并点名，不会有一个悄悄上了模型面的
同名工具。生成器只需保证前缀，剩下的交给内核那两行去查。

### C · 工具面预算：全部 `manual` + `recommended: false`

`max_tools` 缺省 20（`composition.zig`），而一个 GitHub MCP server 自己就三十几个工具。
答案已经在成员表那根轴上，不需要第二根：

- 生成的每个工具都写 `surface: "manual"` + **`recommended: false`**（ext-defaults 的那个键：
  "这是附赠品，要的人自己点名"）。
- 人在成员表里点名要的那几个：`--with mcp.github:create_issue,list_prs`。
- 只有被点名的才算预算（`composition.zig` 的 `builtin_count + out.items.len > opts.max_tools`）。

于是"装上一个五十工具的 server"与"模型面多五十个名字"**不是同一件事**——后者永远是人写的一行。

### D · 配置两层，是**约定**不是内核概念

先例已经有了，本轮只是第二个 consumer：`extensions/agent` 的定义住
`.nulya/agents/<name>.md`（workspace）与 `<NULYA_HOME|~/.nulya>/agents/<name>.md`（本机），近的赢，
内核对这两个目录一无所知。**mcp 照抄这个形状**：`.nulya/mcp/<server>.json` 与 `~/.nulya/mcp/<server>.json`。

分工是硬的，因为 store 是内容寻址且世界可读：

| 住哪 | 什么 | 为什么 |
|---|---|---|
| **包快照里**（`server.json`，进 version hash） | transport 的**形状**：`command` / `args` / `url` / 要读哪几个**环境变量名** | 换了命令就是换了这个包的身份，本该是新版本 |
| **包自己的两层目录**（永不进 store、永不进 hash） | 那几个变量的**值**（token / key） | secret 不进内容寻址的字节；physics #6 的 `isSecretKey` denylist 把 `*TOKEN*` / `*API_KEY*` 从子进程 env 里抹掉了（§9），所以**宿主 env 这条路是不通的，不要试图放宽 denylist** |

**内核 config 一个键都不加**：`[extensions]` 只有 `with`，"没有第二个键"（§9.5）是要守的。

### E · "装了但还没配"必须自己说得出来

这是本轮真正的产品级缺口，而且对 mcp 是必答题（不像 `agent` 自带四个定义，装上就能用）：
包进了成员表、工具面全是它的名字、然后每一次调用都失败。

**答案是一次干净的失败调用，不是一个新的 manifest 字段。** 缺配置时 runtime 退出非零、
stderr 一句话说清**哪个文件、缺哪个变量、去哪读**（自己的 skill ref）。stderr 就是模型读到的那句话
（§7.3：包必须独占 stderr），与「一个包解析不出来时，把它自己那句话说出来」是同一条纪律。

**不加 manifest 字段**："我还没被配置"是运行时事实，不是 schema；写进 manifest 就得由内核判真假，
而内核判不了。

### F · 教学：包教自己，`guide` 只教机制

**guide 是索引，不是容器。** 把 mcp 的配置正文合进 guide 的 SKILL.md 是本轮**明确拒绝**的形状，
四条理由：guide 的 skill body 是它自己那个内容寻址版本里的**冻结字节**（physics #5），
运行时往里合别人的文本 = 一个**第二写者**，且合出来的东西**没有版本身份**（说不出模型读到的是哪些字节）·
抄一份就必腐（mcp 换了格式，guide 的副本没人管）· 内核得认识 `guide` 这个名字，
为一个包长一个概念（physics #8）。

分工因此是：**guide 只路由，每条路由的终点是一条与代码同源的命令**——这正是
`nulya help` / `nulya src` / `ext api` 已经在用的那条纪律（"只指路不复制，所以不会漂"）。

- `extensions/mcp` 自带 `contributes.skills`：怎么加一个 server、配置文件长什么样、
  怎么点名工具、怎么换版本。这是**这个包自己的**真相，随它的版本走。**标 `surface: "reference"`**
  （[discoverable.md](discoverable.md) 决策 B）：这个包今天不当成员，标了它将来也不会因为
  谁把它写进 `with` 就在每一场多印一行手册描述。
- `guide` **不提 mcp 三个字母**，只补两句机制到 `## Finding your way` / `## Configuring`：
  1. **`nulya skill list` 的作用域是本机所有 `current` 指到的包（`extension/skills.zig` 的
     `listActive`），不是你这一场戴着的那些。** 今天 guide 与 `nulya help` 都只说"the catalog"
     / "available here"，两处都读不出这个区别——而整条"配一个没戴的包"的路就架在它上面。
  2. **这个二进制自带哪些包**（`nulya ext list` / `ext seed`）。bundled 清单随二进制走，
     guide 也随二进制走，所以这一句**零腐烂风险**；没有它，一个还没装的能力连发现都发现不了。

于是完整的链是：kernel prompt → `nulya help` → `guide` → `nulya skill list` → `skill load mcp/…`。
**每一跳今天都已经存在**，本轮只是把第 3 跳那句话说准。

### G · 面板：v1 不做

`contributes.ui.tui{entry, api}` 与 plugin host 的 `OpenPanel` 已经能表达"一个管理 server 的面"
（`plan` / `ask` 是先例），`tui.toml` 的 `[extensions] plugins` 是总开关。但 v1 的地板足够：
`contributes.commands` 声明 `/mcp`（没装代码插件时的降级地板）+ `mcp_list` 的输出。
**等真的被"看不见 server 状态"绊到再做**——那时它是 `tui/` 的一次加法，不是这个包的阻塞项。

### H · 成本：先测量，要常驻由包自己起

每次调用冷启一个 node server（0.5–2 s）。纪律是 §7.3 那条**先测量再持久化**。真疼的时候：
**那个包自己**留一个常驻进程（首调起、之后走命名管道 / unix socket），完全在它自己的权限里，
内核不知情。**绝不拿它当理由去做内核里的 persistent extension runtime**——那是 PLAN 里"没做的"
一项，它的第一个 consumer 必须带着实测数字来。

### I · 不做

- **运行时工具发现**（`tools/list_changed`、session 中途长出新工具）。server 改了 = 重新生成 = 新版本 = 下一场。
- MCP 的 resources / prompts / sampling / elicitation。sampling 需要一条回打的通道，
  而 §7.3 明写不做 host callback；prompts 将来若要，形状是 skill 不是新机制。
- **不给内核 config 加 `[mcp]` 之类的表**（D）。
- **不放宽 `isSecretKey`**（D）。

## 2. 验收（e2e，挂 `tests/e2e_ext.zig`）

用一个**离线 fake MCP server**（一个脚本，说得出 `initialize` / `tools/list` / `tools/call`），不联网：

1. `mcp_add` 生成的 draft 经 `ext build` 封版；**同一个 fake server 再生成一次，version 逐字节相同**（内容寻址成立）；fake 多报一个工具，version 变。
2. 生成的 manifest 里工具名全部带前缀、全部 `surface: "manual"` + `recommended: false`；两个 server 声明同名工具时，同时点名它们的 `session new` 以 `DuplicateToolName` **失败并点名**。
3. 一次真实调用走完模型面：`--with mcp.fake:echo` → `session step` → tool_results 是 server 的答案。
4. **缺配置**：删掉配置文件后同一次调用是一次**失败的调用**（`ok=false`），文本里有那个文件的路径与 skill ref，**不是 host error**。
5. `nulya skill list` 在这个包**只 activate、不是成员**时列得出它的 skill（F 那条链的守门测试）。

> 第 4、5 条是本轮的**验收下限**，不是加分项：它们守的正是「装了但没配」与「没戴也找得到」这两件本轮真正新增的事。

## 3. 同一 commit 内必须同步的

`docs/DESIGN.md` §7.8（自带扩展表加一行）· `CLAUDE.md` 现状段的自带扩展清单 ·
`extensions/guide/skills/guide/SKILL.md`（**只加 F 那一小节机制，不提 mcp**）·
`docs/PLAN.md` §3.11 删掉 MCP 那一行、M8 相应收窄。

## 4. 落地记录（2026-09-05）

`extensions/mcp/`（六个 zig 文件 ~1360 行 + 一个 `reference` skill）+ `tests/e2e/mcp.zig`。
**`src/` 一个字节未动**——本轮的中心主张成立。`build.zig` 多 14 行（照 `ground_ext_mod` 的写法给这个包
挂单测，rooted 在 `gen.zig` 而不是 `main.zig`：test 模式下没有东西到达 `main`，一个自己没有 test 的根
收不到它 import 的那些）。

**形状比契约写的更省一层**：一个二进制两个身份，靠自己旁边有没有冻着 `server.json` 分辨（生成器 / 就是
那个 server 的包）。生成出来的包带着同一份源码，所以没有第二份实现要同步。细节进了 DESIGN §7.8。

验收五条全过：`zig build test` 629/633（4 skip）· `zig build e2e` 184/191（7 skip），两条都 exit 0。

**实测的三个数**（契约 §1 H 说先测量）：一次调用端到端 **~204 ms**（`ext run` 启动 + seal + spawn +
PowerShell 假 server 冷启 + 握手 + `tools/call` + 拆除），连着五次 1.02 s——真 node server 会被它自己的
启动主导。`mcp_add` 一个新工具面 **~8.9 s**（几乎全是 `zig build-exe`），不变的重复生成 **0.31 s**。
**没有加任何持久化**。

### 契约错了一处，判断留了四处

1. **§1 A 的复用主张是错的。**「`ext build` 复用匹配路径命中同一份字节，所以不为每个 server 编一次」
   不成立：seal 的复用键是 `package_digest + target + compiler`，而每个 server 的 `extension.json` 都不同，
   所以**每个不同的工具面各编一次 ~9 s**；只有不变的重复生成才命中复用。后果要写下来：**`mcp_add` 需要
   工具链**。没有工具链时 draft 照写，消息里原样引内核自己的 `ZigVersionUnreadable` 那句话。
2. **§1 D 的两层，两个判断**（这是我当初最不确定的一节，结论是它站得住：值不碰 store、不放宽 denylist、
   这个包做的事不比一条 `shell` 命令更多）：① 层是**近的整份赢**而不是逐键合并——照抄 `agent` 的
   `.nulya/agents/` 先例，代价是 workspace 那份要写全，换来的是「哪一份在生效」只有一个答案；
   ② 一个读得出但不是 `{"env":{…}}` 的文件是**错误**，不是穿透到下一层——穿透会让 server 拿着另一层的
   凭据跑，而写文件的人以为自己改的那份在生效。
3. **拒绝里的 skill ref 是一个模式加一条命令**，不是一个具体的冻结 ref。具体 ref 得住进 `server.json`，
   而那在快照里——于是 `mcp` 每前进一个版本，所有生成包的身份都跟着动，哪怕 runtime 一个字节没变。
   §1 E 那句「自己的 skill ref」按版本无关的那种读法实现。
4. **`url?` 声明了但当场拒绝**（"stdio only"）。`mcp_add` 是 `internal`，schema 不花模型注意力，
   而悄悄不声明只会让人试一次失败之后才读成「还不支持」。
5. **§2 第 2 条的「失败并点名」到内核为止**：`session new` 打的是 `session new failed: DuplicateToolName`
   ——错误点名了，撞名的那个工具没有。要它说出是哪个工具得改 `src/`，本轮不改。

### 一个值得记下来的坑（Windows）

扩展 spawn 出来的子进程会继承**扩展自己的 stdout 写端**（Zig 0.16 的 spawn 没有 handle allowlist），
所以一个起了长命助手进程的包**必须在自己退出前杀掉它**，否则调用方在一个永远不会到来的 EOF 上等到超时。
而且 MultiReader 要在 kill **之后**拆，绝不能在之前——它那些停着的读只有在持有写端的进程消失之后才结束。
两条都写在 `client.stop` 里。这与 supervisor 那边的 `closeInheritedStrayPipes`（DESIGN §8）是同一类事实的
两个面。
