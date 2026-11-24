#!/bin/bash
# Set up ComfyUI + Qwen-Image-Edit-2511 (GGUF Q6_K + Lightning LoRA) on a RunPod Pod.
# Same model set as the imagestudioqwen serverless worker:
#   transformer: unsloth/Qwen-Image-Edit-2511-GGUF qwen-image-edit-2511-Q6_K.gguf (17.95GB)
#   text encoder: Comfy-Org/Qwen-Image_ComfyUI qwen_2.5_vl_7b_fp8_scaled.safetensors
#   vae: Comfy-Org/Qwen-Image_ComfyUI qwen_image_vae.safetensors
#   loras: lightx2v/Qwen-Image-Edit-2511-Lightning 4steps + 8steps (bf16)
# Idempotent: safe to re-run. Logs to /workspace/setup_qwen.log.
# Prints SETUP_DONE only if ComfyUI is up on port 8188.
set -eu
LOG=/workspace/setup_qwen.log
exec > >(tee -a "$LOG") 2>&1

echo "=== Qwen Pod setup started: $(date -u +%FT%TZ) ==="
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

# --- Custom node: ComfyUI-GGUF (city96) for GGUF model loading ---
echo "--- Installing ComfyUI-GGUF custom node ---"
if [ ! -d custom_nodes/ComfyUI-GGUF ]; then
  git clone https://github.com/city96/ComfyUI-GGUF.git custom_nodes/ComfyUI-GGUF
fi
pip install -q -r custom_nodes/ComfyUI-GGUF/requirements.txt

# --- Qwen-Image-Edit-2511 model files (~30 GB) ---
# NOTE: huggingface_hub 1.x dropped the `huggingface-cli` console script (now `hf`),
# so download via the Python API instead — robust across versions.
echo "--- Downloading Qwen edit model files ---"
python3 -c "import huggingface_hub; print('huggingface_hub', huggingface_hub.__version__)"
hf_get() {
  # $1 = repo_id, $2 = remote path in repo, $3 = destination dir under models/
  python3 - "$1" "$2" "$3" <<'PYEOF'
import os, shutil, sys
from huggingface_hub import hf_hub_download
repo, remote, dest = sys.argv[1], sys.argv[2], sys.argv[3]
dest_dir = os.path.join("/workspace/ComfyUI/models", dest)
os.makedirs(dest_dir, exist_ok=True)
p = hf_hub_download(repo_id=repo, filename=remote, local_dir=dest_dir,
                    local_dir_use_symlinks=False)
target = os.path.join(dest_dir, os.path.basename(remote))
if os.path.abspath(p) != os.path.abspath(target):
    shutil.move(p, target)
    # clean up leftover empty subdirs (e.g. split_files/...)
    d = os.path.dirname(p)
    while os.path.abspath(d) != os.path.abspath(dest_dir) and d.startswith(dest_dir):
        try: os.rmdir(d)
        except OSError: break
        d = os.path.dirname(d)
print("downloaded:", target)
PYEOF
}
hf_get unsloth/Qwen-Image-Edit-2511-GGUF qwen-image-edit-2511-Q6_K.gguf diffusion_models
hf_get Comfy-Org/Qwen-Image_ComfyUI split_files/text_encoders/qwen_2.5_vl_7b_fp8_scaled.safetensors text_encoders
hf_get Comfy-Org/Qwen-Image_ComfyUI split_files/vae/qwen_image_vae.safetensors vae
hf_get lightx2v/Qwen-Image-Edit-2511-Lightning Qwen-Image-Edit-2511-Lightning-4steps-V1.0-bf16.safetensors loras
hf_get lightx2v/Qwen-Image-Edit-2511-Lightning Qwen-Image-Edit-2511-Lightning-8steps-V1.0-bf16.safetensors loras
echo "--- Model files on disk ---"
du -sh /workspace/ComfyUI/models/*
ls -la /workspace/ComfyUI/models/diffusion_models /workspace/ComfyUI/models/text_encoders /workspace/ComfyUI/models/vae /workspace/ComfyUI/models/loras

# --- Custom nodes: RunPod balance display ---
echo "--- Installing RunPod balance custom node ---"
mkdir -p /workspace/ComfyUI/custom_nodes/runpod_balance
curl -sSL https://raw.githubusercontent.com/zk3u5pp-ops/h3-pod/main/comfyui_nodes/runpod_balance/__init__.py \
  -o /workspace/ComfyUI/custom_nodes/runpod_balance/__init__.py
python3 -c "import ast; ast.parse(open('/workspace/ComfyUI/custom_nodes/runpod_balance/__init__.py').read()); print('runpod_balance node OK')"

# --- Start script for later restarts (Pod stop/start) ---
# --enable-cors-header disables ComfyUI's origin check, which otherwise
# returns HTTP 403 when the URL is reached by clicking a link from another
# site (browser sends Sec-Fetch-Site: cross-site).
cat > /workspace/start_comfyui.sh <<'EOF'
#!/bin/bash
cd /workspace/ComfyUI
nohup python main.py --listen 0.0.0.0 --port 8188 --enable-cors-header > /workspace/comfyui.log 2>&1 &
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
