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
