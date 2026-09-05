# ============================================================
# ComfyUI AI 视频生成工作流镜像（目标 GPU: RTX 4090 24GB × 2 / Ada sm_89）
# 基础镜像保持 cu126：sm_89 完整支持，且同一镜像兼容 V100（sm_70），
# 注意 CUDA 13 / cu13x 轮子已放弃 Volta，跨机型复用时不要升 cu13x
# ============================================================
# 基础镜像已转存至 ACR（构建机内网拉取，快且稳）；本地手动构建可临时改回
# pytorch/pytorch:2.7.1-cuda12.6-cudnn9-runtime
ARG BASE_IMAGE=crpi-9pf9lin5vvnxq7uh.cn-hangzhou.personal.cr.aliyuncs.com/ininyumo/pytorch-base:2.7.1-cu126-cudnn9

FROM ${BASE_IMAGE}

# --- 可在 build 时覆盖的参数 ---
ARG COMFYUI_VERSION=v0.34.0
# GitHub 加速前缀（gh-proxy），直连稳定的网络可改回空值: --build-arg GH_PROXY=
ARG GH_PROXY=https://gh-proxy.com/
# 国内网络可改用其他镜像源；清华源对数据中心 IP 可能 403，默认用阿里云源
ARG PIP_INDEX_URL=https://mirrors.aliyun.com/pypi/simple/

ENV PIP_INDEX_URL=${PIP_INDEX_URL} \
    PIP_DISABLE_PIP_VERSION_CHECK=1

RUN apt-get update && apt-get install -y --no-install-recommends \
        git curl wget \
    && rm -rf /var/lib/apt/lists/*

# --- L2: 固定版本的 ComfyUI + Manager ---
# ComfyUI 用 codeload 压缩包获取（单次 HTTP 比 git clone 抗抖动），直连失败自动切 gh-proxy
WORKDIR /opt
RUN set -eux; \
    (curl -fL --retry 3 https://codeload.github.com/Comfy-Org/ComfyUI/tar.gz/refs/tags/${COMFYUI_VERSION} \
     || curl -fL --retry 3 ${GH_PROXY}https://codeload.github.com/Comfy-Org/ComfyUI/tar.gz/refs/tags/${COMFYUI_VERSION}) \
     | tar -xz -C /opt; \
    mv /opt/ComfyUI-${COMFYUI_VERSION#v} /opt/ComfyUI; \
    pip install --no-cache-dir -r ComfyUI/requirements.txt; \
    pip install --no-cache-dir -r ComfyUI/manager_requirements.txt

# --- L3: 视频工作流常用节点 ---
# VideoHelperSuite: 视频加载/帧拼接/保存 | KJNodes: 遮罩与 latent 工具
# GGUF: 低比特量化模型支持 | controlnet_aux: DWPose 姿态提取（Wan2.2-Animate 必需）
RUN git clone --depth 1 ${GH_PROXY}https://github.com/Kosinkadink/ComfyUI-VideoHelperSuite.git \
        ComfyUI/custom_nodes/ComfyUI-VideoHelperSuite \
 && git clone --depth 1 ${GH_PROXY}https://github.com/kijai/ComfyUI-KJNodes.git \
        ComfyUI/custom_nodes/ComfyUI-KJNodes \
 && git clone --depth 1 ${GH_PROXY}https://github.com/city96/ComfyUI-GGUF.git \
        ComfyUI/custom_nodes/ComfyUI-GGUF \
 && git clone --depth 1 ${GH_PROXY}https://github.com/Fannovel16/comfyui_controlnet_aux.git \
        ComfyUI/custom_nodes/comfyui_controlnet_aux \
 && for r in ComfyUI/custom_nodes/*/requirements.txt; do \
        pip install --no-cache-dir -r "$r" || echo "skip $r"; \
    done

# --- L3.5: SageAttention（4090 sm_89 支持，配合 --use-sage-attention 提速 10-30%） ---
RUN pip install --no-cache-dir sageattention==1.0.6 || echo "sageattention skipped"

# --- L4: 预置工作流（烘焙进镜像；entrypoint 会同步到用户目录） ---
COPY entrypoint.sh /entrypoint.sh
COPY workflows/ /opt/baked_workflows/
RUN chmod +x /entrypoint.sh

VOLUME ["/opt/ComfyUI/models", "/opt/ComfyUI/user", "/opt/ComfyUI/input", "/opt/ComfyUI/output"]
EXPOSE 8188

HEALTHCHECK --interval=30s --timeout=5s --start-period=90s --retries=5 \
    CMD curl -sf http://127.0.0.1:8188/system_stats || exit 1

ENTRYPOINT ["/entrypoint.sh"]
