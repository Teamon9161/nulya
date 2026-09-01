# model rebind：一场 session 中途换模型

BUGS.md #12：「就算冻结了也要允许换模型，可以提醒一下。」

今天 `model_identity` 在 `session new` 时由 `resolveDescriptor` 一次解析、冻进 header，
`session step` 没有任何 model flag，resume 只重解 credential——「跑的 == 冻结的」。
这条契约说的是：**怎么在不放弃那句保证的前提下，允许换。**

## 1. 为什么不是「换 = 开新场」

`session new --parent` 不复制 history（fork 的语义就是不带），所以「换个模型接着刚才的对话」
今天没有原语。compact 那条路带的是摘要，不是逐字历史——那是压缩，不是换模型。

## 2. 为什么不按 provider 设门

`provider` 在 nulya 里说的是 **wire 形状**（openai 兼容口 / anthropic Messages / codex responses），
不是模型的出身：

- OpenRouter 是一个 `openai` profile，里面同时供 anthropic、google、deepseek 的模型
  ——「只允许同 provider」在它身上什么都拦不住；
- 反过来 anthropic profile 里 opus → sonnet 是同 provider，thinking block 带签名，
  跨模型回放本来也没有保证。

按 provider 名字设的门是一道**假门**：拦不住真正危险的，又拦掉合理的。
而且「哪些模型互相兼容」是判断不是事实，判断不进内核（physics #8）。

## 3. 真正危险的只有一样：`reasoning`

`ledger.Event.assistant.reasoning` 是 provider 不透明的原样回放（DESIGN §13），
它的正确性前提写在 `ledger.zig` 的注释里：**「model-locked by construction——
session 的 `model_identity` 是冻结的，所以别的东西永远看不到它」**。
换模型正是打破这个前提的那件事。

所以规则不是「拦住不兼容的切换」，而是**让切换之后一定可回放**：

> **rebind 之前、由别的 (provider, model) 产生的 reasoning item，不回放。**

投影里做（`prompt.zig`），与 `max_tokens` 那条 torn-args 规则同一个位置、同一个理由：
ledger 存事实（那一轮确实有 reasoning），投影只交出**可以合法回放的东西**。
A → B → A 这种回头路不做特例：只有最后一次 rebind 之后的 turn 保留 reasoning，
简单、说得清、永远安全。

## 4. 它是一条 append 的事实，不是 header 的改写

physics #1（ledger 只能 append）与 #3（model-visible 状态只经 append 改变）：
header 不可改写，所以身份改变长成**第五种 ledger 事件** `model_rebind`。

- 事件里冻的是**已解析的 `ModelDescriptor` + profile 名**，与 header 里那一列同形同哲学
  （谁 rebind 谁解析，credential-aware；跑的仍然 == 冻结的，只是冻结点多了一个）；
- **有效身份 = 最后一条 `model_rebind`，没有就是 header 的**（`ledger.effectiveIdentity` 一处定义）；
- 它**不是一个 turn**：模型面上什么都不多出来（投影不给它 Turn），它只改变
  「哪些 reasoning 还能回放」。

## 5. 投递走 inbox，不是第二个写者

今天只有 `session step` 写 session 文件（`append` 投 inbox、`cancel` 写标记、`events` 只读）。
rebind 是**跨进程的事实**，与 `capability_note` / `task_finished` 同一个 genre，
所以 `nulya session rebind` 投 inbox，由 `prepareStep` 在 step 边界排干（exactly-once 靠既有的 `origin`）。
好处是正在跑的 session 也能被 rebind（下一步生效），而单写者语义一个字都不用改。

排干之后内核发现有效身份变了 → 通过 `Options.rebind` 回调（`composition.ExecTargetProbe` 的先例：
内核决定**什么时候**要，壳层知道**怎么造**）换掉 `AgentSession.model`。
resume 走同一条路：壳层按 header 造一个 handle，内核开场发现 ledger 里已有 rebind → 同一个回调重造。
一条规则，两个入口。

## 6. 三道门（都是事实，不是判断）

