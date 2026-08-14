# Nulya — 设计文档 (v0.1 draft)

> A minimal immutable kernel + a self-evolving native capability layer.
>
> Nulya 不给 AI 一堆工具，而是给 AI 一个足够可靠的"制造工具的底座"。
> 内核只有两个工具（shell、edit），第三个工具由 Nulya 自己造出来。

本文档是设计基线，不是最终 API。术语：**ledger** = 会话事件日志；**generation** = 缓存世代；**step** = 一次 model 请求-响应。

---

## 0. 三条硬约束（一切设计服从于此）

1. **Ledger 从 API 层就不可变**：会话是严格 append-only 的事件日志，没有任何"改历史"的接口。目的是把 prompt-cache 命中率变成一个**可断言的不变式**，而不是一句愿望。
2. **尽量少与模型交互**：core 默认并发执行同一 turn 内的多个 tool call，全部完成后合成**一条** user turn 回传，绝不一个工具一次请求。
3. **单文件可执行、离线可跑**：Zig 工具链内嵌进二进制（`@embedFile`），拷一个可执行文件过去就能编译/运行 extension，无任何网络下载。

这三条都由 **kernel** 保证，不下放给"让 AI 自己实现"。

---

## 1. 贯穿全局的主线：缓存世代 (cache generation)

引入一个单调计数器 `generation`。它把三条约束统一成一个不变式：

> **在同一个 generation 内，第 N+1 次请求发给模型的字节前缀，逐字节 ⊇ 第 N 次的前缀。**

于是同一 generation 内每次请求都是"纯前缀延长" → 缓存最大命中。`generation` 只在三件事发生时 +1：

| 事件 | 为什么会炸缓存 | 设计对策 |
|---|---|---|
| 工具集合变化 | `tools[]` 位于缓存前缀最前面（Anthropic 顺序：tools → system → messages），一变全后缀失效 | **对话内绝不改 tools[]**；工具集只在对话开始时选定并冻结（见 §5） |
| Compaction | 它重写历史 = 定义上就是炸前缀 | 让 compaction 罕见、边界明确；compaction 后新摘要成为新的稳定基座（见 §11） |
| system prompt / 工具定义变化 | 同样在前缀里 | 把易变量（时间戳、随机 id）挤到序列化尾部或排除出缓存区 |

**可测性**：core 应能在任意两次同 generation 请求上 `assert(bytes[N] is a prefix of bytes[N+1])`。这个断言是 Nulya 缓存正确性的守门员，写进测试。

---

## 2. 架构总览

```
                         ┌───────────────┐
                         │      LLM      │
                         └───────┬───────┘
                                 │  immutable ToolSetSnapshot (frozen per step)
                                 │  request bytes = pure prefix-extension within a generation
                  ┌──────────────┴──────────────┐
                  │            KERNEL            │
                  │  ┌────────────────────────┐ │
                  │  │ Agent loop / step m/c   │ │  ← batch, immutable snapshot per step
                  │  │ Ledger (append-only)    │ │  ← the immutable API
                  │  │ Cache-generation mgr    │ │
                  │  │ Provider runtime        │ │  ← normalize + place cache breakpoints
                  │  │ Compaction              │ │
                  │  │ Tool registry           │ │
                  │  │ Extension manager       │ │  ← build/validate/test/activate/rollback
                  │  │ Execution Environment   │ │  ← local | sandbox | remote | acp
                  │  │ Authority / policy      │ │
                  │  │ Managed Zig toolchain   │ │  ← @embedFile'd, extracted on first use
                  │  └────────────────────────┘ │
                  └──────────────┬──────────────┘
             ┌──────────────┬────┴─────┬──────────────┐
          shell           edit    (对话开始选入的      Extensions
        (builtin)      (builtin)   少量 native 工具)   (subprocess, JSON stdio)
```

