# `plan` — 计划模式

一个包，把「先调查、再计划、什么都不改，最后交人审阅」这件事说完整：
一段 system prompt（这一场是干什么的）、一条收窄的 `policy`（戴着它的时候能做什么）、
一条 `/plan` 命令（怎么戴上）、三个 tool，以及一段前端代码（`tui/plan.ts`）。
内核只强制其中一样（`activation: "on_request"`，DESIGN §7.2.1），其余全是**声明**——
读它的 driver 有权不信。

## 三个 tool

| tool | 给谁 | 做什么 |
|---|---|---|
| `propose{plan_md}` | 模型 | 把想好的计划**整篇**作为参数记下来，然后收尾。**不写盘、不 fork、不阻塞**——计划本身进 ledger，那就是唯一那份记录。 |
| `todo{items}` | 模型 | 当前的清单（`ui: {render: "checklist", panel: true}`）。同样不写盘，调用本身就是记录。 |
| `approve{session, plan_md}` | driver（`audience: "driver"`） | 把**已被批准**的计划渲染成 `.nulya/handoffs/<session>-<n>.md`（与 `extensions/handoff` 逐字节同形），返回路径。 |

## 装它

```bash
nulya ext build extensions/plan --user      # 编译型包，第一次需要 zig 0.16
nulya ext activate --user plan <version>
```

不在 nulya 的 checkout 里也一样：源码随二进制走（DESIGN §7.8），`nulya ext seed --user plan`
把它写进 user store 再 build。TUI 里这两步是 `/ext` 上那一行的 `Enter`；开屏那趟后台
sync 本来也会把它 activate（`on_request` 的包 activate 只是登记，不改变任何一场 session）。

`activation: "on_request"` 的意思是 **activate 只是登记**：它一场 session 都不改变，
只进点名它的那一场。戴上一场：

- TUI：`/plan`（这个包自己声明的命令）或 `/with plan`；
- 命令行：`nulya session new --with plan --pin ext:plan/propose --pin ext:plan/todo`。

**它是只读的，所以它需要读的工具。** `policy: {readonly: true}` 会在 gate 上先于一切表
拒掉 `shell`，以及每一个没有自称 `readonly: true` 的 tool。只戴 `plan` 而不带别的，
模型就只能凭已有的上下文说话。实际用法是与 `extensions/std` 一起：它的 `read` /
`grep` / `glob` 正是声明了 `readonly: true` 的那三个。

## 装了插件之后

- `propose` 的调用在 transcript 里由这个包自己画：参数还在流式到达时就一行行显示；
- 一次 `propose` 结束，**评审面板自己打开**（输入框上方，transcript 仍然看得见）：
  `j/k` 移动 · `u/d` 翻页 · `v` 起选区 · `c` 对当前行/选区写评论 · `r` 把全部评论
  作为**一条** user turn 送回去 · `a` 批准 · `Esc` 收起（`/plan-review` 重开）；
- `a` = `approve` 写出 brief → `/compact` 的 `brief_file` 分支 fork。
  **执行场不戴这个包**：`session new --parent` 不带 `--with`，所以计划过去了、persona 没过去。

## 没有插件时（降级）

**全部功能仍在，只是少了键盘快捷方式。**

- 计划在 ledger 里，就在 `propose` 那张卡的参数上——读得到；
- 评论就是**直接打字**：把意见写成一条普通消息发过去，模型照样改了再 `propose`；
- 清单靠声明层：`ui.render: "checklist"` 画成 `[x] 3/5` 的卡，`ui.panel: true` 让最新一次
  调用常驻在输入框上面；
- 批准 = `nulya ext run plan approve --arg session=<id> --arg plan_md=<计划>`，
  再 `nulya ext run compact --arg session=<id> --arg brief_file=<那个文件>`。

`tui.toml` 的 `[extensions] plugins = false` 把代码层整个关掉，得到的就是上面这一档。
