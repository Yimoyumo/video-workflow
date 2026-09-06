#!/usr/bin/env bash
# ============================================================
# 本机练习套件（4GB 显存 / 8GB 内存友好版）
# 与 download_models.sh 共用 models/ 目录，4090 部署后这些模型直接可用
# 依赖: wget + curl（断点续传，中断重跑即可）
# ============================================================
set -uo pipefail
cd "$(dirname "$0")/.."

HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"
R21="Comfy-Org/Wan_2.1_ComfyUI_repackaged"

have() { # 先 HEAD 校验 URL 可用（防 404 浪费时间）
    curl -sIL --max-time 20 -o /dev/null -w '%{http_code}' "$1" 2>/dev/null | grep -q '200\|302'
}

dl() { # dl <repo> <repo内路径> <本地目标目录>
    local url="$HF_ENDPOINT/$1/resolve/main/$2"
    local dest="$3/$(basename "$2")"
    mkdir -p "$3"
    if [ -s "$dest" ]; then echo "== 已存在，跳过: $(basename "$2")"; return 0; fi
    if ! have "$url"; then echo "!! 404，跳过: $url"; return 1; fi
    echo ">> 下载: $(basename "$2")"
    wget -c -q --show-progress -O "$dest" "$url"
}

# 1) Wan 2.1 1.3B t2v —— 本机视频工作流练习主力（fp16, 2.7GB 进 4GB 显存）
dl "$R21" split_files/diffusion_models/wan2.1_t2v_1.3B_fp16.safetensors models/diffusion_models || true
# 2) VAE（小）
dl "$R21" split_files/vae/wan_2.1_vae.safetensors models/vae || true
# 3) 文本编码器 GGUF Q4（~2GB；fp8 原版 6.7GB 会撑爆 8GB 内存）
dl "city96/umt5-xxl-encoder-gguf" umt5-xxl-encoder-Q4_K_M.gguf models/text_encoders || true
# 4) lightx2v 4步蒸馏 LoRA（1.3B 用，28步变4步，练习必备提速）
dl "Kijai/WanVideo_comfy" LoRA/Wan21_T2V_1.3B_lightx2v_cfg_step_distill_lora_rank16.safetensors models/loras \
  || dl "Kijai/WanVideo_comfy" LoRA/Wan21_T2V_1.3B_lightx2v_cfg_step_distill_lora_rank8.safetensors models/loras \
  || echo "!! lightx2v 1.3B LoRA 未找到，练习时用全步数即可"
# 5) SD 1.5 动漫底模（界面/图像流练习，~2GB）
dl "Linaqruf/anything-v3.0" anything-v3-fp16-pruned.safetensors models/checkpoints \
  || dl "Lykon/DreamShaper" DreamShaper_8_pruned.safetensors models/checkpoints \
  || echo "!! SD1.5 底模两个源都失败，稍后从 Manager 或 Civitai 手动补"

echo "== 练习套件下载完成，目录占用："
du -sh models/*/ 2>/dev/null || true
