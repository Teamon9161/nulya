# `ask` — 模型半路问人

一个 tool：`ask{question, options?, free_text?}`。模型把一个**会改变它下一步**的问题
提出来然后收尾；答案作为下一条 user turn 到达。

**它不阻塞、不等待、不轮询。** 一个会等人读完的 tool，等于把一个 step 进程押在人的
阅读速度上（而 extension 的天花板是 600 s，`tool.Timeouts.extension_max_ms`），
并且会让没人看着的 driver 直接挂死。所以这里的形状与 `extensions/handoff` 一样：
立刻返回「记下了，收尾吧」。对话是 append-only 的，答案作为下一轮到达只付一次增量。

## 装它

```bash
nulya ext build extensions/ask --user       # 编译型包，第一次需要 zig 0.16
nulya ext activate --user ask <version>
```

不在 nulya 的 checkout 里也一样：源码随二进制走（DESIGN §7.8），`nulya ext seed --user ask`
把它写进 user store 再 build。TUI 里这两步是 `/ext` 上那一行的 `Enter`——它会 activate
并把 `ask` 写进 `[extensions] with`，这一个键就是「模型可以问我了」。

**它想常驻，和隔壁 `extensions/plan` 相反**——但这不是 manifest 说得出的话：
「进不进每一场」是人的决定（config 的 `[extensions] with`，DESIGN §5.1）。理由值得写下来：
`plan` 是模式，戴上它是在说**这一场**是什么（人格、只读立场），而那是人在开工前做的决定。
**没有人能预先决定"待会儿会有一个问题"**——模型是在任务中间才发现的，所以一个只在被预先
指定的 session 里才存在的提问包，等于一个永远不会触发的包。所以把 `ask` 写进
`[extensions] with`，这个 tool 的 `surface: "with"` 会让它随显式成员进模型工具面——占不占
`max_tools` 槽仍由这台机器把不把 `ask` 列为成员决定，一个键收回。

只想给某一场用、不想常驻占槽：

- TUI：`/ask`（这个包自己声明的命令）或 `/with ask`——`--with` 带的那一场会连它的 tool
  一起放上工具面（tui.md §11 T46）；
- 命令行：`nulya session new --with ask`。

## 装了插件之后

一次 `ask` 调用结束，输入框上面出现一个面板：问题 + 一行一个选项。
`↑↓` / `j` `k` 移动 · `1`-`9` 直接落到某一行 · `Enter` 作答 · `t`（或选中
「something else」那一行）改成自己打字 · `Esc` 收起（`/ask-review` 重开）。
答案经 `session append` 落进 ledger，卡片折回原话并带上 `ask · answer` 的 badge。

## 没有插件时（降级）

**问题就在 transcript 的那张 tool 卡里，人照常打字回答，效果完全等价。**
这正是这个包被选作第二个 consumer 的理由：它是一个便利，不是一个通道——
插件加载失败、API 版本对不上、包没被 activate，对话一样进行得下去。

`tui.toml` 的 `[extensions] plugins = false` 把代码层整个关掉，得到的就是这一档。