模型永远只直接看到 **builtin(shell, edit) + 本场对话选定的少量 native 工具**。其余能力全部经 `shell → nulya ext run` 调用。

### 2.1 Frontend / Core 分离 + subagent = 自调用

- **Core 是 headless、以 ledger 为中心的引擎**（上图 KERNEL）。**CLI / live TUI / app 都只是 core 之上的薄客户端**：观察 ledger（tail append-only 日志）+ 追加 user 事件。这保证三种前端共用同一个 core。
- **Subagent = 自调用（self-invocation）**：subagent 不是 in-process 对象，而是 `nulya` 拿一个子 ledger、经 Execution Environment **再 spawn 自己一遍**，与 extension 走**同一套 spawn 机制**。因为通信是 append-only 事件（见 agents-and-review §2），且 ledger 持久化让 **resume ≡ 重新 spawn**，subagent 轮间不常驻，承载状态的是磁盘上的子 ledger。
- 独立子 ledger = 独立 cache scope，**不碰主 agent 缓存前缀**；前端是长期进程，re-spawn 的只是 worker，**UI 状态不丢**。唯一需要常驻进程的是"子 agent 与真人持续流式对话跨多轮"——DESIGN §7.3 `process_mode = persistent`，纯后期加法。详见 [agents-and-review.md](agents-and-review.md) §6。

---

## 3. Ledger：不可变的会话 API

### 3.1 数据模型

Ledger 不是 `Vec<Message>` 加随手 truncate，而是一条 **durable、append-only 的事件日志**。事件类型（初版）：

```
user_message | assistant_message | tool_call | tool_result
| tool_available_note      // 对话中新增能力，见 §5.3
| registry_selection       // 对话开始时选定的 tools[]
| extension_build | extension_activate
| extension_review         // 审阅门结论，见 agents-and-review.md
| review_question | review_answer   // 主 agent ↔ 审阅者的 append-only 通信
| compaction               // 见 §11
```

每条事件：`seq`（单调）、`generation`、`parent_seq`、内容、`content_hash`。整条日志内容可寻址。

### 3.2 API 约束（硬性）

- **没有 `edit_event` / `delete_event` / `reorder`**。API 表面只有 `append(event)` 和只读的 `read/replay/fork`。
- "纠正"语义 = **append 一条纠正事件**（例如工具结果错了，append 一条新的 tool_result 修正 + 一条说明），或 **fork 一条新 ledger**。
- **fork 与父 ledger 结构共享前缀**（copy-on-write）；前缀部分的 prompt-cache 依旧有效。"重新生成上一轮"在语义上只能是 fork 出新分支，不能原地改。
- 发给模型的请求字节，是 `events[0..k]` 的**纯函数**。这保证 §1 的前缀不变式。

### 3.3 派生视图（projection）

工具统计、UI、trajectory、metrics 全部是 ledger 的**投影**，不持久化 mutable 状态：

```
immutable events ──projection──▶ ToolStats { uses_total, uses_recent, last_used, success_rate, latency }
```

统计口径以后改了可以重算。这也是为什么工具排序（§5）能安全演进。

---

## 4. Agent loop 与 batch（少交互的核心）

一个 **step** 的生命周期，core 保证如下不变式：

```
build request (freeze ToolSetSnapshot for this step)   ← 工具集在一个 step 内不可变
        ↓
model response  (可能含多个 tool_use A, B, C)
        ↓
并发执行 A,B,C（相互独立者并行；经 Execution Environment §8）
        ↓
等【全部】 resolve —— 绝不提前回传任何单个结果
        ↓
按 tool_use_id 有序合成【一条】 user turn（多个 tool_result block）
        ↓
commit registry changes（若 A 造了新工具，见下）
        ↓
next step 的请求才反映新工具（通过 append note，不改 tools[]）
```

