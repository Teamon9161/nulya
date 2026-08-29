# Remote environment — 工作区住在别的机器上

> **状态：设计已审阅通过；§4 的 Phase 1–3 已落地**（2026-08-29，见 DESIGN §8 的第四个动词、§8.2 的 `remote:` 一族与 §14 的 `remote` 动词族；
> Phase 3 的 `ext build --target` / `ext push` 见 §6.3，`ExtensionRequest` 搬迁与 header 的 `exec_version` 见 §6.4。TUI 那半同日另一轮落地（tui.md T101/T102：`/env` remote 档 + 远端目录浏览、`/ext` 的 push 动作；per-target 常驻状态列经裁决不做，见 T102））。
> Phase 4–5 未实施。原有的 [DESIGN §8/§8.1](../DESIGN.md) exec target（`session new --env wsl|ssh`，**只有 `shell` 的命令移动**）；
> 方向笔记在 [PLAN §3.8](../PLAN.md)（「真·remote environment = 第二个 `Environment` 实现」）。本文件答那一节列出而没答的缺口。
> 八条 physics 与「内核只长 substrate」是尺子（[CLAUDE.md](../../CLAUDE.md)）。

## 0. 为什么

今天的 `--env ssh:<dest>` 是**裂脑**的：`shell` 的命令在远端跑，而 `ext:std/read` 是 host 上的一个进程、读的是**本地**盘。
对 ops 型任务（"去那台机器上重启一下服务"）这条边界够用且诚实；对"这个项目住在那台机器上"不够用——
模型 `grep` 出来的是本地的文件，`shell` 里 `cat` 的是远端的文件，两个答案说的不是同一个仓库。
过渡期的止血是 TUI 的 per-env profile（tui.md T88：ssh 场干脆 `bare=true`、一个 std 都不带），
这是对的止血，也正好说明了病：**能力被关掉，不是因为它没用，是因为它在错的机器上。**

要的东西一句话：**harness 与模型连接留在本机，工作区（以及一切读写它的东西）住在远端。**

## 1. 目标 / 非目标

**目标**

- `shell`、`extensions/std` 的六个 tool、以及任何 workspace 型 extension，**一字不改**地作用在 wsl / ssh 的那台机器上。
- 每个 tool call 不付一次连接握手。
- 取消与超时**真的**结束远端那个进程，而不只是本地客户端。
- 远端**永远不需要 API key**，也永远不持有这场对话的转录。
- TUI 能选机器、能浏览那台机器上的目录、能记住每台机器上次工作在哪。

**非目标**

- **不做 sandbox。** 与 §8.1 同一句话：换的是命令**在哪跑**，不是**跑的时候能碰什么**。远端就是那个账号的全部权限（PLAN §3.8）。
- **不做双向同步 / 网络文件系统。** 见 §3.8 被否掉的备选。
- **不把整个 harness 搬到远端。** 那是另一个形状，已经能做，且不需要 nulya 写一行代码（§3.8）。
- **不做远端自演化。** 演化循环（`ext build` → `activate` → usage journal → outcome journal）整套留在 host，
  远端 store 是**只收不建**的。理由见 §3.1 末尾。
- 不做流式的远端输出（v1 的协议里 `shell` 仍是"跑完再返回"，与今天的 local 一样）。

## 2. 结论：形状

**一句话：`Environment` 的第二个 vtable 实现，而实现它的远端进程就是 nulya 自己。**

```
host                                                   remote
┌──────────────────────────────────────┐               ┌───────────────────────────┐
│ ledger / journals / store(宿主面)     │               │ 工作树                     │
│ provider 连接 / credential            │               │ .nulya/scratch/<sid>/      │
│ driver（TUI）· gate · approvals       │               │ store(远端面：bin/)        │
│                                      │  一条常驻通道  │                           │
│ RemoteEnvironment ───────────────────┼──────────────▶│ nulya remote serve         │
│   runShell / runExtension /          │               │   Tree · 净化 env · 超时    │
│   startShellTask / putWorkspaceFile  │               │   spawn 命令与 extension   │
└──────────────────────────────────────┘               └───────────────────────────┘
```

三条支撑它的既有事实（**都不是要新造的东西**）：

1. **`Environment` 这个缝早就在那儿**（DESIGN §8）：`shell` 与 extension 从不裸 spawn，全走它。三个动词一起搬，工具无知。
   这也正是 T86 选 `switch` 而不是独立类型时写下的翻转条件——当时三个 target 之间变的只有 argv 一个决定；**三个动词都要变的那天到了。**
2. **模型面上没有绝对路径。** `cwd` 一律是 `"."`（`loop.zig` / `session.zig` 的 `tool_context`），
   spill footer 与 task 的 `log_path` 经 `emit.joinRel` 一律是 `/` 分隔的 workspace 相对路径，
   `std` 显示用 `relDisplay`。**于是"翻译路径"这件事根本不存在**——每一侧把 `.` 理解成自己那个工作区就对了。
   （对比：`--env wsl` 之所以要 `wslPath`，恰恰是因为它**没有**搬工作区，两侧说的是同一个目录的两个名字。）
3. **remote 那半就是这个二进制的又一个壳层角色**，与 `nulya task supervise` 同一先例：
   单文件分发、`nulya src` 自描述、`Tree` / `isSecretKey` / `emit` 全部现成，**两台机器上跑的是同一份实现**。

**内核长的是 substrate**：一个 vtable 实现 + 一个壳层动词族（`nulya remote …`）。
**智能仍在外面**：哪台机器、什么时候把包推过去、要不要在 ssh 场里带 std——全是 driver / 人的决定，内核一个字不判断。

## 3. 逐条结论

### 3.1 extension 子进程在哪跑：**远端**

**结论**：跟着走。`runExtension` 是三个动词之一，`std/read` 必须读远端的盘，否则这条边界仍然裂脑。

**二进制怎么到远端**——三块拼图已经躺在设计里，不需要新概念：

- **version id 本来就含 target**（DESIGN §7.4，只对 `compiled` kind 非空）。"给远端 linux 编的 std" 天然是**同一个包的另一个版本**。
- **Zig 交叉编译**：`nulya ext build <path> --target <triple>` 在 host 上出远端二进制，**远端不需要工具链**。
- **内容寻址让同步是幂等的一次拷贝**：`nulya ext push <id>@<v> --env <spec>` 把 `versions/v-<hash>/` 整树复制进远端 store root，
  远端按 `.sealed` 复验（DESIGN §7.4 的 donor 复制路径，只是这次跨了一台机器）。**hash 就是校验**，重复 push 是 no-op。

**谁解析"跑哪个文件"：远端自己。** `ExtensionRequest` 今天带的是 host 解析好的绝对 `entry_path`；
改成带 **`(id, version, tool)`**，由执行那一侧解析 entry 变体、验 `.sealed`、拼路径。三条理由：

- 按 OS 选 entry 变体（`store.versionRuntimeEntryPath`，DESIGN §7.1）读的是 `builtin.os.tag`——**执行方的 OS**，不是 host 的。
  让 host 去猜远端该跑 `run.ps1` 还是 `run.sh` 是把一个答案抄成两份。
- integrity 该在**持有那些字节的机器**上验，否则 host 验了 host 的副本、跑的是远端的副本。
- host 从此完全不需要为远端的路径建模。

这是**收窄而不是加东西**：DESIGN §7.5 说"composition 冻结时解析出绝对 `entry_path`，运行期绝不二次读 `current`"——
后半句的保证来自**版本被点名**，不来自路径；`(id, version)` 本来就冻在 header 里。绝对路径是一个纯 host 事实，从来不必冻。

**一个包的两个 target 版本，冻结身份是什么**（PLAN §3.8 列的那个缺口）：

> **结论：两个 id 都冻。** 成员是 `(id, v_host)`（宿主面：manifest / prompt / skills / ui entry / driver tool），
> 远端场额外冻 `exec_version = v_remote`。host 从**自己的 store**按 `package_digest + target` 反查 `v_remote`
> ——那正是 donor 匹配已经在用的那把键（DESIGN §7.4），零新概念。
> `data` / `script` kind 两者相等（纯 snapshot 身份），所以只有 compiled 包才有第二列。
>
> **被否掉的备选**：把冻结身份收敛到 package snapshot digest、per-target 二进制降格为派生 artifact（PLAN 里的候选答案）。
> 它要改 store 布局、seal 与 composition 的 schema，换来的是少记一列；而代价是**溶掉「一个 version id 恰好命名一份可执行字节」这条性质**
> ——那条性质正是 `.sealed` 与 usage journal 的 `version` 列（DESIGN §5.5）赖以成立的东西。少记一列不值这个价。