在 `nulya session rebind` 那一侧、投递**之前**（与 §9 trust gate、vision gate 同一先例：
门在壳层，内核核心不知道它们存在）：

1. **凭据**：新 descriptor 解析不到 credential → 拒绝并指路（与 `session new` 的 `MissingCredential` 对称）；
2. **vision**：ledger 里已经有图片，而新模型的 `[[models]]` 目录没有主张 `vision = true` → 拒绝并点名
   （没有条目 = 不主张 = 拒绝，与 `session append --image` 同一把尺子）；
3. **step 边界**：由 inbox 排干天然保证，不需要额外机制。

「该不该换成这个模型」不设门——那是人的判断。TUI 那侧说两句代价：
前缀缓存作废（换 provider 是全额重付一次 input）、历史 reasoning 不再回放。

## 7. 波及面：读「这一场跑在什么模型上」的每一处

加了第二个冻结点之后，`header.model_identity` 就不再是这个问题的答案。

**committed identity ≠ next-step identity**——两个时刻，两处唯一实现，都在内核：

| 谁问 | 什么时刻 | 答案 |
|---|---|---|
| `session step` 的 handle 构造与 effort 解析、`session list --json` | step **里面**（写者，事实都已 committed） | `ledger.effectiveIdentity(header, events)` |
| `session append --image` 与 `session rebind` 的门、`session new --parent` 继承什么、TUI | step **外面**（读者，与写者并发） | `ledger.scanSession`（header → committed → **pending inbox**） |

外面那一栏为什么必须多看一眼 inbox：一条投递了还没排干的 `model_rebind` 与已经 append 的那条一样是定了的事，
下一个 step 边界就会应用它。只看 committed 的读者会用一个**马上要离开**的模型作判断——
于是 pending 的目标模型不支持图片时 `--image` 照放行、
反悔的第二次 rebind 被答成「已经在这个模型上了」而 pending 的那个照样生效。
`scanSession` 顺便一次读出「这一场有没有图片」（同一份字节，同一条 crash-tail 规则），
且**不开 ledger**——`openDurable` 要拿写者租约，而这些门每一个都必须在 step 跑着的时候能工作。

**相等只有一处判据 `ledger.identityEqual`：整个 `Identity`，profile 也在内。**
descriptor 说的是「哪个模型、走哪条 wire」，profile 说的是「用谁的凭据够得着它」，
所以只差 profile 的两个身份是**两种被回答的方式**（`kernel` 侧的 `applyRebind` 同样按它决定要不要重建 handle）。
比得少了，一次真的切换会被读成 no-op——而 no-op 是静默的。

**投递 id 必须是新的**（`ledger.freshDeliveryName`）：inbox 的文件名就是 exactly-once 键，
固定名字会让第一次之后的每一次 rebind 都被当成同一件事、在下一次排干时被删掉而永远到不了 ledger。

## 8. 一轮外部 review 的四条（2026-09-01）

三条真 bug，一条过度承诺。前两条是同一件事的两半：**gate 读到的东西必须是权威的**。

1. **两道 vision 门之间的 TOCTOU。** `--image` 与 `rebind` 守的是同一条规则的两侧，
   而两条命令都是「读状态 → 判断 → 投递」。同时跑，两边都读到旧状态、都放行，
   落地的正是它们要拒的那一对（图片 + 看不见图片的模型），下一个 step 边界照单全收。
   修法**不是**把判断挪到 drain 之后（那时 rebind 已 committed，拒绝只剩「这一场从此走不动」），
   而是让检查与投递成为一次动作：两条命令在 `<id>.inbox/.deposit.lock` 上排他串行
   （`cli/session.zig` 的 `depositLease`）。写者只有这两个，串起来这条规则就闭合了；
   锁在 inbox 里而不是 `<id>.lock` 上——后者是 step 的租约，而每道门都必须在 step 跑着时能工作。

