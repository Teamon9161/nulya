# 一轮外部 review：fork 丢环境、task 交接、UTF-8 边界

2026-08-30。对 remote Phase 4 + ledger-handoff 那一轮的外部评审，五条里四条成立。
本文件是这一轮的契约，实施记录在 §6。

## 0. 一句话

四个洞形状不同，但只有两种病因：**内核冻结的事实要靠 driver 抄一遍**（①），
**同一个问题有两份答案、弱的那份在承重路径上**（②④）；③⑤ 是第三种——
**裁剪/渲染方在越过边界之前不知道自己已经切坏了，失败落在下一层**。

## 1. ①　`session new --parent` 必须继承 environment / remote_workspace

`extensions/compact` fork 时只跑 `session new --parent <old>:<seq>`，
而 `src/cli/session.zig` 只从 argv 读 `--env` / `--workspace`。于是一个
`remote:ssh:box` 的场 `/compact` 一次就静默落回本机：shell 换机器、extension
换机器、spill 换机器，连 `Far.linkFor` 都读不出 child 是远端场，②的 sweep 更
不可能对。

**修在内核，不是在 compact。** environment + remote_workspace 与 model identity
同类：**创建时冻结的 session identity**，不属于"新 session 边界该重新 resolve
的 composition"。让 compact 自己读 header 抄两列，是把内核已经知道的事实绕一圈
从磁盘读回来，而且下一个 `--parent` 调用者要重学一遍（CLAUDE.md：一个决定在多
层各做一遍 = 该收的信号）。

规则（两支，各自可辩护）：

- `--env` **缺席**且有 `--parent` → `environment` 与 `remote_workspace` 一起从
  父 header 继承；此时 `--workspace` 若给出则**只覆盖目录那一列**（同一台机器
  换个目录是有意义的请求，不是猜）。
- `--env` **给出** → 两列都只从 argv 取，父场的两列一概不参与（换机器还沿用父
  场的路径才是猜）。`--env local` 归一成 `""`，所以"我要一个本机 fork"有显式出路。

继承来的值要走**与 argv 同一条校验**（`execTargetRefusal` / `legacySshHint` /
"workspace 只在 remote 族"），拒绝文案要说清这个值来自父场。

## 2. ⑥　`--prompt` 的 `source` 也要验 UTF-8

`promptRefs` 验了正文（`session.zig` 那段注释已经把理由写全了：非法 UTF-8 会被
`std.json.Stringify` 写成数字数组，header 不再是 §3 的形状），但
`.source = std.fs.path.stem(path)` 没验，而它一样进 header。同一个 BUGS #22
形状，入口窄，修法同款：点名拒绝。

## 3. ②　"这个 session 该收哪些 task 的结果" 只该有一份答案

两半，落点不同。

**a. 内核这半：`sweepRemoteReports` 用的是弱投影。** 它只扫
`launch.sessionTasksDir(session_id)`（自己 owner 的目录），而
`collectRows(only=X)` 已经同时按 owner 和 `notify` 扫。于是 retarget 到本场的
远端任务，`session step` 永远扫不到——它 doc comment 里那句 "a driver that never
runs a `task` verb still gets its results" 对 retarget 过来的任务不成立。

注意 `readRow` 的 remote 分支**已经**调 `pollAndDeliver`，所以正确的 sweep 基本
就是"跑一遍 `collectRows(only=session)` 并丢掉行"。要保住的只有那句
"pays no second connection"：已经开着的通道要能被复用，而不是让 `Far` 再连一次。
并且 `pollAndDeliver` 的 `cwd` 必须取 **owner 场**的 workspace，不是调用方的。

**b. 扩展这半：compact 问错了问题。** 它问 `--running`，但它要的是"该跟着我走
的任务"。`taskRetarget` 本来就有 `moveDeposit` 那条"结果已经落地"的路，正是为这
个窗口存在的；`--running` 把它过滤掉了。改成 retarget 父场的**每一行**（对已经
drain 过的 done 行是无害的 no-op），footer 里仍只列 live 的。

**开放（本轮不做）**：fork 要不要把父场 inbox 里其余未排干的 deposit 一起搬走。
`brief=latest` / `brief_file` 两条分支根本不碰父场，所以早于窗口就躺在那儿的
`task_finished` / `capability_note` / 排队的 `user_text` 一样会被遗弃。如果答案是
"compaction 是同一场对话换个文件"，那整个 inbox 都该跟过去，而且该是
`session new --parent` 自己做的事（又一条"内核冻的东西内核继承"）。等人裁决。

## 4. ③　handoff section 按字节切，而且切坏时 child 已经建好了

`handoffSection` 是裸 `trimmed[0..@min(trimmed.len, max_section_bytes)]`。
64 KiB 落在多字节字符中间 → 渲染出的 brief 不是合法 UTF-8 → `session append`
的 gate 拒绝，而那时 `session new --parent` 已经跑过、task 已经 retarget 过去，
留一个收不到 summary 的孤儿 child。

两件事都要做：

