# workflows/ — 预置工作流目录

把你在 ComfyUI 里调好的工作流 JSON（菜单 Workflow → Export）放到这个目录，
然后重新 `docker build`，它们就会被烘焙进镜像。

镜像启动时会自动把这些 JSON 同步到 `user/default/workflows/`（不覆盖同名文件），
在左侧 Workflows 面板即可看到。

## 2D 动画生产管线建议固化的工作流

| 文件名 | 用途 | 模式 | 基础模板 / 改法 |
|---|---|---|---|
| `wan22_i2v_anime.json` | 主力：首帧→动画 | dual 快速迭代 | 模板库 → Wan2.2 i2v 14B + Anime Style LoRA（低噪侧）+ lightx2v，steps 8 |
| `wan22_i2v_anime_quality.json` | 主力：定稿精出 | split + CFG Split | 同上去掉 lightx2v，cfg 3.5，分辨率 720p |
| `wan22_flf_anime.json` | 两张关键帧补中间动画 | 按档位 | Wan2.2 i2v 首尾帧模板 + Anime LoRA |
| `wan22_animate.json` | 角色动作迁移（角色图+参考视频） | dual | 模板库 → Wan2.2 Animate；首跑自动下载 DWPose 姿态模型 |
| `wan21_smoke.json` | 冒烟测试 | 任意 | 模板库 → Video → Wan2.1 t2v 1.3B |

## CFG Split 接入方法（仅质量档工作流）

在「模型加载链（UNETLoader → LoRA → …）的最后一环」与「采样器」之间插入内置节点
`MultiGPU CFG Split`，节点参数 `max_gpus = 2`。要求：

- 运行实例必须能看到两张同型号卡（即 split 模式的 `comfyui-dual` 容器）；
- 采样器 cfg > 1（cfg=1 的蒸馏工作流无收益，用 dual 双实例跑）。

## 2D 动画工作流要点

- 写实偏置对抗：Anime Style LoRA 强度 1.0–1.2，负向提示词加 `realistic`；
- 「逐格感」出不来是模型特性：想要日式 on-twos 卡顿感，用 stop-motion 类 LoRA 或
  生成后隔帧抽帧，RIFE 插帧节点用于反向需求（把稀疏关键帧补顺）；
- 大幅度编排在舒适区外，微动/走动/表情/风吹类小动作用 i2v，整段表演用 Animate 动作迁移。