**关键子规则（ChatGPT plan 第 12 条，采纳）**：若 A 在本 turn 中激活了新能力，B、C 仍然只看见**本 step 冻结的旧快照**；新能力最早在**下一个 step** 通过 append 的 note 出现。即：

> **ToolSetSnapshot = immutable for one model step.** 写进 kernel invariant。

**batch 友好性**：因为低频能力走 shell，模型也可以在**一条** shell 命令里并发多件事（`nulya ext run a & nulya ext run b & wait`），进一步压缩 round-trip。

---

## 5. 工具面与缓存（本设计的核心决策）

### 5.1 对话内 `tools[]` 冻结

- 一场对话**开始时**，按规则选定 `tools[]`，**整场冻结**。对话内 `generation` 不因工具变化而 bump。
- 选择规则（`registry_selection` 事件记录）：
  1. builtin：`shell`, `edit`（永远在，位置固定最前）。
  2. 用户 pin 的 native 工具（配置指定）。
  3. 自动按使用统计排序补足到上限 K（`uses_recent` + `uses_total` + `last_used` + `success_rate` 的投影排序）。K 是早期默认值（如 6–8），非永久。
- 排序**只在此刻发生一次**。对话开头本就是新前缀、无缓存可炸，所以"晋升"零成本。**排序绝不在对话中途重排**（那才是缓存杀手）。

### 5.2 native 工具的位置稳定性

选入的 native 工具在 `tools[]` 里**按稳定 ID 排序**，不因"刚调用过一次"就前移。位置抖动同样伤缓存与可复现性。

### 5.3 对话中新增能力 = append 一条 Note（不改 tools[]）

Agent 在对话中途造出/发现新 extension 时：

- **不修改** `tools[]`（改了就 miss）。
- **append** 一条 `tool_available_note` 事件，内容形如：
  > 新能力可用：`web_search`。调用方式：`shell` 执行 `nulya ext run web.search '{"query": "..."}'`。
- 因为是追加，前缀不动，缓存继续命中；模型下一 step 即可经 shell 调用。
- 该 extension 会在**下一场对话**的 §5.1 选择里，凭统计有机会被晋升进 `tools[]`（此时零缓存成本）。

> 一句话：**晋升发生在对话边界，对话中途只追加 note。** 这条规则同时满足"缓存不可变"与"能力可增长"。

### 5.4 为什么不做 ChatGPT 的动态 promotion/eviction/ranking

它的机制漂亮，但每次 activate/evict 都在对话中途改 `tools[]` = 全量 cache miss，与头号诉求正面冲突。§5.1–5.3 拿到它的全部好处（stats 驱动的能力增长）而**零缓存代价**。

---

## 6. 两个内置工具

> 输出截断/落盘/裁剪的细节与踩坑数字见 [base-tools.md](base-tools.md)。核心：**一个统一 `emit` 原语 + 自动落盘**，基础工具保持薄。

### 6.1 shell

- 单一工具，不拆 `bash`/`powershell`/`sh`/`zsh`。model-facing schema 恒定：`{ "command": "..." }`。
- 系统提示告知当前 `shell_dialect = bash | powershell`。dialect 由 Execution Environment（§8）决定。
- 所有 `nulya ext ...` CLI 都经 shell 调用 → 保持模型工具面极小。

### 6.2 edit

- **不采纳** ChatGPT"纯 patch"的激进方案（AI patch 上下文常 fuzzy、apply 失败就多一轮 round-trip，违反 §0.2）。
- 采用**精确匹配 + 优质报错**（类 Claude Code）：`old_string` 唯一匹配替换 / `replace_all` / 新建 / 删除，作为一个事务。apply 失败要给出可操作的 diff 上下文，让模型一次纠正。
- 读文件交给 shell（`cat`/`rg`/`sed`/`git diff`）——读本就要一个 round-trip，native read 并不省，故不必为它单列工具。

---

## 7. Extension 模型

### 7.1 形态：Native Executable + stdio JSON（不是 .so/.dll）