- **按 codepoint 边界裁**（`emit.zig` 的 head/tail 预算已经是这条纪律，不是新发明）。
- **顺序**：carried text 组装完、验一次，**再** fork。这样将来任何新的坏字节来源
  都不会再留下孤儿。今天 fork 在前、append 在后，中间还隔着 retarget。

## 5. ④　remote `task-poll` 把真实 I/O 错变成 "starting"，且远端任务永远 running

`cli/remote.zig` 的 `readTaskFile` 是 `catch ""`，host 侧把空 status 明确读成
`.starting`。AccessDenied / StreamTooLong / I/O fault 全塌成"还没启动"——正是
`Repo.outside → unknown`、`Answer` 收成 union 那一轮修过的形状。只把
`FileNotFound` 当空，其余走 refusal（host 侧就是 `unreachable`）。

顺带把 lease 投影一起带回来：`readRow` 的 remote 分支今天写死
`if (done) .done else .running`，所以 supervisor 死掉的远端任务永远显示 running，
`wait` 只能靠 timeout 收场。`TaskSnapshot` 是 `ignore_unknown_fields` + 全默认值
的 struct，加一列 **`lease_held: ?bool = null`** 对新旧两侧都兼容，**零额外
roundtrip**。消费规则：`done` → `.done`；否则 `lease_held == false` → `.lost`，
`true` → `.running`，`null`（老 peer 没这一列）→ `.running`（不知道就不主张）。

## 6. ⑤　ground 没有终验 UTF-8

`render()` 直接 `out.toOwnedSlice()` 返回，而非 git 回退路径上 `layout.zig` 把
readdir 的 `entry.name` / `child.name` 原样写进文档，POSIX 文件名不保证 UTF-8。
于是 `render` 报成功、`session new --prompt` 拒绝——正是这个包反复在修的那个形状。

修法两层：`layout` **跳过**非法 UTF-8 的条目（与 `instructions.zig:175` 跳过非法
候选文件同一条纪律：一个坏文件名该少一行，不该少一场 session），`render` 返回前
再 `utf8ValidateSlice` 兜底。

**这条后来被推翻**：`facts.zig` 的 `%<(240,trunc)%s` 曾被认为按显示列截、最坏
4 字节/列 ≈ 960 字节。**实测证伪**（下一轮 review，2026-08-30 晚，真 git
2.50.1）：一个由 U+0301 combining mark 堆出来的 commit subject——combining
mark 占一列但零宽度，列数与字节数的比例因此没有上限——让同一句
`%<(240,trunc)%s` 打出 2.2 MB，而不是预计的 960 字节。`git.zig` 的 `bounded()`
允许 4 MiB 原样通过，于是 `render` 照样报成功、`session new --prompt`（2 MiB）
拒绝——和 layout/UTF-8 那两条是**同一个形状**，只是换了一个字段。修法**不是**再
在列数上找安全边界（git 的截断本身就没有字节上界这个属性），而是给
`main.zig` 的 `render()` 加一个独立于任何单一 section 的**文档级 byte
budget**（`max_document_bytes = 1 MiB`，UTF-8-safe 裁剪 + 说明性 marker，复用
`instructions.zig` 已有的 `boundaryAtOrBefore`），`facts.zig` 里那段"960 字节"
的推导注释一并改成如实记录这次测量与它证伪的结论。

## 7. 实施记录

### 7.0 ①⑥ 落地（2026-08-30）：fork 继承环境、prompt 文件名验 UTF-8
**2026-08-30，①⑥ 落地（`src/cli/session.zig`，只此一个文件；②③④⑤ 由并行的其它 lane 负责，未动 `cli/task.zig` / `cli/remote.zig` / `extensions/compact/` / `extensions/ground/`）。**

① `createSession` 新增 `env_named` / `inherit_env` 两个局部：`env_named = flagValue(args, "--env")`（不 `orelse ""`，"缺席"与显式 `local` 分得开）；`inherit_env = env_named == null and parent_header != null`。`exec` 三路合一——命名了就 `normalizeExecSpec(e)`，没命名但有父场就取 `normalizeExecSpec(parent_header.?.value.environment)`（header 里存的本来就是创建时归一过的值，所以这一次是**保证规范形**而不是修复——冻进 child 的值不该取决于它走的是哪个分支），否则 `normalizeExecSpec("")`。`execTargetRefusal` 走同一次调用，不分叉；只有报错文案分叉，`inherit_env` 时点名 `parent.?.session` 与继承来的值，并附一句"在这个 fork 上显式写 `--env` 换一台机器"。`remote_workspace` 同一形状：`flagValue(args, "--workspace") orelse (if (inherit_env) parent_header.?.value.remote_workspace else "")`；后面那条"只在 remote 族接受"的校验完全不变，因为它只关心最终的 `exec`/`remote_workspace` 组合，不关心来源。

② `promptRefs` 里 `.source = std.fs.path.stem(path)` 挪出来做局部变量，`utf8ValidateSlice` 通不过就 `printErrFmt("--prompt {s}: file name is not valid UTF-8\n", …)` 并 `return null`（连 `bytes` 一起释放），在任何 `alloc.dupe` / `out.append` 之前——不留会话、不留半截分配。

