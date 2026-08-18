# Goal · vision：内核 image 输入支持（ledger → 投影 → 壳层门 → 三 provider 序列化）

> 这是一份**执行契约**，不是设计文档。现状在 [DESIGN.md](../DESIGN.md) §3（ledger 事件与 durable 文件）/ §5.1（pin）/ §7.5（composition 冻结）/ §9（authority 与 trust gate——"门在壳层"的先例）/ §11（fork / compact）/ §13（provider）/ §14（CLI 命令表）；physics 在 [CLAUDE.md](../../CLAUDE.md)。
> 与 [tui-panel.md](tui-panel.md) 的"内核零改动"**相反，这是一个内核 track**：它改 `src/` 的 ledger 事件形状、PromptIR、provider 序列化与 CLI 面。铁律照常生效：**改了内核语义，同一个 commit 更新 DESIGN.md 对应节**——每个里程碑的完成标准里都含这一条。
> physics 定位一句话：本 track 动的全部是 **substrate**（事件形状 / 纯投影 / wire 序列化——把"用户给了一张图"这个事实存住、投影出去、序列化对）；"哪个模型看得懂图"的判断经 `[[models]]` 目录 + 壳层门表达，**kernel 核心（ledger / prompt / provider / loop）不知道门存在**（与 §9 trust gate 同一先例）；"什么时候给模型看图"是 driver / 用户的事，不进内核。
> 本文件的决策来自 2026-08-18 的设计对话（记录在 §3），已定的不要重开；认为错了写进 §6 BLOCKED 并停下，不要自行改方向。

## 0. 目标（一句话）

让一场 nulya session 的 **user turn** 能携带 png / jpeg 图片：base64 内联进 ledger 的 `user_text` 事件（D1）→ PromptIR 原样投影 → `session append --image <path>` 是唯一入口、壳层按 header 冻结的 `model_identity` 查 `[[models]]` 目录的 `vision` 标注设门（D2/D3）→ anthropic / openai / codex 三个 provider 各按自己的 wire 形状序列化（D5）；fork 语义一字不动（D4）。v1 只做 user 输入，不做 vision 输出、不做 blob store、不做 TUI 粘贴（§5）。

## 1. 内核事实（设计必须绕着走的，都已存在、写代码前先核对）

