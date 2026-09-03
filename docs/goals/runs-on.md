# Goal · runs-on：一个包声明它要挨着**会话**还是挨着**工作区**（2026-09-03）

> **执行契约**。地图与 physics 在 [CLAUDE.md](../../CLAUDE.md)，现状在 [DESIGN.md](../DESIGN.md) §7.2.1（manifest）/ §8.1–8.2（exec target 与 remote）/ §9（authority）。
> 同一轮的另一半是 [model-roles.md](model-roles.md)（档位表）；委派本身的既有契约在 [agent-runner.md](agent-runner.md)。
> **pre-release，不要向后兼容。**

## 0. 结论（一段）

`--env remote:` 的会话里，**委派完全不可用**——而且第一道门（`NULYA_SESSION` 不过通道）只是最浅那层，打通它也走不通：委派必须起后台任务，而 `startDelegationTask` 走的是 `nulya task run --session <parent>`，`task run` 第一件事是读 host 上的 session 文件；扩展进程在对面，那里没有 `.nulya/sessions/`，也**没有第二条起任务的路**（`start-task` 是 host 发起的帧，协议一次一请求、没有 unsolicited 帧）。

**做不到的不是子会话，是"从对面那台机器上把它开出来"。** 子会话本身与父会话同构完全可行：ledger 在 host、模型调用在 host、`shell` 过通道。位置错的是**调用者**。

所以：**让包自己声明它要挨着谁。** `runtime.runs_on: "workspace"`（缺省，今天的行为）| `"session"`。这不能做成全局开关——`std:read/edit/write` 必须挨着**文件**，`agent` 必须挨着**会话**，这个差别只有包自己知道，内核无从推导（DESIGN §8.1 已经否决了"只搬命令"那条轴，正是同一个理由）。

**它也不是发明一个新位置**：`nulya ext run` 今天就无条件用 `LocalEnvironment`（`cli/ext.zig` 的 `extRun`），CLI 路径的扩展本来就在本机跑。今天的不对称是——手敲 `nulya ext run agent …` 在本机跑得好好的，模型调同一个 tool 却被送去对面死掉。

## 1. 已定决策

### A · manifest：`runtime.runs_on`

- 闭合词表 `workspace` | `session`，**缺省 `workspace`**（老 manifest 读回来就是它，零迁移）。未知词整份 manifest 拒绝——`surface` 的同一条纪律。
- 落在 `runtime` 下（它说的是**怎么跑**），不是顶层（顶层的 `apply` 说的是"装上我意味着什么"）。
- 随版本冻结。**header 不加列**：成员版本本来就冻在 `composition.active` 里，落点跟着 manifest 走，所以 physics #2 自动守住。
- **`data` / `script` / `compiled` 三种实现都可以声明**；与 `implementationKind` 正交。

### B · 授权：没有第二道门（**2026-09-03 撤销：这条曾要求拒绝 workspace 层的声明**）

原来这里写的是"workspace 层拿到 reach 的包不得声明 `session`，否则 checkout 里的扩展就把自己从对面那台机器挪回你的笔记本上跑"。**它的前提是错的**：

- **workspace 层是指针，不是字节来源。** 版本字节一台机器只有一处（store），只能由有人在本机 `ext build` 放进去；workspace 里只有 draft 源码与一个可选的 `current`。一个 clone 带不进可执行字节，committed 的 `current` 也只能点名这台机器 store 里已经封好的版本。
- 而"把字节放进 store"按 DESIGN §9 的既有立场**与 `shell` 已有的权限同级**——那是一次人或 agent 的动作，不是 clone 的副作用。所以拒绝这个指针层挡不住任何真实威胁。
- 落地后还发现它**无条件生效**：本地会话里 `runs_on` 根本不起作用（两台机器是同一台），却也照样拒绝——把"在 checkout 里开发这个包"这条路堵了。

所以**没有这道门**。诚实的说法是：落点是包在 manifest 里的**公开声明**（`ext inspect` 打的就是 manifest 原文），不是内核替某个 id 开的后门；而它站在 §9 那条既有的话上——**exec target 从来不是权限边界**，`runs_on` 撑开的不是一条守住过的边界，而是一条从未主张过的。真要一道门，它的轴是"这一场允不允许宿主侧扩展"（会话或 trusted config 的决定），不是指针层——今天不做，等有人真的要。

### C · 内核的两处缝（同一个概念的两次应用，**词必须一样**）

1. **扩展落点**：`RemoteEnvironment.runExtensionImpl` 对 `runs_on: session` 的成员不过通道，走本机 `invoke.zig`。分流做在 `RemoteEnvironment` **内部**——`Environment` 的 vtable 仍是四个动词，`ToolContext` 不加字段。落点集合由壳层（`launch.sessionEnvironment`）在建环境时交下来。
   - **实现者要先确认的顺序问题**：composition 与 environment 谁先建。落点集合来自 composition，若 environment 先建，需要把它推迟或二次注入——**不许**让 `RemoteEnvironment` 自己去读 manifest（持有字节的机器才回答 schema 问题，而它不持有）。