**契约核对**：两条要求逐句照办，没有发现契约本身写错的地方。唯一补充：contract 只举了"`--env` 缺席 + `--parent`"与"`--env` 给出"两支，没显式写"没有 `--parent`"这一支（原逻辑分支，未受影响：`inherit_env` 恒 `false`，`exec` 走 `normalizeExecSpec("")`，与改动前逐字节相同）——落地时确认过这一支被现有代码路径自然覆盖，不需要第三条规则。

**测试**：
- 单元测试仍在 `zig build test`（569/573，4 个既有 skip，改动前后一致）——`createSession` 需要真实文件系统/host env，历来没有独立于 e2e 的单元覆盖，这次也保持这个分工。
- `tests/e2e/exec_env.zig` 新增两条（挂在 `e2e-core`）：
  - `"session new --parent inherits environment and remote_workspace from the frozen header, and --env local forks back to nothing"`——用 `--env remote:exec:true --workspace /x --bare` 建父场（`remote:exec:` 只需要非空 argv 词就能 PARSE 通过 `execTargetRefusal`，`--bare` 保证没有 compiled 成员、`ExecTargetProbe` 不会真的去连——落地前专门读了 `composition.ExecTargetProbe` 的调用点确认这一点，不是假设），断言① 无 `--env` 的 fork 两列都跟着来，② `--env local` 的 fork 两列都清空。
  - `"session new --parent: an inherited legacy ssh: environment is refused with a pointer at remote:ssh:, and names the parent"`——用 `ledger.encodeHeaderLine` 直接手搓一个带 `environment: "ssh:box.example"` 的父 header（今天的 CLI 已经拒绝 `--env ssh:…`，这是唯一还能构造出"老 header 里冻着退休拼法"这个场景的办法），断言 refusal 里同时有 `remote:ssh:`（`legacySshHint` 给出的具体建议）与 `s-legacy`（父场 id），且没有新建任何 session 文件。
- `tests/e2e/session.zig` 新增一条（同挂 `e2e-core`，POSIX-only——Windows 的 NTFS/UTF-16 路径没有办法构造出一个"文件名本身不是合法 UTF-8"的真实磁盘条目，`if (builtin.os.tag == .windows) return error.SkipZigTest`）：`"session cli: --prompt refuses a file whose name is not valid UTF-8, before a session exists"`，真在磁盘上建一个 `"bad-\xff\xfe.md"` 文件，断言 refusal 里有 `UTF-8` 且 session 计数未变。

**跑法与结果**（Windows，`.claude/worktrees/agent-acb6fa8d514e520bd`，基线 `0635ae9`）：`zig build test` → 569/573 pass（4 skip）；`zig build e2e-core` → 50/51 pass、1 skip（就是上面那条 POSIX-only 测试，在这台 Windows 机器上如预期跳过）；`zig build e2e`（全部五组）在改动落地、`zig fmt` 之前跑过一次，155/157 pass（2 skip），随后 `zig fmt` 只重排了新增代码的换行（多行 argv 字面量），语义零改动，重新单独确认 `zig build test` 与 `zig build e2e-core` 仍是同样的绿。三个新用例各自用 `-Dtest-filter` 单独跑过，逐一确认它们各自绿（而不只是整体计数对得上）。

**DESIGN.md / CLAUDE.md / guide skill 同步**：DESIGN §8.1（`Header.environment` 段落后新增一段说 fork 继承）与 §14 命令表的 `session new --parent` 那一条都补了这条规则；CLAUDE.md 追加一条"也跑通"记录（`src/root.zig` 那条之后）；`extensions/guide/skills/guide/SKILL.md` 的 `--parent` 那条项目符号补了 `--env`/`--workspace` 继承说明——它是模型会读到的文本，不出现 `DESIGN §x`，只讲行为。
### 7.1 ②③ 落地（2026-08-30）：一份答案的 sweep、跟着走的结果、fork 之前的那次校验

本节记 §3（②）与 §4（③）。§1 / §2 / §5 / §6 属另一条 lane。

**改动落点**：`src/cli/task.zig`（`Far` 两处 + `sweepRemoteReports` 整个）· `src/cli/session.zig`
（调用点一行 + 它上面那段注释）· `extensions/compact/src/main.zig`（`handOverTasks` /
`compact` 的顺序 / `handoffSection` / 新 `utf8PrefixLen` / 新 `isLive`）· `build.zig`
（`extensions/compact` 的 test module）· `docs/DESIGN.md` §8.2 / §11 · `CLAUDE.md` 两条。
`src/environment/remote/*` 与 `src/cli/remote.zig` **一个字节都没动**。

#### ② a — sweep 就是 `collectRows`，不是第二份遍历

`sweepRemoteReports` 从"走一遍 `sessionTasksDir(<本场>)`"变成：

```
var far: Far = .init(alloc, io);
far.lend(session_id, ch);              // 借通道
_ = collectRows(arena, io, &far, session_id);   // 行丢掉，投递是路上顺手做的
```

