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

## 2026-06 - vg / vg minimizer 性能优化（AI 主导）

### 背景
- 工具: vg `minimizer` 子命令（gbwtgraph 库，`deps/gbwtgraph/src/index.cpp`）；上游 v1.74.1
- 优化目标: 缩短 `vg minimizer -p --weighted --save-memory` 构建索引的 wall clock 与 CPU 开销
- 数据集: chr1 小图（快速验证）+ HPRC v2.0 全基因组 pangenome（gbz ~6.4G，dist 索引）；10 线程
- 硬件: AMD R5 3600 6 core 12 threads
- 参与方: **AI 主导 profiling + 实现，人工审查方向与回退决策**；参考脚本 `run_v1.74.1_example.sh`
- 结果（全基因组，CMS 方案 vs 原版 4-pass）:
  - 频繁 kmer 阶段：1111s → 336s（**−70%**）
  - 总 wall clock：28:48 → 14:46（**−49%**）
  - User CPU：11277s → 4157s（**−63%**）
  - 三重正确性验证通过：frequent kmer 数 84993 一致、MinimizerIndex 统计一致、`.zipcodes` MD5 完全一致

### AI 做得好的地方
- **Profiling 流程规范**：perf + flamegraph 双模式（dwarf 8.4GB 慢但完整，frame pointer 98MB 快且干净）；用 self/leaf profile + progress log wall-time 做相位归因，识破"OpenMP 栈终止于 libgomp 导致 folded-stack 相位归因不可信"的陷阱。
- **热点定位准确**：识别出三大瓶颈——`frequent_kmers` 66%（`--save-memory` 4 次全图遍历）、OpenMP `critical` 43% 自旋、`cache_payloads` 单线程 10.5%；给出 P0–P4 优先级与预期收益表。
- **小步验证 + 正确性闭环**：每个方案先 chr1 跑基线/优化对比，再全量；用 keys/unique/occurrences + `.zipcodes` MD5 做逻辑等价校验，正确解释了 `.min` 二进制布局差异（hash 表插入顺序变化，逻辑等价）。
- **量化取舍清晰**：内存方案对比表（A 2-pass/B LZ4/C 缩 hash/D 回退）给出 frequent_kmers 阶段内存、总峰值增量、磁盘占用、遍历次数四列，并精确算出 `2^31` hash table = 32 GiB、cell 16 bytes 的来源。
- **在人工引导下可调研外部方案**：人工提示"调研 jellyfish、kmc"后，对比 Jellyfish（CAS 无锁 + quotienting）、KMC3（磁盘分桶 + 基数排序），逐条评估对我们 `KmerIndex`（open-addressing + 多值 position 列表）的适用性，最终沉淀出 Count-Min Sketch 预过滤方向。**非主动发起**——AI 未在 P0-1 受阻时自发提议外部算法对标，需人工点拨才展开调研。
- **正确性论证严谨**：CMS 预过滤用 one-sided error（只高估不低估）证明"高频 kmer 不会漏、低频不会误报"，并指出 `原始出现次数 ≥ 去重 position 数` 进一步消除假阴性；明确 CMS 只能做预过滤不能替代 KmerIndex。

### AI 遗漏的地方
- **磁盘开销低估**：P0-1 单趟外部分桶预估 ~62GB，实际产出 150GB+（2.4×），原因是只算了去重后 kmer 数，忽略了 overlapping haplotype windows 产出的重复记录；导致全量跑了一半被人工叫停。**应在落盘方案前对 chr1 实测单遍产物量再外推，而非按 distinct key 数算理论值。**
- **方案 C 自查不彻底**：先说"`2^30` load factor 升到 0.80 超过 MAX_LOAD_FACTOR 0.77 不可行"，下一段重算发现实际 load ≈ 0.10 完全可行——同一回答内自相矛盾，说明对 `genome_size/2` 是"上界+2×余量"而非实际占用理解不牢。**人工追问后才理清。**
- **墙钟 vs CPU 收益混报**：P1 实施后报"CPU −30%"但 wall clock 仅 −3~5%，最初未明确说明墙钟受限于串行插入、需 P0 才能真正缩墙钟，直到对比表才讲清。**结论应先分清 wall clock / user CPU / 利用率三类指标各自的含义与瓶颈归属。**
- **编辑工具反复失败**：P0-1 实施时多次"重复循环实现但不编辑文件"，最后靠整体 Write 覆盖才完成。大段重构应直接用 Write 而非碎片段 StrReplace。
- **没主动报报告缺口**：未提示缺 1/4/8/16/32 扩展曲线、重复次数、I/O 量等，沿用了和 bcSTAR 一样的报告短板。