**贡献面的归属不需要决定**（PLAN 已定，重述一句）：ui entry 只在前端进程里跑、prompt / skills 由 kernel 在 host 投影、
声明由 driver 在 host 读——**会移动的只有 runtime tool 的那一次 spawn**。区分单位是包的**面**，不是包。

**script extension 是不是更薄的第一步？** 是更薄，但**不配单独一个 phase**。
script kind 免交叉编译（version = 纯 snapshot，跨平台同一个 id），拷贝路径与 compiled 完全一样，所以它**顺带就支持了**；
但真正要用的那个包（`std`）是 compiled 的，所以"先只支持脚本"交付的是一个 demo 不是一个能力。
phase 的边界该画在"extension 到底动不动"，不画在它的 kind 上。

**远端 store 只收不建。** 远端没有 session、没有 journal、没有工具链，`remote serve` 也不跑 `ext build`。
模型写出来的新能力在 host 上 build、在 host 上 activate、证据落在 host 的两条 journal 里，**推过去的只有字节**。
好处是演化循环仍在一个地方（DESIGN §9 的 trust gate、§5.5 的 usage journal、outcome journal 都不必分裂成 per-machine）。
（模型当然可以 `shell` 进远端自己敲 `nulya ext build`——那与它今天能敲 `rm -rf` 同级，是 `shell` 的权限，不是这条设计给的。）

### 3.2 `.nulya/` 的归属：按**谁读它**切

| 东西 | 归属 | 为什么 |
|---|---|---|
| `.nulya/sessions/<id>.jsonl` + `.lock` + `.inbox/` | **host** | 单写者锁、provider 连接、driver 都在 host；ledger 是**这台机器**的记忆 |
| `tool-usage.jsonl` / `session-outcomes.jsonl` / `trusted-stores.jsonl` | **host** | 证据与授权属于这个 harness，不属于某台执行机器 |
| extension store（宿主面：manifest / prompts / skills / ui entry） | **host** | kernel 在 host 投影它们 |
| extension store（远端面：该 target 的 `bin/`） | **remote** | 只有 spawn 那一次移动（§3.1） |
| 工作树 | **remote** | 定义上 |
| `.nulya/scratch/<sid>/` 的 spill | **remote** | ↓ |
| `.nulya/scratch/<sid>/tasks/` + `output.log` | **remote**（Phase 4） | ↓ |
| `std-freshness.jsonl` | **remote** | 它是 extension **自己**相对自己的 cwd 写的——跟着走，不需要任何决定 |

**spill 与 task log 跟工作区走，判据只有一条：footer 是给模型看的指针，而模型的手在远端。**
一个指向 host 盘的 `[full output: .nulya/scratch/…]` 在远端场里是一句**读不了的话**，比不给更糟。
所以 `Environment` 长**第四个动词** `putWorkspaceFile(rel_path, bytes)`（唯一 consumer 是 `emit`；local 实现就是今天那行写盘）。

这与「不加便利」不冲突：删掉它，`emit` 的第 3 条 guarantee（"完整输出总在盘上、footer 指向它"）就成了一句假话——
**它买的是诚实，不是方便。**（`WorkspaceFs` 当年被删是因为**零读者**；这个有一个真读者，而且是内核自己。）

**Phase 1 的诚实降级**（在第四个动词落地之前）：spill 仍写 host，footer 改成写明它在 harness 那台机器上、
本场的命令够不着。丑，但不撒谎；而且 std 六个 tool 自己封顶预算（goals/std.md D5），spill 对它们**永不触发**，
真会撞上的只有超过 128 KB 输出的裸 `shell`。
**这段降级 2026-08-29 随 Phase 2 整个删除**（`emit` 两个 budget 的 `spill_note` 字段与 `launch.remote_spill_note` 一并消失）：
footer 回到只有路径，因为那个路径现在在模型够得着的那台机器上。

**一个已知的牺牲品：`extensions/handoff`。** 它的契约是"往 `.nulya/handoffs/<id>-<n>.md` 写一个文件、driver 去读"，
而 driver 在 host。包一旦跑在远端，那个文件落在远端，`drivers/goal.*` 与 TUI 都看不见它。
**这正是 CLAUDE.md 那条工作约定说的事**（"欠答案的机制长成 inbox 事件，不长成 driver 要认的新盘面文件；handoff 的文件形态是历史特例"）——
远端化把这个特例的代价第一次变成了可观测的。**结论**：在 handoff 的提议改成**随 stdout 走的数据**（`compact` 收字节而不是路径）之前，
它不进远端场的 composition。TUI 的 `[env.ssh] with = []`（T88）碰巧已经是对的。

**第二个牺牲品：`extensions/ground`——而且它比 handoff 更隐蔽。**
`ground` 在**机制上**不受影响（它是 `surface: "internal"`，driver 在 host 上 `ext run` 它，从不经过 session 的 environment），
但**语义上是错的**：它渲染的是 **host 的** cwd、host 的目录树、host 的 git 分支与工作树状态，
而这一场的工作区在远端。那份 prompt 会被冻进 header、进缓存前缀、一辈子留在那场对话里——
**一张画错了的地图比没有地图更糟**，因为模型不会去核对它，`ground` 存在的全部意义就是让模型不必核对。
这也说明"机制上不受影响"这句话本身不是安全判据：**判据是这个包渲染的事实属于哪台机器**。

**Phase 1 的结论**：远端场里 driver **跳过 `ground`**——TUI 的 `[env.<kind>] session_prompts` 对 `remote:` 一族缺省为空
（`ssh` 那一档 T88 已经是空的，`remote:wsl` 这一档新加，理由与 T88 那句"`ground` 渲染的开场事实对远端命令是错的"逐字相同）。
**这是 driver 的 policy，不是内核的判断**（physics #8）：内核不知道 `ground` 是什么，也不该知道。
**远端 grounding 是 Phase 3+ 的题目**——`ground.render` 经通道在远端渲染（它已经是一个 `internal` tool，
一旦 `runExtension` 能远端跑，"在哪渲染"就与"在哪读文件"是同一个答案），本文件不提前设计它。

**别的自带包不受影响**，机制上：`agent.render` / `compact` 都是 `surface: "internal"` 或 driver tool，
**由 driver 在 host 上用 `nulya ext run` 调**（那条路走的是 host 的 `LocalEnvironment`，根本不经过 session 的 environment）。
于是规则要**两句**才够，而 `ground` 正是第二句存在的理由：

1. **execution**：effects 落在工作区里的 tool 跟着走；把路径交给 driver、或者驱动 harness 自己的 tool 留在 host。
   这一半 `surface` 已经画好了线，**内核强制**。
2. **provenance**：一个包**渲染的事实属于哪台机器**——`ground` 在 host 上跑得好好的，答出来的却是另一台机器的实话。
   这一半 manifest 里**没有**、也不该有一个字段（写一个 `about: "workspace"` 出来，解析了、冻结了、零强制，
   就是 `permissions` 那个已经被删掉的字段的第二次），所以它是 **driver 的判断**：
   哪些 `session_prompts` 在哪种 env 上有意义，由 `[env.<kind>]` 说（T88 的形状，不是新机制）。

### 3.3 路径语义：**不翻译**

- **`cwd` 恒为 `"."`，各自理解。** 远端 agent 在连接时 `cd` 进那一场冻结的 remote workspace，此后 `.` 就是它。
  host 侧一个字符都不用翻译。
