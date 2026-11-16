# 人设可观测性审计

事实底座：WSLg 4000x1440、真实 Intel 核显、Firefox 160/Linux、机房 IP、4c8t、266 字体家族。

## 逐问结论

| 问 | 判定 | 依据 |
|---|---|---|
| 1. screen 3200x1152 + dpr 1.25 | 比不动 DPR 更糟 | 反推物理屏 4000x1440，无此市售面板（最接近的真货是 5120x1440@125%→4096x1152）。125% 缩放在 Windows 常见、Linux 少见；DPR=1 是 Linux 主流默认，熵最低，且不引入与 availWidth/窗口尺寸的失配风险。 |
| 2. 19 个纯开源家族 | 不合理 | 主流发行版标配 Liberation（Arial/Times 的 metric 替身，fontconfig 别名常使 Arial 探测报"存在"），纯 Linux 却无 Liberation 属异常；家族数 19 本身是高辨识度离群值。不子集（266）更接近真实开发机形态，更自然。 |
| 3. 仅差 tz/核数/DPR/字体 | 作用≈0 | 跨账号关联靠高熵稳定信号：WebGL/GPU 串、canvas 哈希、音频、JA3/JA4、UA、IP 段——全部相同。tz 与核数是低熵、可人为设置的维度，几乎无区分力。 |
| 4. 强制 4 线程 | 会矛盾 | 并行 Worker 计时可推出真实 ~8 线程，与 navigator 报值失配即"检测到伪装"；且同 GPU/canvas 下 8/8/4 无真实 SKU 支撑。 |
| 5. 最保守人设 | 见下清单 | — |

## 保守清单

- 一律保持默认：hardwareConcurrency(8)、deviceMemory、DPR(1)、screen/availWidth/色深、UA 与平台、GPU/WebGL/canvas、音频、字体 266 全量。
- 只允许差异：时区（须与出口 IP 地理一致）、语言/区域偏好、行为节奏。
- 应删除：DPR 1.25、19/23 字体子集、伪核数 4。
- 红线：机房 IP + 同 canvas/GPU 已把三号绑死；低熵差异无效且内部失配反暴露伪装。要 unlink 须换独立出口并加 canvas/WebGL 噪声。