签名少了 `cwd` 那个参数——**它正是那个 bug 的形状**：调用方把自己的
`remoteWorkspace()` 交出来，而每个任务的 `cwd` 该由它 **owner 场**的 header 说，
`Far.cwdFor(owner)` 早就是那个答案。现在没有第二处能回答它。

`Far` 多两个字段一个方法（`lent_spec` / `lent` / `lend`）。**按 spec 键而不是按
session 键**，这是契约没说但必须这样的一点：retarget 之后要问的是**别人那一场**的机器，
按 session 借的话 `channelFor(owner)` 会重连——而 owner 与 reader 冻在同一台机器上
正是 compaction 的常态。`lend` 的 spec 取自 `linkFor(session_id)`，也就是那一场 header
的那一列，所以借用不引入第二个"这一场在哪台机器上"的答案。

**留下的两处代价，写下来不是欠账**：

1. **owner 在另一台机器上时，扫描会连一次。** 没有加"只用借来的通道"的模式位——
   那正是 CLAUDE.md 说的 flag，而它买到的是"一个读者比它旁边的 `task list` 答得少"。
   `Channel.connect` 失败即 `unreached`，扫描 best-effort，step 照常。
2. **本场是 local 时不扫。** 调用点仍在 `if (lenv == .remote)` 里，因为那里没有可借的通道，
   而让每次本机 `session step` 都可能停下来跟一台远端机器握手，代价落在最热的路径上。
   这种任务（远端 owner，retarget 进一个 local 场）由任何 `task` 动词收走——TUI 每 1–2 s
   就在轮。契约那句"不同的机器该开就开（或留给下一个 `task` 动词）"两条都用上了：
   有通道时前者，没通道时后者。

顺带：扫描现在与 `task list --session X` 走同一条路，于是它也读 `notify`、也对
已 `delivered` 的远端行 poll 一次（旧 sweep 提前 skip 过）。这不是新代价——
`task list` 一直在这么做，而两个答案变一个答案的收益远大于每步多几帧。

**`RemoteEnvironment.remoteWorkspace()` 一并删掉**（`src/environment/remote/mod.zig`）：
它是当年**专为**这个调用点加的公开访问器，参数没了之后读者归零——CLAUDE.md 那条
"一个动词没有语义就是该删的信号"。私有的 `remoteCwd()` 照旧（内部还在用）。

#### ② b — compact 交接的是"该跟我走的"，不是"还在跑的"

`handOverTasks` 的 `task list` 去掉 `--running`，retarget 每一行；footer 用新的
`isLive(row)` 只描述 `running`/`starting`。理由写在函数注释里：`--running` 滤掉的正是
`moveDeposit` 那条路存在的理由——**结果已落地、还没人排干**，也就是 fork 与任务完成
之间那个窗口留下的状态。`unreachable` **不算 live**（那一行没人知道它在不在跑，而 footer
是一句承诺）。

#### ③ — 顺序是渲染 → 校验 → fork，裁剪按字符边界

两件都做了，落点按契约那句"更早更好"选：

- `handoffSection` 的 `trimmed[0..@min(…)]` 换成 `trimmed[0..utf8PrefixLen(trimmed, cap)]`。
  `utf8PrefixLen` 是 `emit.validUtf8PrefixLen` 那五行的第二份——**不得不是**：extension
  从自己的冻结 snapshot 编译，够不着 `src/`（`extensions/agent/src/record.zig` 抄
  `journals/journal.zig` 是同一条先例）。注释点名了出处。
- `compact()` 里新的一步 4b：`footer` + `carried` 在 fork **之前**拼好并
  `utf8ValidateSlice` 一次，不合格就 `failed` 且什么都没动。于是"孤儿 child"这个状态
  不再取决于我们今天想到了哪些坏字节来源——`brief_file` 读的是这个包没写过的文件。
- fork **之后**才拼得出来的只有 `tasks_footer`（retarget 要 child 的 id）。它由代码从
  任务名与命令生成、必然合法（`task list --json` 里非法 UTF-8 的 `command` 会被
  `std.json.Stringify` 写成数字数组，于是 `stringField` 读回 null），仍单独验一次：
  不合格就**少这一句**并往 stderr 说一声，而不是少一场 session——retarget 已经发生，
  那句话只是描述它。

#### 契约里说得不够准的一处

§3a 写"正确的 sweep 基本就是跑一遍 `collectRows(only=session)`"，这是对的；但它把
"pays no second connection"当成唯一要保住的东西，而**真正的不变量是 `cwd` 取 owner 的
那一条**——契约在下一句才提到它，且没说这正是旧签名里 `cwd` 参数的由来。删掉那个参数
是这次改动里最能防止复发的一步：那个洞不是"扫描扫得不够广"，是"调用方被允许回答一个
不属于它的问题"。

另外，§3a 说的"pays no second connection"在 retarget 跨机器时**做不到**，契约自己在
括号里给了两条出路。取了"该开就开"，理由见上面第 1 条。

#### 开放那条（fork 要不要搬走父场 inbox 里其余未排干的 deposit）

