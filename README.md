# ComfyUI 视频工作流镜像（2× RTX 4090 定版）

构建一个自带视频生成环境的 ComfyUI Docker 镜像：固定版本代码 + 视频节点 + 预置工作流，
模型走挂载卷。同一镜像兼容 4090（sm_89）与 V100（sm_70），两种 GPU 机器均可直接部署。

## 硬件适配结论

| 决策 | 原因 |
|---|---|
| 基础镜像 `pytorch/pytorch:2.7.1-cuda12.6-cudnn9-runtime` | cu126 轮子同时覆盖 4090（sm_89）与 V100（sm_70），一套镜像跨机型复用；CUDA 13 已移除 Volta，跨机型时不要升 cu13x |
| 主力模型 **Wan 2.2 14B fp8**（t2v + i2v） | 4090 有 fp8 tensor core，fp8_scaled 模型原生计算（V100 则自动转 fp16 计算）；24GB 装不下双专家全量也无妨，ComfyUI 在高/低噪两阶段间自动换入换出（本就串行使用） |
| 镜像内置 SageAttention 1.0.6 | 配合 `--use-sage-attention` 在 4090 上提速 10–30%，默认关闭 |
| 双卡不开双实例时才用 CFG Split | ComfyUI 内置 MultiGPU CFG Split 节点：同构卡（4090×2 ✓）+ cfg>1 时，单条视频最高 ~1.9× 加速 |

## 双卡运行模式（核心设计）

| 模式 | 启动命令 | 形态 | 适用 |
|---|---|---|---|
| **dual**（默认） | `docker compose up -d` | 双实例各占一卡，端口 8188 / 8189，模型卷共享、用户状态隔离 | 快速档工作流（lightx2v，cfg=1）——CFG Split 对 cfg=1 无效，靠双实例提吞吐 |
| **split** | `docker compose --profile split up -d` | 单实例占双卡 | 质量档工作流（cfg 3.5）：在模型加载链与采样器之间插入内置 `MultiGPU CFG Split` 节点（max_gpus=2），单条 720p 从 15–30 分钟压到 8–15 分钟 |

两种模式互斥（GPU 分配冲突），用 `.env` 里 `COMPOSE_PROFILES` 或命令行 `--profile` 切换。
推荐把「质量版工作流（带 CFG Split）」和「快速版工作流」都固化进镜像，按需选模式。

## 性能预期（Wan 2.2 14B fp8，81 帧 5 秒）

| 配置 | 480p | 720p |
|---|---|---|
| dual 模式单实例（≈1×4090）质量档 | 5–8 分钟 | 15–30 分钟 |
| dual 模式两条并行（吞吐 ×2） | 每条 5–8 分钟 | 每条 15–30 分钟 |
| split 模式 CFG Split 质量档 | 3–5 分钟 | 8–15 分钟 |
| 快速档（lightx2v 8 步） | 1–2 分钟 | 2–5 分钟 |

## 目录结构

```
comfyui-video/
├── Dockerfile               # 四层镜像：基础环境→ComfyUI→视频节点→工作流
├── docker-compose.yml       # dual/split 双模式、GPU 绑定、健康检查
├── .env.example             # 构建与运行参数（复制为 .env）
├── entrypoint.sh            # 启动脚本（同步预置工作流→启动服务）
├── workflows/               # 你的工作流 JSON，烘焙进镜像
└── scripts/
    └── download_models.sh   # 模型下载（hf-mirror，断点续传）
```

## 使用步骤（在 2×4090 服务器上）