采纳 ChatGPT 第 3 条。动态链接对 AI 生成代码是灾难（ABI / Zig 版本 / crash 带死 host / allocator 所有权 / 跨平台）。Extension = 子进程，wire protocol 就是 ABI，也因此不绑定 Zig（Rust/Go/Python/TS 都能实现，Zig 是官方默认语言）。

### 7.2 目录与 manifest

```
.nulya/extensions/web-search/
├── extension.json      # manifest：可发现性元数据 + （若晋升 native 时的）schema
├── src/main.zig
└── tests/*.json        # 真实验收用例，见 §12
```

`extension.json`（示例）：

```json
{
  "schema": "nulya.extension/v1",
  "id": "web.search",
  "version": "0.1.0",
  "entry": "bin/web-search",
  "tools": [{
    "name": "web_search",
    "description": "Search the web and return relevant results.",
    "input": { "type": "object",
      "properties": { "query": { "type": "string" } },
      "required": ["query"] }
  }],
  "permissions": { "fs": [], "network": ["https"], "process": [] }
}
```

**manifest 是 schema 的唯一真相**（采纳 ChatGPT 第 4 条）：绝不"启动 binary 再问它有什么工具"，避免 source / manifest / runtime describe() 三份状态漂移。binary 只负责 `execute(tool, args)`。

> 注：在 §5 的 shell-first 方案下，manifest 的 `tools[].input` schema **只在该 extension 被晋升进 tools[] 时**才喂给模型；平时它只是 `nulya ext find` 的可发现性元数据 + 供 shell 调用者参考的用法。这让 v0.1 的 manifest 负担很轻。

### 7.3 Wire protocol（v1 傻瓜化，spawn-per-call）

```
spawn → stdin(request JSON) → stdout(response JSON) → exit
```

```json
// request
{ "v": 1, "id": "call-17", "tool": "web_search", "args": { "query": "..." } }
// success
{ "v": 1, "id": "call-17", "ok": true,  "value": { "results": [] } }
// error
{ "v": 1, "id": "call-17", "ok": false, "error": { "code": "NETWORK_ERROR", "message": "...", "retryable": true } }
```

v1 **不做** daemon / persistent worker / streaming / bidirectional events / host callbacks。

**关于"每次 spawn 会不会慢 / 会不会堆一大堆进程"（重要，写清）：**

- **不会堆积**：oneshot 模型是"读请求→干活→写结果→**退出**"，毫秒级消失。一个 turn 内并发 N 个 tool call 就并发 N 个进程，干完全退，任意时刻活着 ≤ N（N=模型这一轮的调用数，很小），然后归零。**会堆积一大堆常驻进程的恰恰是持久化没管好生命周期时**——oneshot 天生不残留。内核再加一个**并发上限**兜底。
- **spawn 本身很便宜**：原生 Zig binary spawn ≈ 1–5ms（Linux；无解释器/VM 预热，不同于 Python/Node），对比模型 round-trip ≈ 秒级、真干活的工具自身几十 ms–秒级 → **spawn 开销对绝大多数工具 <1%**。且**最高频的 shell/edit 是 in-core 内置、根本不 spawn**，extension 是低频长尾。
- **真正的成本不是进程启动，是某些 extension 每次调用的重初始化**（browser 每次启 Chromium、DB 每次重连、embedding 每次 load 模型）——这跟"是不是子进程"无关，in-process 一样痛。

**对策：默认 oneshot，`persistent` 按 extension 声明、按需 opt-in**（`"process_mode": "persistent"`，默认 `"oneshot"`）。只有当某 extension 的重初始化被**实测**证明是瓶颈时才开。开启后内核给它一个**有界 warm worker 池**：

