# 注释与文档的密度（契约）

**状态**：2026-09-01 立，执行中。

## 1. 起因

一次实测：

| | 立契约时 |
|---|---|
| `src/**.zig` | 39,984 行，整行注释 9,572 行（24% 的行、**35% 的字节**，≈166k tokens） |
| 代码里的文档指针 | `DESIGN §x` 430 处、`goals/*.md` 83 处、`BUGS #N` 8 处 |
| 最长模块头 | `remote/protocol.zig` 167 行、`agent/runner.zig` 98 行 |
| `CLAUDE.md` | 185 KB ≈ 62k tokens，每次开场都付；其中 82% 是「现状一句话」那一节 |

`nulya src` 把整个 `src/**` 打进二进制，正是为了让 AI 零漂移地读内核——而它三分之一的字节是散文。**这条产品面自己在为文风买单。**

而 `DESIGN §8.1` 对 `nulya src` 的读者是**悬空指针**：花了 token，指向一个它打不开的地方。

## 2. 规则

### 注释只写代码说不出来的东西

**写**
- 不变量与顺序（"必须先 X 后 Y，否则 Z"）
- 非显然的取舍（"不用 Set 因为要保序"）
- 外部约束（"Windows 的 `CreateProcessW` 无 handle allowlist，会继承全部句柄"）
- 格式契约（wire 形状、落盘 schema、协议帧）

**不写**
- 复述代码在干什么
- 为什么没写成另一种样子（论辩、自我辩护、"这半句是承重的"）
- 某段代码曾经是什么样（"it used to be…"、"no longer"、"BUGS #16 就是这条"）
- **文档指针**：`DESIGN §x` / `PLAN §x` / `BUGS #N` / `goals/*.md` / `tui.md`

### 代码不引用文档，文档引用代码

文档会漂，而代码的读者更多（`nulya src` 的读者根本打不开 docs）。方向是单向的：DESIGN.md 可以写 "见 `ledger.zig` 的 `depositEvent`"，`ledger.zig` 不写 "DESIGN §3.4"。

一条注释如果**离开那个 §x 就不成立**，说明它想说的事实还没写出来——把事实写进去，指针删掉。

### 模块头 ≤ 15 行

说"这个模块是什么、有哪些不变量"，不说"为什么这样设计"。

唯一例外是**真·契约模块**——`extension/protocol.zig`、`environment/remote/protocol.zig`——它们的模块头就是被 `nulya src` / `ext api` 打印出去的规格，规格本身是产品。即便如此也只写规格，不写它的辩护。

### 一条规则只说一次

在它定义的地方说。同一句话在四个相邻字段上各写一遍（`ledger.zig` 的 "只在非空时写、老行逐字节相同"）应该收成一条；在两个函数里各写一遍（`cli/session.zig` 的 "under the lease, waiting is a moment in which…"）说明该抽出一个有名字的东西。

### 设计论证归 commit message 与 `docs/goals/`

那是说服评审者的话，有它的位置，不在源文件里。

## 3. 目标

- `src/` + `extensions/` 注释字节占比 **35% → ≤ 15%**
- 代码里的 `DESIGN §` / `PLAN §` / `BUGS #` / `goals/` / `tui.md` 指针 → **0**
- 模块头 > 15 行的文件 → 只剩两个 protocol 模块

## 4. 机械守卫

`zig build test` 里一条 grep：`src/**` 与 `extensions/**` 出现文档指针即失败（`build.zig` 的 `doc-pointer` 步骤）。这是唯一能自动执行的一条；其余靠 review 和本文件。

## 5. 不做的事

- **不删测试。** 这次只动注释与文档。
- **不改代码语义。** 一个字节的行为改动都不算在这轮里。
- **不为了压行数而删掉真的不变量。** 尺子是"下一个读者不知道这件事会不会写错代码"——会，就留下。