2. **任务落点**：`nulya task run --runs-on session|workspace`（缺省 `workspace` = 今天：按 header 的 `environment` 建环境）。`session` 形态无条件用 `localEnvironment`。
   - **好消息，已核实**：任务名今天就在 host claim（`RemoteEnvironment.startShellTaskImpl` 调 `claimTaskSlot(tasks_dir)`，host 路径），host 目录本来就存 host-only 的事实（retarget、报告有没有投递）。所以宿主侧任务**不需要新的命名机制**，只是 spawn 换一侧。
   - **由此产生的一个真问题**：一场 session 的任务从此可能落在两台机器上，`task list` / `status` 的读者得知道该问哪一侧。**不许靠"host 目录里有没有 `status.json`"去猜**——那和 `starting` 这个投影状态直接撞车。**claim 的时候在那个目录里写一个 marker**，读者按 marker 分流（`cli/task_remote.zig` 的 `Far.isRemote` 从"按 session 判"改成"按任务判"）。

### D · `agent` 包这一侧

- `extension.json` 声明 `runs_on: "session"`。
- `parent` 改从 **`NULYA_SESSION_ID`** 取。今天读 `NULYA_SESSION` 再取 `stem`，而 `parent` 往下传给 `startDelegationTask` / `allowedHere` / `parentIdentity` 时**全部当 id 用**——这是绕路，本地也该改。
- 开子场时从父 header 取 `environment` / `remote_workspace`，传 `--env` / `--workspace` 给 `session new`：**父子同构**——两场的 ledger 都在 host，两场的命令都在对面同一个工作区。
- ~~`record.zig` 的 `created` 行冻住这两列~~ **不做**（2026-09-03 落地时撤销）：子场自己的 header 已经按内核 physics 冻着 `environment` / `remote_workspace`，而 record 的 `remote` 就是那个子场的 id——再抄一份是**一个只写不读、且复述 ledger 已有事实的列**。要问"这次委派的命令在哪跑"，读子场的 header。
- `startDelegationTask` 用 `task run --runs-on session`。

### E · 代价，写下来而不是藏起来

1. **workspace 层的 `.nulya/agents/*.md` 换了目录**——宿主侧的包按 **host 的 cwd** 解析定义，而远端会话的 checkout 在对面。user 层（`~/.nulya/agents/`）与 builtin persona 不受影响。**不要**为此发明第二条查找路径。
   **落地时的修正**：契约原来要在 `defs.zig` 加一句 warning，**没做**——那需要把这一场的 exec target 一路穿到定义加载器里，只为一句话；而 host 那个目录**不是错的地方**（这一场的 ledger 就在那儿，那是人本地工作的那个 checkout），只是与过去不同的地方。`agent list` 的 layer 列本来就把"workspace 层是空的"显示出来。写进 DESIGN §8.2 与 guide skill。
   **同一族的第二条**：外置 runner（codex / claude / pi）从此在**会话那台机器**上起它们的 harness，所以远端会话里它们看见的是 **host 的文件系统**。留在远端工作区里干活的是 nulya 子场。
2. **physics #6 的字面被撑开**：宿主侧扩展拿到的是 host 的执行权限，而这一场的 `shell` 拿到的是远端的，`extension ⊆ shell` 字面不再成立。DESIGN §9 已经先答过"exec target 不是权限边界：把工作区搬到另一台机器改变的是命令在哪跑，不是它能碰什么"——**这次要在 §9 写明这是一次显式取舍**，以及它没有第二道门（§1.B）与为什么。
3. **`emit` 的溢出仍走 `putWorkspaceFile` → 落在远端工作区**。对 `agent` 无所谓（回执很小），但这是这个缝的一处不对称，写下来免得以后当 bug 查。
4. 子场自己是远端场，所以它 `--bare` 之后定义里 `with:` 的 compiled 成员需要为远端 target build + push——与任何远端会话同一条规则，但对"委派"是新摩擦，refusal 要指路。
5. `exec_version` 那一列对 `runs_on: session` 的成员**恒空**（`composition.freshExecVersions` 跳过 target 反查）——于是 `--env remote: --with agent` 不再要求先给 agent 包 `ext build --target` + `ext push`。

## 2. 不做

- **不按 id 在内核里写死任何包**。落点是包的公开声明，不是内核的后门。
- **不加反向帧 / 不让对面主动发起请求**（方案 B 的死因，也正是 CLAUDE.md 否决的 watcher 方向）。
- **不让 driver 代劳**（TUI 从 ledger 认出 agent 的 tool call 自己起任务）：每个 driver 都要重学同一份 folklore，`drivers/goal.*` 那两个 ≤70 行、不解析 JSON 的做不到。
- **不加 header 列**、不加 `Environment` 的第五个动词、不给 `ToolContext` 加字段。
- **不改 `putWorkspaceFile` / `runShell` / `startShellTask` 的过通道行为**。

## 3. 验收

守机制：

- 远端会话里委派开出的子场，**文件在 host**，报告经 inbox 回到父场；子场的 `shell` 跑在**对面**。
- `runs_on: session` 的成员在远端会话里 `exec_version` 为空，且**不要求** push。
- 一场 session 同时有宿主侧任务与远端任务时，`task list` 两个都答得出来（marker 分流）。
- 老 manifest（没写 `runs_on`）行为逐字节不变。

不断言文案、不枚举排列组合。
