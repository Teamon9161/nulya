# Goal · std：一个随仓库带的 extension，复刻 tcode 的 read / write / append / grep / glob 体验

> 这是一份**执行契约**，不是设计文档。设计背景在 [PLAN.md](../PLAN.md) §0.1 #3（脚本 / 编译 extension 优先于改内核）、§3.4.1（"nulya 没有 std tool 层"——随仓库带的一方 extension是**默认可得、按需可见**）；现状在 [DESIGN.md](../DESIGN.md) §5.1（pin）/ §7（extension 模型）/ §7.3（wire protocol）/ §7.6（tool 拿不到 ledger、tool 间只经磁盘制品共享）；输出纪律在 [base-tools.md](../base-tools.md)；地图和 physics 在 [CLAUDE.md](../../CLAUDE.md)。
> **每次 compaction 后先重读本文件**，尤其是 §6 进度区。
> 本文件的决策来自 2026-08-18 的设计对话（记录在 §3），已定的不要重开；认为错了就写进 §6 BLOCKED 并停下，不要自行改方向。
> **规格书就是 tcode 的 Rust 源码**（本机 `C:/code/rust/tcode/crates/tcode-tools/src/`，见 §4）：数字、错误文案、边界行为**照抄**，只砍 §1 明说不做的东西。

## 0. 目标（一句话）

`extensions/std/`：一个 **compiled** Zig extension（与 `compact` / `handoff` 同层、同理由），contribute 五个 tool——`read` / `write` / `append` / `grep` / `glob`——让一场 pin 了它们的 nulya session 拿到 tcode 的文件与搜索体验：**零猜测的错误信息、自分页、freshness 去重与覆盖门、smart-case 搜索、per-file 上限、gitignore**。内核只改一处（§1.0），其余全在 extension 里。用户装法：`nulya ext build extensions/std --user` → `nulya ext activate --user std <v>` → user config `[registry] pinned_native_tools = ["ext:std/read", …]`（builtin 2 + std 5 = 7 ≤ `max_tools` 8，剩一格给 `/goal` 的 handoff）。

## 1. 范围

**做（按顺序；每步 `zig build test` + `zig build e2e` 全绿再进下一步；每个子项一个 commit `std-x: …`）：**

0. **std-a · 唯一的内核改动：extension `result` 是 JSON 字符串时按原文交给模型。** `src/extension/protocol.zig` `decodeResponse`：`result` 为 `.string` → `DecodedResponse.result` 就是那段字符串的字节（dupe，不再加引号、不转义）；其它 JSON 值仍 compact 成 JSON（`compact` / `handoff` 返回对象，行为不变）。改 `protocol.zig` 顶部注释与 `DecodedResponse.result` 的 doc；同文件加单测（string 结果原文、含换行与引号；对象结果仍 compact）；`tests/e2e/extension.zig` 的 `closed loop … round-trips JSON` 不受影响。DESIGN §7.3 加一句（"`result` 为字符串 = 这个 tool 的文本输出，原样进 `emit`；为对象 = 结构化数据，compact JSON"）。`nulya ext api protocol` 打的是源码，自动同步。**理由**：read 返回 2000 行文件若是 JSON 转义串，每次 read 都多付 token，且模型从转义文本抄 `old_string` 给 edit 更易错；这个渲染点只在内核里，extension 自己绕不开。
1. **std-b · 骨架 + vendor。** `extensions/std/{extension.json, src/main.zig, src/rpc.zig, src/vendor/mvzr.zig}` + `build.zig` 把 `extensions/std/src/main.zig` 挂进 `zig build test`（extension 的纯逻辑模块——glob 匹配、gitignore 规则、freshness、输出整形——值得单测；`compact` / `handoff` 没有是因为它们没有纯逻辑）+ `tests/e2e/std.zig`（新文件，注册进 `tests/e2e.zig`）一条 smoke：`ext build extensions/std` 成功、`ext run std@<v> read '{"path":"x"}'` 走到 tool（返回 not-found 教学而不是 unknown tool）。
   - `extension.json`：`id: "std"`，`runtime.entry: "bin/std"`，`contributes.tools` 五个（name / description / input schema **照 tcode 的 `description()` / `input_schema()` 改写**：去掉 vision / 图片 / redaction 相关句子；`read` 保留 `force`；`grep` 保留 context/before/after/head_limit/offset/glob/case_insensitive；`glob` 保留 follow_symlinks/offset；描述里**零文档引用**（D8））；`permissions: { fs: [".nulya/scratch"], network: [], process: [] }`。
   - `src/main.zig`：读 stdin 一条 JSON-RPC → `params.name` 分派到 `read.zig` / `write.zig` / `append.zig` / `grep.zig` / `glob.zig` 的 `run(ctx, arguments) !Outcome` → 写一条响应。未知 name → `-32601`。顶部一段 doc 说清"为什么是 compiled、为什么叫 std 但不是内核层、状态在哪"。`test { std.testing.refAllDecls(@This()); }` 或逐个 `_ = @import` 让 `zig build test` 覆盖所有模块。
   - `src/rpc.zig`：`Outcome = union(enum){ text: []const u8, failed: Fail{code,message} }`（成功 = **字符串** result，靠 std-a 原样到模型；失败 = JSON-RPC error，`ok=false` 进 usage journal）；`readRequest(alloc, io) !Request{ id, name, arguments: std.json.ObjectMap }`（stdin 上限 16 MB——`write` 的 content 可能大）；`writeResponse(...)`。从 `extensions/handoff/src/main.zig` 抽出来，别重写第二份。
   - `Ctx`（`main.zig` 或 `rpc.zig` 定义）：`alloc` / `io` / `cwd`（绝对路径，`std.process` 取）/ `env`（`std.process.Environ.Map`）/ `session_id: ?[]const u8`（`NULYA_SESSION` 的 stem，同 handoff）。
   - `src/vendor/mvzr.zig`：mnemnion/mvzr **v0.3.9** 原文（MIT，单文件；已在本机 Zig 0.16.0 下跑通其 31 个自带测试）；文件头加一行来源 + 版本 + 许可证注释；**不改它**（要改就 wrap）。
   - `nulya ext build` 的 snapshot 收 `src/**`，vendor 文件进 version hash——正确：它们就是这个版本的一部分。
