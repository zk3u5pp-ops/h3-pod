#!/bin/bash
# Set up ComfyUI + MiniMax H3 (FL2VA template files) on a RunPod Pod.
# Idempotent: safe to re-run. Logs to /workspace/setup_h3.log.
# Prints SETUP_DONE only if ComfyUI is up on port 8188.
set -eu
LOG=/workspace/setup_h3.log
exec > >(tee -a "$LOG") 2>&1

echo "=== H3 Pod setup started: $(date -u +%FT%TZ) ==="
nvidia-smi --query-gpu=name,memory.total --format=csv
df -h /workspace | tail -1
python3 -c "import torch; print('torch', torch.__version__, 'cuda', torch.cuda.is_available())"

cd /workspace

# --- ComfyUI ---
if [ ! -d ComfyUI ]; then
  echo "--- Cloning ComfyUI ---"
  git clone https://github.com/comfyanonymous/ComfyUI.git
else
  echo "--- ComfyUI already present ---"
fi
cd /workspace/ComfyUI
echo "--- Installing ComfyUI Python deps (keeping preinstalled torch) ---"
grep -viE "^(torch|torchvision|torchaudio)([^a-zA-Z0-9]|$)" requirements.txt > /tmp/comfy_req.txt || true
pip install -r /tmp/comfy_req.txt
pip install -q "huggingface_hub[cli]"
pip install -q hf_transfer 2>/dev/null && export HF_HUB_ENABLE_HF_TRANSFER=1 || echo "hf_transfer unavailable, using standard download"

# --- H3 model files (~42 GB) from Comfy-Org/MiniMax-H3 ---
echo "--- Downloading H3 model files ---"
REPO=Comfy-Org/MiniMax-H3
M=/workspace/ComfyUI/models
huggingface-cli download "$REPO" diffusion_models/minimax_h3_fl2va_pruned_int8_convrot.safetensors --local-dir "$M" --local-dir-use-symlinks False
huggingface-cli download "$REPO" text_encoders/qwen3vl_32b_minimax_h3_nvfp4_awq.safetensors --local-dir "$M" --local-dir-use-symlinks False
huggingface-cli download "$REPO" vae/minimax_h3_video_vae_int8_convrot.safetensors --local-dir "$M" --local-dir-use-symlinks False
huggingface-cli download "$REPO" vae/minimax_h3_audio_vae_fp32.safetensors --local-dir "$M" --local-dir-use-symlinks False
huggingface-cli download "$REPO" loras/minimax_h3_fl2v_turbo_8step_v1.0_comfyui_bf16.safetensors --local-dir "$M" --local-dir-use-symlinks False
echo "--- Model files on disk ---"
du -sh "$M"/*
ls -la "$M/diffusion_models" "$M/text_encoders" "$M/vae" "$M/loras"

# --- Start script for later restarts (Pod stop/start) ---
cat > /workspace/start_comfyui.sh <<'EOF'
#!/bin/bash
cd /workspace/ComfyUI
nohup python main.py --listen 0.0.0.0 --port 8188 > /workspace/comfyui.log 2>&1 &
echo "ComfyUI started on port 8188 (log: /workspace/comfyui.log)"
EOF
chmod +x /workspace/start_comfyui.sh

# --- Start ComfyUI ---
echo "--- Starting ComfyUI on port 8188 ---"
pkill -f "main.py.*8188" 2>/dev/null || true
sleep 2
bash /workspace/start_comfyui.sh
echo "--- Waiting for ComfyUI to respond ---"
for i in $(seq 1 24); do
  if curl -sf -o /dev/null http://127.0.0.1:8188/; then echo "ComfyUI is up"; break; fi
  sleep 5
done
curl -s http://127.0.0.1:8188/system_stats | head -c 500; echo
df -h /workspace | tail -1

echo "=== SETUP_DONE: $(date -u +%FT%TZ) ==="
