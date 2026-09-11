# ============================================================
# ComfyUI AI 视频生成工作流镜像（目标 GPU: 单卡 RTX 5090 32GB / Blackwell sm_120）
# 栈：ComfyUI v0.35.0 + pytorch/pytorch:2.12.1-cuda13.0-cudnn9-runtime
#     （Ubuntu 24.04 底座，pytorch 官方 cu128/cu130 镜像全系 24.04）
# 注意：CUDA 13 移除了 Volta——cu13x 镜像跑不了 V100；
# 老 4090/V100 机器用旧 tag v0.34.0-cu126-4090x2
# ============================================================
# 基础镜像已转存至 ACR（构建机内网拉取，快且稳）；转存方法见 README「基础镜像转存」。
# 本地手动构建可临时改回 pytorch/pytorch:2.12.1-cuda13.0-cudnn9-runtime
ARG BASE_IMAGE=crpi-9pf9lin5vvnxq7uh.cn-hangzhou.personal.cr.aliyuncs.com/ininyumo/pytorch-base:2.12.1-cu130-cudnn9

FROM ${BASE_IMAGE}

# pytorch 2.12+ 官方镜像弃用 conda，改用 Ubuntu 系统 Python（PEP 668 externally-managed），
# 不移除标记则一切裸 pip install 被拒；旧 conda 底座（2.7.1 系）无此限制
RUN rm -f /usr/lib/python3*/EXTERNALLY-MANAGED

# --- 可在 build 时覆盖的参数 ---
ARG COMFYUI_VERSION=v0.35.0
# GitHub 加速前缀（gh-proxy），直连稳定的网络可改回空值: --build-arg GH_PROXY=
ARG GH_PROXY=https://gh-proxy.com/
# 国内网络可改用其他镜像源；清华源对数据中心 IP 可能 403，默认用阿里云源
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/

ENV PIP_INDEX_URL=${PIP_INDEX_URL} \
    PIP_DISABLE_PIP_VERSION_CHECK=1

# gcc：Triton 首次运行要现场编译 C 模块（comfy_kitchen/sageattention 导入链）
# libgl/libxcb 等：OpenCV wheel 的系统运行时依赖（无 GUI 服务器上必缺）
RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl wget gcc \
        libgl1 libglib2.0-0 libxcb1 libsm6 libxext6 libxrender1 \
    && rm -rf /var/lib/apt/lists/*

# --- L2: 固定版本的 ComfyUI + Manager ---
# 先下载到文件再解压（管道模式无法断点续传）；停滞检测：30 秒内低于 10KB/s 即断开重试；
# gh-proxy 主用（国内稳定），失败切直连并断点续传。
# py3.12+ 环境下 comfy-kitchen==0.2.31 无轮子（仅 cp310/cp311），
# 顶到 0.2.33（cp312-abi3 兼容 3.12/3.13/3.14；Comfy-Org 补丁版本，v0.34.5 仍钉 0.2.31）
WORKDIR /opt
RUN set -eux; \
    curl -fL --retry 5 --retry-all-errors --speed-time 30 --speed-limit 10240 \
      -o /tmp/comfyui.tar.gz \
      https://codeload.github.com/Comfy-Org/ComfyUI/tar.gz/refs/tags/${COMFYUI_VERSION} \
 || curl -fL --retry 5 --retry-all-errors --speed-time 30 --speed-limit 10240 -C - \
      -o /tmp/comfyui.tar.gz \
      ${GH_PROXY}https://codeload.github.com/Comfy-Org/ComfyUI/tar.gz/refs/tags/${COMFYUI_VERSION}; \
    tar -xzf /tmp/comfyui.tar.gz -C /opt; \
    mv /opt/ComfyUI-${COMFYUI_VERSION#v} /opt/ComfyUI; \
    rm /tmp/comfyui.tar.gz; \
    # v0.35.0 已升级 comfy-kitchen 至 0.2.33（cp312-abi3），无需 sed 补丁
    pip install --no-cache-dir --timeout 60 --retries 10 --resume-retries 10 \
      -r ComfyUI/requirements.txt; \
    pip install --no-cache-dir --timeout 60 --retries 10 --resume-retries 10 \
      -r ComfyUI/manager_requirements.txt

# --- L3: 视频工作流常用节点 ---
# VideoHelperSuite: 视频加载/帧拼接/保存 | KJNodes: 遮罩与 latent 工具
# GGUF: 低比特量化模型支持 | controlnet_aux: DWPose 姿态提取（Wan2.2-Animate 必需）
# 低速检测：git 传输 30 秒低于 10KB/s 即失败重跑（避免无限挂起）
RUN export GIT_HTTP_LOW_SPEED_LIMIT=10240 GIT_HTTP_LOW_SPEED_TIME=30; \
    git clone --depth 1 ${GH_PROXY}https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
        ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite \
 && git clone --depth 1 ${GH_PROXY}https://github.com/kijai/ComfyUI-KJNodes.git \
        ComfyUI/custom_nodes/ComfyUI-KJNodes \
 && git clone --depth 1 ${GH_PROXY}https://github.com/city96/ComfyUI-GGUF.git \
        ComfyUI/custom_nodes/ComfyUI-GGUF \
 && git clone --depth 1 ${GH_PROXY}https://github.com/Fannovel16/comfyui_controlnet_aux.git \
        ComfyUI/custom_nodes/comfyui_controlnet_aux \
 && for r in ComfyUI/custom_nodes/*/requirements.txt; do \
        pip install --no-cache-dir --timeout 60 --retries 10 --resume-retries 10 -r "$r" \
          || echo "skip $r"; \
    done

# --- L3.5: SageAttention（triton 实现；torch 2.12 + sm_120 组合需首跑验证，
#      报错就不开 --use-sage-attention，不影响其他功能） ---
RUN pip install --no-cache-dir --timeout 60 --retries 10 --resume-retries 10 \
      sageattention==1.0.6 || echo "sageattention skipped"

# --- L4: 预置工作流（烘焙进镜像；entrypoint 会同步到用户目录） ---
COPY entrypoint.sh /entrypoint.sh
COPY workflows/ /opt/baked_workflows/
RUN chmod +x /entrypoint.sh

VOLUME ["/opt/ComfyUI/models", "/opt/ComfyUI/user", "/opt/ComfyUI/input", "/opt/ComfyUI/output"]
EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
    CMD curl -sf http://127.0.0.1:8188/system_stats || exit 1

ENTRYPOINT ["/entrypoint.sh"]