1. **`user_text` 今天是裸字符串，不是 struct**：`ledger.Event` 的变体是 `user_text: []const u8`（`ledger.zig:71`），落盘形状 `{"seq":n,"kind":"user_text","text":"…"}`。加 `images` 意味着变体要改成 struct（照 `assistant` 变体的样子），**全仓库每个 `.user_text = "…"` 构造点跟着动**（providers / prompt / loop / cli / tests，机械但量大）。wire 层有现成先例：`WireEvent` 的可选列（`usage: ?Usage = null`，`ledger.zig:717`）**只在有值时写**，老行读回 null、形状逐字节不变——`images` 照抄这套纪律。
2. **老读者静默跳过新列**：`json_opts` 是 `ignore_unknown_fields = true`（`ledger.zig:419`），旧 nulya 二进制读到带 `images` 的行**不报错、只是看不见图**（会把 turn 当纯文本投影）。这是既有语义，不是本 track 引入的；诚实记录即可，不为它造版本门（header `v` 仍是 1——多出的列不改变已有列的含义，DESIGN §3.4）。
3. **`session append` 经 inbox，不写主文件**：`sessionAppend`（`cli/session.zig:426`）把 user turn 用 `ledger.depositEvent` 投进 `<id>.inbox/`（`cli/session.zig:468`），inbox body 就是 `encodeEventBody`——所以 V1 改了事件编解码，**图片走 inbox 这条路零额外机制**（原子投递、exactly-once、mid-run append 全部白得）。注意 `--file` 今天有 8 MB 读取上限（`cli/session.zig:438`，`readFileAlloc .limited(8 << 20)`）；图片按 D6 上限 5 MB（base64 后 ~6.8 MB）单独读，别复用这条限制的语义。
4. **PromptIR 是纯投影，turns 借 ledger 字符串**（`prompt.zig`：`Turn.user_text` 也是裸字符串，`prompt.zig:49`）。"不投影"的字段（`usage` / `stop_reason` / `spill_path` / `origin`）靠**类型里没有字段**来保证——图片与它们相反，**是 model-visible 的**，所以 `Turn` 必须长出对应字段，`isStablePrefix`（`prompt.zig:176`）要把它纳入比较。
5. **`model_identity` 创建时单处解析、冻结进 header**：`launch.resolveDescriptor`（`launch.zig:218`）是唯一一次 credential-aware 模型解析，resume 只重解 credential（DESIGN §3.4）。门（D3）查的就是这个冻结身份的 `model` 字段。**一个要当心的事实**：scripted 身份今天是 `.{ .provider = "scripted" }`，`model` 为空串（`launch.zig:226`）——离线 e2e 要让门"放行"，就必须让冻结身份能对上一条目录条目（见 V3 的落点说明）。
6. **`[[models]]` 目录纯描述、kernel 不读**：`config.ModelParams`（`config.zig:74–88`：`label` / `efforts` / `default_effort` / `context_window`），按 id 跨 trusted 层合并（`upsertModel`），`config show [--json]` 投影它（`cli/config.zig`）。`vision` 加进来就是又一个描述字段，维持"kernel 不读"——读它的是**壳层**（`cli/session.zig` 的 append 路径），与 `context_window` 只被 TUI 读同理。
7. **门在壳层的先例**：trust gate 住在 `launch.ensureWorkspaceStoreTrusted`（`launch.zig:435`）+ `cli/session.zig`，`composition.zig` / `session.zig` / 库路径 `AgentSession.init` 都不知道它存在（DESIGN §9）。vision 门照这个形状放：校验与拒绝在 `cli/session.zig` 的 `sessionAppend`，kernel 核心零感知；绕过门（比如库调用直接 `append`）的后果是 provider 的 400 原样浮出——诚实。
8. **`session events` 今天是 raw tail，明文承诺"不解析、不重编码"**：`EventTail`（`cli/session.zig:713` 起）的头注释写着 "the file IS the wire format"，DESIGN §14 同句；`session step --stream` 的 ledger 行与它同形（同一个 `encodeEventLine`）。D1 要求 events 打印时省略 base64——这**触碰**这条已声明的性质，V1 必须有意识地处理（只对带 `images` 的 `user_text` 行做替换重编码、其余行照旧原样；`seq` 保留，所以 `extensions/compact` 靠 events 找 tail seq 的用法不受影响），并把 DESIGN §14 那句改准。`--stream` 的 ledger 行**不**省略（它是 driver 面，要与文件同形；前端自己折叠）。
9. **三个 provider 的 user turn 序列化现状**（D5 的落点要对得上）：
   - **anthropic**（`providers/anthropic.zig`）：user 内容本来就是 content **块数组**（`writeMessage` → `writeTextBlock`，`anthropic.zig:299`），image source block 顺着塞即可。**当心 cache breakpoint 的计数**：`cacheableBlocks`（`anthropic.zig:371`）与 `writeMessage` 的实际写块数**必须同步**——一个 user turn 从"恒 1 块"变成"1 + N 块"，两个函数一起改，否则移动断点落错块（image block 可以带 `cache_control`，计入即可）。
   - **openai**（`providers/openai.zig`）：user message 的 `content` 今天是**纯字符串**（`writeRoleContentMessage`，`openai.zig:202,226`）。带图时要变成 parts 数组（`{type:"text"}` + `{type:"image_url","image_url":{"url":"data:<mt>;base64,<data>"}}`）；**不带图的 turn 保持纯字符串形状逐字节不变**（implicit prefix cache 的稳定性、也与"老行形状不变"同一纪律）。
   - **codex**（`providers/codex.zig`）：user turn 本来就是 parts 数组（`writeMessageItem` 写 `input_text` part，`codex.zig:365,400`），加 `input_image` part（data URI）即可。
   - **wire.zig** 目前没有任何 user 内容的共享件。data URI 拼接（`data:<media_type>;base64,<data>`）openai 与 codex 都要——**两个 consumer**，可以落 `providers/wire.zig`（D5）；anthropic 的 source block 是它独有的形状，留在自己文件里。
10. **fork 本来就不复制历史**：`session new --parent` 只记 lineage、子 ledger 从零开始，跨 fork 的载体是 compact 的 brief（DESIGN §11）。所以"图片不跨 fork"**不是特例、不需要任何代码**（D4）；完整回放走 resume（`openDurable` 同一文件），那里图片随事件自然回放。