2. **`scanSession` 自己有一个交接窗口。** 它先读 ledger 后读 inbox，
   而 drain 搬事件的动作是「先 append 进 ledger，再删文件」——于是一条比这次扫描还早就定下的
   rebind 可以在两处都不在（读完文件之后才 commit、列目录之前就被删），
   `scanSession` 于是答出一个已经作废的模型，正好毒化它服务的每一个读者。
   修法是**换读的顺序**：先 inbox 后 ledger，凡扫描开始前已定下的事实两趟必有一趟看得见。
   代价是次序（ledger 里那条可能比 inbox 里等着的更旧），
   所以**只有 inbox 一条 rebind 都没有时才采信 committed 的那条**；图片只增不减，两趟都往上加。
   （不做「再读一段 suffix 直到 tail 稳定」：那要多一次读、循环没有终止保证，
   而换顺序把窗口从代码里**去掉**而不是再补一层。）

3. **inbox 收得下的必须读得回。** `--image` 允许单图 5 MiB（base64 后 ≈ 6.67 MiB）且可重复，
   而 `drainInbox` / `scanSession` 只读 4 MiB —— `session append` exit 0 收下一条 durable 事实，
   然后**每一个** step 边界都排干失败。修法是把它变成一条有名字的不变量
   `ledger.max_inbox_event_bytes`（32 MiB），**守在唯一的写入点**（`depositEvent` 拒绝并让 CLI 说清楚），
   两个读点用同一个数。「拒绝一条命令」与「收下一条走不动的事实」不是同一量级的失败。

4. **`freshDeliveryName` 的 ordering 承诺是假的**（注释说 “ordering after every name minted before it”）。
   lexical 序先看 prefix，所以 `msg-` 与 `rebind-` 之间根本不按投递时间排；
   同 prefix 下时钟可以回拨、可以重复，重复时决定顺序的是随机 nonce。
   **契约收成「每次都不同」**（名字就是 exactly-once 键，这才是承重的那一句），
   顺序如实写成「只有时钟那么好，且没有东西依赖它」；
   断言 `first < second` 的那条测试随之删掉——它钉的是时钟粒度，不是机制。

## 9. 第二轮 review 的三条（2026-09-01）

上一轮的修法本身被查出两个洞，外加一条一直都在的：

1. **`scanSession` 的 inbox-first 只修好了一半。** 「inbox 一条 rebind 都没有才采信 committed 的」
   这条规则在**两条 pending** 时会翻车：inbox 那一趟是一个文件一个文件读的，
   并发的 drain 可以在两次读之间把更晚的 R2 commit 掉并删除，
   于是扫描手里攥着 R1、更晚的 R2 哪儿都没看见，而 ledger 又被整个闭嘴 → 答 B，真相是 C。
   **裁决靠投递 id 本身**：ledger 里若把这条 pending 记成了 `origin`，
   说明 drain 已经走过，ledger 最后那条才是更新的真相。
   于是规则从「有 pending 就闭嘴」收成「**pending 且它还没被 committed** 才赢」——
   顺带把「崩在 append 与 delete 之间的残余文件」也白拿地答对了。
   （不采用「ledger → inbox → ledger suffix」：那条路对称地会错——
   inbox 看到 C 还等着、而 suffix 只读到刚被 commit 的更旧的 B，就会答 B。）

2. **删掉假的 ordering contract，不等于代码不再依赖 ordering。** 上一轮把注释改诚实了，
   但 `drainInbox` 仍按文件名排序、rebind 仍是最后一条赢、消息仍按这个次序合成一个 turn——
   两条**顺序执行**的 `session rebind`（都拿了 deposit lease，人的意图明明白白是 B then C）
   在时钟回拨或同刻时可以被应用成 C then B。所以选了「**名字就是队列位置**」这一侧：
   `freshDeliveryName` 铸名时读一眼 inbox、跨过同前缀的最新戳。
   作用域正好是顺序有含义的那个集合（同时在等的那些）；已 committed 的不需要，
   因为「等着的排在后面」是另一条独立成立的规则。
   不把顺序另开一条通道的理由：那要第二份 durable 状态，
   而一个每次排干就清空的目录上的计数器会重用编号——重用的名字正是静默的「同一件事再说一遍」。