没动手。实现过程中冒出来的、能让这个决定更清楚的两件事：

- **`task_finished` 这一类已经有答案了，而且答案是"搬"**：`moveDeposit` 就是在搬它，
  只不过是**逐任务**搬、由 `task retarget` 顺手做的。所以问题不是"要不要搬"，而是
  "剩下那两类（`capability_note`、排队的 `user_text`）凭什么不搬"——今天的不对称
  纯粹来自 retarget 恰好握着那个文件名，不是任何人想过的边界。
- **搬的落点确实该是 `session new --parent`，但只对 fork 那一刻在 inbox 里的东西成立。**
  `task_finished` 不一样：它在 fork 之后还会**继续到达**父场的 inbox（任务的 `notify`
  没改的话），所以它需要的是 retarget 那个持续生效的指向，而不是一次性的搬运。
  如果整个 inbox 都由 `--parent` 搬走，`task retarget` 的 `moveDeposit` **仍然不能删**
  ——两者服务的是不同的时间段。裁决时值得把这一条摆在旁边：它意味着"整个 inbox 跟着走"
  不是"compact 少做一件事"，而是"内核多做一件事、compact 一件都不少"。

#### 测试

- `extensions/compact` 第一次挂进 `zig build test`（`build.zig` 新 test module，
  `std`/`agent`/`ground` 的同一条先例）。三条单测：**按字符边界裁**（`max_section_bytes - 1`
  个 ASCII + 一个三字节汉字，恰好跨界）· **整份 brief 仍是合法 UTF-8**（四节全部越界）·
  **footer 只描述 live 的行**（含"读不出的 state 不算 live"）。
- `tests/e2e/background.zig` +1：**fork 之前就落地、还没人排干的结果跟着走**——
  deposit 从父场 inbox 消失、在 child inbox 出现、child 的下一步把它排进自己的 ledger，
  而 footer 不提它。
- `tests/e2e/remote.zig` +1：**一场 session 的 step 收的是"报告进它"的任务，不只是它起的**
  ——两场远端 session 同机同工作区，任务在 owner 场起、**在还被 hold 住时** retarget 给
  reader 场（所以 retarget 自己不可能已经投递过），放行、等对面写出 `report.txt`、
  确认 host 上还没有 deposit，然后**只**跑 `session step <reader>`。

**先红验证过三处**：`handoffSection` 换回裸字节切片 → 两条 UTF-8 单测当场红 ·
`handOverTasks` 换回 `--running` → 新的 background e2e 在 `deposit 从父场消失` 那一行红 ·
`sweepRemoteReports` 换回旧的 `sessionTasksDir` 遍历 → 新的 remote e2e 在
`"kind":"task_finished"` 那一行红。

**数字**：`zig build test` 576（572 pass / 4 skip，+3）· `e2e-core` 49（+1）·
`e2e-remote` 25（+1）· `e2e-ext` 51（50 pass / 1 skip，不变）。

### 7.2 合并时记下的一条代价（审阅者补，未修）

②a 把 sweep 塌进 `collectRows` 是对的，但顺带丢掉了一个只有 sweep 有的短路：
旧 sweep 在**发帧之前**就 `if (markerPresent(delivered_file)) continue`，而
`pollAndDeliver` 是**先 `pollTaskOn` 再看** `delivered`。于是一个远端场每 step
要为**每个已完成且已交付**的任务各付一次 round trip，且这个数只增不减。

**不阻塞**，因为它不是这次引入的：`task list --session <id> --json` 走的就是这条
路，而 TUI 状态栏一直在轮询它——这个代价在轮询侧早就在付了，本次只是让 step
路径也开始付同一份。

**要修就不该修成一个 flag**（"只投递不看状态"就是那个 CLAUDE.md 警告的模式位）。
更像答案的形状：**一个 delivered 的任务已经结束，而结束了的状态不会再变**，所以
host 在交付时把那份 status 留在自己这边（`delivered` 旁边），此后 `readRow` 读本地
副本、不再发帧。它同时修好轮询侧，并且让一个已完成的远端任务在机器够不着时仍能
显示 `done` 而不是 `unreachable`——今天那种情况下 `task list` 会永远说
`unreachable`，而那句话对一个早就交付过的任务是假的。等第一次真的嫌慢再做。
### 7.3 ④⑤ 落地（2026-08-30）：远端 poll 的诚实与 lease 投影、ground 终验

**④ a. `readTaskFile` 不再把真实 I/O 故障折成"还没写"**（`src/cli/remote.zig`）。
只把 `error.FileNotFound` 读成空（= "supervisor 还没写"，与本机 `starting` 同一
纪律）；别的错误（权限、`.limited(cap)` 读越界、任何这台机器磁盘上真发生的故障）
一律传播给 `serveTaskPoll`，那里对 status / report 两次读各自 `refuseFmt`——两次
读失败说的是不同的话，因为调用点知道是哪个文件。一次 refuse 落到 host 侧走的是
**已经存在**的那条路：`pollTaskOn` 把 `!rep.ok` 变成 `error.RemoteRefused` →
`pollAndDeliver` 折成 `.unreached` → `readRow` 本来就把它映成
`.@"unreachable"`——缺的只是别让 `catch ""` 拦在半路。