## 2. 范围（按序 V1 → V4；每步 `zig build test` + `zig build e2e` 全绿、DESIGN.md 同 commit 更新，再进下一步）

### V1 · ledger schema：`user_text` 长出 `images`，events 打印省略 base64

- `Event.user_text` 改为 struct：`{ text: []const u8, images: []const Image = &.{} }`，`Image = { media_type: []const u8, data: []const u8 }`（`data` 是 base64 文本；命名照 ledger 现有平铺风格，D1 允许微调）。ledger 只存不校验（存事实）：media_type / 尺寸的门在壳层（V3），文件里已有的怪值照读。deep-copy 走既有 arena，无新生命周期。
- wire：`encodeEventBody` **只在 `images` 非空时写**该列（老行形状逐字节不变——`usage` 先例）；`WireEvent` 加 `images: ?[]const WireImage = null`，`toEvent` 把 null 映成空 slice。inbox body 同一套编解码，自动覆盖（内核事实 #3）。
- `session events`：带 `images` 的 `user_text` 行打印时把每个 `data` 替换为占位（形如 `[image image/png, N bytes]`，N = base64 前的原始字节数或 base64 长度——挑一个、文案说清），**其余行照旧 raw**；`seq` 与其它列原样。改 `EventTail` 头注释与 DESIGN §14 那句"不解析、不重编码"（内核事实 #8）。`--stream` 不动。
- 全仓库 `.user_text` 构造点机械迁移（内核事实 #1）。
- **完成标准**：`zig build test` 绿；新单测覆盖——带图事件 round-trip（encode → parse → toEvent 逐字节）、老形状行读回 `images` 为空、`depositEvent`/`drainInbox` 带图 exactly-once、不带图的新写行与旧写行逐字节相同、events 打印替换（带图行有占位无 base64、别的行原样）；DESIGN §3.1 / §3.4（事件表与示例 JSONL）+ §14（events 那句）同 commit 更新。

### V2 · PromptIR 投影

- `prompt.Turn.user_text` 同样变 struct（text + images，全部借 ledger 字符串——不复制，与现状同一纪律）；`projectWithSystem` 传递；`isStablePrefix` 比较图片（media_type + data 指针/内容，照现有字符串比较的写法）。
- **完成标准**：`zig build test` 绿；单测——投影携带图片、含图 turn 的前缀稳定性（append 新 turn 后旧前缀 `isStablePrefix` 成立）、`usage`/`stop_reason` 照旧无字段（类型级不投影不回退）；DESIGN §3 相关句（"replay 时模型看到的一切 = header + events 的纯函数"不变，只需事件表已在 V1 更新）核对无漂移。

### V3 · `session append --image <path>` + 壳层门 + `[[models]].vision`

- `config.ModelParams` 加 `vision: bool = false`（+ `RawModelParams` / `mergeModelFields`）；`config show` 文本形态与 `--json` 都投影它（TUI / 选择器与门用**同一份**判断，D2）。
- CLI：`session append <id> [text|--file f] [--image <path>]…`（`--image` 可重复，与文本合成**同一条** `user_text` 事件投 inbox）。usage 常量（`cli/common.zig`）与 DESIGN §14 命令表同步。
- 类型与尺寸门（D6）：按魔数 sniff（png `\x89PNG` / jpeg `\xFF\xD8\xFF`；扩展名不作数——文件内容才是事实），其余类型拒绝并列出支持的两种；单张原始字节 > 5 MB 拒绝，错误文案带实际大小与上限。拒绝走 stderr + exit 1，stdout 保持空（§14 输出纪律）。
- vision 门（D3）：`readHeader` 拿冻结的 `model_identity.model` → 加载合并 config → `[[models]]` 按 id 查 → `vision == true` 放行；**没有条目 = 不主张 = 拒绝**（显式 opt-in，不猜），文案指路 config 键（`[[models]] id = "…" vision = true`）与 `nulya config show`。门只在 `--image` 出现时才查（纯文本 append 一字不变）。kernel 核心零感知（内核事实 #7）。
- **需要定的一处落点**（执行时定，不是重开决策）：scripted 身份的 `model` 是空串（内核事实 #5），离线 e2e 的"门放行"需要冻结身份对得上目录条目。最小落点是 `resolveDescriptor` 的 scripted 分支把 chosen model id 一并冻结（`launch.zig:226` 一行，壳层文件、语义只是"记下当时选的 id"）；若嫌它动了 scripted 身份的含义，备选是 e2e 直接写一条 id 为空串的 `[[models]]` 条目。选哪个、为什么，记进 §6。
- **完成标准**：`zig build test` + `zig build e2e` 绿；e2e（scripted，`tests/e2e/` 新文件或并进 `session.zig`）——① 门拒绝：目录无条目 / `vision=false` 时 `--image` exit 1、文案含 config 键、inbox 无投递、纯文本 append 照常；② 门放行：目录标 `vision=true` → append → step → ledger 行携带 `images`；③ resume 回放：`openDurable` 重开后投影 turn 级相等、图片在场；④ events 占位（V1 的断言在真 session 文件上再钉一次）；⑤ 类型 / 尺寸拒绝各一条。DESIGN §14（append 签名）+ §9.5（config 链的目录描述）同 commit 更新。

