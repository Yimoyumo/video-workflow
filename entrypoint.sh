#!/usr/bin/env bash
set -euo pipefail
cd /opt/ComfyUI

# 允许 docker run <image> <cmd> 覆盖默认启动（调试用）
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

# WSL 等环境下容器内只有 libcuda.so.1、缺无版本号的 libcuda.so，
# Triton JIT 编译（-lcuda）会失败；裸金属 + nvidia-toolkit 环境本步是空操作
LIBCUDA_SO1=$(ldconfig -p 2>/dev/null | awk '/libcuda\.so\.1 \(/{print $NF}' | head -1)
if [ -n "${LIBCUDA_SO1}" ] && [ ! -f /usr/lib/x86_64-linux-gnu/libcuda.so ]; then
    ln -sf "${LIBCUDA_SO1}" /usr/lib/x86_64-linux-gnu/libcuda.so 2>/dev/null || true
fi

# 把烘焙进镜像的工作流同步到用户目录（卷挂载后首次启动时生效，不覆盖已有文件）
mkdir -p user/default/workflows
cp -n /opt/baked_workflows/* user/default/workflows/ 2>/dev/null || true

exec python main.py \
    --listen 0.0.0.0 \
    --port "${PORT:-8188}" \
    --enable-manager \
    --disable-auto-launch \
    ${COMFY_EXTRA_ARGS:-}
