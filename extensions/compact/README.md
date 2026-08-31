# compact

`compact` 是 continuation driver：它把旧 session 压缩成 continuation brief，并创建一个带 parent 指针的新 session。旧 ledger 不复制、不改写。

TUI plugin 只是便利层。它注册 `/compact [focus]`，识别实时且成功的 `handoff` call，显示 follow/dismiss 面板，并渲染 compact request 与 context summary。plugin 不可用或被关闭时，这些 turn 和 tool call 仍是普通、可读、可重放的 ledger 内容；headless driver 也仍可直接调用 internal `compact` tool。

compact 完成后，TUI 打开 child 的新 tab，parent tab 保留。由 handoff 触发的 continuation 会安全排干 child inbox 并继续；手工 `/compact` 仍只创建并打开 child。`ask` 模式显示 follow/dismiss 面板，`unsafe` 模式自动 follow。完整 handoff 参数由 handoff 包自己的可重放卡片展示。
