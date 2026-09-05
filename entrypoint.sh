#!/usr/bin/env bash
set -euo pipefail
cd /opt/ComfyUI

# 把烘焙进镜像的工作流同步到用户目录（卷挂载后首次启动时生效，不覆盖已有文件）
mkdir -p user/default/workflows
cp -n /opt/baked_workflows/* user/default/workflows/ 2>/dev/null || true

exec python main.py \
    --listen 0.0.0.0 \
    --port "${PORT:-8188}" \
    --enable-manager \
    --disable-auto-launch \
    ${COMFY_EXTRA_ARGS:-}