3. **`discardIfUntouched` 与正在进行的投递赛跑。** 前端在 `.nulya/sessions/` 里 unlink，
   判据靠**探测**锁（有没有 lock 文件、读不读得到第 0 字节）——而两条禁止删除的事实都是锁，
   **锁只能靠拿来回答，不能靠看**：探测恰好在最要紧的那一刻猜错，
   即另一个进程正卡在它自己的 check 与 deposit 之间（text-only 的 `append` 更是连锁都不拿）。
   结果是 session 文件没了、inbox 里躺着一条 rebind、而那条命令报了成功。
   修法是把这个动作收进 CLI：**`nulya session discard <id>`**（§14），
   全程持写者租约与 deposit lease（后者 non-blocking——「有人正在投递」是答案不是队列），
   exit 0 只有一个含义。相应地 `session append` **一律**拿 deposit lease，
   两条投递命令都在拿到锁之后再确认一次 session 文件还在。
   前端那一大坨跨平台的「我猜现在能不能删」随之删除。

## 10. 第三轮 review 的两条（2026-09-01）

1. **deposit lease 沉进 ledger，成为 inbox 的并发原语（P1）。** 上一轮把锁放对了层
   （CLI 拿锁，而不是前端猜锁），但那把锁仍是 `cli/session.zig` 的私有约定，
   而 inbox 的投递者不止 `append` / `rebind` 两个：`extension/notes.zig` 的
   `capability_note` 与 `cli/task.zig` 的 `task_finished` 都直接 `depositEvent`。
   于是窗口仍在——`discard` 拿两把租约、看见 inbox 里没有 `*.json`、删掉 session，
   而一个 supervisor 正卡在自己的 `write .tmp` 与 `rename` 之间，
   最后留下一条没有 session 的 durable 事实。而且这不是纯理论：
   compact 的顺序是 create child → retarget → append summary，
   中间那一段 child 还是 header-only，却已经是未来 `task_finished` 的合法目标。

   修法按 review 的建议：**锁跟 `depositEvent` 放在一起**。
   `ledger.acquireDepositLease` / `depositLockPath` / `DepositWait` 移进 `ledger.zig`，
   **缺省的 `depositEvent` 自己拿锁**（新投递者不必*记得*遵守），
   已经握着锁跨越「先读后投」的两条命令走 `depositEventLeased`（重复拿会自己死锁自己）。
   配套的另一半是**在锁下重新确认 session 还在**（`NoSuchSession`，一个字节都不写）：
   锁让 `discard` 的检查与删除成为一次动作，这个确认让删掉之后才到达的投递不留下孤儿事实。
   `task retarget` 的 `moveDeposit` 是 `task_finished` 进 inbox 的另一条路，守同一条规则
   （目标场的租约 + 同一次确认）。锁顺序写在 `acquireDepositLease` 的文档里：
   没有任何地方先拿写者租约再拿它（`step` 从不投递），
   唯一同时握两把的 `discard` 先拿它、写者租约用 non-blocking。

2. **delivery id 的契约措辞与 128 位 nonce（P3）。** `freshDeliveryName` 只扫当前 inbox、
   不扫历史 origin，所以「distinct on every call」对**已排干**的名字是抗碰撞而不是证明。
   两条都做了：nonce 从 32 位提到 128 位（风险落到可以忽略），
   文档改成如实说出作用域——按构造成立的是「这个 inbox 里」，
   对排干过的名字靠的是随机尾巴。要数学意义上的唯一得引入 durable sequence，
   而「活得过排干的状态」正是这里刻意没有的东西（同 §9.2 的理由）。

## 11. 不做的

- 不做兼容性白名单（§2）；
- 不做「回头路保留 reasoning」的特例（§3）；
- 不改 header schema（§4）；
- 不让 rebind 变成一个 model-visible 的 turn——模型不需要读自己被换了，
  就像它不读自己的 `stop_reason`。