```bash
# 0. 前置（仅首次）：安装 nvidia-container-toolkit 并重启 docker
#    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

# 1. 构建镜像（国内网络加: --build-arg GIT_PREFIX=https://gh-proxy.com/https://github.com/）
docker compose build

# 2. 下载模型（支持断点续传；先只下 smoke 套件可快速冒烟）
./scripts/download_models.sh smoke      # Wan2.1 1.3B，先跑通
./scripts/download_models.sh i2v        # Wan2.2 14B 图生视频（2D 动画主力，必下）
./scripts/download_models.sh t2v        # Wan2.2 14B 文生视频（可选）
./scripts/download_models.sh animate    # Wan2.2-Animate 动作迁移全套（2D 动画）
./scripts/download_models.sh lora       # lightx2v 加速 LoRA（推荐）
# 动漫风格 LoRA（Civitai 需令牌，见 workflows/README）:
export CIVITAI_TOKEN=<你的令牌> ANIME_LORA_URL=<模型页下载链接>
./scripts/download_models.sh anime_lora

# 3. 启动（默认 dual 模式：8188 主创作 + 8189 第二工作流）
docker compose up -d
docker compose logs -f comfyui-a     # 看到 "To see the GUI go to" 即成功
```

## 首次验证流程

1. **冒烟**：8188 → 模板库 → Video → Wan 2.1 1.3B t2v → Queue。
2. **主力**：模板库 → Video → Wan 2.2 t2v 14B → Queue，480p×81 帧先验证。
3. **双卡验证**：质量工作流插入 MultiGPU CFG Split 节点后切 split 模式跑一次，
   对比时间应接近减半；快速工作流在 8188/8189 各排一条任务，确认并行。
4. 加速：挂 lightx2v LoRA（steps 8、cfg 1），速度提升 3–5 倍。

## 2D 动画生产管线（本镜像的主场景)

```
① 关键帧        手绘 / 动漫图像模型生成首帧（可选尾帧）
② 动起来        Wan2.2 14B i2v + Anime Style LoRA + lightx2v 快速抽卡（dual 双实例）
③ 定稿          去掉加速 LoRA，cfg 3.5 + CFG Split 精出（split 模式，720p）
④ 表演级动作    Wan2.2-Animate：角色图 + 参考视频 → 复刻表情与动作（含重光照）
⑤ 后处理        RIFE 插帧（原生节点，models/frame_interpolation）
```

- **风格**：Wan2.2 写实偏置强，2D 质感必须挂 Anime Style LoRA（强度 1.0–1.2，
  负向词加 `realistic`）；想要逐格卡顿感用 stop-motion LoRA 或隔帧抽帧。
- **动作分配**：微动/走动/表情/风吹交给 i2v；整段舞蹈、武打等大表演交给
  Animate 动作迁移（拿实拍视频当表演参考）。
- **关键帧**：手绘、已有素材，或在 ComfyUI 里用动漫图像模型生成（属图像侧，按需加装）。

## 固化成镜像（核心目标）

在 UI 里把工作流调好后：

```bash
# 1. 导出 JSON 到 workflows/（如 wan22_t2v_14b_cfgsplit.json、wan22_t2v_fast.json）
# 2. 重建并打版本 tag
docker compose build
docker tag comfyui-video:v0.34.0-cu126-4090x2 comfyui-video:v1.0-wan22
# 3a. 有 registry 就推送
docker push <registry>/comfyui-video:v1.0-wan22
# 3b. 没有 registry 就导出文件分发（压缩后约 4–4.5GB，解压态 9–11GB）
docker save comfyui-video:v1.0-wan22 | gzip > comfyui-video-v1.0.tar.gz
# 目标机: docker load < comfyui-video-v1.0.tar.gz
```

之后任何机器：导入镜像 → `docker compose up -d` → 挂 `models/` 卷即用。
升级镜像时**不要动 models/ 卷**，资产与镜像解耦。

## 程序化调用（可选）

工作流 JSON 里改 `"title"` 的节点参数后可直接走 API；dual 模式下可用 8188/8189
两个端点做简单负载轮询：

```bash
curl -X POST http://127.0.0.1:8189/prompt -H 'Content-Type: application/json' \
  -d '{"prompt": <工作流JSON>, "client_id": "demo"}'
# 配合 WebSocket /ws?clientId=demo 收进度与产出
```

## 镜像构建：在阿里云进行（GitHub 仅作代码仓库）

分工：GitHub 存代码 → 阿里云构建并产出镜像 → GPU 服务器从 ACR 拉取。
GitHub 侧**无需启用 Actions**（备用 workflow 已存为
`.github/workflows/docker-build.yml.off`，想用 GitHub 构建时把后缀改回 `.yml` 即可）。