### 人工审查发现
- **P0-1 落盘方向被否决**：150GB 临时文件不可接受，人工要求"内存增加不能超过 4GB"，迫使从磁盘分桶转向纯内存方案。
- **方案 C 的"降低桶大小有风险"被叫停回退**：人工最终选择回退 Solution C，改用 CMS 预过滤——因为缩 hash table 虽然当下 load factor 安全，但失去了上界余量，对极端 pangenome 倾斜有风险。
- **关键设计点要人工追问才浮现**：`hash_table_size = 2^31` 的来源（`genome_size/2` + MAX_LOAD_FACTOR=0.77 + 向上取 2 的幂）、`genome_size/2` 为何是 /2 而非 /4（GC 不均 + canonicalization 偏斜 + 2× 安全余量，实际 load 仅 0.05）都是人工逐层追问后 AI 才讲清的。
- **CMS 阈值选择由人工确认**：采用方案 A（阈值不变，`ĉ > threshold`）而非更保守的 threshold/2，因为 CMS 不会低估。

### 可复用的优化模式
- **`#pragma omp critical` 自旋 → `std::mutex` + 增大 batch**：spinlock 烧 CPU，换 yielding mutex 消除自旋；batch 1024→8192 降锁频 8× 且 `removeDuplicates` 去重更有效。额外内存可忽略（每线程 ~0.5MB→4.5MB，相对 33 GiB 工作负载 < 0.02%）。
- **多遍全图遍历 → 减遍历次数**：原版 `space_efficient` 用时间换空间（4 遍，每次 1 个 full-size KmerIndex）；减遍历是缩 CPU/wall 的主方向，但必须配合内存约束选路径。
- **Count-Min Sketch 预过滤 + 精确验证**：第一遍用 ~1 GiB CMS 粗筛（无锁原子更新、支持并行），第二遍只对 `ĉ > threshold` 的候选做精确 KmerIndex 计数。利用 one-sided error 保证高频不漏、低频不误报；候选 KmerIndex 极小，遍历开销显著降低。
- **`candidate_capacity` 按 CMS 候选数自适应**：扫描 CMS 第一行统计 `count > threshold` 的 slot 数作为 distinct candidate 下界，×2 余量，再 `minimum_size()`，避免拍脑袋。
- **大段重构用 Write 整体覆盖**，碎片段 StrReplace 易循环失败。
- **正确性校验三件套**：frequent kmer 数 + MinimizerIndex 统计（keys/unique/occurrences/load factor）+ `.zipcodes` MD5；`.min` 二进制布局差异属 hash 插入序变化，逻辑等价可接受。
- **chr1 小图先行 + 全量收尾**：chr1 跑通再上全基因组，加速验证迭代。

### 需要更新的 skill 内容
- **建议下沉到 `OPTIMIZATION_PLAYBOOK.md`**：
  - 通用模式："OpenMP critical 自旋 → std::mutex + 增大 batch"（含 batch 增大对内存影响可忽略的量化论证范式）
  - 通用模式："多遍全图遍历的减遍历路径选择"（含内存/磁盘/遍历次数三维权衡表模板）
  - 通用模式："Count-Min Sketch 预过滤 + 精确验证"（one-sided error 正确性证明 + 候选容量自适应）
  - AI 审查要点：落盘方案外推必须按"单遍实测产物量 × 遍历数"而非 distinct key 理论值；wall clock / user CPU / 利用率三类指标分清瓶颈归属；大段重构直接 Write