**④ b. `lease_held` 搭着同一轮 `task-poll`回来，`lost` 不再是要避开的"第二个
问题"**。契约原文说"远端不做 lost 投影……每次 poll 多问一次不值"，判断错了对象：
真正要省的是**一次协议往返**，不是**多读一个文件**——`leaseHeldIn` 与
`status.json`/`report.txt` 那两次读同属一次 `task-poll`。`TaskSnapshot` 加一列
`lease_held: ?bool = null`（`src/environment/remote/protocol.zig`，**不 bump 协议
`v`**：新字段 + 已有的 `ignore_unknown_fields` + 默认值，对老 peer 天然兼容，
`null` 就是它诚实的答案）。`src/cli/task.zig` 的 `leaseHeld` 按契约要求重构成
**`pub fn leaseHeldIn(base: std.Io.Dir, io, alloc, dir)`**——第一个参数从写死的
`std.Io.Dir.cwd()`换成调用者给的目录句柄，本机 `projectState` 传
`std.Io.Dir.cwd()`，`serveTaskPoll` 传它已经打开的远端工作区句柄；**一处实现，
两个 caller**，原注释解释的"探测用 `openFile` 不用 `createFile`"那条理由原样
保留（探针创建 `.lock` 会在关闭的一瞬间让真 supervisor 的非阻塞抢锁失败）。
`FarAnswer.status` 从裸 `[]const u8` 改成 `struct{bytes, lease_held}`（唯一两个
调用点是 `readRow`——我的——与 `sweepRemoteReports`——按边界说明没有碰它的代码，
它把返回值整体丢弃，字段增加对它零影响）。

`readRow` 的消费规则（`lost is not available over there` 那段旧注释已改写成
现在的事实）：`status.state == .done` → `.done`；否则 `lease_held == false`
（对面明确说没人守着这个租约）→ `.lost`；`true` 或 `null`（老 peer 没这一列，
答不上来）→ `.running`——不知道不许读成"没人守着"。

**⑤ ground 的两层 UTF-8 终验**（`extensions/ground/src/{layout,main}.zig`）：
`layout.zig` 的 `skip()` 对不是合法 UTF-8 的目录条目直接跳过（与
`instructions.zig:175` 跳过非法候选文件同一条纪律，参照契约建议未在标题里加话——
`instructions.zig` 对同类情况也没有，一个坏名字该少一行不该多一句解释）；
`main.zig` 的 `render()` 在拼好整份文档、返回前再 `utf8ValidateSlice` 兜底一次，
不合法就 `return error.InvalidUtf8`（一次失败的调用，`.status.json`/文档一个
字节都不写）。`facts.zig` 的 `%<(240,trunc)%s` 按契约要求**只改了注释**（"no
bound of its own" → 说清是列上限不是字节上限），代码未动——契约给出的三个数量级
边际核实无误。

**测试**：单测 `extensions/ground/src/layout.zig` 新增一条（`skip` 拒绝非法字节、
放行普通非 ASCII UTF-8 名字）；e2e `tests/e2e/remote.zig` 新增两条：一条构造
"远端 supervisor 死掉——status 还写着 running，没有 `.lock`"，断言 `task list
--json` 读出 `"state":"lost"`；一条构造"`status.json` 在远端是目录而不是文件"
（真实 `error.IsDir`），断言读出 `"state":"unreachable"` 而非 `"state":"starting"`。
三条都在改回旧代码后单独复现过失败（`skip` 去掉 UTF-8 检查、`readRow` 的新分支
改回 `if (done) .done else .running`、`readTaskFile` 改回 `catch ""`），改回来后
全绿。`zig build test`：574（+2 ground）。`zig build e2e-remote`：26（+2）。
`zig build e2e-core`：48（无回归）。

**契约哪里说得不够精确**：④a 段"读同一个文件的两种失败要说不同的话"这句读起来
容易理解成"同一个文件的两种不同错误码要分别措辞"，实际含义（结合上下文）是
"status 文件与 report 文件各自读失败时的话不同"——两次 `readTaskFile` 调用各自
`refuseFmt`，而不是在 `readTaskFile` 内部对错误类型分支措辞（`FileNotFound` 与
其它错误的分野本身已经是"两种失败"）。照最合理的读法实现，未发现契约条目本身
有错误。

**审阅补一处（合并时）：远端的 lease 探针要等 status 出现。** ④b 落地时
`serveTaskPoll` 是**无条件**探 lease 的，而这个探针会**自己短暂持有那把锁**
（`openFile` 带 `lock=.exclusive, lock_nonblocking`）。supervisor 拿不到 lease 时
的行为是打一句 `another supervisor already owns` 然后 **exit 1**——于是一次落在
supervisor 的 `open(O_CREAT)` 与它的 `flock` 之间的 poll，就能让那个任务静默地
永远不跑。

