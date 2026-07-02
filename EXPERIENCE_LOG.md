# 经验日志

用本文件积累团队经验。条目要简洁、可复用。

## 条目模板

```markdown
## YYYY-MM-DD - 项目 / 工具

### 背景
- 工具:
- 优化目标:
- 数据集:

### AI 做得好的地方
- ...

### AI 遗漏的地方
- ...

### 人工审查发现
- ...

### 可复用的优化模式
- ...

### 需要更新的 skill 内容
- ...
```

## 经验记录

项目完成后在下方追加经验。

## 2023-04 / 2023-11 - bcSTAR / STAR RNA-seq 比对优化（STOmics SAW 流程）

### 背景
- 工具: STAR（上游 v2.7.2b）→ 优化版 STAR v1.4；集成到 bcSTAR（STOmics SAW pipeline）
- 优化目标: 缩短 SAW 分析流程时间；STAR 阶段占 SAW 总耗时约 70%
- 数据集: Stereo-seq 空间转录组；S1 芯片 ~6 亿 barcode，6×6 芯片 ~150 亿 barcode
- 硬件: 32 线程测试；核心数据结构 40–50 GB，跨 NUMA 节点访问延迟明显（具体 CPU 型号与 NUMA 拓扑文档未记录）
- 参与方: SAW 团队 + Intel 工程师；**本条为人工优化基线经验，AI 未参与**，用作未来 AI 复现同类工作时的对照与提醒
- 结果:
  - bcSTAR v2.0.0 vs v1.0.6：整体 **2×**（32 线程）
  - STAR v1.4 vs v2.7.2b：**优于商业软件 sentieon**（16 线程）
  - MMPs 搜索单模块：**4.5×**；IPC 0.42 → 1.05，memory bound ~60% → ~25%（TMA 分量随三件套逐步下降）

### 优化按 ROADMAP 阶段归类

**阶段一（工程优化）**

1. **IO 共享锁 → 生产者-消费者 + 双缓冲队列**
   - 原：N 个 alignment 线程各自 parse FASTQ、竞争同一把 IO 锁，锁粒度粗 → 扩展比差
   - 后：1 个 IO 线程解析入队；alignment 线程只从 full 队列取、写回 empty 队列；buffer 数 = 2× alignment 线程；锁仅在入/出队时短暂持有
   - 副产品：切成 PC 模型后能直接观察"瓶颈在 IO 还是算法"，为下一步定位提供依据
2. **per-record loop → per-stage batched loop（为 SIMD 铺路）**
   - 把"对每条 read 依次跑 MMP→CEW→AAW→SAW→…→BAM-OUT"改成"对 batch 内所有 read 先跑 MMP，再一起跑 CEW…"
   - 引入分阶段承载中间结果的数据结构（pkgPC/pkgWC/pkgWA/pkgTR/pkgBR，工具专属细节见 recipes 建议）
   - **这一步是 AVX-512 的前置条件，不是 AVX-512 本身**
3. **barcode HashTable：`std::unordered_map` → `folly::F14`**
   - 性能与内存双赢
4. **超大规模数据分片**
   - 6×6 芯片 150 亿 barcode 下 folly::F14 也 ~400 GB，"换实现"已到顶；按规则切分 mask/FASTQ 文件同时降内存并增并行

**阶段二（算法重构）**

5. **SA 二分搜索 → FM-Index + 隐藏内存延迟三件套**
   - 算法替换：seed 阶段的 MMP 搜索用 FM-Index 替换 SA 二分，复杂度更优
   - 三件套按顺序应用，每一步在 TMA 指标上都独立地压低 memory bound、拉高 IPC：
     - (a) **同批多路 overlap**：同批 8~16 条 reads（实测扫描过），每次每条只推进一个字符，计算与访存互相重叠
     - (b) **软件预取**：`__builtin_prefetch` 提前发出下一步 checkpoint 访问
     - (c) **NUMA 感知分配**：控制大索引的内存分配，避免跨节点访问

### AI 复现时的预期陷阱（预判，非事后复盘）

以下是本项目工程师凭经验做对、但 AI 在无明确提醒时容易漏的检查点：

1. **改索引结构后同步更新下游语义**：SA→FM-Index 时坐标编码、offset 语义、StitchPieces 中的坐标转换全都要一起改。本项目做对了，正确性通过验证。
2. **Batch size 实测扫描而非拍脑袋**：本项目实测最优 8~16，硬件相关；AI 常直接给 32/64。
3. **状态机改造保留原有 skip / short-circuit 语义**：stage/status/task 三级状态机重排时不应破坏原有的 stage 跳过逻辑。本项目保留了。
4. **NUMA 是隐式假设**：核心数据结构 > 单 NUMA 节点内存（现代服务器单节点常 32–64 GB）时必查；本项目 40–50 GB 已明显吃亏，AI 通常不主动检查。
5. **微架构证据要求**：每一步优化都应看到目标 TMA 分量（如 memory bound %）朝预期方向移动、IPC 同步上升；只有 wall time 提升、无 TMA 佐证的"命中瓶颈"结论不可信。

### 人工审查发现（本项目工程师的判断，值得沉淀）
- STAR seed 阶段是**随机内存访问型 memory-bound kernel**，Roofline 直接判定后，隐藏内存延迟成为唯一正确方向。
- **三件套的推荐应用顺序 overlap → prefetch → NUMA**：先拉起批内并发，再加预取，最后 NUMA 亲和；每步都要独立带收益，没有独立收益就该回滚该步并复查瓶颈定位。
- **IO producer-consumer 的战略价值不仅是"更快"**：它把瓶颈从 IO 转移到算法本身，暴露了下一步该攻击的目标。
- **换实现有天花板**：当数据规模让最优容器也顶不住（150 亿 barcode / 400 GB），唯一出路是数据分片 + 并行。

### 可复用的优化模式（本次已下沉到 PLAYBOOK）
- 共享 IO 锁 → 单 IO 线程 + 双缓冲/环形队列
- per-record loop → per-stage batched loop，为 SIMD 铺路
- 随机内存访问 memory-bound kernel 的三件套（overlap + prefetch + NUMA）及其验证方法（TMA 分量 + IPC）
- `std::unordered_map` → `folly::F14` / `absl::flat_hash_map` / `robin_hood`
- 超大数据分片以同时降内存并增并行
- Roofline + 微架构指标作为方向验证工具

### 需要更新的 skill 内容
- **本次同步更新** `OPTIMIZATION_PLAYBOOK.md`：接入清单、Profiling 指南、常见瓶颈、改动策略（新增"通用工程模式"）、AI 审查要点
- **本次不做、建议未来补**：
  - `recipes/STAR.md`：stage/status/task 三级状态机、pkgPC/pkgWC/pkgWA/pkgTR/pkgBR 数据结构、`ThreadBufWrapper::searchMMPs` / `storeAlign` / `BatchForCreateWind` / `BatchForAssignAlign` / `BatchForStitchAlign` / `FinishRemainStage` API、STAR 索引 ≈ 参考 12× 的经验数字
  - `recipes/bcSTAR.md`：barcode HashTable(folly::F14) 要点、mask/FASTQ 拆分规则、SAW 中 STAR 占 70%
- **本项目报告缺口**（未来项目应改进）：
  - 只报了 32 线程与 16 线程结果，缺 1/4/8/16/32 完整扩展曲线
  - 缺具体 wall time / 峰值 RSS / CPU 利用率 / I-O 量 / 临时空间 / 重复次数
  - 总 2× 提速中 IO / SIMD 铺路 / FM-Index 三部分的独立贡献未拆分归因