### V4 · 三 provider 序列化 + integration

- 按内核事实 #9 落点：anthropic image source block（base64，`cacheableBlocks` 同步计数）；openai 带图 turn 变 parts 数组、不带图逐字节不变；codex `input_image`；scripted 忽略图片（照旧只看文本）。data URI 拼接落 `providers/wire.zig`（两个 consumer，D5）。
- **完成标准**：`zig build test` 绿；每个 provider 单测——带图 turn 的 request body 含期望形状（照各文件现有的 body 断言写法）、**不带图的 body 与改动前逐字节相同**（三个都断言，缓存前缀不回归）、anthropic 断点仍落最后一块（含图时）；integration（`zig build integration`，DESIGN §13.2）加 codex 一条：小图 append → step → 回复提及图片内容，无 `NULYA_INTEGRATION_PROFILE` 即 skip；anthropic 口的对应条**写好等 first-party key**（仓库已有"第三条已写好等 key"的先例）；deepseek 不支持 vision，不测。DESIGN §13（provider 各节）同 commit 更新；CLAUDE.md「现状一句话」加一条。

## 3. 已定决策（不要重开；认为错了写 §6 BLOCKED 停下）

- **D1 · 存储：base64 内联进 ledger。** `user_text` 事件加可选 `images: [{media_type, data}]`（命名可按 ledger 现有风格微调），老行读回空（`usage?` 先例）。**不搞 blob 旁库**：一文件一 generation、resume 只靠 ledger，这两条不变量比行大小值钱；"一张截图几百 KB 一行"的代价已明确接受。`session events` 打印省略 base64、呈现占位——**ledger 存事实，投影选择呈现**。
- **D2 · 能力标注：`[[models]]` 加 `vision = true`（bool）。** 不抽 `input=[...]` 数组——第二种 modality 出现之前不抽象。目录维持"纯描述、kernel 不读"；`config show --json` 投影它，TUI / 选择器与门用同一份判断。
- **D3 · 门在壳层**（trust gate 同一先例，DESIGN §9）：`session append --image` 是唯一入口，壳层按 header 冻结的 `model_identity` 查目录：没标 `vision` → 拒绝 + 指路 config 键 + exit 1；无条目 = 不主张 = 同样拒绝。内核核心（ledger / prompt / provider）不知道门存在；绕过则 provider 的 400 原样浮出——诚实。
- **D4 · fork 语义不变，图片与文本同等待遇。** `--parent` 本来就不复制任何原始 history（DESIGN §11），"图片不跨 fork"不是特例。完整回放的路径是 resume。compact 时模型认为某图重要 → brief 留落盘路径、子 session 由 driver 再 `append --image`——那是 policy，不进内核。
- **D5 · 三个 provider 的序列化**：anthropic = image source block（base64）；openai chat/completions = `image_url` data URI；codex responses = `input_image`。scripted 忽略。共享件只在确有两个以上 consumer 时落 `providers/wire.zig`（data URI 拼接够格；source block 不够）。
- **D6 · 类型与尺寸门在壳层**：v1 只认 png / jpeg（魔数 sniff）；单张上限 5 MB（anthropic 的 per-image 限制），超了在 `session append --image` 拒绝，文案说清楚。
- **integration 事实**：deepseek 不支持 vision → 联网实测口只有 codex（responses 端点支持 `input_image`）；anthropic 口写好等 first-party key（既有先例）；scripted 供离线 e2e（断言投影与门，不需要真模型）。

