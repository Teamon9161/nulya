# compact

`compact` 是 continuation driver：它把旧 session 压缩成 continuation brief，并创建一个带 parent 指针的新 session。旧 ledger 不复制、不改写。

TUI plugin 只是便利层。它注册 `/compact [focus]`，识别实时且成功的 `handoff` call，显示 follow/dismiss 面板，并渲染 compact request 与 context summary。plugin 不可用或被关闭时，这些 turn 和 tool call 仍是普通、可读、可重放的 ledger 内容；headless driver 也仍可直接调用 internal `compact` tool。

compact 完成后，TUI 打开 child 的新 tab，parent tab 保留。child 的 summary 留在 inbox；plugin 不自动 step，只有用户随后明确发送内容时才开始继续。