2. **std-c · fs：`read` / `write` / `append` + `freshness.zig` + `text.zig`。**（可与 std-d 并行）
   - `freshness.zig`：**移植 `tcode-core/src/freshness.rs`**（`FileRecord{hash, ranges}` / `check_read → New|Unchanged|ChangedOnDisk|NewRange` / `record_read` / `uncovered_gap` / `record_write` / `record_append` / `seen_current` / `visibility → Unseen|Stale|Partial(ranges)|Full`），语义逐条对齐、单测照搬。持久化：**append-only JSONL** `.nulya/scratch/<session-id>/std-freshness.jsonl`（一行一次 `record_*` 事件 `{"op":"read|write|append","path":"<绝对路径>","hash":"<hex>","range":[a,b]|null}`；每次调用 replay 重建；文件不存在 = 空；坏行忽略）。**没有 `NULYA_SESSION` 就没有 freshness**：不去重、不设门（`ext run` 从 CLI 裸调时如此；模型经 shell 调 `nulya ext run` 时 `NULYA_SESSION` 在环境里，照样有）。路径 key = 绝对路径（相对 cwd 解析），Windows 上大小写按字节（与 tcode 同）。hash 用 `std.hash.Wyhash`（只在本文件内比较，不跨实现）。
   - `text.zig`：`rel(path, cwd)` 显示用相对路径 · `notFoundHelp(path)`（父目录存在 → 列最多 20 项、目录带 `/`、排序；父目录不存在 → 说不存在）· `numbered(lines, start)`（`{:>6}\t` 行号，只给 edit/append 回显用）· `clip(line)`（**16384 字节**、UTF-8 边界、`…[+N bytes]` 标记，与 `emit` 同形）与 `clipNote` · `hasReadMarker(s)`（`…[+` 即拒）· `dominantLineEnding` 如需要。
   - `read`：`{path, offset?, limit?, force?}`。stat 先行：不存在 → notFoundHelp；目录 → "`X` is a directory, not a file. It contains: …"（≤ 50 项）；> **10 MB** → too large（提示 grep 或 shell `sed -n`）；前 8 KB 含 NUL → binary 拒绝。offset 1-based，limit 缺省 **2000**、下限 **120**（放大小读）；offset 越界 → "`X` has N lines; offset O is past the end of the file"。freshness：`Unchanged` 且非 force → `unchanged: … has not changed since you last read it; the content is already in your context above. (force=true overrides.)`；`NewRange` → `uncovered_gap` 只回没见过的那段 + note；`ChangedOnDisk` → 头一行 note。正文**逐字、无行号**；总输出 ≤ **120 KB**（比 `emit` 的 128 KB 低，让 `emit` 永不二次截断）、至少一行；footer `[showing lines A-B of N; continue with offset=B+1]`（没读完）或 `[showing lines A-B of N]`（局部窗口，整文件不打）；clip 了行就追 clipNote；空文件 `(empty file)`。`record_read` 记**实际到达模型**的范围。
   - `write`：`{path, content}`。content 含 read marker → 拒（教学句说 marker 不是文件内容）；创建父目录；已存在文件过 visibility 门：`Full` 放行；`Partial(ranges)` → 列出已看过的行段、要求补读或用 edit/append；`Stale` → 要求重读；`Unseen` → 要求先读；写；`record_write`；返回 `wrote <rel> (N lines)`。Windows `ERROR_USER_MAPPED_FILE`(1224) 重试一次 50 ms（`write_with_windows_retry`）。
   - `append`：`{path, content}`（非空）。不存在 → 建（父目录）、`record_write`、回显编号片段 `created new file <rel> (N lines). Result:`；存在 → UTF-8 校验、`Full|Partial` 放行、`Stale|Unseen` 拒；读-改-写；`record_append((start,new_total))`；回显尾部（前 3 行上下文 + 新增行，编号）；旧文件不以换行结尾 → merge note。
   - e2e（`tests/e2e/std.zig`，用 `ext run std@<v> <tool> '<json>'`，带 `NULYA_SESSION` 环境对时对比）：read 全文 / 窗口 + footer / offset 越界 / 目录 / 不存在（含目录列表）/ 二进制拒绝 / 第二次 read → unchanged stub / 改盘后 read → note / `NewRange` 只回新行；write 新文件 / 未读覆盖被拒 / 读过后放行 / 部分读被拒并列行段 / marker 拒；append 建新 / 未读拒 / 读过后追加 + 回显 + merge note；**无 `NULYA_SESSION` 时 read 不去重、write 直接覆盖**。
