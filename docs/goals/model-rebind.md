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
唯一真相收在 `ledger.effectiveIdentity`，调用点：`session step` 的 handle 构造与 effort 解析、
vision gate、`session list --json` 的投影、TUI 的模型 chip。

## 8. 不做的

- 不做兼容性白名单（§2）；
- 不做「回头路保留 reasoning」的特例（§3）；
- 不改 header schema（§4）；
- 不让 rebind 变成一个 model-visible 的 turn——模型不需要读自己被换了，
  就像它不读自己的 `stop_reason`。