本机撞不上这个窗口，**而且是碰巧撞不上**：`projectState` 只在"已经有 status"时
才探，而 supervisor 是**先拿 lease 再写第一条 status** 的。无条件探等于只在远端
这一侧把这层保护拆掉。所以远端也按同一顺序问：`status.len == 0` → `lease_held`
答 `null`（诚实：`readRow` 对没有 status 的任务本来就读成 `starting`，根本不看
这一列）。**两台机器同一个提问顺序**，这条才算真的只有一份实现。

### 7.4 第三轮 review 的两条（2026-08-30）：⑤ 的"三个数量级"被证伪、`leaseHeldIn` 自己也在塌答案

第三轮外部 review 用真 git（2.50.1）实测推翻了 §7.3 结尾那句"契约给出的三个
数量级边际核实无误"——不是没做验证，是当时的验证本身就没跑对着 combining
mark 构造过。

**⑤（重开）：`%<(n,trunc)` 没有字节上界这个属性，不是"上界更宽"。**
`git log -1 --format='%h %<(240,trunc)%s'` 对一个由 ~110 万个 U+0301 组成的
subject 打出 2,200,249 字节；`%<(10,trunc)%s` 对 2000 个 U+0301 打出 4011
字节。combining mark 占且仅占它依附的那个字符的显示列，本身零宽度，所以
"列数"与"字节数"之间没有任何比例关系可言——240 列可以是 240 字节也可以是
2.2 MB，`bounded()` 的 4 MiB `max_output` 才是它现在的真实上限。

修法**不是**在列数上继续找更保守的安全边际（这条路本身就走不通），而是给
`extensions/ground/src/main.zig` 的 `render()` 加一个与任何单一 section 无关的
**文档级 byte budget**：新常量 `max_document_bytes = 1 MiB`，新函数
`clipToBudget`（复用 `instructions.zig` 已有的 `boundaryAtOrBefore`，因此该函数
改为 `pub`）在 `out.toOwnedSlice()` 之后、UTF-8 终验之前跑一次，超预算就 UTF-8
安全裁剪并追加一行说明（"this document was N bytes; the render budget is M,
so it was cut here"）。选 1 MiB 而不是等于内核的 2 MiB：这是 Ground 自己的
渲染预算，不是把 kernel policy 抄一份，留出的余量正是给这类"某个上游工具的
截断比想象中松"的情况。`facts.zig` 里那段推导注释整段重写，如实记录这次
测量与它推翻的结论，不再声称任何字节上界。

**新增的 leaseHeldIn 问题（不在原契约里，是这一轮新读出来的）：** 同一次
review 顺带读出 `cli/task.zig` 的 `leaseHeldIn`——④a/④b 刚刚才把
`readTaskFile` 与 `TaskSnapshot.lease_held` 修成"答不上来就说答不上来"——自己
仍在犯同一个错：`catch |err| switch (err) { error.WouldBlock => true, else =>
false }` 把权限拒绝、`.lock` 是目录、任何真实 I/O 故障，与"没有 lease 文件"
一并读成"没人持有"。远端这一侧 `serveTaskPoll` 已经在用 `try` 调用它，只是
`leaseHeldIn` 从不真的返回错误，所以这条路径此前从未被走到。

修法对齐 ④a 已经立好的规矩：`leaseHeldIn` 只把 `error.FileNotFound` 折成
`false`，其余错误 `return e`；`serveTaskPoll` 里 `try` 改成显式
`catch |err| { refuseFmt(...); return; }`，让一次读锁故障从"这个任务的
supervisor 已经死了"变成"这台机器现在答不上来"（host 侧因此读成
`unreachable` 而不是 `lost`）；本机侧 `readRow` 里 `.state = try
projectState(...)` 改成 `projectState(...) catch return null`——与紧邻的
`readStatus(...) catch return null` 同一条纪律，一次真实的锁读故障跳过这一行
而不是让整个 `task list` 崩掉。

**测试**：`extensions/ground/src/main.zig` 新增三条单测（在预算内原样通过、
3 MiB 全 ASCII 被裁到预算附近且带说明文字、裁切点恰好落在多字节字符中间时不
产生非法 UTF-8）；`tests/e2e/remote.zig` 新增一条——远端 `status.json` 说
`"running"` 但 `.lock` 是目录（真实 `error.IsDir`），断言 `task list --json`
读出 `"state":"unreachable"` 而不是 `"state":"lost"`。

### 7.5 第四轮 review 的四条（2026-08-30）：本机 lease 故障别把 task 吞掉、compact 的 unknown-state footer、ground 预算算成真的硬上限、"resolves itself" 那句话改准

