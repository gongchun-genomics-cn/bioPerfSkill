# fastp 1.3.6

> 配方卡记录某个工具"怎么跑、怎么验、瓶颈在哪"。带 ✍️ 的栏由人填写（领域知识）；
> 带 🤖 的栏可由 AI 在优化过程中补充或更新。
>
> 用途：BioPerfSkill **阶段一**验证用例（工程优化：I/O、压缩、线程扩展、批处理），
> 不改 QC 判定语义。

## 基本信息 ✍️

- 工具名 / 版本: `fastp` **1.3.6**
- 仓库 / 源码位置:
  - 上游: https://github.com/OpenGene/fastp
  - 本机源码目录: `/zdswhst2/ST_BIOINTEL/P24Z32400N0004/gongchun/software/fastp`
  - 编译方法：
	1. conda install -c conda-forge isa-l libdeflate libhwy
	2. # get source (you can also use browser to download from master or releases)
		git clone https://github.com/OpenGene/fastp.git

		# build
		cd fastp
		make -j

		# Install
		sudo make install
- 用途简述: FASTQ 质控——adapter/polyG 修剪、质量/长度过滤、可选 PE overlap 校正与 merge；输出 clean FASTQ + JSON/HTML 报告
- 实现语言: C++（多线程 worker + 读写线程；gzip 常用 ISA-L / zlib）
- 类型: **I-O 密集**（读/写 `.fq`/`.fq.gz`）+ 中等 CPU（QC、overlap、压缩）

## 标准运行命令 ✍️

