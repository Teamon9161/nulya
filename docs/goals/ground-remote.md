# 远端 grounding —— 地图画在工作区那台机器上

2026-08-30。`goals/remote-env.md` §3.2 把这件事留成了 "Phase 3+ 的题目"，
并且已经给了判据；Phase 3 之后条件齐了，这里是它的契约。

## 0. 为什么现在

§3.2 那段结论今天仍然对：`ground` 在**机制上**不受远端化影响（`surface:
"internal"`，driver 在 host 上 `ext run` 它，从不经过 session 的
environment），但**语义上是错的**——它渲染的是 host 的 cwd、host 的目录树、
host 的 git 分支，而这一场的工作区在别的机器上。那份 prompt 会被冻进 header、
进缓存前缀、一辈子留在那场对话里，**而一张画错了的地图比没有地图更糟**：模型
不会去核对它，`ground` 存在的全部意义就是让模型不必核对。

Phase 1 的处置是**跳过**（TUI 的 `[env.remote] session_prompts` 缺省为空），
诚实但只是止损：远端场从此开场即失明——不知道自己在哪个目录、这个 checkout 有
没有自己的 `AGENTS.md`、工作树干不干净。

§3.2 也已经写好了出路：「一旦 `runExtension` 能远端跑，"在哪渲染"就与"在哪读
文件"是同一个答案」。Phase 3 后半（§6.4）让**session 的** extension 调用跑在
持有字节的那台机器上了，缺的只剩一个：**`ext run` 这个 driver 动词还是 host-only**。

## 1. 三件事，形状

### 1.1 `nulya ext run --env <spec> [--workspace <dir>]`

`extRun`（`src/cli/ext.zig:884`）今天建的是 `LocalEnvironment`，然后把
`(id, version, tool)` 交给 `invoke.invokeTool`。Phase 3 已经把
`ExtensionRequest` 改成身份、`remote serve` 已经服务 `run-extension`，所以这
条路差的**只是换一个 `Environment` 实现**，不是新机制。

一处真活：**版本要按对面的 target 反查**。host 上 `ground` 的 `current` 是为
host target 编译的那个 id，对面要的是同一份 snapshot 为它的 target 编译出来的
另一个 id。这与 composition 冻 `exec_version` 是**同一个问题、同一份实现**
（`Roots.resolveForTarget`，按 `(package_digest, target)`）——target 从 `hello`
来，通道本来就要开。

- 反查不到 → exit 1，点名 `nulya ext build <id> --target <arch>-<os>` 与
  `nulya ext push <id>@<v> --env <spec>` 两条命令（不是一句"没找到"）。
- data / script 包没有 target，两边同一个 id，直接送；对面没有那个版本时
  `run-extension` 既有的失败调用已经指路 `ext push`。
- `--workspace` 与 `session new` 同名同义（远端族才接受），缺省 `"."`。

**不做自动 push。** 这是这个仓库反复挡掉的那种便利：push 是人的决定，
`ext run --env` 的工作是**把该跑的命令说清楚**。

### 1.2 renderer 的约定从"答一个路径"改成"答一段文本"

今天：`nulya ext run <id> render` → `{"prompt": "<workspace 相对路径>"}`，
TUI 把这个路径交给 `session new --prompt`。

**远端上这个约定当场断掉**：ground 在对面渲染，文件落在对面盘上，而
`session new --prompt` 是在 **host** 上读字节（那些字节要冻进 host 的 header）。

改成 `{"text": "<正文>"}`：

- `ground` 删掉 `write()` 与那圈 `O_EXCL` 抢名的循环、删掉 `out_root`——
  **它的工作是产出文本，落在哪里是前端的决定**（与 Phase 2 让 `emit` 一个文件
  都不建、"字节变文件"只剩 `putWorkspaceFile` 一处，是同一个动作）。
- 前端把文本写进 **host** 的 scratch 再 `--prompt`，local 与 remote 走**同一条路**。
- **不加 `get-file` 协议动词**：一个路径只对产生它的那台机器有意义，而
  `--prompt` 冻的本来就是字节——把字节直接送回来比先送一个路径再回头取它少一步。
- 代价与收获各一条：文本要经 plain wire 的 stdout 当 JSON 字符串过来，所以
  **必须是合法 UTF-8**——`review-fork-remote.md` §6 那道终验从"防御"变成
  **承重**；而 `ext run` 的捕获上限是 1 MiB，ground 的预算（16 KB instructions
  + layout + git）离它很远。

这是一个**破坏性约定改动**，但它今天只有一个实现（`ground`）和一个消费者
（`tui/src/sessionprompt.ts`）——这是改它最便宜的一刻。

### 1.3 `[env.remote] session_prompts` 缺省翻成 `["ground"]`

policy 那一层**已经是对的、也已经可覆盖**（`tui/src/state/envprofile.ts`），
不需要新机制：只是等 1.1 + 1.2 让这句话变成真的之后，把 `remote` 那一档的
缺省从 `[]` 改回 `["ground"]`。

**没推过去的机器降级是诚实的**：`renderSessionPrompt` 抛出 → `App.tsx` 已经把
renderer 自己的诊断原样显示、**照开 session**（那正是 T66 那轮把"包解析不出"与
"render 失败"分开说的理由）。所以人看到的是一句指向 `ext push` 的话，不是一场
开不起来的对话。

## 2. 自动就对的与要核对的

跑在对面 = cwd 是远端工作区，于是 layout / instructions / git **三段自动是那台
机器的实话**；`builtin.os.tag` 也是对面的（跑的是对面 target 的二进制）。

要核对的两处：

- **`renderEnvironment` 里那句"`shell` tool 实际跑的命令行"**——它今天怎么得到
  这个答案，在远端上还成不成立。
- **日期**取的是对面的钟。这多半更对（工作区在哪，"今天"就在哪），但要写下来
  而不是默认。

## 3. 开放：`std` 跟不跟

同一个机制。Phase 3 之后，`--pin ext:std/read` 在一个远端场里**本来就会跑在对面**
（session 的 extension 调用已经跟着工作区走了），所以 `envprofile.ts` 那句
"`ext:std/read` reads THIS machine's filesystem" 的注释**可能已经是 Phase 3 之前
的旧话**——真正拦着它的更像是"得先为对面 target build + push"，而不是它会读错机器。

**先核对那条注释还成不成立，再决定要不要动 `remote` 那一档的 `pins`/`bare`。**
这一条不在本轮范围内——它比 ground 多一层 UX（六个 tool、`max_tools` 预算、
以及一个远端场该不该 `--bare`），值得单独一轮。

## 4. 验收

- 远端场开场，`ground` 的四段描述的是**远端工作区**：e2e-remote 里用
  `remote:exec:<本机 nulya> remote serve` 指向一个临时目录，断言渲染出的文本里
  的目录清单是那个临时目录的，不是 host cwd 的。
- 没为对面 target build/push 过 `ground` → 一句指名两条命令的失败，session 照开。
- local 路径逐字节不变（`{"text"}` 改的是谁写文件，不是写出什么）。

## 5. 实施记录