**① §7.4 里 `readRow` 本机分支那处 `.state = projectState(...) catch return
null` 本身是新 bug**（不是历史遗留，是上一轮引入的）：一次真实的 `.lock` 读
故障会让 `readRow` 整体返回 `null`，而 `null` 经 `lookupRow` 变成
`taskStatus`/`taskWait`/`taskKill` 的"no such task"——比 `lost` 更强的一句假
话：claim 与 status 都还在，只是这一次读不出锁，`task list` 把它悄悄漏成一行
不存在的任务。改回 `.state = try projectState(...)`（不折进 `null`），错误
往上传播，`task list`/`status`/`wait` 响亮失败而不是报告一个不存在的任务；
`readRow` 头顶的文档注释与 `.state` 那一行各补一句，说清"为什么这里**不**跟
`readStatus` 用同一条 `catch return null`"（一个 skip 掉一行列表，一个是对
"这任务存不存在"这个问题给出错误答案，程度不同）。**测试**：`cli/task.zig`
新增单测直接钉 `projectState`（`.lock` 是目录）——Windows 上这个组合实际抛的
是 `error.Unexpected`（NTSTATUS INVALID_PARAMETER，非 `error.IsDir`：带
`lock=.exclusive` 的 open 在目录上撞的是另一条 NT 路径），所以断言改成"任何
错误都要传播"而不是钉某个具体错误名——真正要守的不变量是"这是一个错误，不是
一个值"。`tests/e2e/background.zig` 新增一条端到端的：手搓一个本机 claim 目录
（status 写 running、`.lock` 是目录），`task status` 前后两次调用分别验证
①退出码非零 ②stdout 为空（没有走到"打印 state"那一步）③stderr 里没有
"no such task"。两条都在临时改回 `catch return null` 后验证过会红。

**② compact 的 `unreachable` retarget 从"完全不提"改成单独一句 unknown-state
footer**：`handOverTasks` 新增第二个桶 `unknown`（`isUnreachable`），与
`moved`（`isLive`）平行收集、平行生成句子——"Background tasks with unknown
remote state at fork: … their machine could not be reached when this session
was forked, so whether they are still running is not known, but they were
retargeted here and may still report."，与"still running"那句**互斥且不
覆盖**（两句可以同时出现，各管各的事实）。retarget 本身不变（§7.1 已经改成
对每一行都做，这里只是 footer 怎么说）。**测试**：`tests/e2e/background.zig`
新增一条——真实起一台"曾经可达、后来不可达"的远端机器（复制本进程的可执行
文件到工作区、指向那份拷贝的 `remote:exec:` spec、在拷贝还在时正常
`append`+`step` 拿到一个真实 ledger seq、再删掉那份拷贝让后续连接必然失败），
手搓一个本机 claim 目录模拟"任务的报告没跟着回来"，`task list --json` 确认
读成 `unreachable`，跑 `compact` 后**直接读子场 inbox 里那条被 deposit 的
brief**（不 step 子场——fork 在没给 `--env` 时继承父场的 `environment`，子场
会带着同一个已经不可达的 exec target，`session step` 对任何一步都要先建
environment、不管这一步会不会真的调 shell，所以 step 子场会跟 step 父场
一样失败），断言新句子的三个关键片段都在、且旧句子"still running when this
session was forked"不在。在临时改回旧 `handOverTasks` 后验证过会红。

**③ ground 的 `max_document_bytes` 改成真的硬上限**：旧代码先把正文裁到
`max_document_bytes`，再把说明性 marker **追加**在后面——于是 `render` 真正
返回的字节数是 `max_document_bytes + marker.len`，注释说的"hard ceiling"其实
只管到正文那一段。改成先量 marker（`std.fmt.bufPrint` 到一个 256 字节的栈
buffer，两个 `usize` 十进制数字 + 固定文案，远够用）、正文预算收成
`max_document_bytes -| marker.len`，`clipToBudget` 返回值因此**恒 ≤
max_document_bytes**。测试断言从 `clipped.len <= max_document_bytes + 200`
改成 `clipped.len <= max_document_bytes`（真正的硬上限，不再留一个"够用就行"
的容差）。

**④ "那台机器一回来就自己解决" 这句承诺删除，不新增机制**：`start-task` 的
channel-故障分支（`src/environment/remote/mod.zig`）与
`docs/goals/remote-env.md` §6 偏差 6 都写着这句话，而它不成立——`task-poll`
对"supervisor 还没写 status"与"对面根本没有这个任务目录"给的是同一个空答案，
所以一个从未真正送达对面的 `start-task` 请求会让这一行永远读成 `starting`，
不管那台机器回不回来。按 review 的建议**不新增机制**（真要收敛需要
`start-task` 能安全重放，今天重放一次就是起两个 supervisor，代价比这个窄
边界本身大得多）：两处注释都改成如实记录这是一个已知、边界很窄的缺口（channel
恰好断在"claim 已经写下、请求还没真正送达"这一小段窗口），不再暗示它会自愈。
只改文字，不改代码，不加测试——没有行为可断言，只有一句不该说的承诺被删掉。

**四条修完之后**：本机 / 远端两侧对"读不出一个事实"的处理终于对齐到同一条
纪律——本机 `.lock` 故障、远端 `.lock` 故障、远端 `status.json`/`report.txt`
故障，四个位置现在都是"传播错误或读成 unreachable"，没有一个还在把"读不出"
悄悄变成"没有"或"死了"。这轮 review 到这里为止，不再继续找 remote Phase 4 /
ground 这两块的边角。
