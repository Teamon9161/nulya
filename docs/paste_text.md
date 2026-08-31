议修的 P1
roposal>()
现在 handoff 从单个 proposal 改成了：个场景其实是同一个问题：
这是对的。ound)
const pending = new Map<string, Phandoff 在后台 tab 到达。后台跑，而你当前正在看 B：
但 Map 解决了“不覆盖”，没有完全解决“怎么重新把它呈现给用户”。if (api.observe.session()?.id === session)        ↓
acceptResults() 现在：  panel.open()current = BA != current任何东西会再次调用 panel.open()。
具体有两           ↓它。
pending.set(key, f也就是说，如果 A session 正在A model → handoff不 panel.open()所以 proposal 没丢，Map 里还在，但 UI 上再也没有入口 follow sion = B
           ↓你当前的新测试没有真正覆盖这个情况。sal 没有互相覆盖。
pending[A] 存下来了之后你切回 A。B proposal看到。
   测试是：→ panel 本来就还开着但没有证明：A 的 handoff 会变成“内存里存在，但 UI 不可达”。
问题是：这个现实中挺容易出现：ntProposal() 是从 Map 中拿这个 session 最后的非 done proposal：
A proposal切回 Apanel 已经关闭时，后台 session 新来 proposal，之后切回去还能同一 session 多个 proposal 也有类似问题.values()) {
切 tab 本身没有→ panel 已经打开→ panel 也一直没关A 正在跑for (const proposal of pending  if (proposal.session === session && proposal.state !== "done")sal
↓curre    found = propo} = currentProposal()
切 bench.ses所以它证明了：你切去 B 看东西  proposal.state = "done" 已经关了。
↓假设：}ng    ← 永久躺着
A/B propoA 完成并 handoff然后同样没有机制把 panel 为 A1 重新打开。A2 done入复杂的“proposal queue UI”。
↓A1 pending只 dismiss A2。有效的待处理 handoff；新的成功 handoff supersede 旧的。
你切回 AA2 pending所以现在实际上可能得到：而用户什么都看不到。handoff 这个概念更合理的语义可能就是：于 assistant/result correlation
A1 仍然：也就是：) → Proposal
现在 panel 显示 A2。Map:这个我建议先把语义拍简单一个 session 最多有一个pending:ff
pendingA1 pendicalls:session → Proposal这样同场根本不存在 A1/A2 的 UI 队列问题：↓actionable。
此时 Esc：我反而不建议为了它引(session, call) → 用pending[A] = A2session change，例如以后 API 增长一个：
但 panel而不是：A1 handoff但跨 session 仍然需要解决重新 surface 的问题。> {
onClose() {↓新的 proposal 是模型对“现在应该怎么继续”的更新，旧 proposal 没必要还保持 observe.onSession(...)  if (currentProposal()) panel.open()以先采取更小的方案：至少对后台到达的 handoff 发一个 persistent/可恢复入口，而不是仅仅存在 Map 
  const proposalpending:pending[A] = A1最干净的是让 plugin 能感知 front })里。
(session, call然后 compact：现在这个 invariant 还没有成立。
A2 hando不过如果你不想为了一个 consumer 立刻扩 API，也可关键 invariant 是：
onSession(() =一个小的 race，我暂时不列 P1如果这时用户再 Esc，host 一定关闭 panel，并调用 onClose()。ning proposal 标成 done，但已经启动的 extRun() 不会被取消，所以它之后还是可能成功创建 child、op
pending handoffenTab(child)。
⇒ 用户一定存在某条路径重新看到 / follow / dismissEnter 之后：compact 的 onClose() 会把当前 run打开
也就是说：是 cancel operation。
pending → running我觉得这个可以接受，前提是语义明确成：去做 extRun cancellation 状态机。