## 4. 参考（先读这些，再动手）

- `src/ledger.zig` —— `Event`（:70）/ `encodeEventBody`（:634）/ `WireEvent`（:706）/ `toEvent`（:749）/ `depositEvent`（:818）/ `Header.model_identity`（:389）/ `json_opts`（:419）。`usage` 那一列从声明到落盘到读回的每一处，就是 `images` 要照抄的形状。
- `src/prompt.zig` —— `Turn`（:48）/ `projectWithSystem`（:127）/ `isStablePrefix`（:176）。
- `src/cli/session.zig` —— `sessionAppend`（:426）/ `EventTail`（:713）；stdout / stderr 纪律见文件头与 DESIGN §14。
- `src/launch.zig` —— `resolveDescriptor`（:218，scripted 分支 :226）/ `ensureWorkspaceStoreTrusted`（:435，门在壳层的参照物）。
- `src/config.zig` —— `ModelParams`（:74）/ `upsertModel` / `mergeModelFields`；`src/cli/config.zig` 的两种投影形态。
- `src/providers/anthropic.zig` —— `writeMessage`（:284）与 `cacheableBlocks`（:371）这对必须同步的函数；`src/providers/openai.zig` `writeRoleContentMessage`（:226）；`src/providers/codex.zig` `writeMessageItem`（:400）；`src/providers/wire.zig`（共享件的家）。
- `tests/e2e/session.zig` / `tests/e2e/support.zig` —— e2e 夹具与 scripted provider 用法；`tests/integration.zig`（`zig build integration` 的现有几条，DESIGN §13.2）。
- DESIGN §3.1 / §3.4 / §9 / §11 / §13 / §14；CLAUDE.md 八条 physics。

## 5. 不做（明确越界）

- TUI 图片粘贴（tui-panel.md 内核事实 #7：那是本 track 落地后的 TUI 后续里程碑，不在这里）；
- vision 输出（模型生成图片）；
- 多 modality 抽象（`input=[...]` 之类——第二种 modality 出现之前不抽）；
- blob store / 旁库 / 去重；
- `@` 引用注入图片（tui-panel.md D5 同理）；
- assistant / tool_results 里的图片（v1 只做 user turn 输入）；
- png / jpeg 之外的类型、图片压缩 / 缩放（超限就拒，不替用户改图）；
- `--stream` 行协议的 base64 省略（driver 面要与文件同形，前端自己折叠）；
- 自动判断"该不该带图"（那是 driver / 用户的判断，不进内核）。

## 6. 进度区（执行时更新）