- **建议新增 `recipes/vg_minimizer.md`**：
  - `frequent_kmers` 两种模式（`space_efficient` 4-pass vs 非 space_efficient 4-index 并行）与 middle-base 4 桶分片语义
  - `hash_table_size = KmerIndex::minimum_size(genome_size/2)` 链路、`genome_size/2` 的 2× 余量来源、实际 load ~0.05
  - `KmerIndex` cell 大小（payload=0 时 16B）与 `--save-memory` vs `--fast-counting` 的内存取舍
  - `.zipcodes` MD5 作逻辑等价校验、`.min` 布局差异可接受的原因
  - 全量 CMS 方案基线数字：频繁 kmer 1111→336s、wall 28:48→14:46
- **本项目报告缺口（未来应补）**：缺 1/4/8/16/32 扩展曲线、重复次数、I/O 量、临时空间；CMS 方案中 Phase 1 sketch 更新 / Phase 2 精确计数 / MinimizerIndex 构建三段的独立贡献未拆分归因。

## 2026-07 - merge_bams / 多 BAM 分片合并（AI 主导）

### 背景
- 工具: `merge_main`（`aligner/src/SortDuplicate/merge_bams.cpp`）；独立测试载体 `aligner/test/fast_merge_bam.cpp`。配方卡见 `recipes/merge_bams.md`
- 优化目标: 把大量**已按坐标排序**的 BAM 分片合并成一个排序 BAM，可选打 dup + 内联建索引；原版 CPU 利用率上不去、慢
- 数据集: 微型（3 人造分片）+ 真实（362 分片 / ~60GB，hg38）；32 线程
- 硬件: 32 线程（型号未记录）；页缓存热（同机重复跑）
- 参与方: **AI 主导 profiling + 实现，人工把方向、抓错、定验收口径**
- 结果（2M 窗口 / 32 线程）: 全量合并 **~120s 含内联建索引**，平均 ~20 核、峰值打满 32；记录数精确对齐参考 726123637；FDUP 按 qname 精确命中（合成 354/354）；内联 `.bai` 的 `idxstats` 与 samtools 自建索引一致

### AI 做得好的地方
- **架构定位准**：识别原版瓶颈是单线程 k 路归并（`priority_queue` pop/push + `sam_write1` 全串行），换成"基因组窗口分区 → worker 乱序并行处理 → 单写线程按窗口序输出"。
- **ordinal 冲突的解法**：dup 信息是**按分片顺序读的 0 基序号（ordinal）**给的，与随机访问窗口天然冲突。用 **Pass1 预扫描**记下每个(文件,窗口)首条的 `(virtual_offset, ordinal)`，Pass2 seek 回去再顺序 +1 还原序号——用一遍全解码（~7% 开销、~10MB 内存）换 Pass2 的完全独立并行。
- **高 CPU 的关键点抓得住**：worker 内用 **libdeflate 手工并行压 BGZF 块**、**写线程只 `fwrite`**（几乎不干活）。
- **内联索引不牺牲并行**：worker 产出每条记录的 `(块内偏移 block_coff, uoff)` 元数据，写线程按绝对文件偏移 `hts_idx_push`，末尾 `hts_idx_save_as`，省掉单独一遍 ~38s 建索引。
- **正确性闭环规范**：合成数据先验（记录数 + FDUP 按 qname 精确 diff + 内联索引 idxstats 与 samtools 对拍 md5），再上全量；发现并修了原版结尾 `exit(1)` 在成功路径上误退出的 bug。
- **窗口扫描给结论**：2M/1M/500K 三档实测出"2M 最快、内存随窗口近线性降、过小收益递减"的权衡曲线。

### AI 遗漏的地方
- **中途选错方向，被用户抓回**：为了拿"内联索引"，一版把输出改成 **htslib 单线程 `sam_write1`**，结果重新引入串行瓶颈——CPU 上不去、和原版一样慢。用户看进度后指出"上个版本很快"。**教训：不要为了便利特性（内联索引）牺牲已经拿到的并行压缩收益；写线程必须保持 trivial（只 fwrite）。** 正确做法是保留手工并行 BGZF，用元数据在写线程建索引。
- **报告缺口沿用旧短板**：窗口基准是页缓存热、只有 32 线程、无重复次数、markdup off、无 I-O 量；缺 1/4/8/16/32 扩展曲线。
- **多文件时的隐性内存/句柄没主动预警**：每个 worker 会把碰到的输入文件**都保持打开**，同时打开句柄 ≈ 线程数×文件数，多文件时可能撞 `ulimit -n` 或吃内存；缩小窗口治不了这个，需人工追问才展开分析。

