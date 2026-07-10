# merge_bams / merge_main（aligner SortDuplicate）

> 配方卡记录某个工具"怎么跑、怎么验、瓶颈在哪"。带 ✍️ 的栏由人填写（领域知识）；
> 带 🤖 的栏可由 AI 在优化过程中补充或更新。

## 基本信息 ✍️

- 工具名 / 版本: `merge_main`，位于 `aligner/src/SortDuplicate/merge_bams.cpp`
- 仓库 / 源码位置:
  - 库函数: `aligner/src/SortDuplicate/merge_bams.cpp`（供 `markDupAndMerge.cpp` 调用）
  - 独立测试载体: `aligner/test/fast_merge_bam.cpp`（带 `main()`，本地可编译，用于基准/验证）
- 用途简述: 把许多**各自已按坐标排序**的 BAM 分片合并成一个排序好的 BAM，可选按 `dupInfo` 打 `FDUP`，并**内联建 `.bai`/`.csi`**（不再单独跑一遍索引）。
- 实现语言: C++17 + htslib + libdeflate
- 类型: CPU 密集（解码 + 排序 + 压缩）+ I-O 密集（读多个分片、写大文件）

## 标准运行命令 ✍️

库函数签名（**不可改**，下游依赖）:

```cpp
int merge_main(vector<string> bamList, string unmap_bam, string out_bam,
               vector<vector<uint32_t>> &dupInfo, uint16_t threadsNum);
```

独立测试工具（先 `bash aligner/test/build_fast_merge.sh` 编译）:

```bash
cd aligner/test
# 纯合并（不打 dup）
./fast_merge_bam -o out.bam -@ 32 -w 2000 -b merge_inputs.fofn
# 打 dup（--dup 文件每行 "fileIdx ordinal"，ordinal=顺序读该分片的0基序号，含所有记录）
./fast_merge_bam -o out.bam -@ 32 -w 2000 --dup dup.txt --unmap result_wgs/hg001.align.unmap.bam -b merge_inputs.fofn
# -w 单位 kb（2000=2M）；-l 压缩级别默认3
```

库的构建走镜像里的 `autobuildandtestdcstools/buildTool.sh`（本地不能编译 SortDuplicate）。

## 代表性输入数据 ✍️

- 微型 fixture（快速正确性检查）: 3 个人造分片各 ~800 mapped + 20 unmap（脚本现场生成，见下）
- 大数据集（最终性能结论）: `aligner/test/result_wgs/`，362 个分片、合计 ~60GB；文件列表 `merge_inputs.fofn`，外部 unmap `result_wgs/hg001.align.unmap.bam`
- 关键边界: 分片内的 unmap（tid<0）记录、超长 `n_cigar>65535`、CSI（ref>512Mb）

## 预期输出 ✍️

- 输出: 坐标排序 BAM + 同名 `.bai`（或 `.csi`）内联索引
- 大小量级: 全量 ~38GB；参考记录数 **726123637**

## 正确性验证方法 ✍️（最关键）

- 比较方式: 排序后等价；记录顺序、FLAG（含 FDUP）、序列/质量、mate/isize 必须一致
- 记录顺序 tie-break: `(tid, pos, fileIdx, readIdx)`——等 pos 时按"分片序→分片内读入序"，须与原版 `BamRecCmp` 一致
- dup 口径: `dupInfo[i]` 是文件 i 的 ordinal 列表，ordinal = **顺序读该分片时的 0 基序号（含 unmap 记录一并计数）**，与原版 `eachFileReadIdx` 一致

```bash
# 记录数
samtools view -c -@8 out.bam            # 应 == 参考总数
# FDUP 精确到 read 名字（造 dup 时同时把 qname 存入 expected.txt）
samtools view -f 0x400 out.bam | cut -f1 | sort > got.txt
diff got.txt <(sort expected.txt)       # 应无差异
# 内联索引正确性：与 samtools 自建索引对拍
cp out.bam v.bam && samtools index v.bam
diff <(samtools idxstats out.bam) <(samtools idxstats v.bam)   # 应一致
samtools quickcheck out.bam
```

## 已知瓶颈 ✍️/🤖

- **原版**: 单线程 k 路归并（`std::priority_queue`），pop/push + `sam_write1` 全在一个线程 → CPU 上不去、慢。
- **快版残余**: 写线程单线程 `hts_idx_push`（每记录一次）+ `fwrite`；有序写导致慢窗口拖尾时 CPU 出现"坑"（但有背压，不会 OOM）。

## 基线测量记录 🤖

真实数据 362 分片 / 60GB / 32 线程 / markdup off / 页缓存热（同机重复跑）:

| 日期 | 硬件 | 线程 | 窗口 | 窗口数 | Wall | 平均CPU | 峰值RSS | 备注 |
|---|---|---:|---|---:|---:|---:|---:|---|
| 2026-07-09 | 32 线程 | 32 | 5M | 802 | ~129s | 21.5 核 | 22.1G | |
| 2026-07-09 | 32 线程 | 32 | 2M | 1729 | ~120s | 19.9 核 | 11.85G | 记录数精确对齐参考 726123637 |
| 2026-07-10 | 32 线程 | 32 | 1M | 3274 | ~141s | 20.4 核 | 7.89G | |
| 2026-07-10 | 32 线程 | 32 | 500K | 6362 | ~144s | 20.0 核 | 5.84G | |

窗口权衡：**2M 最快**；内存随窗口近似线性下降；再小（→100K）拖尾/开销上升、`winVoff` 索引数组反弹、输出小块变多，收益递减。建议窗口下限 ~500K，速度优先用 2M、内存优先用 1M。

报告缺口（未来补）: 缺 1/4/8/16/32 扩展曲线、重复次数、冷缓存、I-O 量；窗口基准是 markdup off。

## 历史优化与经验 🤖

- 详见 `EXPERIENCE_LOG.md` 的 `2026-07 - merge_bams` 条目。核心：单线程归并 → 窗口分区并行归并 + 有序单写线程；ordinal 型 dup 信息靠 Pass1 预扫描解决随机访问冲突；worker 内 libdeflate 并行压 BGZF、写线程只 fwrite 是高 CPU 的关键（换成 htslib 单线程 `sam_write1` 会退回瓶颈）。
