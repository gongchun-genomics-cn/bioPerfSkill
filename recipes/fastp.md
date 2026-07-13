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

基线二进制与常用 PE 命令（与生产接近：开 adapter 检测、默认质量/长度过滤、gzip 输出）:

```bash
FASTP=/zdswhst2/ST_BIOINTEL/P24Z32400N0004/gongchun/software/fastp
OUTDIR=/zdswhst2/ST_BIOINTEL/P24Z32400N0004/gongchun/project/bioPerfSkill/test/bioperf_fastp_$$   # 换成你的工作目录
mkdir -p "$OUTDIR"

# 推荐主场景：PE gz → gz（压缩写往往是瓶颈）
"$FASTP" \
  -i "$R1" -I "$R2" \
  -o "$OUTDIR/out.R1.fq.gz" -O "$OUTDIR/out.R2.fq.gz" \
  -w 8 \
  -j "$OUTDIR/fastp.json" -h "$OUTDIR/fastp.html" \
  --detect_adapter_for_pe

# 对照场景：PE fq → fq（弱化压缩，观察解析/QC 是否成为瓶颈）
"$FASTP" -i "$R1" -I "$R2" -o "$OUTDIR/out.R1.fq" -O "$OUTDIR/out.R2.fq" -w 8 \
  -j "$OUTDIR/fastp.json" -h "$OUTDIR/fastp.html"

# 快速冒烟：只处理前 N pair
"$FASTP" -i "$R1" -I "$R2" -o "$OUTDIR/s.R1.fq.gz" -O "$OUTDIR/s.R2.fq.gz" \
  -w 4 --reads_to_process 100000 -j "$OUTDIR/s.json" -h "$OUTDIR/s.html"
```

测量包装（与 skill 一致）:

```bash
/usr/bin/time -v -o "$OUTDIR/time.txt" \
  bash -c '"$FASTP" ... ; sync'   # 或 scripts/collect_perf_snapshot.sh
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
2. **解压后 FASTQ 内容一致**（顺序敏感：默认输出顺序须与上游一致；若优化改变了写出序，须先证明对下游无影响并在此写明，否则视为失败）

```bash
# 解压后逐字节比（fq→fq 或 gunzip 后）
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

- **单写线程串行 gzip 压缩**：`-w` 加大后 worker 很快喂饱 writer，墙钟不降（作者亦称 >8–16 线程常无收益）。
- **`.gz` 输入串行解压**：读者跟不上多 worker。
- **I/O 上限**：冷缓存、网络盘上表现为低 CPU、高 iowait——优化前先分清冷/热缓存。
- 近期上游已有「worker 内并行压缩 + `pwrite`」「BGZF 并行解压」类 PR；**本 skill 用例以本机 1.3.6 为基线**，优化方向可与之对照，但验收仍走本配方正确性口径。

优化时优先验证的主题（阶段一）:

1. 写路径：压缩移出单写线程 / 有序并行写（注意顺序与背压）
2. 读路径：并行解压或更大读缓冲
3. 批大小、压缩级别 `-z`、线程扩展曲线 1/4/8/16/32
4. 避免为了速度改动过滤阈值或 adapter 判定

## 基线测量记录 🤖

| 日期 | 硬件 | 输入 | 场景 | 线程 | Wall | 峰值 RSS | 输出校验 | 备注 |
|---|---|---|---|---:|---:|---:|---|---|
| （待跑） | | HG002_20k | fq→fq | 4 | | | | 冒烟 |
| （待跑） | | 20m | gz→gz | 8 | | | | 开发基准 |
| （待跑） | | wes | gz→gz | 1/4/8/16/32 | | | | 最终结论；冷/热分列 |

## 历史优化与经验 🤖

- （尚无；完成后追加到 `EXPERIENCE_LOG.md`，并在此留一行摘要）

## 接入本 skill 时的最小流程

1. 读本配方 + `SKILL.md` / `EVALUATION.md`
2. 用 HG002_20k 建立正确性 oracle（上游 1.0.1 输出）
3. `perf` / `/usr/bin/time` 在 simu 或大库上定位瓶颈
4. 一次只改一个主题 → 再跑正确性 → 再记基准表
5. 回写 `EXPERIENCE_LOG.md` 与本卡「基线 / 历史」栏

## 优化目标
在32线程及以下，比基线运行速度快20%以上