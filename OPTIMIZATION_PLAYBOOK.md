# 优化手册

## 接入清单（Intake Checklist）

改代码前先收集这些信息：

- 工具名、版本、仓库、目标命令。
- 输入类型、代表性数据集、预期输出文件。
- 当前运行时长、内存、磁盘占用、失败现象。
- 硬件：CPU 型号、核数、内存、存储类型、操作系统、编译器/运行时。
- 线程数，以及工具属于 CPU 密集、I/O 密集还是内存密集型。
- 正确性要求：精确匹配、排序后等价、容差，或领域特定的等价规则。
- 参考索引 / 主要数据结构的内存占用；是否 > 单 NUMA 节点内存（现代服务器单节点常 32–64 GB）。
- 是否已有微架构基线（IPC、memory bound %、LLC miss、DRAM 带宽），或至少能用 `perf stat` 现场取到。
- Batch size 与线程数是否已按硬件扫描过最优点。

## Profiling 指南

选择能回答瓶颈问题的最小 profiler：

- Linux 进程指标：`/usr/bin/time -v`、`pidstat`、`iostat`、`vmstat`。
- C/C++ CPU 热点：`perf record/report`、`gprof`，对可疑代码用编译器 sanitizer。
- Python：`cProfile`、`py-spy`、`line_profiler`、内存 profiler。
- I/O 行为：`strace -c`、文件数量与临时目录增长。
- 内存：峰值 RSS、分配热点、对象大小、重复缓冲区。
- Roofline 模型：先判断算法是 compute-bound 还是 memory-bound，再选优化方向。
- 微架构 TMA：`perf stat` 的 IPC、memory bound %、LLC-load-misses、DRAM BW；`likwid-perfctr`；Intel VTune 的 Microarchitecture Exploration / Memory Access。每一步优化都要看到目标指标朝预期方向移动。
- NUMA 拓扑：`numactl -H`、`numastat -p <pid>`、`lstopo`；核心数据结构 > 单 NUMA 节点内存时必查。
- 线程扩展曲线：1 / 4 / 8 / 16 / 32 / N 线程各测一次，找加速比拐点；拐点意味着共享资源饱和（锁、内存带宽、NUMA 跨节点）。

## 常见生信瓶颈

- 反复读取 FASTA/FASTQ/BAM/VCF 文件，而不是建索引或流式处理。
- 在分块流式处理就够用时，却把完整 reads/records 全读入内存。
- 过度的字符串拷贝、正则使用、split/join 循环，或逐碱基的 Python 循环。
- 低效的压缩/解压选择和过小的缓冲区。
- 在流水线各阶段之间写大量临时文件。
- 因全局锁、共享写入者或线程超订导致的糟糕线程扩展。
- 排序或去重了超过必要量的数据。
- 重复计算本可安全缓存的参考衍生数据。
- 多线程 worker 各自 parse FASTQ/BAM/VCF 并竞争同一把 IO 锁，锁粒度粗、线程扩展比差。
- 大参考索引跨 NUMA 节点分配（生信索引常达参考序列 10× 以上，绝对值 40 GB+ 常见），随机访问型 seed / lookup kernel 因跨节点访问延迟劣化。
- 随机内存访问的 kernel（FM-Index、SA 二分、hash / B-tree lookup）没做批内多路 overlap 与软件预取，被内存延迟卡住。
- `per-record → 全阶段串行` 的代码组织阻碍 SIMD / AVX-512 向量化。
- `std::unordered_map` 在 10⁸+ 键规模同时输在性能与内存。
- 单机内存装不下超大参考 / barcode 集合时仍在单进程内硬扛，未做数据分片并行。

## 改动策略

优先按以下顺序改动：

1. 去掉冗余计算。
2. 流式与批量 I/O。
3. 减少分配与拷贝。
4. 改进数据结构。
5. 调优并发与流水线阶段。
6. 仅当正确性可被严格验证时，才引入算法改动。
7. 仅对已证实的热点做底层重写。

### 通用工程模式

以下是已多次验证的可复用工程模式，可在上述 1–7 优先顺序内按需嵌入：

- 共享 IO 锁 → 生产者-消费者 + 双缓冲/环形队列：单 IO 线程解析入队；worker 只争 buffer；buffer 数 ≥ 2× worker；锁只在入/出队时短暂持有。副产品是能直接观察瓶颈到底在 IO 还是算法。
- 隐藏内存延迟三件套（适用 FM-Index / hash lookup / B-tree lookup 等随机访问 memory-bound kernel）：
  1. 同批多路 overlap：同批 N 个独立请求（8~16 起步，需实测扫描），每次每个只推进一步，让计算与访存互相重叠。
  2. 软件预取：`__builtin_prefetch` 在使用前 2–8 步发出，通常紧跟 (1) 之后加。
  3. NUMA 感知分配：`numactl --membind` / `mbind` / `set_mempolicy` / first-touch 控制；核心数据结构 > 单 NUMA 节点时必做。
  - 推荐应用顺序：先 overlap → 再 prefetch → 最后 NUMA（先解决批内并发，再解决访存局部性）。每一步都应独立地压低 memory bound %、拉高 IPC；没独立收益就回滚该步、复查瓶颈定位。
