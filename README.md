# ComfyUI 视频工作流镜像（单卡 RTX 5090 定版）

构建一个自带视频生成环境的 ComfyUI Docker 镜像：固定版本代码 + 视频节点 + 预置工作流，
模型走挂载卷。目标硬件：**单卡 NVIDIA RTX 5090（32GB / Blackwell sm_120）+ 90GB 内存**。

## 硬件适配结论

| 决策 | 原因 |
|---|---|
| 基础镜像 `pytorch/pytorch:2.12.1-cuda13.0-cudnn9-runtime`（ACR 转存为 `pytorch-base:2.12.1-cu130-cudnn9`） | Blackwell sm_120 需要 cu128+，cu126 轮子没有 5090 内核；cu130 + torch 2.12.1；pytorch 官方 cu128/cu130 镜像全系 Ubuntu 24.04 底座。CUDA 13 移除了 Volta——**V100 已出局**（旧 tag `v0.34.0-cu126-4090x2` 仍可跑 4090/V100 老机器） |
| 主力模型 **Wan 2.2 14B fp8**（t2v + i2v） | 5090 原生 fp8 tensor core；32GB 显存下双专家（约 30GB）接近全驻留，步数边界基本免换卡；90GB 内存非常充裕 |
| 镜像内置 SageAttention 1.0.6 | triton 实现；torch 2.9 + sm_120 组合**需首跑验证**，启动日志出现 "Using sage attention" 才算生效，报错就先不开 |
| CFG Split 随双卡方案退役 | 单卡无 CFG Split；质量档=全量步数，快速档=lightx2v 4 步 LoRA（预置工作流已同步更新） |

## 运行模式

单实例单卡，端口 8188，`docker compose up -d` 即可，没有模式切换。
质量档和快速档的区别在**工作流**而不是部署：两版工作流都已预置。

## 性能预期（Wan 2.2 14B fp8，81 帧 5 秒 @16fps；5090 按 4090 的 ~1.5 倍估算）

| 配置 | 480p | 720p |
|---|---|---|
| 质量档（全量 20 步） | 3-6 分钟 | 10-18 分钟 |
| 快速档（lightx2v 4 步，cfg 1） | <1 分钟 | 1.5-3 分钟 |

## 目录结构

```
comfyui-video/
├── Dockerfile               # 四层镜像：基础环境→ComfyUI→视频节点→工作流
├── docker-compose.yml       # 单实例单卡、GPU 绑定（镜像健康检查继承自 Dockerfile）
├── .env.example             # 构建/运行参数（复制为 .env）
├── pytorch-base/Dockerfile  # 一行 FROM：ACR 海外构建转存基础镜像用
├── entrypoint.sh            # 启动脚本（同步预置工作流→启动服务）
├── workflows/               # 你的工作流 JSON，烘焙进镜像
└── scripts/
    └── download_models.sh   # 模型下载（hf-mirror，断点续传）
```

## 使用步骤（在 5090 服务器上）

```bash
# 0. 前置（仅首次）：安装 nvidia-container-toolkit 并重启 docker
#    https://docs.nvidia.com/datacenter/cloud-native/container-toolkit/install-guide.html

# 1. 镜像：构建在 ACR 控制台进行（本机与服务器都不构建）。
#    首次换基础镜像前先做「基础镜像转存」（见下方方案 A），然后 ACR 海外构建主镜像。
#    服务器上只拉取：
docker compose pull

# 2. 下载模型（支持断点续传；先只下 smoke 套件可快速冒烟）
./scripts/download_models.sh smoke      # Wan2.1 1.3B + 文本编码器 + VAE，先跑通
./scripts/download_models.sh i2v        # Wan2.2 14B 图生视频（2D 动画主力，必下）
./scripts/download_models.sh t2v        # Wan2.2 14B 文生视频（可选）
./scripts/download_models.sh animate    # Wan2.2-Animate 动作迁移全套（2D 动画）
./scripts/download_models.sh lora       # lightx2v 加速 LoRA（推荐）
# 动漫风格 LoRA（Civitai 需令牌，见 workflows/README）:
export CIVITAI_TOKEN=<你的令牌> ANIME_LORA_URL=<模型页下载链接>
./scripts/download_models.sh anime_lora

# 3. 启动
docker compose up -d
docker compose logs -f comfyui      # 看到 "To see the GUI go to" 即成功
```

## 首次验证流程

1. **冒烟**：模板库 → Video → Wan 2.1 1.3B t2v → Queue。
2. **主力**：模板库 → Video → Wan 2.2 i2v 14B → Queue，480p×81 帧先验证。
3. **两档对比**：预置的快速档与质量档工作流各跑一条，记录时间差；顺手验证
   `--use-sage-attention`（先关跑一条，再开跑一条，报错即关闭）。

## 2D 动画生产管线（本镜像的主场景)

