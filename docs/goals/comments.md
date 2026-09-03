# 注释与文档的密度（契约）

**状态**：2026-09-01 立并执行完第一轮。

## 1. 起因

一次实测：

| | 立契约时 |
|---|---|
| `src/**.zig` | 39,984 行，整行注释 9,572 行（24% 的行、**35% 的字节**，≈166k tokens） |
| 代码里的文档指针 | `DESIGN §x` 430 处、`goals/*.md` 83 处、`BUGS #N` 8 处 |
| `tui/**.ts` | 656 行引用实施日志编号（`T39` 这类）、307 行引用 `DESIGN §x` |
| 最长模块头 | `remote/protocol.zig` 167 行、`agent/runner.zig` 98 行 |
| `CLAUDE.md` | 185 KB ≈ 62k tokens，每次开场都付；其中 82% 是「现状一句话」那一节 |
| `docs/tui.md` | 737 KB，其中 §11 实施日志 587 KB |

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
- **文档指针**：`DESIGN §x` / `PLAN §x` / `BUGS #N` / `goals/*.md` / `tui.md`，以及实施日志编号 `T<n>`

### 代码不引用文档，文档引用代码

文档会漂，而代码的读者更多（`nulya src` 的读者根本打不开 docs）。方向是单向的：DESIGN.md 可以写 "见 `ledger.zig` 的 `depositEvent`"，`ledger.zig` 不写 "DESIGN §3.4"。

一条注释如果**离开那个 §x 就不成立**，说明它想说的事实还没写出来——把事实写进去，指针删掉。

### 模块头 ≤ 15 行，例外是契约模块

说"这个模块是什么、有哪些不变量"，不说"为什么这样设计"。

例外写成**原则而不是文件白名单**：**一个模块的头如果就是被打印出去、由读它的人照着实现的规格，它可以更长，但只写规格、不写规格的辩护。** 今天符合的有四个——`extension/protocol.zig`（`nulya ext api protocol`）、`environment/remote/protocol.zig`（`nulya src`，远端 agent 作者照它实现帧协议）、`extensions/agent/src/external.zig`（`agent_runner` 契约，第三方接一个新 harness 照它实现）、`src/lease.zig`（全系统的锁与顺序表，下一个加锁的人照它加一行）。

### 一条规则只说一次

在它定义的地方说。同一句话在四个相邻字段上各写一遍（`ledger.zig` 的"只在非空时写、老行逐字节相同"）应该收成一条；在两个函数里各写一遍说明该抽出一个有名字的东西。

### 设计论证归 commit message 与 `docs/goals/`

那是说服评审者的话，有它的位置，不在源文件里。

## 3. 目标（可检查的三条）

第一轮之后把原来那个"注释占比 ≤ 15%"的目标**删掉了**——它是在不知道内容的情况下拍的。实测：清完 430 处指针、176 处论辩、85 处考古与四份重复之后，注释字节降了 21%（36% → 31%），而抽查 `ledger.zig`、`extension/target.zig` 的第二轮显示剩下的是锁序、崩溃安全、wire 形状和 OS 陷阱——删它们就是删正确性。**这个内核的注释密度高不是文风问题**，一条带着谁也够不到的数字的规则只会烂掉。

换成三条：

1. **文档指针 → 0**（机械强制，见 §4）
2. **模块头 ≤ 15 行**，例外只有上面那条原则下的契约模块
3. **无论辩 / 无考古 / 无重复**（靠 review 与本文件）

## 4. 机械守卫

两条，都已落地：

- `zig build test` 里 `src/source.zig` 的 `shipped source carries no documentation pointers`：扫 `nulya src` 与 `ext seed` 打印的**全部**嵌入源码（`src/**` + `extensions/**` 的 `.zig`，跳过 vendored）。needle 列表用 `++` 拼开，所以守卫**覆盖它自己的文件**、不留豁免口——它第一次运行就抓到了写在它自己注释里的那个 `DESIGN §8.1`。
- `bun test` 里 `tui/test/docpointers.test.ts`：同一件事，扫 `tui/**.ts(x)` 的**注释行**（只扫注释，所以一个叫 `T2` 的泛型参数不会被误判）。

## 5. 第一轮的结果

| | before | after |
|---|---|---|
| `src/` + `extensions/` 注释字节 | 977,676 | 774,075（−21%） |
| 代码里的文档指针 | 521 | **0** |
| `CLAUDE.md` | 185,816 B | 17,747 B（−90%） |
| `docs/tui.md` | 737,450 B | 154,856 B（−79%） |
| `docs/DESIGN.md` | 348,421 B | 见 commit |

`CLAUDE.md` 与 `docs/tui.md` 的编年史**一字未删地归档**在 `docs/history/`（`2026-08-changelog.md`、`tui-implementation-log.md`）——那是搬家不是删除。

顺带买到的：压缩逼着有人从头读一遍 `docs/tui.md` §1–§10，**查出 37 处它与现实的矛盾**（`session rebind` 在文档里根本不存在、`/compact` 后父 tab 保留、`permissions` 三档取代了已被拒的 `readonly:`、600 s 天花板整条已不成立……）。`CLAUDE.md` 那边同样修掉三处（ledger 写着 4 种事件而实际 6 种、subagent 标着未实现、remote Phase 2–4 标着没做）。

## 6. 不做的事

- **不删测试。** 只动注释与文档。
- **不改代码语义。** 第一轮只有三处有意的代码改动：落地守卫、一个测试名字里的指针、`ext init` 脚手架模板里那个会写进**每一个新建扩展**的指针。
- **不为了压行数而删掉真的不变量。** 尺子是"下一个读者不知道这件事会不会写错代码"——会，就留下。