### 方案 A（推荐）：ACR 个人版自带的「镜像构建」

不引入任何额外服务，ACR 仓库自带代码源绑定和自动构建：

1. ACR 控制台 → 镜像仓库 → 仓库详情 → **构建** → 绑定代码源（GitHub 授权）
2. 添加构建规则：分支 `main`、Dockerfile 路径 `/`、
   标签生成「分支名-提交ID短格式」，勾选**代码变更时自动构建**
3. 之后 push 到 GitHub 即自动构建出镜像，服务器 `docker compose pull` 更新

**基础镜像转存（建议做）**：ACR 构建机拉取 Docker Hub 基础镜像可能慢或不稳，
先把它转存进你的 ACR（在 ACR 控制台先建仓库 `pytorch-base`，然后任意一台能
访问 Docker Hub 的机器执行）：

```bash
# 登录你的个人版实例（用户名/固定密码见 ACR 控制台「访问凭证」）
docker login crpi-9pf9lin5vvnxq7uh.cn-hangzhou.personal.cr.aliyuncs.com

docker pull pytorch/pytorch:2.7.1-cuda12.6-cudnn9-runtime
docker tag pytorch/pytorch:2.7.1-cuda12.6-cudnn9-runtime \
  crpi-9pf9lin5vvnxq7uh.cn-hangzhou.personal.cr.aliyuncs.com/ininyumo/pytorch-base:2.7.1-cu126-cudnn9
docker push crpi-9pf9lin5vvnxq7uh.cn-hangzhou.personal.cr.aliyuncs.com/ininyumo/pytorch-base:2.7.1-cu126-cudnn9
# 然后把 Dockerfile 里 ARG BASE_IMAGE 换成上述 ACR 地址（文件里已备好注释行）
```

局限：ACR 构建只有构建动作，**没有冒烟测试环节**——首次出镜像后手动
`docker compose up -d` 看 logs 确认即可（后续版本基本不会坏构建）。

### 方案 B：云效 Flow（想保留自动化冒烟测试时）

阿里云 [云效](https://www.aliyun.com/product/yunxiao) DevOps 个人版免费：
代码源绑定 GitHub → 流水线「构建 → `docker run` CPU 冒烟（curl `/system_stats`）→
推 ACR」。构建机在阿里云国内，推 ACR 走内网秒级。适合在意「坏镜像不能推出去」
这道闸门的情况；免费额度对单人使用足够（有并发/时长限制，构建 10–20 分钟无压力）。

### 方案 C（兜底）：服务器本地构建

最简单可靠，适合单机：服务器上 `git pull && docker compose build`（可包成脚本或
cron）。构建在本机完成没有传输，还能顺手做真 GPU 冒烟。缺点是构建占用 GPU 机
资源、多机部署时每台都要拉代码。

三种方案可组合：日常用 A，重要版本发布前在服务器上跑一次 C 做真 GPU 验证。

## 常见问题

- **下载 404**：模型仓库名或文件名有更新，去 `https://hf-mirror.com/Comfy-Org/Wan_2.2_ComfyUI_Repackaged` 核对。
- **Animate 工作流第一次跑很慢**：DWPose 姿态模型（约 400MB）在首跑时经 hf-mirror 自动下载，之后正常。
- **anime_lora 报错缺 token**：Civitai 下载需登录令牌，见 `scripts/download_models.sh` 头部注释。
- **构建时 git clone 失败**：加 `--build-arg GIT_PREFIX=https://gh-proxy.com/https://github.com/`。
- **CFG Split 没有加速**：检查工作流 cfg 是否 >1（lightx2v 等 cfg=1 工作流无效）、两卡是否同型号、节点是否放在模型链最后一级与采样器之间。
- **两实例抢显存/模型重复加载**：正常现象（每卡各一份），fp8 双专家 24GB 可承载；如 OOM 再 `--lowvram`。
- **页面打不开但容器健康**：确认安全组/防火墙放行 8188、8189 端口。