- **V1 done**（`zig build test` + `zig build e2e` 绿）。`ledger.Image{media_type,data}` + `ledger.UserText{text,images=&.{}}`，`Event.user_text` 变 struct；`cloneImages` 走既有 arena。wire：`encodeEventBody` 只在 `images` 非空时写该列，`WireEvent.images: ?[]const Image = null`（**微调**：契约写的是新造一个 `WireImage`，实际直接复用 `Image`——它两个字段名就是 JSON 键名，与契约自己援引的 `usage: ?Usage` 先例完全同形，多一个类型只会多一次手抄），`toEvent` 把 null 映成空 slice。`session events` 只对带 `images` 的 `user_text` 行重编码（`cli/session.zig` 的 `redactImages`：先按 `"images"` 子串廉价拒绝，再解析；解析不了 / 不是 user_text / 图数为 0 一律回落原样打印），占位选 **base64 长度**并在文案里说明（`[image image/png, 16 base64 bytes]`），`seq` 与 `origin` 保留。全仓库 `.user_text = "…"` 机械迁移（`prompt.Turn` 本步仍是裸字符串，V2 才动）。新单测 2 条（ledger：带图行 round-trip + 纯文本行逐字节等于旧形状 + 老行读回空；inbox 带图 exactly-once + resume 回放）+ 1 条（cli：events 占位、文件未被改动、"images" 字样的诱饵行原样）；`expectEventsEqual` 补图片比较。DESIGN §3.1（事件表 + 新增一段 `user_text.images`）/ §3.4（示例 JSONL + 括号注）/ §14（`events` 那句"不解析、不重编码"改准）同 commit。
- **V2 done**（`zig build test` + `zig build e2e` 绿）。`prompt.Turn.user_text` 变 `Turn.UserText{text, images}`，`images` 是 **`[]const ledger.Image` 原样借过来**——与 `ToolCall` / `ToolResult` 各有其类型的理由相反：那两个是收窄（丢 `spill_path`）或改写（torn args → `{}`），图片一个字都不改，于是不需要第三个类型、也不需要 `call_storage` 那样的 per-projection 存储。`turnsEqual` 比 media_type + data（内容比较，不是指针）；`projectWithSystem` 传递。三个 provider 的 `.user_text, .capability_note => |text|` 合并 prong 拆开（本步仍只写文本，V4 才序列化图片），`launch.hasCarriedBrief` 同。e2e `support.flattenIR` 多打一行 `I|<media_type>|<data>`——只差图片的两次投影因此**不**算 turn 级相等（V3 的 resume 断言要靠它）。新单测 1 条（投影带图 + 借的是 ledger 的指针 + 含图 turn 上 append 后前缀仍稳 + 换图 / 去图都不再是前缀）。DESIGN §1（turn 四种的字段表 + 为什么 images 没有自己的类型）同 commit；§3 的"replay = header + events 的纯函数"未受影响，逐句核对无漂移。
- **V3 done**（`zig build test` + `zig build e2e` 绿，e2e 49 → 52）。`config.ModelParams.vision: bool = false`（+ `RawModelParams` / `mergeModelFields`），`config show` 文本形态只在 true 时打一个 `vision`（"没写 = 没主张"与门的读法一致），`--json` 因为直接投影 `[]ModelParams` 自动带上。`session append` 重写参数解析（`--file` / `--image` 各取下一个参数，`--image` 可重复，第一个剩下的位置参数是文本；只给图不给文本 = 空文本 turn），三道门都在投递之前：`visionAccepted`（读 header 冻结的 `model_identity.model` → `config.load` → `[[models]]` 查 id → `vision` 才放行；无条目与 `vision=false` 两条不同文案，都指路 user config 的真实路径 + `nulya config show`）、`loadImage` 的魔数 sniff（png `\x89PNG` / jpeg `\xFF\xD8\xFF`）与 5 MB 上限（先 stat 后读，文案带实际字节数与上限）。kernel 核心零改动。
  - **V3 落点（契约留给执行者的那处）**：选了**最小的那个**——`resolveDescriptor` 的 `.scripted` **profile kind** 分支把 chosen id 一并冻结（`.{ .provider = "scripted", .model = chosen }`，一行）。理由：门要问"这场 session 是什么模型"，而 scripted 身份把这个事实丢了；备选（e2e 写一条 id 为空串的目录条目）等于让离线测试依赖一个空 id 的特例条目，那条目对真实用户没有意义、也会让"没有条目 = 拒绝"这条语义在测试里被一个哑条目绕过。**只动 profile kind 是 scripted 的分支**：credential 缺失时的两条 fallback 仍返回裸 scripted 身份——那里"用户点名的 id"恰恰是**没有**发生的事，把它冻进 header 会让一个没 key 的 openai session 通过 vision 门。
  - e2e 新文件 `tests/e2e/vision.zig` 三条（全走 scripted，49 → 52）：① 门拒绝（无条目 / 有条目但不主张，两次都 exit 1 + stdout 空 + inbox 0 个文件 + 文案含 `[[models]]` / `vision = true` / `nulya config show`；纯文本 append 照常进 inbox；`config show` 两种形态都投影这个主张）；② 放行全程（一次 append 两张图 + 文本 = **一条**事件 → step → 文件里有两个 media_type 与真 base64 → `openDurable` 重开投影 `flattenIR` 里图片在场 → `session events` 有占位、无 base64、seq 与文本原样、assistant 行原样）；③ 类型与尺寸与不存在的路径各一条（`.png` 后缀的 GIF 被魔数拆穿、5 MB + 1 报实际大小与上限、`nope.png`），三次 inbox 都是 0。`nulya help` 的 append 行改成两行并加 `--image`，`tests/e2e/cli.zig` 的"一屏"预算 40 → 42（唯一一次为真能力放宽，注释写明）。DESIGN §14（命令表 append 签名 + 一条讲三道门的新 bullet）/ §9.5（`models[]` 字段表 + 两张表那段）同 commit。