- 复用长连接，**同一套 JSON 协议**，只是 transport 从"spawn-stdin-stdout-exit"换成"长管道 + 分帧" → **扩展代码无需改写**，两种模式共享协议；
- **上限 N 个 warm worker（LRU 淘汰）+ 空闲 TTL（如 60s 无调用即退出）** → 有界、会自回收，不堆积；
- worker 崩溃重启，仍崩不死 host（隔离保留）。

> 纪律：**先测量再持久化。** 不为想象中的慢提前造 daemon。
>
> 考虑过 WASM in-process（免进程 + 沙箱），**否决**：与"原生 Zig + 内嵌工具链"冲突，要拉入 WASM runtime、削弱语言无关性、WASM 沙箱自带性能/复杂度成本。原生子进程的 crash 隔离与语言无关更值。

### 7.4 生命周期：不可变版本 + 原子切换（采纳 ChatGPT 第 7/22 条）

绝不"改源码直接覆盖正在运行的工具"。状态机：

```
draft ──build──▶ built ──validate/test──▶ installed ──activate──▶ active
                                                                    │
                                                     update│        │disable
                                                           ▼        ▼
                                                    new immutable  installed
                                                       version
```

- 每次 build 产出**不可变版本**，版本 id = `hash(source + zig_version + target + manifest)`。
- 布局：`foo/{v-a8fc3c, v-b193ab}, current -> v-b193ab`。
- 更新 = build 新版本 → validate → test → **审阅门** → **原子切换 current**；旧版本保留。
- rollback 本质就是 `current = old_version`，无需复杂逻辑。B 挂了 A 完全不动。
- **`installed → active` 之间有一道内核强制的审阅门**：由一个 read-only 审阅 subagent 把关，专治"为单任务加参数"的工具膨胀。工具变动**必须过审**。详见 [agents-and-review.md](agents-and-review.md)。

### 7.5 能力三级（采纳 ChatGPT 第 8 条，略调整）

```
Scratch    一次性：shell 里 `nulya toolchain zig run /tmp/foo.zig`，不进工具库
   ↓
Extension  复用第 2、3 次：沉淀为 .nulya/extensions/foo，经 `nulya ext run` 调用（仍不进 tools[]）
   ↓
Native     真高频：下一场对话 §5.1 选择时晋升进 tools[]
```

Scratch 与 Extension 其实是一条连续谱：唯一区别是"是否存盘 + 给 manifest"。

### 7.6 工具的上下文模型（tool 拿得到什么、拿不到什么）

**大原则：tool 是无状态纯函数 `f(args, environment, ctx_header) → result`，它拿不到 ledger。**

core 探索到的信息分两类，走两条完全不同的路——这是本节的核心区分：

| 信息类型 | 例子 | 持有者 | tool 如何获得 |
|---|---|---|---|
| **事实性 / 持久** | 文件内容、目录结构、命令输出、代码 | **工作区文件系统** | 经 environment（cwd/fs）**直接读**；文件系统 = 共享持久记忆，不是"重新探索" |
| **语义性 / 对话** | "决定用方案 B"、"X 是根因" | **ledger（模型上下文）** | **不给 tool**；由**模型提炼进 `args`** |

所以 core **不是**"零信息只有 shell"——它信息丰富，但那份丰富是**模型的**（在 ledger 里）。tool 与 core 共享的是**文件系统**，不是 ledger。

**为什么坚决不把 ledger 给 tool：**

1. **模型是上下文路由器**：模型读了一切、挑出相关的塞进 `args`；tool 需要什么模型已备好。
2. **开销爆炸**：大对话几 MB，每次 spawn 都序列化 + IPC 一遍（正是"对话大了开销大"的来源）。
3. **最小权限**：AI 生成的 extension 不应能读整段对话（§9 authority）。
4. **可复现**：保持 `args → result` 纯函数，审阅门 golden 测试（§12）才成立。

**tool 只拿一个恒定大小的 `ctx_header`**（与对话大小无关）：workspace root / cwd / os / shell dialect / scratch+cache 目录 / 截断上限 / 权限描述。经 env var 或 request 里一个 `_ctx` 字段注入。

