#!/usr/bin/env bash
# ============================================================
# 在阿里云 ECS 上构建并推送 ComfyUI 工作流镜像（2核4G 即可）
# 前置: docker 已装；ECS 与 ACR 同地域（cn-hangzhou）内网可达最优
# 用法: ./scripts/build-on-ecs.sh
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

REGISTRY="crpi-9pf9lin5vvnxq7uh.cn-hangzhou.personal.cr.aliyuncs.com"
REPO="$REGISTRY/ininyumo/vedio_woekflow"
TAG="${1:-v0.34.0-cu126-4090x2}"

# 1. 磁盘检查：构建全程约需 25GB 余量（基础镜像 9.8G + 依赖层 + 缓存）
AVAIL=$(df --output=avail -BG /var/lib/docker 2>/dev/null | tail -1 | tr -dc '0-9')
[ -z "$AVAIL" ] && AVAIL=$(df --output=avail -BG / | tail -1 | tr -dc '0-9')
echo ">> docker 分区可用空间: ${AVAIL}GB"
if [ "$AVAIL" -lt 25 ]; then
    echo "!! 磁盘可用空间不足 25GB，请先清理（docker system prune -a 可回收旧镜像）"
    exit 1
fi

# 2. 4G 内存小机保险：确认有 swap（pip 解压大 wheel 时内存峰值较高）
FREE_MB=$(free -m | awk '/^Mem:/{print $2}')
SWAP_MB=$(free -m | awk '/^Swap:/{print $2}')
if [ "$FREE_MB" -lt 6000 ] && [ "$SWAP_MB" -lt 2000 ]; then
    echo ">> 内存 ${FREE_MB}MB 且无 swap，创建 2G swapfile 以防 OOM"
    fallocate -l 2G /swapfile && chmod 600 /swapfile && mkswap /swapfile && swapon /swapfile
fi

# 3. 登录 ACR（已登录则跳过；凭证 = 控制台「访问凭证」的固定密码）
if ! docker pull "$REPO:$TAG" 2>/dev/null; then
    echo ">> 首次构建前拉一次基础镜像以验证登录态"
fi
docker pull "$REGISTRY/ininyumo/pytorch-base:2.7.1-cu126-cudnn9" \
    || { echo ">> 需要登录:"; docker login "$REGISTRY"; }

# 4. 构建（Dockerfile 自带断点续传/停滞熔断/重试，弱网也能磨完）
echo ">> 开始构建: $REPO:$TAG"
docker build -t "$REPO:$TAG" .

# 5. 推送
echo ">> 推送到 ACR"
docker push "$REPO:$TAG"
echo ">> 完成: $REPO:$TAG"
echo ">> 服务器侧更新: docker compose pull && docker compose up -d"