```
① 关键帧        手绘 / 动漫图像模型生成首帧（可选尾帧）
② 动起来        Wan2.2 14B i2v + Anime Style LoRA + lightx2v 快速抽卡（快速档）
③ 定稿          去掉加速 LoRA，cfg 3.5 全量步数精出（质量档，720p）
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
# 1. 导出 JSON 到 workflows/ 并 commit
# 2. push 到 GitHub → ACR「海外机器构建」出镜像（tag 在 ACR 构建规则里定，如 v1.0-wan22）
# 3. 服务器: docker compose pull 更新
# 兜底（ACR 不可达的目标机）：在能登录 ACR 的机器上导出文件分发
docker save <ACR完整路径:tag> | gzip > comfyui-video.tar.gz
# 目标机: docker load < comfyui-video.tar.gz
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

### 方案 A（主路径）：ACR 个人版自带的「镜像构建」

不引入任何额外服务，ACR 仓库自带代码源绑定和自动构建：

1. ACR 控制台 → 镜像仓库 → 仓库详情 → **构建** → 绑定代码源（GitHub 授权）
2. 添加构建规则：分支 `main`、Dockerfile 路径 `/`、
   标签生成「分支名-提交ID短格式」，勾选**代码变更时自动构建**
3. 之后 push 到 GitHub 即自动构建出镜像，服务器 `docker compose pull` 更新

**基础镜像转存（首次换 cu130 基础镜像时必做）**：ACR 构建机直拉 Docker Hub
慢且不稳，用 ACR 自己转存自己——仓库里已备好一行 Dockerfile
（`pytorch-base/Dockerfile`，内容就是 `FROM pytorch/pytorch:2.12.1-cuda13.0-cudnn9-runtime`）：

1. ACR 控制台先建仓库 `pytorch-base`
2. 该仓库 → 构建 → 绑定同一代码源，添加规则：分支 `main`、
   Dockerfile 路径 `pytorch-base/Dockerfile`、tag `2.12.1-cu130-cudnn9`
3. 触发「海外机器构建」→ `pytorch-base:2.12.1-cu130-cudnn9` 进入你的 ACR
4. 主 Dockerfile 的 `BASE_IMAGE` 默认已指向它，正常构建主镜像即可

局限：ACR 构建只有构建动作，**没有冒烟测试环节**——首次出镜像后手动
`docker compose up -d` 看 logs 确认即可（后续版本基本不会坏构建）。

### 方案 B：云效 Flow（想保留自动化冒烟测试时）

阿里云 [云效](https://www.aliyun.com/product/yunxiao) DevOps 个人版免费：
代码源绑定 GitHub → 流水线「构建 → `docker run` CPU 冒烟（curl `/system_stats`）→
推 ACR」。构建机在阿里云国内，推 ACR 走内网秒级。适合在意「坏镜像不能推出去」
这道闸门的情况；免费额度对单人使用足够（有并发/时长限制，构建 10–20 分钟无压力）。

### 方案 C（备用）：ECS / 服务器上构建

推荐在阿里云 ECS（2核4G 起，磁盘余量 ≥25GB）上构建——阿里云网络下 pip/镜像拉推都是内网速度，且无构建时长限制：

```bash
git clone https://github.com/Yimoyumo/video-workflow.git && cd video-workflow
./scripts/build-on-ecs.sh        # 一键：磁盘检查 → 构建 → 推送 ACR
```

脚本自动处理：磁盘/swap 检查、ACR 登录校验、构建（断点续传）、推送。
ECS 与 ACR 同地域时拉推走 VPC 内网，不占公网带宽。

### 方案 D（兜底）：本机或任意机器构建后推送

`docker build -t <ACR完整路径:tag> . && docker push`——Dockerfile 已内置
断点续传/停滞熔断/双源兜底，弱网可磨穿，只是耗时随网络质量浮动。

## 常见问题

- **下载 404**：模型仓库名或文件名有更新，去 `https://hf-mirror.com/Comfy-Org/Wan_2.2_ComfyUI_Repackaged` 核对。
- **ACR 构建注意事项**：个人版构建超时 30 分钟（pip 慢导致超时可开「海外机器构建」）；
  基础镜像支持同地域同账号的私有仓库（我们的 pytorch-base 满足）；「不使用缓存」保持关闭。
- **Animate 工作流第一次跑很慢**：DWPose 姿态模型（约 400MB）在首跑时经 hf-mirror 自动下载，之后正常。
- **anime_lora 报错缺 token**：Civitai 下载需登录令牌，见 `scripts/download_models.sh` 头部注释。
- **构建时 git clone 失败**：加 `--build-arg GIT_PREFIX=https://gh-proxy.com/https://github.com/`。
- **5090 上开 SageAttention 报错**：torch 2.9 + sm_120 组合未充分验证，报错就把
  `.env` 的 `COMFY_EXTRA_ARGS` 清空（sage 只是提速项，不影响出片）。
- **老 4090 / V100 机器**：继续用旧 tag `v0.34.0-cu126-4090x2`（cu126 覆盖
  sm_89/sm_70）；cu13x 镜像跑不了 V100。
- **页面打不开但容器健康**：确认安全组/防火墙放行 8188 端口；ComfyUI 无鉴权，
  建议只走 SSH 隧道或安全组限源 IP，不要裸暴露公网。