### 人工审查发现
- **"慢且 CPU 低"必须先归因再改**：用户凭进度判断退化，方向正确——问题不在 dup 而在写线程模型。
- **dup 口径要对齐上游**：ordinal 必须与原版 `eachFileReadIdx` 一致（顺序读、含所有记录的 0 基序号），否则打错 read。
- **窗口是内存↔速度旋钮且要有下限**：文件多时自动缩小窗口控内存方向对，但下限建议 ~500K（过小则窗口数暴涨、`winVoff` 索引数组反弹、输出小块变多）。
- **拖尾 ≠ OOM**：有序写 + `max_inflight=threads*3` 背压，慢窗口只会让 CPU 出现"坑"（吞吐下降），完成但没写出的窗口数有上界，内存不会无限堆积。

### 可复用的优化模式
- **单线程 k 路归并（priority_queue）→ 基因组窗口分区并行 + 有序单写线程**：worker 用原子计数器抢窗口乱序并行，writer 严格按窗口号顺序落盘保证坐标有序。
- **写线程保持 trivial**：重活（解码/排序/压缩）全在 worker，writer 只 `fwrite`（+ 轻量索引记账）；**避免用 htslib 单线程 `sam_write1` 当写线程**，否则序列化+压缩重新串行化成瓶颈。
- **worker 内 libdeflate 手工并行压 BGZF**：`libdeflate_deflate_compress` 逐块（≤0xff00）压 + 手工拼 BGZF 头/CRC/ISIZE + 末尾 EOF 块。
- **ordinal 型附加信息 + 随机访问并行 → 预扫描 pass**：先顺序扫一遍记下每个分区首元素的 `(offset, ordinal)`，让并行阶段能 seek 到任意分区并还原序号。
- **手工 BGZF 写时内联建索引**：worker 产出每记录 `(块偏移, 块内未压缩偏移)` 元数据，写线程按绝对 voffset `hts_idx_push` + `hts_idx_finish` + `hts_idx_save_as`，免去单独建索引 pass。
- **有界内存生产者-消费者**：`max_inflight = threads*K` 背压封顶待写窗口数；理解"拖尾=吞吐坑，非 OOM"。
- **窗口/tile 尺寸作内存↔速度旋钮**：多输入时按 `(文件数 × 窗口) ≈ 常数` 自适应缩小并设下限。

### 需要更新的 skill 内容
- **建议下沉到 `OPTIMIZATION_PLAYBOOK.md`**：
  - 通用模式："单线程归并 → 分区并行 + 有序单写线程"（含写线程保持 trivial、避免 htslib 单线程 writer 的反例）
  - 通用模式："ordinal 型附加信息 + 随机访问并行 → 预扫描 pass"
  - 通用模式："手工 BGZF 并行压缩 + 写线程内联建索引"
  - 通用模式："max_inflight 背压 + 拖尾=吞吐坑非 OOM"的判据
  - AI 审查要点：不要为便利特性牺牲已拿到的并行收益（内联索引 vs 并行压缩的反例）；多文件时预警 `线程数×文件数` 句柄/内存
- **已新增 `recipes/merge_bams.md`**：签名、dup 口径、正确性三件套、窗口基线表
- **本项目报告缺口（未来应补）**：冷缓存、1/4/8/16/32 扩展曲线、重复次数、I-O 量、markdup on 的基准、Pass1 vs Pass2 vs 写线程三段独立耗时归因

## 2026-07 - fastp 1.3.6 / PE gz→gz 工程优化（AI 主导）

### 背景
- 工具: fastp **1.3.6**（源码 `/zdswhst2/.../software/fastp`）；基线二进制 `bioPerfSkill/test/fastp.baseline`，优化版 `test/fastp.opt`
- 优化目标: ≤32 线程相对基线 wall clock **≥20%**；保持 QC 语义一致
- 数据集: HG002_20k（oracle）；hg001 20M PE gz→gz（主基准，热缓存）；硬件 Intel Xeon Gold 6442Y 96 逻辑核
- 命令: `--detect_adapter_for_pe`，默认质量/长度过滤
- 参与方: **AI 主导 profiling + 实现**；配方卡 `recipes/fastp.md`
- 结果（20M PE，热缓存）:

