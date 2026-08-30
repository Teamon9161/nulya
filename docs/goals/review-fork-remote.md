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

**不成立的那条**：`facts.zig` 的 `%<(240,trunc)%s`。git 按显示列截，最坏
4 字节/列 ≈ 960 字节，离 `prompt.max_system_prompt_bytes` 差三个数量级——注释说
它防住了"a document past the limit"是**成立的**。只把注释里 "no bound of its own"
改准（列上限，不是字节上限），不改代码。

## 7. 实施记录

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