3. **std-d · search：`grep` / `glob` + `walk.zig` + `vendor/ignore.zig` + `vendor/globpat.zig` + `regex.zig`。**（可与 std-c 并行）
   - `vendor/globpat.zig`：**移植 zeegrep `src/core/glob.zig`**（MIT，~200 行；`match` / `matchPath` / `classify` / `fastMatch`；`std.fs.path.sep` → 同时认 `/` 与 `\`，测试在 Windows 上要过）；**补 `{a,b}` 交替**（tcode 用 globset 支持它，模型会写 `**/*.{ts,tsx}`）；`**`、`*`、`?`、`[...]`。文件头记来源 / 版本 / 许可证 / 改动。
   - `vendor/ignore.zig`：**移植 zeegrep `src/core/ignore.zig`**（gitignore 语义：`.gitignore` / `.rgignore` / `.ignore`、否定、dir-only、锚定、外层先内层后、最后匹配胜；`std.fs.Dir` → `std.Io.Dir`）。文件头同上。
   - `walk.zig`：**单线程**递归 walker（`std.Io.Dir` iterate），参数 `{ base, follow_symlinks, allow_pruned_descend, deadline_ms }`，每个 entry 回调；跳过 **`PRUNE_DIRS`**（tcode 那张表原样，含 `.git`/`node_modules`/`target`/`zig-out`/`.zig-cache`/`AppData` 等）并计数（`PruneReport` → 末尾 note `[N pruned directories were skipped: a/ × 2, b/ — set path inside one explicitly to search it]`）；`path` 参数落在 pruned 目录里就允许下钻（`path_arg_allows_pruned_descend` 原样，含 `node_modules` 特例）；隐藏文件**搜**（`.github/` 等），只靠 prune 表与 gitignore 剪；目录符号链接默认跳过并计数；**10 s** deadline → 标 timed_out 返回部分结果。
   - `regex.zig`：mvzr 的薄 wrapper。`SizedRegex(256, 32)`（默认 64 ops / 8 sets 对模型写的交替不够）；compile 失败 → `invalid regex: … Remember this is regex syntax — escape literal ( ) [ ] { } . * + ? with a backslash.`；**smart case**：pattern 无大写字母（`case_insensitive` 也可强制）→ 大小写不敏感，实现 = 小写化 haystack 行 **并**小写化 pattern 里的**字面**字母（`\` 转义与 `\d\W\S` 等类保持原样、`[...]` 内字面字母也小写）；mvzr 按字节匹配（无 Unicode 类）——写进 grep description 一句 "byte-level regex; no lookaround/backreferences"。
   - `grep`：`{pattern, path?, glob?, case_insensitive?, context?, before?, after?, head_limit?, offset?}`。base = path 或 cwd，不存在 → 报错。文件过滤：glob（相对 base 匹配）、目录扫描时 > **512 KiB** 跳过并计数、显式单文件上限 **10 MiB**、前 8 KB 含 NUL 跳过。**输出形状照 tcode**：按 file → 首行排序；同文件一个标题 `path:`；`N: text` 匹配行 / `N- text` context 行；同文件不相邻 context 块之间 `--`；每行 **512 字节** cap + `…[+N bytes]`；`-C`/`-B`/`-A` 上限 **30**；**per-file 上限 30 匹配**（只在多文件结果时）；按**匹配数**分页 `head_limit`（缺省 **200**）/ `offset`，跨页边界的组只留窗口内的匹配与其 context（`clip_to_window`）；总输出 ≤ **100 KB**。尾注（原样）：`[more matches beyond this page — raise head_limit or set offset=N]` / `[N further matches in M files not shown — over 30 per file; re-run with path set to one of them for the rest]` / prune note / `[search timed out after 10s — partial results; narrow the path or glob]`；无匹配：`no matches for /pat/ (N files scanned, glob g)` + oversized 提示 + prune note + `[.gitignore entries are excluded]` + timeout；offset 越过末尾 → `offset=N is past the last of M matches for /pat/ — lower offset or drop it`。
   - `glob`：`{pattern, path?, follow_symlinks?, offset?}`。相对 base 匹配（无 `/` 的 pattern 只匹配 basename）；按 **mtime 降序**；上限 **200**；`[N results shown; M more — set offset=200]` 之类的分页尾注（照 tcode）；跳过的目录符号链接计数 note；prune note；timeout。
   - 单测（模块内）：globpat（含 `{}`、`**`、Windows 分隔符）、ignore（否定 / dir-only / 锚定 / 嵌套优先级）、regex smart-case 改写（`\D` 不被小写破坏）、grep 的 `clip_to_window` 与 per-file 上限、walk 的 prune 计数。e2e：造一棵小树（含 `.gitignore`、`node_modules/`、大文件、二进制、CRLF 文件）→ grep 命中 / smart case / glob 过滤 / context 输出形状 / per-file 上限 note / 分页 offset / 无匹配 note / gitignore 生效 / 显式 path 进 pruned 目录 / 无效 regex 教学；glob 排序与分页 / follow_symlinks 缺省跳过。
4. **std-e · 收尾。** `docs/goals/std.md` §6 进度；DESIGN §7.3（std-a 已加）+ §11 附近或 §7 末尾一段"随仓库带的 extension"清单里加 `std`（**不是**内核层：默认不在任何 composition 里、只经 pin 进模型工具面、状态只有 `.nulya/scratch/<sid>/std-freshness.jsonl` 一个磁盘制品）；CLAUDE.md「现状一句话」加一条 + `tests/e2e.zig` 头注释加一段；PLAN §3.4.1 那句"nulya 没有 std tool 层"后补半句（"`extensions/std` 是这句话的例证：叫 std、是 extension、靠 pin"）；`extensions/guide/skills/guide/SKILL.md` 的 Building 一节加一行指路（可选，≤ 2 行）。**真实跑一次**（有 provider key 时）：`session new --with std@<v> --pin ext:std/read --pin ext:std/grep --pin ext:std/write --pin ext:std/append --pin ext:std/glob`，让模型在本仓库做一个小改动（如"在 docs/base-tools.md 里找到 MIN_READ_WINDOW 的说明并把 120 改成 120（不改）——先 grep 再 read 再 edit"），把它用了哪些 tool、read 去重有没有命中、有没有撞门贴进 §6；跑不了写明原因。

**不做（明确越界）：** 改 kernel `edit`（tcode 的 CRLF / 归一化回退 / `target_line` / 候选上下文 / 回显片段是**另一条 track**，base-tools.md 已列为 later hardening）；改 `shell`（`run_in_background` / `output_mode` / filters 已被 base-tools.md 砍）；后台任务（`kill_task` / `monitor`）、`web_fetch` / `web_search`、`skill` tool（已有 `nulya skill load`）、`agent` / `progress` / `ask_user` / `show` / `view_image`；redaction（`redact.rs`——base-tools.md §4 明说 read 不耦合它）；图片读入（ledger 无 image 内容块）；多线程 walker（10 s deadline 兜底，先测量）；给内核加任何 std 专属的东西（除 std-a）；自动 build / activate / pin std（安装是用户的决定）；把 std 塞进 `nulya src` 内嵌；改 `max_tools` 缺省；TUI；push。

**可选 stretch（核心全绿之后才碰）：** 无。

## 2. 完成标准（可机器验证；全部满足才算完成）

- `zig build test` 与 `zig build e2e` 在 **Windows（本机）** 全绿；代码不得 Windows-only（`std.Io.Dir` API、路径分隔符两种都认、CRLF 文件读写正确）。
- `extensions/std` 两次 `ext build` 同一 version；`ext list` 标 `[tools]`。
- 五个 tool 的 e2e 覆盖 §1.2 / §1.3 列出的每一条行为（名字可微调，语义不可少）；既有 e2e 全部继续通过（断言不减弱）。
- 每个 std tool 的单次输出 ≤ 120 KB（read）/ ≤ 100 KB（grep），`emit` 的 spill 对它们**永不触发**（e2e 里 read 一个 200 KB 文件，结果无 `[full output:` footer、有 `continue with offset=`）。
- 所有 model-facing 文本（五个 description、input schema description、错误信息）不含 `DESIGN` / `PLAN` / `tcode` 字样。
- 文档：DESIGN §7.3 与 §7 末尾 / CLAUDE.md 现状 / PLAN §3.4.1 / `tests/e2e.zig` 头注释与代码一致。
- **手动**：§6 里有一份真实 session 记录（或写明为何跑不了）。
- 每个子项一个或多个 commit，信息格式 `std-a: …` … `docs: …`；在本 worktree 分支上；**不 push**。

## 3. 已定决策（不要重开；如认为错了，写进 §6 BLOCKED 并停下）

- **D1 · 一个 compiled extension、一个二进制、五个 tool。** 理由同 `compact` / `handoff`：要读 JSON-RPC、两种 dialect 一个 version。id 叫 `std` 只是名字：它**不是**内核层，默认不在任何 composition 里，只经 pin 进模型工具面（PLAN §3.4.1 那句话仍然成立）。
- **D2 · 内核只改 std-a 一处**（string result 原文）。它不是 physics，但这个渲染点只在内核里、extension 绕不开，而不改的代价每次 read 都付。**别的内核文件一字不动**——需要动就是 BLOCKED。
- **D3 · grep/glob 纯 Zig，不依赖 rg。** regex = vendored mvzr（0.16 兼容、单文件、MIT，本机验证过）；gitignore + glob 匹配 = 移植 zeegrep 的两个 core 模块（MIT）；walker 自己写。不 vendor 整个 zeegrep（它依赖 PCRE2）。mvzr 的限制（字节级、无 lookaround / backreference / 大小写 flag）用 wrapper 补 smart-case、用 description 说清其余。
- **D4 · freshness 落盘、按 session 隔离、无 session 就无门。** DESIGN §7.6 允许的 tool 间共享只有磁盘制品；`.nulya/scratch/<sid>/` 是 kernel 已经按 session 隔离的目录（emit 的 spill 就在那）。fork / handoff 后是新 sid → 新文件，语义正好（新 context 里什么都还没读过）。**已知代价**：内核 `edit` 不登记 freshness，edit 后再 write / append **同一文件**会被门拦一次要求重读；tcode 的 edit 会登记而这里不能——接受，e2e 里写一条断言把这个行为钉住（别人改了要看得见）。
- **D5 · 输出预算自守，`emit` 只是保险。** read ≤ 120 KB、grep ≤ 100 KB、行 clip 16384 字节同 `emit`——不是重复实现 emit，是让 tool 的 footer（`continue with offset=`）永远在、不被 emit 的头尾截断吃掉。
- **D6 · 错误 = JSON-RPC error（`ok=false`）**，message 就是 tcode 那句教学文案；不用 "ok=true 的字符串报错"——usage journal 的 `ok` 要如实。模型看到的形状是 `extension error [-32000]: <文案>`，前缀是内核加的，接受。参数缺失 / 类型错 `-32602`，其余 `-32000`。
- **D7 · 照抄 tcode，砍明说的三样**（vision / redaction / 后台任务）；每个数字与文案的出处写在代码注释里（`// tcode fs/read.rs`），日后对表方便。**不引入 tcode 没有的行为**（"我觉得更好"留到 §6 记一笔，不做）。
- **D8 · model-facing 文本零文档引用**（同 M2c / guide）：description、schema description、错误信息不出现 `DESIGN` / `PLAN` / `tcode` / 文件名引用。
- **D9 · 单元测试进 `zig build test`。** `build.zig` 给 `extensions/std/src/main.zig` 加一个 `addTest`（与 `src/main.zig` 的 test 同一个 `test` step）；`nulya ext build` 编译时 `zig build-exe` 忽略 test 块，version hash 不受影响。

## 4. 参考（先读这些，再动手）

- **规格书（tcode，本机 `C:/code/rust/tcode/crates/`）**：`tcode-tools/src/fs/{mod.rs, read.rs, write.rs, append.rs}`（数字与文案全在这四个文件；`edit.rs` 只看它怎么用 freshness，别移植它）、`tcode-tools/src/search.rs`（grep / glob 全部：PRUNE_DIRS、常量、`clip_to_window`、per-file cap、分页、所有 note 文案）、`tcode-core/src/freshness.rs`（整文件移植 + 测试）、`tcode-tools/AGENTS.md`（"read / grep 的返回内容"一节的三条硬规则）。`shell.rs` / `web.rs` / `redact.rs` / `monitor.rs` **不读**——不在范围。
- **nulya 侧形状**：`extensions/handoff/src/main.zig`（JSON-RPC 读写、`Outcome`、`NULYA_SESSION` → session id、`std.process.Init` / `std.Io` 用法——**rpc.zig 从它抽**）、`extensions/compact/src/main.zig`（`runNulya` 子进程、`readFileMaybe`）、`src/tools/edit.zig`（内核 edit 的教学式拒绝口吻与 `teach()`）、`src/emit.zig`（行 clip 的实现与标记形状；std 的 clip 要同形）、`src/tools/shell.zig` + `src/environment.zig`（Zig 0.16 `std.Io.Dir` / `std.Io.File` 读写用法）、`src/extension/protocol.zig`（std-a 改这里）、`src/extension/manifest.zig`（manifest 校验：tool 名不能是 shell/edit、`timeout_ms` 上限）。
- **测试形状**：`tests/e2e/extension.zig` 的 `bundled handoff …` 两条（`buildBundled` / `runCliEnvs` 带 `NULYA_SESSION`）、`tests/e2e/support.zig`（`stageBundled` compile-once cache、`runCli*`、`testHome`）；`tests/e2e.zig` 的注册方式。
- **vendor 来源**：mvzr `https://github.com/mnemnion/mvzr` v0.3.9 `src/mvzr.zig`（MIT）；zeegrep `https://github.com/piranha/zeegrep` `src/core/{glob.zig, ignore.zig}`（MIT）。抓取后**先在本机 `zig 0.16.0 test <file>` 跑一遍**（本机 `zig` 是版本管理器 shim，要显式 `zig 0.16.0 …`；mvzr 已验证 31/31）。
- DESIGN §7.2.1（manifest）、§7.3（wire）、§7.6（tool 上下文：只有 args + 净化 env + cwd；`NULYA_EXE` / `NULYA_SESSION`）、§9（authority：extension ⊆ shell）；base-tools.md §2–§3（数字与 emit）。
- 本仓库 `nulya` 不在 PATH 上：`./zig-out/bin/nulya.exe`（`zig build` 后）；e2e 用 `NULYA_EXE` / `NULYA_TEST_ZIG` / `NULYA_REPO`（build.zig 注入）。

## 5. 工作方式与分工

- 分支：本 worktree（`claude/nulya-std-extension-plan-43a976`）。std-a / std-b 先落（串行，它们定接口）；**std-c 与 std-d 并行**（各自 worktree，只碰自己那些文件：c = `read.zig write.zig append.zig freshness.zig text.zig` + `tests/e2e/std.zig` 里自己的 test 块；d = `grep.zig glob.zig walk.zig regex.zig vendor/globpat.zig vendor/ignore.zig` + 自己的 test 块；`main.zig` / `rpc.zig` / `extension.json` 由 std-b 定死，c/d **不改**——要改就是 BLOCKED）；合并后 std-e。
- 每个子项完成：`zig build test` + `zig build e2e` 全绿 → commit → §6 记一行（commit hash + 一句话 + 有无偏离）。
- 代码注释英文，docs 中文，description / 错误文案英文；测试与模块同文件；`zig fmt`。
- 卡住 / 需要改内核 / 发现契约自相矛盾 → §6 写 `BLOCKED: …`，停下等人，不要绕。

## 6. 进度区（执行时更新）

（空）