| 线程 | 基线 wall | 优化 wall | 加速 |
|---:|---:|---:|---:|
| 8 | 74.63s | 75.41s | ~0×（持平） |
| 16 | 60.31s | 55.81s | **1.08×（+7.5%）** |
| 32 | 425.43s | 56.68s | **7.5×（远超 +20%）** |

正确性: 20k 解压后 FASTQ 逐字节一致 + JSON filtering_result 一致；20M JSON filtering_result 一致。

### AI 做得好的地方
- **先测线程扩展再改**: 发现 -w32 基线墙钟暴涨到 7min、CPU 仅 ~154%，而 -w8/16 正常——不是"再加压缩并行"能解决的。
- **根因定位准**: 输入是普通 gzip（非 BGZF），BgzfMt 路径未启用；真正问题是 SPSC 队列「末节点不可消费」+ `PACK_IN_MEM_LIMIT=32` 与 `thread=32` 冲突 → 每 worker 队列长期只有 1 个 pack → worker 空等、reader 背压，近似活锁。
- **改动可审查、主题聚焦**: (1) SPSC `canBeConsumed` 允许 `head==tail`；(2) `packInMemLimitForThreads = max(32, 3*thread)`；(3) pwrite 模式跳过空转 writer 线程；(4) offset 等待改 pause/yield；(5) 增大 igzip/FQ 缓冲。
- **正确性闭环**: 先 20k oracle，再 20M JSON 对拍。

### AI 遗漏的地方 / 报告缺口
- -w8 无收益（甚至略慢）；-w16 仅 +7.5%。**目标在 -w32 达成**，低线程仍受双路串行 gunzip 下界约束（双 zcat 解压地板 ~33s）。
- 全量 WES（~20GB）未跑完最终墙钟；perf 显示 `--detect_adapter_for_pe` 的 `checkKnownAdapters` 占短跑大量周期，尚未做第二主题优化。
- 未报冷缓存、未做 3 次重复取中位数。

### 可复用的优化模式
- **SPSC / 无锁队列末节点可消费性**: `nextItemReady` 只发布后继时，队列里最后一个元素会永远不可消费；fan-out 到 N 个队列且 in-flight≈N 时必炸。
- **背压上限必须随 fan-out 因子缩放**: `PACK_IN_MEM_LIMIT` 不能小于约 `2~3 × thread`。
- **已并行的写路径上勿再拉空转 writer 线程**: pwrite 模式下 `isCompleted()==true` 仍 `spawn writerTask` 是浪费。
- **先确认压缩容器格式**: `.gz` ≠ BGZF；并行解压优化对非 BGZF 无效。

### 需要更新的 skill 内容
- 已更新 `recipes/fastp.md` 基线表与瓶颈说明。
- 建议下沉 PLAYBOOK: 「SPSC 末节点 + 背压与 fan-out 匹配」通用模式。

## 2026-07-13 - fastp 1.3.6 / README 典型命令重基线

### 背景
- 工具: fastp 1.3.6；命令仅 `-i/-I/-o/-O/-w`（无 `--detect_adapter_for_pe`）
- 优化目标: ≤16 线程，相对 baseline **最快墙钟** ≥20%
- 数据集: hg001 20M PE gz；验收写出宜用本地盘（`/data/disk2`），Lustre 噪声大

### AI 做得好的地方
- 先重测 README 命令线程曲线再优化；发现初扫 35s 与热缓存本地盘 ~26s 差一截
- perf：去掉 detect 后主热点是 overlap SIMD、Stats、Duplicate，压缩可用 ISA-L 换掉 libdeflate
- 正确性：20k 解压 FASTQ + filtering/adapter 计数对齐

### AI 遗漏的地方
- 初扫把 Lustre 写出当基线，热起来后两端都变快；必须以交错 A/B 同条件对比
- ISA-L level0 放大输出体积，写放大可抵消压缩加速