**tool↔tool 共享知识，只走两条正道：**

- **(a) 模型中转（默认）**：A 出结果 → 模型 → 把相关部分作为 B 的 `args`。模型是 tool 间的导线，无需 tool 耦合。配合 base-tools §2 **大输出落盘留指针**：大结果落盘、只回指针+摘要，模型把**指针**传给 B、B 自读文件 → 大数据不经过模型上下文，只有指针流动。
- **(b) 磁盘制品（贵的派生态）**：A 把索引/embedding/解析树写进 `.nulya/cache/`，B 直接读（真实工具就这么干：ctags 写 tags、LSP 维护自己的索引）。

**反模式（禁止）**：tool 直接互相调用 / 共享内存态——重建耦合、毁掉无状态可复现。

**防"每个 tool 重新探索"**：共享 fs + `.nulya/cache/` 磁盘缓存 + 模型路由，让事实落 fs、派生态落 cache，谁都便宜复用；再加可选的 **agent 维护的项目笔记/记忆文件**（模型 `read` 便宜、tool 经 fs 可读）——轻约定，可自生长，不做重内核。

**分界线（自调用送的礼）：**

> **凡"真的需要对话/ledger"的东西，就不是 tool，而是 subagent。**

subagent = 自调用，有**自己的子 ledger**；需要上下文时由**父级模型挑一份相关切片喂进子 ledger**（或 attach 报告）。于是"要不要给 tool ledger"被彻底化解：**tool 永远无 ledger；需要 ledger 的都是 subagent 且各有其一。**

**"那给 tool 一个 ledger 文件路径呢？"——伪解，否决。** 它不省开销，只是把成本从"序列化进 request"挪成"**每个 tool 各自读+解析一遍**"（同样几 MB，还乘以 N），并把"上下文路由"塞进每个 tool（那是模型的活），同时毁掉最小权限与可复现。正解相反：让 ledger 待在**已解析好**的地方（core/模型），只传**蒸馏后的 args**。

**唯一窄例外**：本职就是操作对话本身的 tool（导出转录、搜历史）——"对话"才是它的 args。即便如此：① 只给**那一个** tool、作为**显式 arg**（`export_transcript(ledger_id)`）；② 给的是 core 提供的**只读查询 API**（"取第 N 条 / 搜 X"），**不是**让 tool 自己 parse 原始文件（否则又回到"每个 tool 重复解析"）；③ 这类东西多半本就是 core 功能（compaction）或 subagent。

---

## 8. Execution Environment 抽象（DeepSeek 理念）

把 **原生/云环境、本地、沙箱、ACP** 统一成一个 `Environment` 接口——shell 与 extension 的执行都经它，方便快速切换执行目标。

```
Environment (interface)
├── run_shell(command, dialect, authority) -> result
├── run_extension(entry, request_json, authority) -> response
├── fs view / cwd / env (sanitized)
└── dialect() -> bash | powershell
```

后端：

| backend | v0.1 | 说明 |
|---|---|---|
| `local` | ✅ | 直接在宿主执行；env 净化（§9）；shell-equivalent authority |
| `sandbox` | 后续 | landlock+seccomp / namespaces（Linux）、sandbox-exec（macOS）、AppContainer/restricted token（Windows）、或容器 |
| `remote` | 后续 | 远程执行环境 |
| `acp` | 后续 | Agent Client Protocol 接入编辑器/外部 agent 环境 |

关键：**authority model 与 environment 解耦**——同一套 permission 概念投射到不同 backend 的强制机制上。v0.1 只实现 `local`，但接口就位，后面加 backend 是 drop-in。

---

## 9. Authority / 安全（v0.1 诚实版）

**明确不假装 manifest.permissions 是安全边界。** AI 生成的原生 binary = 任意机器码；`"network": []` 在没有 OS 强制时拦不住 `curl`。所以 v0.1：