- per-record loop → per-stage batched loop（SIMD 铺路）：把"对每条记录依次跑 A→B→C→D"改成"对 batch 内所有记录跑 A，再全跑 B…"；需引入分阶段承载中间结果的数据结构，避免每阶段重解析原始记录。这一步是 SIMD/AVX-512 的前置条件。
- 哈希表容器替换：`std::unordered_map` → `folly::F14` / `absl::flat_hash_map` / `robin_hood::unordered_map`；替换前后测内存占用与查找延迟。
- 数据分片：当"换实现"到顶（如键规模让最优哈希表也扛不住），按可复现规则切分数据并行处理，同时降内存并增并行。
- OpenMP `#pragma omp critical` 自旋 → `std::mutex` + 增大 batch：`critical` 默认是 spinlock（烧 CPU、表现为高 user time 但 wall 不降），换成 `std::mutex`（竞争时 yield 让出核心）；同时把 per-thread cache/batch 从 1024 提到 8192，降锁频 8× 且 `removeDuplicates` 去重更有效。额外内存可忽略（每线程 ~0.5MB→4.5MB，相对 GiB 级工作负载 < 0.1%）。**注意**：此模式主要降 user CPU 与利用率，wall clock 受限于串行插入工作量时不会显著下降，真正缩 wall clock 需配合减遍历或并发插入。
- 多遍全图遍历的减遍历路径选择：原版"用时间换空间"为控制峰值内存而多遍遍历（如 `frequent_kmers` 4-pass，每遍只持 1 个 full-size index）。减遍历是缩 CPU/wall 的主方向，但路径必须在内存/磁盘/遍历次数三维上权衡：
  - 内存路径：同时持多个 index（每遍处理多桶），峰值内存 = index 数 × 单 index 大小；hash table 容量可对每桶减半（实际 load 远低于 MAX_LOAD_FACTOR 时安全，但需查实际占用而非上界）。
  - 磁盘路径：单趟遍历 + 外部分桶落盘，无内存增量但临时磁盘 = 单遍产物量 × 遍历数；**外推必须按 chr1 实测单遍产物量再乘倍数，不能按 distinct key 数算理论值**（重复记录/overlap 会使实际产物远大于 distinct 数）。
  - sketch 预过滤路径：见下条，常是最优（既减遍历又省内存）。
- Count-Min Sketch 预过滤 + 精确验证（适用"只需判断频率是否超阈值"的高频项筛选）：第一遍用 ~1 GiB CMS 粗筛（多行哈希、无锁原子递增、支持并行），第二遍只对 `ĉ > threshold` 的候选做精确哈希表计数。利用 CMS 的 one-sided error（只高估不低估）保证高频项不漏、低频项不误报；候选哈希表极小（只存候选），**既减遍历又省内存**。CMS 只能做预过滤器，不能替代精确计数（否则引入假阳性）。候选哈希表容量可按"扫描 CMS 第一行 `count > threshold` 的 slot 数 × 2 余量"自适应，而非拍脑袋。当"原始出现次数 ≥ 去重 position 数"时（同一 key 从多条路径被重复访问），CMS 计数天然 ≥ 精确去重计数，进一步消除假阴性。

## AI 审查要点

人应审查 AI 是否：

- 意外改变了输出语义。
- 在过小或不具代表性的数据上做基准测试。
- 忽略了排序顺序、浮点容差、随机种子或压缩元数据。
- 优化了一个数据集却让另一个退化。
- 未经多次测量就宣称提速。
- 在改善 wall time 的同时增加了内存占用。
- 在多线程代码中引入了竞态条件。
- 改索引结构或坐标编码后，是否同步更新了所有下游依赖（如 stitch / 坐标转换 / offset 语义）；正确性验证必须覆盖跨阶段对接点。
- Batch size 是否实测扫描过而不是拍脑袋（不同硬件最优点不同，经验值常在 8~64）。
- 状态机改造是否保留了原有 skip / short-circuit 语义（如某些 stage 在特定条件下应跳过）。
- 是否检查过核心数据结构跨 NUMA 这个隐式假设（数据结构 > 单 NUMA 节点内存时必查）。
- 是否只报告单一线程数下的提速，缺失 1/4/8/16/32 扩展曲线，掩盖共享资源饱和问题。
- 是否只报告 wall time 而缺失微架构证据（memory bound %、IPC、LLC miss、DRAM BW）；没有 TMA 佐证的"命中瓶颈"结论不可信。
- 是否把提速拆分归因到具体优化项，而不是只给一个"总倍数"（不然无法复用哪一项）。
- 落盘方案外推是否按"chr1 实测单遍产物量 × 遍历数"而非 distinct key 理论值；重复记录 / overlap / 多路径访问会使实际磁盘占用远大于按 distinct 数算的理论值（vg 案例：预估 62GB 实际 150GB+）。
- 是否分清 wall clock / user CPU / 利用率三类指标各自的瓶颈归属；换 mutex + 增大 batch 这类改动主要降 user CPU 与利用率，wall clock 受限于串行工作量时不会显著下降，混报会误导方向（真正缩 wall clock 需减遍历或并发化）。
- 自查 hash table 容量结论时是否用了实际占用而非上界；同一回答内不应先说"load 超限不可行"再说"完全可行"自相矛盾——先算实际 distinct key / capacity，再对照 MAX_LOAD_FACTOR。
- 是否主动调研外部同类工具算法作为对标（如 kmer 计数对标 Jellyfish/KMC）；AI 常需人工点拨才展开，受阻时应主动提议外部方案借鉴而非只在内部数据结构上打转。

## 输出模板

```markdown
## 目标
- 工具:
- 命令:
- 数据集:
- 硬件:

## 正确性基准
- 方法:
- 结果:

## 基线
- Wall time:
- 峰值 RSS:
- CPU:
- I/O/临时空间:

## 瓶颈
- ...

## 改动
- ...

## 结果
- 提速:
- 内存下降:
- 备注:

## 风险
- ...

## skill 经验
- AI 做得好:
- AI 遗漏:
- 应补入 skill:
```