- **远端路径对 host 是不透明字节串。** host 绝不用 `std.fs.path.join` 去拼它（Windows 会拼出 `\`）。
  唯一会拼 model-facing 路径的地方是 `emit.joinRel`，它**本来就**全平台用 `/`。
- **`NULYA_ARG_*` 的转义与长度上限：问题随常驻通道消失。** agent 收到的是一个**帧**，
  它自己在远端 spawn 时把 `NULYA_TOOL` / `NULYA_ARG_<k>` 放进子进程 env——**没有一层 shell 引用、没有 `SendEnv`、没有 32 KiB argv 上限**。
  （PLAN 提过的备选"把它们并进 stdin 的参数对象"因此不必做：env 那一面是 DESIGN §7.3 的契约，不该为传输方式改。）
- **Windows host ↔ Linux 远端**：`--env` 的 spec、remote workspace、`ext push` 的目标路径都是远端形状的字符串，
  host 只负责原样传。反过来远端答给 host 的路径（spill、log）是 `/` 分隔的相对路径，TUI 原样显示。

**session 冻什么**：`environment` 的 spec（§4 的新词表）+ **remote workspace 的绝对路径**，一起进 header
（可空列、老 header 读回空、header `v` 仍是 1——`usage?` / `images` / `environment` 的同一条纪律）。
resume 时够不着那台机器就**响亮失败**，与 `MissingCredential` / §8.1 对称。
**不冻远端 agent 的版本**：那是 creation-time provenance，PATH 上的二进制升级即覆盖，钉不住——
`docs/goals/agent-runner.md` 第六期 ⑥ 的同一条原则，**只声称真正 enforce 得了的 freeze**。

### 3.4 连接与性能：**一条常驻通道，对面是 nulya 自己**

**每个 tool call 一次 ssh 握手不可接受**（200–500 ms × 每次 read/grep）。三个备选：

| 备选 | 结论 |
|---|---|
| **ssh ControlMaster / ControlPersist** | **否。** Win32-OpenSSH **不支持 ControlMaster**——而这个仓库的主力机器是 Windows。且它每次调用仍要 spawn 一个 `ssh` 进程 + 开一个 channel，`NULYA_ARG_*` 的引用与 `SendEnv` 问题一个都没解决。它是给"只搬 shell"那条路的优化，不是这条路的答案。 |
| **每次调用一次 ssh** | 否，就是上面那个成本。 |
| **一条长连接 + 对面一个常驻进程** | **是。** 每个动词是一条已开管道上的一次往返，两侧都不再 spawn 传输进程。 |

**那个常驻进程就是 nulya 自己**（`nulya remote serve`，一个壳层动词，与 `nulya task supervise` 同一先例）。理由：

- 单二进制分发（`ext seed` 的同一条纪律："分发就是二进制本身"）；`nulya src` 让远端那半也自描述。
- `Tree`（整树 kill）、`isSecretKey`（env 净化）、`emit` 的预算、超时、drain——**全部现成，而且两侧是同一份实现**。
  一个专用的瘦代理会把这些逐条抄第二遍，正是"一个决定在多层各做一遍"。
- 它顺手就能当 supervisor（§3.6、Phase 4）。

**传输是"怎么把 agent 拉起来"，就三种拼法**：

```
--env remote:wsl[:<distro>]     wsl.exe [-d <d>] -e <remote-nulya> remote serve
--env remote:ssh:<destination>  ssh -o BatchMode=yes <dest> -- <remote-nulya> remote serve
--env remote:exec:<argv…>       原样 spawn 这条命令（docker exec / kubectl exec / 测试里的本机管道）
```

`exec:` 是**通用形**，另外两个是常用拼法的便利名。它让内核**永远不必学会 "docker" 这个词**（physics #8），
也让离线 e2e 成立（§5）。三种拼法共用同一个协议、同一个 `RemoteEnvironment`。
命名的 agent 假定远端 PATH 上有 `nulya`；不在就用 `exec:` 写全 argv——**一条规则，没有第二处配置可查**。

**协议**（`src/environment/remote/protocol.zig`，契约写在模块注释顶部 = `nulya src` 打印的东西，`extension/protocol.zig` 的同一先例）：

- **一帧 = 一行 JSON 头 + 可选的定长原始字节负载。** 不把 stdout 塞进 JSON 字符串：
  BUGS #22 已经交过学费——`std.json.Stringify` 把非法 UTF-8 写成**数字数组**，而命令输出是任意字节。
  定长裸负载对任意字节精确，JSON 那半仍然人读得懂。
- 动词：`hello`（双向报版本 / OS / arch / home / store root / 解析后的 workspace）· `run-shell` · `run-extension` ·
  `put-file` · `list-dir` · `cancel` · `start-task`（Phase 4）。
- **版本不匹配就拒绝并说清怎么修**，不猜测兼容（`hello` 是唯一一次协商）。
- **协议里没有任何字段能装 credential**（§3.5），host 也从不转发自己的 env map。

**一场 session 一条通道**（一个 `RemoteEnvironment` 实例一条）。批次内的 tool call 本来就是串行的（`loop.zig`），够用。
TUI 的目录浏览各开各的短连接；真嫌慢是前端自己留一条 `remote serve` 的事，属 policy。

### 3.5 authority：远端**永远不需要 key**——把这条写成卖点

模型连接住在 host，远端只是执行。于是：

- **credential 一个字节都不过线。** 协议里没有能装它的字段；host 不转发 env map；
  远端 agent 用**它自己那台机器**的环境，并且用**同一个 `isSecretKey` denylist**（同一份代码，两台机器）净化子进程 env。
  physics #6 因此在远端**逐条成立**，而且比今天的 `--env ssh` 更强：今天靠"`wsl.exe`/`ssh` 拿到的就是净化过的 map、
  所以没有 secret 可供 `WSLENV`/`SendEnv` 转发"这条**间接**论证；有 agent 之后是**直接**执行同一条净化。
- `extension ⊆ shell ⊆ session` 在远端成立：两者经同一个 agent、同一份净化 env、同一个 cwd。
- **`NULYA_EXE` 在远端设成远端那个 nulya**——正确且有用。
- **`NULYA_SESSION` 不设**：session 文件在 host，那个路径在远端不存在，给一个假路径就是撒谎。
  **代价与修法**：`std` 靠 `NULYA_SESSION` 的 stem 取 session id 来隔离 freshness journal，不设 = 远端场没有 freshness 门。
  这暴露了一个本来就在的问题——**`NULYA_SESSION` 把「身份」与「位置」塞进了一个变量**，远端化只是把它掰开：
  再发布一个 **`NULYA_SESSION_ID`**（两台机器都发，host 上也发——它不花任何东西，而且是更诚实的名字），
  只要 id 的包（`std` 的 freshness、`agent`）改读它，路径仍只有 host 上那个 `NULYA_SESSION`。
- **`ext push` 授予了什么？** 严格说：什么都没多授。往远端写一个文件并执行它，`shell` 今天就能做
  （那把 ssh 钥匙已经是那个账号的全部权限）。所以门**不是**权限门，是**意外门**——
  在别人的机器上留下状态该是一次说出口的手势。判据不新造：**远端 store 里有没有这个版本，本身就是记录**
  （与 DESIGN §9 的"本机 build 填满空 store = 出生即可信"同构），**不加第四条 journal**。
- **gate 完全不动**：`session step --gate` 是 host 上那个 step 进程里的问答，跨不跨机器与它无关。approvals / readonly 天花板同理。

### 3.6 取消与整树 kill：**这次真的杀得到**

今天 §8.1 如实记录的局限 ①（"杀得到本地客户端，不保证杀得到对面"）**在这条路上消失**，而且不用新机制：
远端 agent 在**它那台机器上**用同一个 `Tree` 跑命令（POSIX pgid / Windows job object），
`cancel` 是通道上的一条消息，agent 收到就 `killAll` 并回一个 outcome。超时同理——**由 agent 在进程旁边计时**，
它比 host 更早知道该杀谁。

**host 侧仍留一层保险，而且不是重复**：通道 stall watchdog（`providers/wire.zig` 的 `Watched` 同一形状）——
一个负责**结束那个进程**，一个负责**结束这次等待**。

**连接在命令跑到一半时断了**：host **不知道**远端那个进程的下场，所以就这么说
（`ok=false` + "到 `<dest>` 的连接在这条命令运行中断开了，它在那台机器上的状态未知"），
**绝不编一个退出码、也绝不自动重试**（那条命令已经跑过了）。这是本仓库处处那条纪律的又一处：答不上来不许塌成一个结论。

### 3.7 WSL：**不是捷径，是这件事最容易的那个实例**

诱惑是：host 经 `\\wsl.localhost\<distro>\…` 直接看得见 WSL 的文件系统，所以 extension 留 host、只把 cwd 翻译成 UNC 就行了。
**这条捷径撒三种谎，跳过它**：

1. **性能**：9p/plan9 桥接下一次 `stat` 是毫秒级，而 `std/grep` 与 `glob` 是**整树遍历**——一个仓库的 grep 会从秒变成分钟。
2. **语义**：ext4 大小写敏感 / UNC 那侧默认不敏感；可执行位、符号链接、`mtime` 精度、文件锁全都对不上。
   而 `glob` 按 mtime 排序、`edit` 保留可执行位——**两者会静悄悄地错**。
3. **翻译本身就不总是对的**（tui.md T93 已经写过）：UNC 里的发行版名要与 target 相同才成立，"默认发行版"那一档根本对不上。

而且**真正需要它的那个场景 WSL 已经覆盖了**：WSL2 把 Windows 盘挂在 `/mnt/c`，
所以"工作区在 Windows 侧、命令在 Linux 里跑"正是今天 `--env wsl` 的语义，**保留不动**。
UNC 捷径唯一能补的场景是"工作区住在发行版自己的 ext4 里"，而那恰恰是上面三条最疼的场景。

**结论反过来：WSL 是远端后端的第一个传输。** `wsl.exe -e <remote-nulya> remote serve` 没有网络、没有认证、
spawn 是毫秒级，而三个动词、协议、spill 路由、per-target build 全部照常锻炼——
**用它去掉 ssh 的变量，而不是用它去掉这件事本身。**

### 3.8 被否掉的大备选

**① 整个 nulya 跑在远端，TUI 本地 attach。**

诚实地说，它有真优点：工作区与 harness 同机，于是**今天每一条不变量原样成立**（单写者锁、spill、freshness、后台任务、
`ext build`、trust gate），一个 `Environment` 实现都不用写；而且 TUI 已经有 observer 模式与 `<id>.lock` 探针，
`session step --stream` 本来就是行协议——attach 这件事离得不远。

**不选它的理由，按份量排**：

- **API key 必须住在远端**（或者被转发过去）。用户的前提就是"连接留在本机"，而这也是 physics #6 的精神：
  一台跳板机、一台共享的构建机、一个容器——把 provider 凭据放上去是这条设计最不该做的事。
- **转录、两条 journal、store 全在远端**：一场 session 不再是**这台机器**的记忆，演化证据按机器碎掉。
- **gate 变成跨链路的**：每个 tool call 执行前那一问在**热路径**上，一次 RTT 一次批准。
- **不组合**：两台远端 = 两个 harness；"读一下本地的笔记，然后在那台机器上构建"根本表达不出来。
- **远端要工具链**（或者仍然走同一套交叉编译 + push，那就没省下什么）。

**它对的时候**：远端是唯一重要的那台机器、本机只是瘦客户端。而那个形状**今天就能做，且不需要 nulya 写一行代码**——
`ssh` 上去跑 `nulya` 即可。所以这份设计不必与它二选一，只需**不挡住它**（本地 TUI attach 是 M8 前端的题目，与本文件正交）。

**② 让每个工具自己感知环境**（`read` 自己去 `ssh cat`）。PLAN §3.8 已经否过，重述一句：
每个工具各学一遍连接 / 引用 / 超时 / 凭据，第三方工具再抄一遍——**同一个决定在多层各做一遍**，这条坏味道的教科书例子。

**③ 挂载远端文件系统**（sshfs / rclone / `\\wsl$`）。"什么都不用改"是它的全部卖点，代价是：
每次 `stat` 一个 RTT（walk 型工具无法接受）· 权限位 / mtime / 锁语义撒谎（同 §3.7 第 2 条）·
失败形态是**工具中途的 I/O 错误**而不是一次有名字的连接失败 · 依赖 OS 级组件，离线测不了。

**④ 双向同步工作区**（本地编辑 + rsync 过去）。引入分叉与冲突，而且让模型的心智模型变错：
远端化的**全部意义**就是"真相在那边"，同步等于制造第二个真相。

### 3.9 TUI：内核只欠两个动词

**内核给什么**（其余全是 driver 的事）：

```
nulya session new --env remote:… --workspace <远端绝对路径>   # 冻进 header
nulya remote check --env <spec> [--json]     # 连一次：agent 版本 / OS / arch / home / store root
nulya remote ls    --env <spec> [<path>] [--json]   # 一次 list-dir
nulya ext push <id>@<v> --env <spec>          # 内容寻址的一次拷贝 + 远端 .sealed 复验
```

**为什么 `list-dir` 是协议动词而不是"跑一条 `ls`"**：解析 `ls` 输出是有损的（文件名里可以有换行），
而目录浏览器要的恰好是精确的 `{name, is_dir}`。agent 就在那儿，问它一句比解析一屏文本便宜也准确。

**交互契约草案**（属 tui.md，写在这里只是为了让内核动词的形状有依据）：

- `/env` picker（T93 已在）多一档 `remote:…`；**选中远端 target 之后接着开目录浏览器**——
  "选机器"与"选那台机器上的哪个目录"是一次决定的两半（欢迎屏那对 `cwd` / `shell` 行说的正是这件事）。
- **目录浏览器是同一个组件，换一个数据源**：`browsedir.ts` 的纯函数（`expandPath` / `visibleChildren` / `browserRows`）
  本来就不碰磁盘；把"读一个目录"变成**注入的函数**（本地 = 今天那条；远端 = `nulya remote ls --json`），
  于是本地与远端浏览**不可能漂开**。T98 那条"一个动作落在哪个目录，是那个 tab 说了算"照旧成立。
- **每台机器记自己的 recents**：`tui-state.json` 的 `remote_cwd: { "<spec>": "<path>" }`——一个键，不是新文件。
- **状态栏不加新像素**：`⇥ <spec>` chip 已在（T86），远端场把欢迎屏/状态行的 `cwd` 那一格显示成远端路径即可——
  "文件在哪、命令去哪"这对本来就在那儿。
- **`/ext` 长出 target 感知**（PLAN 说的那个"一直在等的真实用例"）：每行多一个"已推到 `<spec>`"的状态与一个 push 动作；
  T88 的 `[env.ssh]` 缺省仍是 `bare = true, with = []`——**一台什么都没推过的机器就该是空的**，
  推过之后由人把 profile 放宽。何时推、推什么，是人的手势，不是内核的判断。
- 审批 / gate / mode / readonly 天花板：**一个字不改**（§3.5）。

## 4. 分阶段

每个 phase 自己站得住（宁可窄，不许假），而且各自能测。

**Phase 0（已落地）· `--env wsl|ssh`：只搬 shell。** 保留。ops 型任务它就是对的答案，且它不需要远端有任何东西。

**Phase 1 · 通道 + `shell` + 真取消** ✅ **已落地**（2026-08-29，见 §6）
- 内核：`src/environment/remote/{mod,protocol}.zig`（第二个 vtable 实现 + 帧协议）· `src/cli/remote.zig`（`serve` / `check` / `ls`）·
  `--env` 词表加 `remote:wsl|ssh|exec` 一族 · header 多 `remote_workspace` 一列（§6 偏差 4）· `runExtension` 与 `startShellTask` 在远端 env 上**明说拒绝**
  （"这一场的命令跑在 `<dest>`，extension 与后台任务仍在 harness 这台机器上——见 Phase 2/4"）。
- 收益已经是真的：常驻通道（无握手）· **远端真 kill**（限局 ① 消失）· `NULYA_EXE` 到得了对面。
- TUI：`/env` 多一档 + `remote check` 的错误原样显示。

**Phase 2 · scratch / spill 跟着走** ✅ **已落地**（2026-08-29，见 §6.2）
- 内核：`Environment` 第四个动词 `putWorkspaceFile`；`emit` 的 spill 与 `StepOutputLimiter` 经它写。local 实现 = 今天那行。
- 这之前 footer 用 §3.2 的诚实降级措辞。

**Phase 3 · extension 搬走**（用户诉求真正被满足的那一步）✅ **内核侧已落地**（§6.3 + §6.4）
- 内核：~~`ExtensionRequest` 从 `entry_path` 改成 `(id, version, tool)`，解析与 `.sealed` 复验移到执行侧~~ ✅
  （§7.5 的"冻绝对路径"随之删除——**是收窄不是新增**）· ~~`ext build --target <triple>`~~ ✅（两词形，不是 triple——见 §6.3 偏差 1）· ~~`ext push`~~ ✅ · ~~header 的 `exec_version` 列~~ ✅
- **TUI 那半未做**：`/ext` 的 push 动作与 per-target 状态；`[env.*]` profile 由人放宽。
- **`handoff` 显式不进远端 composition**（§3.2），并给它的"提议变成数据"记一条 follow-up。

**Phase 4 · 后台任务**
- `startShellTask` 变成 agent 那一侧起一个 **`nulya task supervise`**（同一个二进制、同一个角色、同一个 `Tree`），
  log 写在远端工作区，完成时经通道回报，**host 那半把它翻成 `task_finished` 投进 host 的 inbox**——
  欠答案的机制仍然是 inbox 事件，driver 不认第二种盘面（CLAUDE.md 那条工作约定）。
- `nulya task list|kill` 的投影跨通道读远端 `status.json`。

**Phase 5（可选，等证据）** · 连接断线重连 · 远端输出流式 · 一个 target 上多场 session 共用一条通道。

## 5. 测试策略

**离线是硬要求**（`zig build e2e` 不许联网），而这条设计天生好测：

- **"远端"就用真的 agent。** `--env remote:exec:<本机 nulya> remote serve` 起一条**本机管道上的真通道**，
  两侧都是真实现——比假进程更强：协议、spill 路由、extension spawn、kill 全走真路。
  这也正是 `exec:` 这个通用形值得存在的第二个理由。
- **假 agent 只用来演病态**（`tests/fake_remote.zig`，先例 `tests/fake_codex.zig`）：
  握手版本不匹配 · 命令跑到一半进程死掉 · 通道静默（stall watchdog）· 半个帧 · 负载长度撒谎。
  真 nulya 不会这么干，所以这些只能由一个会撒谎的对端来演——**它存在的理由与 `fake_codex` 逐字相同**。
- **交叉编译那一半不需要远端**：`ext build --target x86_64-linux-musl` 在任何装了 zig 的机器上都跑得完，
  断言的是 seal 三元组、version id 含 target、两次 build 同 id——**不执行那个二进制**。
- **`ext push` 用本机的第二个 store root 当"远端"**：拷贝 + `.sealed` 复验 + 幂等，与跨机器逐位同构。
- **钉住的不变量**（不钉措辞、不钉行数——CLAUDE.md 的测试纪律）：
  ① 远端场里 `std/read` 读到的是**远端**工作区的字节（两侧放同名不同内容的 sentinel）；
  ② spill footer 指的路径在**模型够得着的那一侧**读得出来；
  ③ `cancel` 之后远端那棵进程树真的没了（远端起一个会写心跳文件的命令，kill 之后心跳停）；
  ④ 协议帧里**不出现**任何 secret 形状的键（把一个假 `OPENAI_API_KEY` 放进 host 环境，断言通道日志里没有它）；
  ⑤ resume 一场远端 session，够不着目标时**硬失败**且什么都不改。
- **新增一组 `zig build e2e-remote`**（今天四组并行，`e2e` 仍是全部）——不要往现有组里塞，一组一个进程一个核。

## 6. 实施记录

### 6.1 Phase 1（2026-08-29）

**落地了什么**（现状写进 DESIGN §8.2 / §14；本节只记过程与偏差）：

| 新增 | 是什么 |
|---|---|
| `src/environment/remote/protocol.zig` | 帧协议：契约在模块注释顶部（`nulya src` 打印它），`Request`/`Reply`/`Op` 与四条规则，纯逻辑单测同文件 |
| `src/environment/remote/mod.zig` | `remote:` spec 解析 · 三种 launcher argv · `Channel`（握手 / 帧读写 / 耐心）· `RemoteEnvironment`（第二个 vtable 实现） |
| `src/cli/remote.zig` | `nulya remote serve\|check\|ls`——serve 是远端那一端，另外两个是 host 侧的两个问题 |
| `tests/fake_remote.zig` · `tests/e2e_remote.zig` · `tests/e2e/remote.zig` · `zig build e2e-remote` | 第五组 e2e：真通道（`remote:exec:` 指向本二进制）+ 会撒谎的假 peer |
| 改动 | `--env` 词表（新增一族，旧的一字未动）· header 可空列 `remote_workspace` + `session new --workspace` · `launch.SessionEnvironment` union · `environment.sanitizedChildEnv`（抽出来，两台机器同一份）· `emit` 两个 budget 的 `spill_note` · `tools/shell.zig` 两条拒绝文案 · `task run` / `task supervise` 对 `remote:` 硬拒 |

**与本文件设计的七处偏差，逐条**：

1. **stall watchdog 是 deadline 不是字节心跳。** §3.4 说"`providers/wire.zig` `Watched` 同形状"——同的是 `Select` 那个形状，**不是**它的心跳判据：一条正当的十分钟构建在这条通道上按设计就是静默的，心跳会杀掉它要保护的那件事。改成"请求自己的 timeout + margin"（`remote.Bounds`），因为 agent 的契约就是"一个请求一个回复、在你给的 timeout 之内"。
2. **`Bounds` 是参数不是常量。** 缩小它是**唯一**能观测到这个守卫（而不是等 60 s）的办法，所以它是 `ConnectOptions` 的一个字段，与 `LocalOptions.dialect` 同一先例；生产路径全部走 `.default`。
3. **第四个动词 `putWorkspaceFile` 没有加**——那是 Phase 2。Phase 1 走 §3.2 写好的诚实降级：`emit.OutputBudget.spill_note`，footer 多一句说明这个文件在 harness 那台机器上。`emit` 不知道"机器"是什么，它只是拒绝在没有说明的情况下打印一个指针；那句话由壳层填。
4. **header 那一列叫 `remote_workspace` 不叫 `workspace`。** 不是风格选择：`session.CreateDurableOptions.workspace` 已经是**这台机器的工作目录句柄**（`std.Io.Dir`），编译器当场撞出来了。撞名本身是有信息的——`workspace` 在这个 harness 里已经有一个意思，远端那个必须自报家门。
5. **`runExtension` 的拒绝答成一次失败的调用，不是 host error。** 一个 error 会失败整个 step；一次 `exit 1` + stderr 走的是 `invoke.zig` 每次失败调用本来就走的那条路——模型读得到那句话、usage journal 记下一个**真实**的 `ok=false`、内核里零新分支。`startShellTask` 只能是 error（它没有 outcome 形状可用），所以由 `tools/shell.zig` 翻成文案，与 `NoDurableSession` 同一先例。
6. **`list-dir` 成了协议动词**（§3.9 已经论证过），于是 `remote ls` 不解析 `ls` 的输出。配套两条纪律：entries 骑在 header 里 → 1000 条封顶且**说出来**；名字不是合法 UTF-8 的条目跳过并**说出来**（`std.json` 会把它写成数字数组，host 一解析就把通道判死——一个怪文件不该带走整张列表）。
7. **`remote:exec:` 的通用形不只是给 docker 的**：离线 e2e 就是靠它把 `--env` 指向本二进制，于是通道两端跑的都是生产代码，比任何 stand-in 都强。假 peer 因此**只演病态**（版本不对 / 半个帧 / 中途死掉 / 撒谎的长度 / 完全不说话），理由与 `tests/fake_codex.zig` 逐字相同。

**一条本来没写进设计、但必须钉住的不变量**：**一条通道要连着服务很多条命令**（一个 step 是一整批 tool call，一场 session 是很多个 step）。
mid-command 的那个控制帧监视在**每条命令结束时都会被取消**，所以"取消它之后这条通道还好用吗"正是让批次里第二个调用成立的前提。
e2e 里一条通道连跑三次并断言每次都答对（`one channel serves many commands in a row`）。

**顺手抓到的一个真 bug（测试先红）**：`Channel.connect` 的 `std.process.spawn` **漏了 `environ_map`**——传输进程（以及 agent，以及它跑的每条命令）会整份继承本进程的环境，secret 在内。是 §5 那条"没有 host secret 到得了 agent 跑的命令"的 e2e 把它照出来的（`build.zig` 给这一组注入一对探针：一个 secret 形状的必须消失，一个普通的必须还在——后者才让前者是关于 denylist 的断言，而不是关于一个坏掉的环境）。

**测试**：`zig build test` **556 pass / 4 skip**（`environment/remote/{mod,protocol}.zig` 的单测在内）。e2e 逐组：`e2e-ext` 47 · `e2e-core` 48 · `e2e-agent` 23 · `e2e-std` 8 · **`e2e-remote` 12**（约 11 s）。
**`zig build e2e` 这个聚合步在本机不稳**，而且**与本次改动无关**（把全部改动 `git stash` 之后连跑两次同样失败）。**后来查清并修掉了（同日）**：不是负载也不是哪个测试慢——失败形状是"每个测试都 pass、run step 却报 `test runner failed to respond for 1m…`"，因为 Zig 0.16 的 Windows spawn 是 `bInheritHandles=TRUE` 且没有 handle allowlist（`std/Io/Threaded.zig`），build runner 并发起五个测试进程时，兄弟进程（连同它们 spawn 的每个 `nulya.exe`）互相继承对方 stdout 管道的写端——先跑完的组等 EOF 等到被最慢的进程树扣押超过 watchdog 的 60 s 窗口（`Step/Run.zig` 的 `response_timeout` 只在**没有测试在跑**时计时，恰好就是"全部跑完等关流"那一刻）。这正是 `environment.DetachedStdio` 在单组内部防的同一个病，跨 build-runner 兄弟只有不同时跑能治。修法在 build.zig：**Windows 宿主上聚合步的五个 run 串成链**（每组一份聚合专用的 run step 克隆，命名的单组步保持无链、互不拖累；POSIX 无此继承竞争，保持并行）。代价如实：Windows 上 `zig build e2e` 从"理论 50 s"变成实测约 4 分钟（各组之和），单组仍是迭代的快路。

### 6.2 Phase 2（2026-08-29）：spill 跟着工作区走 + list-dir 的头上限修复

**落地了什么**（现状写进 DESIGN §8 / §8.2；本节只记过程与偏差）：

| 新增 | 是什么 |
|---|---|
| `Environment.putWorkspaceFile(rel_path, bytes)` | 第四个动词（DESIGN §8）：把字节写进**这一场 session 的工作区**，路径就是 footer 里那个 workspace 相对的字符串。建父目录是实现这一侧的承诺 |
| `emit.FileSink` | `emit` 这一侧的接口：一个指针加一个写函数。`emit` 从此**一个目录都不建、一个文件都不写** |
| 协议 `put-file`（`v: 1 → 2`） | 从"这一期不做"变成真动词：头带 `cwd` + `path` + 长度，负载是文件字节 |
| `protocol.encodeEntries` / `parseEntries` + 编码器的头上限 | `list-dir` 的 entries 改走负载；超过 `max_header_bytes` 的头**拒绝编码** |

**与设计的偏差，逐条**：

1. **`emit` 与 `Environment` 之间没有 adapter，因为不需要一个。** §3.2 说的是"第四个动词，唯一 consumer 是 `emit`"，落地时第一版真在 `loop.zig` 里写了一个 `SpillSink` struct 把环境包成 sink——然后发现 `emit.FileSink` 与 vtable 那一格**逐位同形**（`{ptr, fn(ptr, rel_path, bytes)}`），于是 `Environment.fileSink()` 直接把 `{ptr, vtable.putWorkspaceFile}` 交出去，那个 struct 删掉。签名一改，编译器当场在那一行说话——这比一个转发函数守得更紧。
2. **`emit` 的两个入口不再收 `io`。** `emit()` 与 `StepOutputLimiter.init()` 的 `io` 参数换成 sink，`writeStepSpill` 整个删除——它与 `writeSpill` 本来就是同一件事的两份实现（各自 `createDirPath` 一次），"建父目录"移进动词这一侧之后，第二份没有存在的理由。
3. **`emit` 的单测改用 recording sink，不再真写盘。** 否则仓库里就多了一处"字节变成文件"，而 `FileSink` 存在的全部意义就是不要那第二处。顺带断言变强了：现在拿到的是**被写的那个路径**与**原始字节本身**（"footer 里那个字符串就是 sink 收到的那个字符串"因此是一条可测的断言），而不是"文件存在"。
4. **远端那侧不是第二份实现，是同一份。** `remote serve` 收到 `put-file` 后调的就是 `agent.lenv` 的 `putWorkspaceFile`——§3.4 那句"对面就是 nulya 自己"第一次被兑现成**同一个函数**而不只是同一个二进制。`cwd` 与 `path` 的拼接只在 agent 一侧发生一次，host 从不学远端的路径拼法（§3.3）。
5. **协议版本 bump 到 2，一次覆盖两件事**（entries 改走负载 + `put-file` 成为真动词）。`hello` 是唯一协商，所以新旧两端相遇拿到的是一句"版本不匹配、去装个对得上的 build"，不是猜——这正是当初把版本号放在握手里的用途。
6. **`Channel.last_payload` 而不是让 `controlRound` 返回一对。** 回复的负载从前一律当垃圾读掉（读它只为不让流失步）；现在留在 channel arena 里，生命周期就是这一轮——而想要那些字节的调用方（`remote ls`）要的正好是这一轮。
7. **`max_entries = 1000` 留着，但理由换了。** 它从前被写成"保证这一帧读得进去"，而那是错的单位（1000 **条** vs 64 **KiB**）；现在头上限由编码器强制，这个常量只再说一件事：一次回答该有多大。截断照旧**说出来**。
8. **e2e 走 in-process 的真通道，不走 CLI。** `session step` 没有调 budget 的 flag，而 scripted provider 发的命令是写死的，所以从 CLI 那条路触发一次 spill 只能靠真打 128 KB 或者新加一个 scripted 档——两者都是为了测试去动生产面。改成在一条真通道上直接 `emit.emit`（sink 取自 `RemoteEnvironment`），断言 §5 的不变量 ②：footer 里那个路径在**远端工作区**下读得出完整原始字节，在 **host 工作区**下 `FileNotFound`。loop 那一半的接线由 `e2e-core` 已有的 spill 断言（一次真 step 的 `tool_results` 里 `spill_path` 是字符串）与 `emit` 的单测各守一半。为此 `root.zig` 多导出一个 `emit`。
9. **`tool-presentation/` 明确不走这个动词**，且这不是遗漏：判据是 §3.2 那张表的问题本身——**谁读它**。spill 的读者是模型（手在对面），presentation 的读者是前端（在 host 上读）。同一个 step 里两个文件去两台机器，理由写在 `loop.zig` 那两行之间。

**任务 1 那半是一个真 bug，不是清理**：`serveListDir` 用 `max_entries` 这个**条数**去保证 `max_header_bytes` 这个**字节数**，而 1000 个 255 字节的文件名是四分之一兆——host 侧 `takeDelimiter('\n')` 的 buffer 只有 `max_header_bytes`，于是一个完全合法的目录就能把整条通道判死。修法不止是把 entries 搬进负载：**编码器现在拒绝超界的头**（`error.HeaderTooLarge`），所以下一个往头里塞会长的字段的动词，在造出那一帧的地方就被拦住，而不是在对面变成一条突然不说话的通道。单测钉的是机制而不是数字：1000 个 250 字节名字的 listing 走新路径，头仍在界内、entries 无损回来；一个超界的 `message` / `path` 编不出来。

**测试**：`zig build test` **558 pass / 4 skip**（`protocol.zig` 新增两条：大 listing 走负载、超界的头被拒）。e2e 逐组：`e2e-ext` 47 · `e2e-core` 48 · `e2e-agent` 23 · `e2e-std` 8 · **`e2e-remote` 14**（Phase 2 新增两条：spill 落在远端工作区且 host 上没有、put-file 建得出多层父目录）。

### 6.3 Phase 3 前半（2026-08-29）：`ext build --target` + `ext push`

**落地了什么**（现状写进 DESIGN §7.4 / §8.2 / §14；本节只记过程与偏差）：

| 新增 | 是什么 |
|---|---|
| `src/extension/target.zig` | 两词 target 的唯一定义：闭集 `Arch`×`Os`、`words()`（进 id / seal 的那两个词）、`zigTriple()`（abi 在这里选）、`exeSuffixFor(words)`（后缀属于 target，不属于读它的机器）、`host` |
| `ext build --target <arch>-<os>` | `build_ext.Options{donors, target}`；`-target <triple>` 只在点名时出现（host build 保持 **native**，不改字节）；data/script 写它是 `TargetNotApplicable` |
| `ext push <id>@<v> --env remote:…` | `src/cli/ext_push.zig`：本机 `.sealed` → 逐文件过通道 → 对面 staging → 对面 `.sealed` → 原子 rename |
| 协议 `store-stat` / `store-put` / `store-commit` | **不 bump `v`**（加动词由 unknown-op 那句话覆盖，规则 4）；Request 多 `id` / `version` / `exec`，Reply 多 `held` |
| `tests/remote_home.zig` + `zig build` 接线 | 一个**传输**（不是假 peer）：加一个 `NULYA_HOME` 再 spawn 真 nulya，好让"远端 store"真的是另一个目录 |

**与设计的偏差，逐条**：

1. **`--target` 收两个词，不收 zig triple。** §3.1 写的是 `--target <triple>`，而 seal 的 `target` 列从第一天起就是 `<arch>-<os>` 两个词，且**它就是 donor 匹配的键**（DESIGN §7.4）。收三个词就会让 `x86_64-linux-musl` 与那台机器本机建出的 `x86_64-linux` 成为两个版本——身份必须与已有的那一列逐位对上，而不是与 zig 的命令行对上。于是 abi 是**这里选的**（linux→musl / windows→gnu / macos→none），闭集校验，认不出即拒并列词表。
2. **exe 后缀从 host 常量变成 seal 那一列的函数**，这是一个必须改的既有 bug 面：`integrity.openVersion` 从前用 `builtin.os.tag` 拼 `bin/<entry><exe>`，所以 Windows 上刚建好的 linux 版本会在校验时被找 `bin/x.exe`。改成 `target.exeSuffixFor(seal.target)`——**同一个函数**也定义 host 那个常量（`integrity.exe_suffix`），所以不是两条规则。`testkit` 的 fixture 因此把假 target 词 `"test-target"` 换成 `target.host`：它写的二进制一直用 host 后缀，seal 就得这么说。
3. **ABI 收敛的代价写成结论而不是欠账**：一个 id 不含 host，所以 Linux 本机（glibc）与别处交叉（musl）都记 `x86_64-linux`。安全性不靠这个区分——每台机器对自己持有的字节重验 `.sealed`；而两者都可能出现的那台机器上，`findMatchingVersion` 找到已在的那份、不编译，所以一个 store 里不会有两份字节争一个 id。把 abi/host 塞进 id 换来的是没人提过的区分，付出的是"一个 id 一个答案"。
4. **`--target` 拒绝 data/script 而不是照建**：那不是被婉拒的请求，是没有含义的请求；默默产出普通版本会让调用方以为交叉编译发生过。拒绝发生在拿 lease 与写任何东西之前。
5. **三个动词而不是一个**，因为一个版本是一棵**树**而一帧只有一个负载。`store-put` / `store-commit` **不带 id**：一条通道同时只有一个 push（规则 1），第二处"是哪一个"就是第二个会漂移的答案；让这件事安全的是 commit 的复验 + `<id>/.push-<version>/` 这个**不在 `versions/` 底下**的 staging 位置（`listVersions` 看不见它，`<id>/.lock` 盖得住它）。
6. **`exec` 位是一个真读者的字段**：文件拷贝带 mode，负载不带，而一个到了对面却不可执行的二进制正是 push 要避免的失败。host 按 store 布局定它（`bin/` 下就是编译入口），对面没有这个位就忽略。判据没有第二处实现，也不读 manifest。
7. **落点是 user store 且由对面解析**（§3.3）。host 不为远端拼路径；user store 而不是 workspace store，因为后者正是 §9 的门要管的那一个。
8. **"已持有"用 `.sealed` 而不是 `.structural`**：否则一份坏掉的副本会挡住那次本可以修好它的 push。
9. **不 bump 协议版本，并确认过这条路真的成立**：老 agent 收到 `store-stat` 走 `Op.unknown`，答的是那句列出自己会什么的话——"对面那个 build 太老"于是作为一句话到达，而不是让每个动词一起判死。
10. **`remote check` 没有报告远端 store root**（可做可不做那一条选了不做）：它要往 `hello` 加一列，而 `hello` 是唯一的协商帧，为一个只有 push 用得上的诊断去动它不值。`ext push` 的每一句失败已经点名了 spec 与对面自己的话。
11. **交叉版本仍可以在本机 `activate`**，本轮**不加新规则**（任务书要求发现即报、不自作主张）：`ext build --target` 自己一个字都不碰 `current`，但人手动 `ext activate` 一个交叉版本是允许的，之后 `ext run` 会去 spawn 一个别的平台的可执行文件并失败。真正的修法是 Phase 3 后半的 `exec_version`——**哪一份字节服务这一场**成为一个被冻的答案之后，"本机 composition 用哪个版本"就不再需要靠人不去做错事。
12. **e2e 分两组按语义放**：交叉编译不需要远端，进 `e2e-ext`（用一个最小的 `pub fn main() void {}` draft，不付 `std` 的编译时间，也**从不执行**产物）；push 走真通道，进 `e2e-remote`。远端隔离用 `tests/remote_home.zig` 这个**传输**而不是假 peer——通道两端仍是生产代码，只是对面那个 nulya 有自己的 home。篡改那条**先红过**（把"改一个字节"去掉之后 commit 成功，测试失败），所以它测的是对面的复验而不是别的什么。
13. **`nulya help` 的一屏预算 +1**（60 → 61）：`ext push` 是一个新动词，按那个测试自己写的规矩（"预算只在真能力到场时动，并写下是什么"）记一笔；`--target` **没有花掉一行**——一个既有动词的 flag 属于那个动词那一行。

**测试**：`zig build test` **566 pass / 4 skip**（新增 `target.zig` 三条 + `build_ext` 一条 target 拒绝）。e2e 逐组：`e2e-ext` **49**（+2）· `e2e-core` 48 · `e2e-agent` 23 · `e2e-std` 8 · `e2e-remote` **16**（+2）。

## 7. 开放问题（此处只列，动手那轮拍板）

1. **`ssh:` 与 `remote:ssh:` 两个词要不要并成一个。** `remote:ssh:` 落地后严格覆盖 `ssh:`（也搬 shell、还搬别的、kill 更真），
   留着两个词就是留着一个更弱又更容易被误选的拼法；而 `wsl:` 不同——它有**独立的**含义（同一个工作区经 `/mnt/` 看，extension 留 host），
   该留。**倾向**：pre-release 不留兼容（`runtime.wire` 的先例），`ssh:` 删掉；但这一刀由人来切。
   顺带同一个问题的另一半：`config.environment.backend = "remote"` 这个**已经能解析、今天硬拒**的词
   与 `--env remote:…` 是两处说同一件事，该退休一个。
   > **已裁决（2026-08-29，人确认）**：**删 `ssh:`，退休 backend 的 `"remote"` 词**——pre-release 不留兼容（`runtime.wire` 先例）。
   > `wsl:` 保留（独立含义：同一个工作区经 `/mnt/` 看，extension 留 host）。旧 header 里冻着 `ssh:` spec 的场 resume 时
   > 响亮失败并指路 `remote:ssh:`，不静默翻译。
2. **两个 target 版本的冻结身份**（§3.1）：冻两列（本文倾向）vs. 收敛到 package digest（PLAN 的候选）。
   后者有 schema 后果，值得在动手前定死。
   > **已裁决（2026-08-29，人确认）**：**冻两列**——成员是 `(id, v_host)`，远端场额外冻 `exec_version`（可空列，
   > 只有 compiled 包在 target 不同的远端场上非空）。host 从自己的 store 按 `package_digest + target` 反查（donor 匹配同一把键）。
   > 「一个 version id 恰好命名一份可执行字节」这条性质保住。
3. **远端那个二进制是完整 nulya 还是瘦代理，以及它怎么到远端。** 本文倾向完整 nulya + `nulya remote install <dest>` 一次显式手势；
   要不要允许"人答应一次之后自动装/自动升级"是一个真的取舍（省事 vs. 别人的机器上多了一个会自己更新的东西）。
   > **已裁决（2026-08-29，人确认）**：**本轮（Phase 2/3）仍不做 `install`**——两条规则继续够用：
   > 命名的传输假定远端 PATH 上有 `nulya`，别的一切用 `remote:exec:<argv…>` 写全。
   > nulya 本体绝不往别的机器写可执行文件；`ext push` 推的是 extension 版本的**数据字节**，不在此列。
   > `remote install` 留给后续轮次。
4. **`handoff` 的提议从文件变成数据**：这是远端化逼出来的，但它本身是一条独立的收口（`compact` 的 `brief_file` 收字节），
   值不值得先做掉再远端化。
   > **Phase 1 不受影响**：远端场里 extension 根本不跑（明说拒绝），所以 `handoff` 在远端场里只是一个不该被 `--with` 进来的包，
   > 而不是一个会把文件写错地方的包。这条问题属于 Phase 3。

### 6.4 Phase 3 后半（2026-08-29）：extension 真的跑在远端

**落地了什么**（现状写进 DESIGN §3.4 / §5.3 / §7.3 / §7.5 / §8 / §8.2 / §14；本节只记过程与偏差）：

| 新增 / 改动 | 是什么 |
|---|---|
| `src/extension/exec.zig` | **执行侧**的解析器：`(id, version)` → 要 spawn 的那个文件 + interpreter。按自己的 OS 选 entry 变体、按自己的 `.sealed` 复验、拼自己的 store root，**每个 (id, version) 每进程验一次**（memo）。local backend 与 `nulya remote serve` 共用它 |
| `environment.ExtensionRequest` | `entry_path` / `interpreter` / `env_extra` → `(id, version, tool)` + `presentation_file`。`LocalOptions.extension_roots` 是配套的输入（壳层算好交下来，`SessionRef` 先例），**懒开**、相对 spec 对着**那次调用的 cwd** 解析 |
| `protocol.callEnv` / `requireArgumentsObject` | `NULYA_TOOL` / `NULYA_ARG_<k>` 的派生搬到执行侧（一份实现两台机器）；"arguments 必须是 object" 仍在发起侧、spawn 与发帧**之前** |
| 协议 `run-extension`（**不 bump `v`**） | 头带 `(id, version, tool, cwd, session, timeout_ms, max_output_bytes)`，负载是参数 JSON；回复与 `run-shell` 同形。找不到那个版本 → 一句点名 `ext push` 的拒绝，host 答成一次失败的调用 |
| header `ExtensionRef.exec_version` | 可空列（老 header 读回空、`v` 仍 1）：远端场上服务调用的那个版本。`composition.ExecTargetProbe` 懒问 target，`Roots.resolveForTarget` → `Store.findSealed` 按 `(package_digest, target)` 反查 |
| `NULYA_SESSION_ID` | 身份与位置掰开：`session step` 两个都发布，只有 id 过通道；`envSessionId` / `extensions/std` / `extensions/handoff` 改读它 |
| `Store.findSealed` / `readPackageDigest` | seal 匹配收成**一处实现**：`build_ext.findMatchingVersion` 与远端场的反查问的是同一把键 |

**与设计的偏差，逐条**：

1. **`session new` 在有 compiled 成员时要连一次**——对 Phase 1 那句"new 不连接"的**有意偏离**，因为那台机器的 target 只有它自己说得出，而 `exec_version` 必须在冻结的那一刻定下来（resume 再问一次就可能得到另一个答案）。代价压到最小：`composition.ExecTargetProbe` 是一个**懒回调**而不是一个字符串参数，只在第一个 `compiled` 成员被组进来时问、问一次——一场只由 data / script 包组成的远端 session 仍然不连。内核因此仍然不知道通道是什么（physics #8）：它只知道有这么一个问题、以及该问谁。
2. **`.sealed` 的摊销是「每进程每版本一次」，不是「每次调用一次」，也不是「零次」。** 原则是"持有字节的机器至少在跑它之前验过一次"，而 resolver 的寿命恰好是一个进程（一个 `session step`、一条被服务的通道），所以 memo 让保证成立而代价有界。**如实记下的代价**：host 上因此比从前多付一次整包摘要——composition 冻结时已经对每个成员验过 `.sealed`，resolver 会对**真被调用到的**那些再验一次。没有把它省掉，是因为省掉的唯一办法是让 local 与 remote 两侧对"谁验过"给出不同答案，而那正是这次搬迁要消除的东西。
3. **"这个包在这台机器上没有可用的 entry 变体"从 `session new` 的硬失败变成一次失败的调用。** 这是搬迁的直接后果而不是遗漏：composition 不再替执行方回答"哪个文件"，而它对一场跑在别处的 session **答不了**这个问题；分成"本地时 host 判、远端时对面判"就是同一个决定做两遍。于是 `isUnrunnableHere`（store fault ∪ `EntryUnsupportedOnHost` ∪ `MissingRuntime`）在 `invoke.zig` 里折成一次失败的调用，点名包、版本与主机——**与远端拒绝的形状逐位相同**。e2e（`script_wire`）改成断言这条新行为。
4. **`presentation_file` 不过通道，而且这是判据而不是欠账**：§3.2 那张表的问题是**谁读它**，而它的读者是前端、在 host 上。所以远端 session 里包看不到这个变量，渲染不出面板——与 driver 压根没给一个时的行为完全相同，而不是写到一台没人看的机器上。
5. **`run-extension` 不 bump 协议版本**，与 `store-*` 同一条理由（规则 4：老 agent 答的是那句列出自己会什么的话），并且这次同样确认过那条路成立。
6. **请求头多一个 `session` 列而不是一次握手协商**：它对一条通道是常量，但放在帧里让 agent 对 session 完全无状态（不需要第二种握手后状态，也没有"谁先谁后"的顺序要求），代价是每帧多一个短字符串。`run-shell` 也带它，所以远端的 `shell` 命令与远端的 extension 看到同一个 `NULYA_SESSION_ID`。
7. **`envSessionId` 改读 `NULYA_SESSION_ID` 且不留 fallback。** 逐处判断的清单：`ext run` 的 usage journal `session` 列 / `session outcome` 的 `by:` / `task run|list|status|wait` 的缺省场次（都只要身份，且 task 自己从 id 拼路径）→ 改读 ID；`ext activate` 投 capability note（要那个文件）→ 保留 `NULYA_SESSION`；`extensions/agent` 的 parent（要 `session new --parent` 的那个文件）→ 保留；`extensions/std` 的 freshness 键、`extensions/handoff` 的 `<session>-<n>.md` 文件名 → 改读 ID（两者从来只要一个名字）。
8. **`Binding` 不再持路径与 interpreter**，只持 `(ext_id, version)` + manifest 的声明。于是 `composition.zig` 里 `entryPathAbs` 的调用整个消失，`bindingForSpec` 连 `roots` 都不再需要。
9. **exec_version 走一条与成员列表并行的数组**（`Resolved.exec_versions`，排序之后计算、按 id 与 header 对齐）而不是给 `Roots.Resolved` 加字段：那是 store 的类型，而"哪份字节服务这一场"是 session 的事实。
10. **`--target` 的反查不点名 compiler**：哪个 zig 建出了对面那份不是这一场该要求的，`findSealed` 内部的有序搜索保证多份合格时答案仍然确定。

**测试**：`zig build test` **564 pass / 4 skip**。e2e 逐组：`e2e-ext` 49 · `e2e-core` 48 · `e2e-agent` 23 · `e2e-std` 8 · **`e2e-remote` 20**（+4：extension 读到的是**远端**的 sentinel 且 freshness journal 落在远端 · 没 push 过的包是一次点名 `ext push` 的失败调用而 session 照常继续 · 反查不到 target 时 `session new` exit 1 并点名 `--target` 与 `ext push`，且什么都没创建 · 无 `exec_version` 列的老 header 照常 step）。
