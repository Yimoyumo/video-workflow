#!/usr/bin/env bash
# ============================================================
# 模型下载脚本（在宿主机 comfyui-video/ 目录下执行）
# 用法: ./scripts/download_models.sh [smoke|t2v|i2v|all]   默认 all
# 依赖: wget（支持断点续传，中断后重跑即可）
# 说明: 若 URL 404，去 https://hf-mirror.com/<repo> 页面核对文件名
# ============================================================
set -euo pipefail
cd "$(dirname "$0")/.."

HF_ENDPOINT="${HF_ENDPOINT:-https://hf-mirror.com}"

dl() { # dl <repo> <repo内路径> <本地目标目录>
    local url="$HF_ENDPOINT/$1/resolve/main/$2"
    local dest="$3/$(basename "$2")"
    mkdir -p "$3"
    echo ">> $(basename "$2") -> $dest"
    wget -c -q --show-progress -O "$dest" "$url"
}

R22="Comfy-Org/Wan_2.2_ComfyUI_Repackaged"
R21="Comfy-Org/Wan_2.1_ComfyUI_repackaged"

# 冒烟测试套件：Wan 2.1 1.3B（约 10GB），先跑通全流程用
stage_smoke() {
    dl "$R21" split_files/diffusion_models/wan2.1_t2v_1.3B_fp16.safetensors models/diffusion_models
    dl "$R21" split_files/vae/wan_2.1_vae.safetensors models/vae
    # 文本编码器在 R22 仓库里的真实文件名带 e4m3fn（fp16/fp8_e4m3fn_scaled 两种），写成 umt5_xxl_fp8 会 404
    dl "$R22" split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors models/text_encoders
}

# 主力：Wan 2.2 14B 文生视频 fp8（约 36GB），V100 32GB 显存可全量驻留
stage_t2v() {
    dl "$R22" split_files/text_encoders/umt5_xxl_fp8_e4m3fn_scaled.safetensors models/text_encoders
    # 14B 系列用 wan_2.1_vae（wan2.2_vae 只有 TI2V-5B 用）
    dl "$R22" split_files/vae/wan_2.1_vae.safetensors models/vae
    dl "$R22" split_files/diffusion_models/wan2.2_t2v_high_noise_14B_fp8_scaled.safetensors models/diffusion_models
    dl "$R22" split_files/diffusion_models/wan2.2_t2v_low_noise_14B_fp8_scaled.safetensors models/diffusion_models
}

# 图生视频：Wan 2.2 14B i2v fp8（约 29GB，与 t2v 共享文本编码器和 VAE）
stage_i2v() {
    dl "$R22" split_files/diffusion_models/wan2.2_i2v_high_noise_14B_fp8_scaled.safetensors models/diffusion_models
    dl "$R22" split_files/diffusion_models/wan2.2_i2v_low_noise_14B_fp8_scaled.safetensors models/diffusion_models
}

# 可选：lightx2v 蒸馏 LoRA，8 步快速出片（文件名以仓库页面为准）
stage_lora() {
    dl "Kijai/WanVideo_comfy" LoRA/Wan21_T2V_14B_lightx2v_cfg_step_distill_lora_rank32.safetensors models/loras
}

# 2D 动画：Wan2.2-Animate 动作迁移全套（角色图+参考视频=角色表演，约 22GB）
# 官方模板: 模板库 → Video → Wan2.2 Animate；首次运行 DWPose 会自动下载姿态模型
stage_animate() {
    dl "Kijai/WanVideo_comfy" FP8_e4m3fn/Wan2_2-Animate-14B_fp8_e4m3fn_scaled_KJ.safetensors models/diffusion_models
    dl "Comfy-Org/Wan_2.1_ComfyUI_repackaged" split_files/clip_vision/clip_vision_h.safetensors models/clip_vision
    dl "Kijai/WanVideo_comfy" LoRA/lightx2v_I2V_14B_480p_cfg_step_distill_rank64_bf16.safetensors models/loras
    dl "Kijai/WanVideo_comfy" LoRA/WanAnimate_relight_lora_fp16.safetensors models/loras
}

# 2D 动画：Civitai 动漫风格 LoRA（写实偏置对抗，必装）
# Civitai 需登录令牌: 去 https://civitai.com/models/2222779 页面 → Download 按钮 → 复制链接，
# 然后: export CIVITAI_TOKEN=<你的令牌> && export ANIME_LORA_URL=<复制的下载链接>
stage_anime_lora() {
    : "${CIVITAI_TOKEN:?请先 export CIVITAI_TOKEN=<civitai 个人令牌>}"
    : "${ANIME_LORA_URL:?请先 export ANIME_LORA_URL=<模型页复制的下载链接>}"
    dl_civitai "$ANIME_LORA_URL" models/loras/wan22_anime_style.safetensors
}
dl_civitai() { # dl_civitai <下载链接> <目标文件>   （自动追加 token 参数）
    local sep="?"
    case "$1" in *\?*) sep="&" ;; esac
    echo ">> Civitai LoRA -> $2"
    wget -c -q --show-progress -O "$2" "$1${sep}token=${CIVITAI_TOKEN}"
}

case "${1:-all}" in
    smoke)      stage_smoke ;;
    t2v)        stage_t2v ;;
    i2v)        stage_i2v ;;
    lora)       stage_lora ;;
    animate)    stage_animate ;;
    anime_lora) stage_anime_lora ;;
    all)        stage_smoke; stage_t2v; stage_i2v; stage_animate ;;
    *) echo "未知阶段: $1 (可选 smoke|t2v|i2v|lora|animate|anime_lora|all)"; exit 1 ;;
esac

echo "完成。模型目录结构："
du -sh models/*/ 2>/dev/null || true