### 可复用的优化模式
- pwrite 并行压缩可换 ISA-L；gzip 字节可变，解压内容不变即可
- overlap 搜索：先标量探头再 SIMD，砍掉大量 reject 路径上的 HWY dispatch
- 输出路径选本地盘/tmpfs 做 CPU 对比，避免共享文件系统噪声

### 需要更新的 skill 内容
- recipes/fastp.md 基线表与 Round2 历史；典型命令保持 README-only

## 2026-07-14 - fastp 1.3.6 / PE 配对修复 + 8/12/16 扫线（含 CPU/RSS）

### 背景
- 工具: fastp 1.3.6 opt（`software/fastp` → `test/fastp.opt`）
- 问题: 活锁修复里 R1/R2 **各自** `mSeqCounter.fetch_add` → 写序交错 → **PE mates 错配**（WES 抽样可达数百分点）
- 验收: ≤16 线程相对 baseline 最快墙钟 ≥20%；配对正确；记录 CPU%/RSS

### 修复
- PE pwrite：`mPairOutputSeq` 一次领取，`WriterThread::input(tid, data, seq)` 左右共用同一序号
- SE：仍本 writer 内递增；`noteSeqHighWater` 保证 truncate 高水位无空洞

### 正确性
- 20k（-w4/8/14/16）、20M（各 100 万对）、WES（各 50 万对 ×4）：**配对 broken=0**
- WES JSON：`filtering_result` / before / after / adapter_trimmed reads+bases 与 base 一致

### 性能（2026-07-14，hg001 20M，本地盘，热缓存，交错 3 次）

| 线程 | base best | opt best | 加速 | base/opt CPU% med | base/opt RSS med |
|---:|---:|---:|---:|---:|---:|
| 8 | 40.76s | 31.24s | **+23%** | 861% / 881% | 1.25 / 1.32 GB |
| 12 | 28.93s | 21.35s | **+26%** | 1209% / 1303% | 1.30 / 1.38 GB |
| 16 | 29.33s | 18.26s | **+38%** | 1314% / 1525% | 1.35 / 1.44 GB |

- 推荐：opt **`-w16`**（最快）；稳妥 **`-w12`**
- 代价：RSS +6–7%；csv：`/data/disk2/private/gongchun/tmp/bioperf_t081216_1864088/times.csv`

### WES 全量同条件扫线（2026-07-14；12 线程已订正）

| 线程 | base best | opt best | 加速 | base/opt CPU% | base/opt RSS | 来源 |
|---:|---:|---:|---:|---:|---:|---|
| 8 | 223.1s | 162.3s | **+27%** | 866% / 942% | 1.23 / 1.30 GB | 扫线 2 次 |
| 12 | 154.3s | 133.0s | **+14%** | 1274% / 1155% | ~1.27 / ~1.34 GB | **订正**（opt-first） |
| 16 | 161.1s | 131.7s | **+18%** | 1233% / 1164% | 1.32 / 1.43 GB | 扫线 2 次 |

- 原扫线 `-w12` base→opt 得 152/204s（−34%）作废：近满盘写回伪影。
- 以后 WES 对比用 ABBA / `sync`；csv：`test/bench/wes_t081216_times.csv`；诊断：`test/bench/wes_w12_order_diag.txt`

### 可复用的优化模式
- **配对输出的全局序号必须共享**：两个独立 writer 各自 `fetch_add` 会打乱 mates；“防空洞的全局序号”与“R1/R2 同序”要一起设计
- 线程扫线同时记 **wall + `%CPU` + MaxRSS**（`/usr/bin/time -v`），避免只报墙钟
- **中等集与全量加速比不同**：20M `-w12` +26%，WES 订正后 +14%；全量仍须验收且注意写盘顺序
- **大写盘对比陷阱**：base→opt 固定顺序 + 近满盘 + 压缩写放大 → 后者假性变慢（高墙钟、低 CPU%）；应用 ABBA 或落盘 `sync` 后再测

### 需要更新的 skill 内容
- 已写入 `recipes/fastp.md`「2026-07-14 线程扫线」与「WES 全量扫线」表，并注明 `-w12` 伪影结论