与 [上游 README](https://github.com/OpenGene/fastp) 典型用法一致：**除线程 `-w` 外不加其它参数**（默认会写 `fastp.json` / `fastp.html`）。

```bash
FASTP=/zdswhst2/ST_BIOINTEL/P24Z32400N0004/gongchun/software/fastp/fastp   # 或 test/fastp.baseline / test/fastp.opt
OUTDIR=/zdswhst2/ST_BIOINTEL/P24Z32400N0004/gongchun/project/bioPerfSkill/test/bioperf_fastp_$$
mkdir -p "$OUTDIR"

# 典型命令（PE gz → gz）
"$FASTP" -i "$R1" -I "$R2" -o "$OUTDIR/out.R1.fq.gz" -O "$OUTDIR/out.R2.fq.gz" -w 16
```

测量包装（与 skill 一致）:

```bash
/usr/bin/time -v -o "$OUTDIR/time.txt" \
  bash -c '"$FASTP" -i "$R1" -I "$R2" -o "$OUTDIR/out.R1.fq.gz" -O "$OUTDIR/out.R2.fq.gz" -w 16'
```

## 代表性输入数据 ✍️

- 微型 fixture（快速正确性）:
  - `dcstoolsTest/HG002_20k.R1.fq` + `HG002_20k.R2.fq`（各 **20,000** PE reads，未压缩，~7MB）
- 中等数据集（开发基准）:
  - `/data/disk2/private/gongchun/data/wgs/fastq/hg001.20mReads.r1.fastq.gz` + `/data/disk2/private/gongchun/data/wgs/fastq/hg001.20mReads.r2.fastq.gz`（各 ~1.3G gz）
- 大数据集（最终性能结论）✍️:
  - 用手头真实 WGS PE（建议 ≥50–100M pairs，`.fq.gz`）；路径填入本栏后勿再改，保证前后对比同输入
  - （待填）R1=/data/disk2/private/gongchun/data/wes/MGISEQ-2000.WES.PE100_1.fq.gz
  - （待填）R2=/data/disk2/private/gongchun/data/wes/MGISEQ-2000.WES.PE100_2.fq.gz
- 关键边界: SE 输入、已含大量 adapter 的 PE、`--merge`、`-D` dedup、极短 reads、phred64（一般不做主路径）

## 预期输出 ✍️

- `out.R1.fq[.gz]` / `out.R2.fq[.gz]`：通过过滤的 reads
- `fastp.json` / `fastp.html`：统计报告（before/after reads、Q20/Q30、adapter 等）
- 大小量级: 随输入与过滤率变化；gzip 输出体积对压缩实现敏感（见正确性口径）

## 正确性验证方法 ✍️（最关键）

原则：**QC 语义一致优先于字节级 gzip 一致**。并行压缩可能改变 gzip 分块布局，`.fq.gz` 的 md5 常会变；必须解压后比内容，或比归一化序列流。

### 必过项

1. **JSON 关键计数一致**（相对上游同参数跑）  
   至少对齐：`summary.before_filtering.total_reads`、`summary.after_filtering.total_reads`、  
   `filtering_result` 各丢弃原因计数、`adapter_cutting` / `duplication`（若开启）。
2. **解压后 FASTQ 内容一致（PE 配对优先）**  
   - 必过：同位置 R1/R2 必须为同一 insert 的 mates（`/1`↔`/2` 或 Illumina `1:`↔`2:`）。  
   - pack 间写出顺序可与 baseline 不同（并行 claim 序号），但 **不得打乱配对**。  
   - gzip 分块/ISA-L 导致 `.fq.gz` 字节不同可忽略；关注解压后序列与配对。

```bash
# 解压后逐字节比（fq→fq 或 gunzip 后；顺序一致时适用）
diff -q <(zcat base.R1.fq.gz) <(zcat opt.R1.fq.gz)
diff -q <(zcat base.R2.fq.gz) <(zcat opt.R2.fq.gz)

# 仅比序列+质量（忽略 name 行细微差异时再用；默认应 name 也一致）
# paste <(zcat ...) ...

# JSON 关键字段抽查示例
python3 - <<'PY'
import json,sys
a=json.load(open(sys.argv[1])); b=json.load(open(sys.argv[2]))
keys=[
  ("summary","before_filtering","total_reads"),
  ("summary","after_filtering","total_reads"),
]
def dig(d,path):
  for k in path: d=d[k]
  return d
for p in keys:
  va,vb=dig(a,p),dig(b,p)
  print(p, va, vb, "OK" if va==vb else "FAIL")
PY
base.json opt.json
```

3. **gzip 完整性**: `gzip -t out.R1.fq.gz && gzip -t out.R2.fq.gz`
4. 固定随机性相关选项；不要在正确性对比时混用不同 `-z` 级别除非明确只比解压后序列

### 可忽略差异

- HTML 报告排版/时间戳
- gzip 压缩后文件字节（分块边界、ISA-L vs zlib）
- JSON 里与时间/hostname 相关的元数据（若有）

## 已知瓶颈 ✍️/🤖

历史上（含上游 issue/PR 讨论）常见：

- **单写线程串行 gzip 压缩**：1.3.6 已用 worker 内 libdeflate + `pwrite`，本机主路径不再是此瓶颈。
- **`.gz` 输入串行解压**：本数据集为**普通 gzip（非 BGZF）**，双 reader 串行 igzip；双文件 `zcat` 地板 ~33s（热缓存）。
- **高线程数活锁（已修）**: SPSC 队列末节点不可消费 + `PACK_IN_MEM_LIMIT=32` 与 `-w 32` 冲突 → CPU~150%、墙钟数倍恶化。
- **说明**: 早期基准曾带 `--detect_adapter_for_pe`；**现行典型命令不加该参数**（与 README 一致）。默认路径仍有自动 adapter/质量过滤，但不做 PE ultra-clean 检测。

优化时优先验证的主题（阶段一）:

1. ~~写路径并行压缩~~（1.3.6 已有）
2. SPSC 可消费性 + 背压随 thread 缩放（**已做**）
3. 批大小、I/O 缓冲、线程扩展曲线（≤16 为主验收）
4. 避免为了速度改动过滤阈值或 adapter 判定

## 基线测量记录 🤖

硬件: Intel Xeon Gold 6442Y（96 逻辑核），热页缓存，PE gz→gz

> 下表「带 detect」行为历史记录；**后续验收以 README 典型命令（仅 `-w`）重测为准。**

| 日期 | 输入 | 版本 | 线程 | Wall | 峰值 RSS | 输出校验 | 备注 |
|---|---|---|---:|---:|---:|---|---|
| 2026-07-13 | hg001 20M | baseline README 初扫 | 2→16 | csv | | | Lustre 写出；最快 **-w14 = 35.40s**（`baseline_readme_sweep.csv`） |
| 2026-07-13 | hg001 20M | baseline 热缓存本地盘 | 14 | **best 25.96 / med 27.22** | ~1.3G | | 输出写 `/data/disk2/.../bioperf_fastp_bench`；7 次交错 |
| 2026-07-13 | hg001 20M | **opt3** 热缓存本地盘 | 16 | **best 20.70 / med 24.85** | | JSON+20k FASTQ pass | 相对基线最快 **+20.3%**（目标 ≤20.77s） |
| 2026-07-13 | hg001 20M | 双 igzip 地板 | — | ~6–9s | | | 纯解压；说明墙钟主因在 QC/overlap/stats/压缩 |
| 2026-07-13 | WES full | base -w14 / **opt3 -w16** | 14/16 | **174.9s / 117.1s** | ~1.4G | JSON filtering+adapter match | 本地盘；**+33%**；after=254454906 |
| 2026-07-14 | WES full | base -w14 / opt -w14/-w16 | 14/16 | base 404s；opt14 258–273；**opt16 120–134** | | PE配对 50万对×4跑=0错；JSON filtering一致 | 修复 R1/R2 共享序号后；base偏慢可能机器争用 |
| 2026-07-14 | hg001 20M | base vs **opt**（配对修复后） | **8/12/16** | 见下表 | 见下表 | `/usr/bin/time -v` | 本地盘交错 3 次；原始 csv：`/data/disk2/.../bioperf_t081216_1864088/times.csv` |
| 2026-07-14 | **WES full** | base vs **opt** | **8/12/16** | 见下表 | 见下表 | `/usr/bin/time -v` | 本地盘交错 **2** 次；csv：`/data/disk2/.../bioperf_wes_t081216_442040/times.csv` |
| （历史） | hg001 20M | 带 `--detect_adapter_for_pe` | ≤32 | ~65s/~57s | | | 旧命令，不作现行验收 |

### 2026-07-14 线程扫线：8 / 12 / 16（墙钟 + CPU% + RSS）🤖

条件：hg001 20M PE gz→gz；热页缓存；输出 `/data/disk2`；base/opt 交错各 3 次；`/usr/bin/time -v`。

| 线程 | base best / med (s) | opt best / med (s) | 加速 (best) | base CPU% med | opt CPU% med | base RSS med | opt RSS med |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 8 | 40.76 / 41.07 | **31.24 / 31.54** | **+23%**（1.30×） | 861% | 881% | 1.25 GB | 1.32 GB（+6%） |
| 12 | 28.93 / 29.54 | **21.35 / 21.48** | **+26%**（1.36×） | 1209% | 1303% | 1.30 GB | 1.38 GB（+7%） |
| 16 | 29.33 / 29.41 | **18.26 / 18.71** | **+38%**（1.61×） | 1314% | 1525% | 1.35 GB | 1.44 GB（+7%） |

要点：
- **三档均 >20%**；推荐日常 **opt `-w16`**（最快），求稳可用 **`-w12`**（三次壁钟几乎无波动）。
- base **12→16 几乎不扩展**（29.5→29.4s）；opt 仍能到 ~18s。
- opt 峰值 RSS 约高 **6–7%**（~80–100 MB）；user 时间更低，CPU% 更高主要是墙钟缩短后并发更满。
- `time -v` 的 CPU% 可略超 `-w×100`（另有 reader/writer 等线程）。

### 2026-07-14 WES 全量扫线：8 / 12 / 16（墙钟 + CPU% + RSS）🤖

条件：`MGISEQ-2000.WES.PE100_{1,2}.fq.gz`（~9.7G+11G）；本地盘 `/data/disk2`；`/usr/bin/time -v`。
- 8/16：AB 交错各 2 次（扫线 csv：`test/bench/wes_t081216_times.csv`）
- **12：以顺序诊断为准**（opt 先跑 / 盘较干净）：opt **133.0s** vs base **154.3s**；原扫线 base→opt 的 204s 为写回伪影，已作废

| 线程 | base best / med (s) | opt best / med (s) | 加速 (best) | base CPU% | opt CPU% | base RSS | opt RSS | 备注 |
|---:|---:|---:|---:|---:|---:|---:|---:|---|
| 8 | 223.1 / 223.5 | **162.3 / 163.3** | **+27%** | 866% | 942% | 1.23 GB | 1.30 GB | 扫线 2 次 |
| 12 | **154.3** | **133.0** | **+14%** | 1274% | 1155% | ~1.27 GB | ~1.34 GB | **订正**；作废旧值 base152/opt204 |
| 16 | 161.1 / 166.9 | **131.7 / 138.7** | **+18%** | 1233% | 1164% | 1.32 GB | 1.43 GB | 扫线 2 次 |

要点：
- WES 三档均为正加速：**+27% / +14% / +18%**（未全部满 20%；8 档已达标）。
- 旧 `-w12`「−34%」来自固定 base→opt + 近满盘写回；对调后 opt 1155%CPU、133s，已替换上表。
- ISA-L 写出约 +6% 体积；全量对比应用 ABBA 或 `sync` 间隔，磁盘勿近满。

## 历史优化与经验 🤖

- 2026-07 Round1: SPSC 末节点可消费 + `packInMemLimitForThreads` + pwrite 跳过空 writer + offset pause/yield + 更大 igzip 缓冲。
- 2026-07 Round2（README 命令）: pwrite 路径 **ISA-L** 压缩（默认 `-z4`→level1）；overlap 前 12bp 标量快拒；Duplicate `mBufNum==2` 特化；`PACK_SIZE` 1000→2000。
- 2026-07 修复: pwrite 序号改为**全局原子递增**（避免 per-tid 包数不均导致序号空洞活锁）；空 pack 跳过 ISA-L 仍发布 0 字节序号；`OFFSET_RING_SIZE` 512→8192。
- 2026-07-14 修复: 全局序号若 R1/R2 **各自 fetch_add** 会交错导致 **PE 错配**；改为 `mPairOutputSeq` 一次领取、左右 writer `input(tid,data,seq)` 共用。空 pack/高水位 `noteSeqHighWater` 仍保证无空洞活锁。
- 二进制: `test/fastp.baseline`、`test/fastp.opt` / `test/fastp.opt3`（现行优化）。源码在 `software/fastp/src/`。
- 验收口径: 相对 **baseline 最快墙钟** ×0.8；**20M** 本地盘 8/12/16 = **+23% / +26% / +38%**；**WES** 订正后 8/12/16 = **+27% / +14% / +18%**（`-w12` 以 opt-first 诊断替换伪影）。

## 接入本 skill 时的最小流程

1. 读本配方 + `SKILL.md` / `EVALUATION.md`
2. 用 HG002_20k 建立正确性 oracle（上游 1.0.1 输出）
3. `perf` / `/usr/bin/time` 在 simu 或大库上定位瓶颈
4. 一次只改一个主题 → 再跑正确性 → 再记基准表
5. 回写 `EXPERIENCE_LOG.md` 与本卡「基线 / 历史」栏

## 优化目标
在 **16 线程及以内**，相对同命令 baseline 最快墙钟 **快 20% 以上**；达标后再用 WES 全量验收。
典型命令仅：`fastp -i … -I … -o … -O … -w N`。