- **规定 extension 与 shell 共享同一个 `session_authority`**（≈ 当前用户全权限）。像 DeepSeek 对 Cordis 那样**明说**这个边界，不给虚假安全感。
- **env 净化（必做）**：extension/shell 子进程**默认不继承 host 环境**。`ANTHROPIC_API_KEY` / `OPENAI_API_KEY` / `AWS_SECRET_ACCESS_KEY` / `SSH_AUTH_SOCK` 等**只存在于 host**，永不下传给 AI 生成的 binary。
- **同一 authority model 管 shell 和 extension**：permission 只能在 `session_authority` 内**继续收窄**（`extension_permissions ⊆ session_authority`），绝不能因为注册成 extension 就获得 shell 本来没有的权限。
- **后续里程碑**：`sandbox` backend 上线后，manifest.permissions 才真正被 OS 强制。届时它从"声明"升级为"边界"。

---

## 10. 内嵌 Zig 工具链

- **`@embedFile` 宿主平台那一份 Zig（pinned，如 0.16.x）压缩包进 nulya 二进制**，首次需要时解压到 `~/.local/share/nulya/toolchains/zig/<ver>/`（Windows 用 AppData）。
- nulya 二进制本就平台相关，故只需内嵌宿主平台一份；而**一份宿主 Zig 即可交叉编译到所有 target** —— 白赚跨平台构建。
- 代价：二进制 +~50MB（linux/mac）/ +~90MB（win）；nulya 自更新时重新带上。**符合"不差这点大小、拷一个文件就能跑、零网络"**。
- **删除** ChatGPT 的"按需下载 + hash 校验 + pinned 漂移 + 网络失败处理"整套复杂度——净简化。
- AI **不直接** `zig build`，而是 `nulya ext build .nulya/extensions/foo`，由 nulya 统一决定 zig version / optimize / cache dir / target / output，保证**可复现构建**。
- 可选：另出一个不内嵌 Zig 的瘦身版给"确定系统已有 Zig"的用户；主版内嵌。

---

## 11. Compaction 与缓存

- Compaction 是 ledger 里的一个**事件**，不是"随手 truncate"。它保留近期上下文，把旧消息压成结构化 summary（记录文件操作等），参考 Pi。
- 它**必然**炸一次缓存（重写前缀）→ 因此它是一次显式 `generation++`。设计目标：**让它罕见、边界明确**；compaction 后，新的 summary 成为**新的稳定基座**，之后请求在其上纯前缀延长，缓存重新建立。
- compaction 边界应尽量放在自然断点（一个 task 完成后），避免频繁触发。

---

## 12. 质量门（不让 AI 自证）

ChatGPT 的 validate/test 门是空心的：工具与测试都 AI 写，测试只证明它自洽。要让门有意义，验收标准**不能只由 AI 出**：

- `tests/*.json` 里的 golden 输入/期望输出，优先来自**用户/真实数据**，或人可 review。
- `nulya ext test` 在**真实输入**上跑，结果给人看（尤其首次 install）。
- 高价值工具支持**对拍**（与已知正确实现 diff）。
- validate 至少含：manifest schema 合法、entry 可执行、协议往返正常、声明的 permission ⊆ session_authority。
- **门通过 ≠ 正确**，只是"没有明显坏"。文档里对模型和用户都说清楚这一点。

---

## 13. Provider 抽象与 cache breakpoints

- Provider runtime 归一化不同厂商协议；在**generation-稳定的边界**放置 cache breakpoint：tools 之后、system 之后、最后一条稳定消息之后（append-only 让"最后"这个断点持续前移）。
- breakpoint 数量、最小可缓存 token 数等是**厂商相关**，实现时对齐各家文档核实（不在本文档写死具体数字）。
- 目标：把 §1 的前缀不变式翻译成"每次请求命中最长已缓存前缀"。

