# compact

`compact` 是 continuation driver：它把旧 session 压缩成 continuation brief，并创建一个带 parent 指针的新 session。旧 ledger 不复制、不改写。

TUI plugin 只是便利层。它注册 `/compact [focus]`，识别实时且成功的 `handoff` call，显示 follow/dismiss 面板，并渲染 compact request 与 context summary。plugin 不可用或被关闭时，这些 turn 和 tool call 仍是普通、可读、可重放的 ledger 内容；headless driver 也仍可直接调用 internal `compact` tool。

compact 完成后，TUI 打开 child 的新 tab，parent tab 保留。手工 `/compact`、handoff follow 和其它 continuation consumer 都通过 `openTab(..., {wakePending:true})` 建立 driver attachment：child inbox 有 summary 才继续，空 inbox 绝不裸 step。`ask` 模式显示 follow/dismiss 面板，`unsafe` 模式在当前 tab 确实是 driver 时自动 follow；同一 session 的 writer role 改变会重新裁决。Enter 已提交 follow 后，Esc 只隐藏进度、不取消 continuation，隐藏期间失败会重新显示 retry。完整 handoff 参数由 handoff 包自己的可重放卡片展示。
