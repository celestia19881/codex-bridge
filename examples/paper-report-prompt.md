# The prompt that worked

Produced a 4,748-character Chinese literature report from a 20-page paper in 556 s, zero fabricated numbers. The annotations explain why each block is there — copy the blocks, not the topic.

```text
你是我的助手，现在替我完成一项"替人干活"的任务：精读一篇英文论文，写一份中文文献汇报稿，并生成 Word 文档。

## 权限说明（重要，先读）
你的沙箱是 **workspace-write**：`<WORKDIR>` 下的文件**可以自由创建和修改**，这是本任务明确要求的，不构成越权。请不要因为"只读"顾虑而拒绝写文件；如果某次写入报错，换个写法重试（例如先写到当前目录再移动），不要直接放弃任务。

## 你的输入
1. 论文全文文本（已由我提取，可直接读取）：`<WORKDIR>\paper.txt`
2. 如需原始 PDF：`<PATH>\paper.pdf`（如需转图请先告知，不要自行安装软件）
3. 排版工具（我已备好，直接调用即可）：`<WORKDIR>\tools\md2docx.py`
   用法：`python tools/md2docx.py 输入.md 输出.docx --subtitle "副标题" --author "汇报人：XXX"`
   它已处理中文字体（宋体正文/黑体标题）、1.5 倍行距、首行缩进、表格、列表、引用块、代码块。

## 要做什么
通读全文，理解研究问题、方法与实验，然后写一份**可以直接拿去组会讲**的中文文献汇报稿。

## 内容要求（按此顺序组织）
1. 研究背景和意义
2. 当前研究综述（把论文引用的工作按技术路线归类，不要逐条罗列）
3. 论文的中心思想（一句话能说清的核心主张）
4. 发现的 question 与现有研究的技术 challenge
5. 核心 observation / insight / opportunity（论文看到了什么别人没看到的）
6. 技术方案（讲清设计，含关键公式与符号，但用文字解释其含义）
7. 主要创新点与贡献（相对已有工作的差异，不是自夸复述）
8. 实验结果与讨论（关键数字、对比基线、消融；**数字要能对上图表号**）
9. 结论与启示（对我们自己的研究有什么可借鉴的）

## 硬性约束
- 中文，约 4500–6500 汉字；不要写摘要式流水账，要有"汇报人自己的判断"。
- **不许编造**任何数字、引用、图表号。论文没写的就写"论文未报告"。
- 关键论断后面标出处，例如（Sec. IV-C）、（Fig. 8）、（TABLE IV）。
- 专业术语首次出现时给中英对照，例：低地球轨道（Low Earth Orbit, LEO）。
- 不要照抄原文长句，用你自己的话复述。

## 输出
1. `<WORKDIR>\report.md` — 汇报稿的 markdown 全文
2. `<WORKDIR>\report.docx` — 用上面的工具转出的 Word 文档
3. 完成后运行校验并把统计结果贴出来：`python tools/md2docx.py report.md report.docx` 会打印 `paragraphs=... tables=... chars=...`

## 回复格式
1. 一句话说明生成了什么（汉字数）
2. 两个文件的绝对路径
3. 校验命令的原始输出
4. 五行以内说明你写了哪几部分
5. 若发现论文本身有明显问题（数字对不上、口径不一致、引用错位），单独列出——这比复述摘要更有价值
```

## Why each block exists

| Block | Guards against |
|---|---|
| 权限说明 | codex self-censoring into a read-only summary (cost: one 250 s run) |
| 输入 with absolute paths | codex guessing at your toolchain, or re-extracting the PDF badly |
| 排版工具 + usage | it inventing its own docx conversion, or installing packages |
| 内容要求 1–9 | generic summaries; the numbered structure is what makes it presentable |
| 数字要能对上图表号 | confident prose with numbers that belong to a different experiment |
| 不许编造 / "论文未报告" | hallucinated tables — this is what kept the report honest |
| 标出处 | unverifiable claims |
| 校验命令 + 贴输出 | silent failures where the file is empty or truncated |
| 单独列出论文问题 | the highest-value part: it found three real errors |

## What it produced beyond the brief

The last instruction is the highest-leverage line. On the source paper it surfaced:

- a "时延下降 103%" claim that cannot be true by the usual definition of a percentage decrease;
- an equation `X̃ = M ⊙ X + (1−M) ⊙ stopgrad(X)` whose forward pass still equals `X`, contradicting the described sparsification;
- "200 种拆分全部在 1% 内" while the same paragraph reports ~6 splits dropping 1.0–1.5 percentage points;
- a 71.7% communication saving that appears only in the introduction, with no table able to reproduce it;
- a headline about **LLM** inference whose experiments are all **ViT** image classification.

Ask for that explicitly, and verify it. Do not forward such claims without checking them against the PDF yourself.