---

## 14. CLI 表面（都不是 LLM tool，经 shell 调用）

```
nulya ext init | find | list | inspect | build | test
             | activate | deactivate | rollback | run | api
nulya toolchain zig <args>        # scratch 用
nulya ext api [protocol|permissions|examples]   # 模型查【本机】真实 API，杜绝猜签名
```

**`nulya ext api`（采纳 ChatGPT 第 17 条）**：所有协议/权限/示例由**当前 nulya 二进制自己生成**，模型永远查本机，不会出现"模型知识里的 v0.4 API 与用户机器 v0.7 不一致"。→ 模型工具面恒为 `{shell, edit}`（+ 本场选定的少量 native）。

---

## 15. 明确划线：kernel invariants（不可自生长）vs 可自生长能力

**kernel（必须内置、保证正确性，绝不"让 AI 写个 extension"）：**

```
Agent loop / step 状态机 · Ledger append-only 与前缀不变式 · Cache-generation 管理
Batch（并发执行 + 单条回传）· ToolSetSnapshot per step · Provider 归一 + cache breakpoint
Compaction · Tool registry 与对话开始选择 · Extension build/activate 事务 · rollback
Subagent 能力模型（read_only 天花板 / ToolPolicy）· subagent=自调用 · 工具审阅门（installed→active）
Frontend/Core 分离（headless ledger 引擎 + 薄客户端）
Execution Environment 抽象 · Authority / env 净化 · Managed Zig · Telemetry · Crash recovery
```

**可自生长（内核之上皆可学习）：**

```
grep glob git web-search browser pdf excel database github docker lsp ripgrep
image/audio kubernetes ssh jira notion ...
```

> 定位差异：Pi = minimal harness + 人/模型写的 TS extension；DeepSeek = microkernel + "Everything is a Plugin" + 运行时自修改。
> **Nulya = minimal immutable kernel + self-evolving native capability layer**。不是"Everything is a Plugin"，而是"**Everything above the kernel is learnable**"。

---

## 16. Roadmap（先把闭环跑通）

第一阶段**不碰** browser / subagent / MCP / LSP。先把六样做对：

1. `shell` + `edit`
2. Ledger（append-only 事件日志）+ §1 前缀不变式断言
3. Tool registry + 对话开始选择 + per-step immutable snapshot + `tool_available_note`
4. `extension.json` + subprocess JSON protocol + `Environment.local`
5. `build → 不可变版本 → activate → rollback` 事务
6. 内嵌 Zig `<pinned>` 工具链 + `nulya ext build/run`

**里程碑（项目之魂）：**

> **Nulya v0.1 自带两个工具。第三个工具由 Nulya 自己创造。**

闭环示例（用户："帮我分析这个 parquet 数据"）：

```
无 parquet 能力 → nulya ext find parquet → 无 → AI 写 parquet-inspect/src/main.zig
→ nulya ext build → nulya ext test(真实数据) → append tool_available_note → 经 shell 处理数据
→（三周后再遇 parquet）已有，直接用 →（发现慢）改源码 build v2 → benchmark → 原子切 v2 →（regression）rollback v1
```

这个闭环跑通，Nulya 的灵魂就立住了。

---

## 17. 开放问题（待定）

- **compaction 触发策略**：token 阈值 vs task 边界 vs 混合；如何最小化 generation bump。
- **对话开始 tools[] 的上限 K** 与排序权重（`uses_recent` vs `success_rate` 权衡）的初值。
- **`nulya ext run` 的 JSON 手写负担**：低频工具经 shell 时模型要手写 JSON，是否给一个更宽松的 `--arg k=v` 语法降低出错率。
- **ACP / remote environment** 的具体协议选型。
- **cross-conversation 的 extension 复用**在多用户/多 workspace 下的隔离与共享边界。
- **provider cache breakpoint** 的精确放置与各厂商差异核实。
