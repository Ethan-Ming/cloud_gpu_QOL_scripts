#!/bin/bash
# =============================================================================
# Custom WanGP Provisioning Script
# Base:    vast-ai official wan2gp provisioning (runs first)
# Adds:    latest WanGP main, H3 INT8 weights, supervisor flag injection
# Target:  16GB VRAM | 32GB+ RAM | CUDA 12.6 | Ampere/Ada/Hopper GPU
#
# Verified flags (all source-confirmed):
#   --profile 2              : HighRAM_LowVRAM — correct for 16GB VRAM + 32GB RAM
#   --perc-reserved-mem-max 0.50 : safe pinned-RAM ceiling on 32GB
#   --attention sage2        : WanGP impl — H3 noise bug is ComfyUI-only
#   --compile                : safe on CUDA 12.6, ~20% boost, slow first-gen warmup
#   --teacache 1.5           : confirmed for H3, highest-value flag
#   --preload                : OMITTED — fights Profile 2 VRAM budget
#   --listen / --server-port : OMITTED — already set by official provisioning
#   --fast-disk              : OMITTED — ComfyUI flag, does not exist in WanGP
# =============================================================================
set -euo pipefail

# ── 0. Run official vast-ai wan2gp provisioning first ────────────────────────
# FIX: wrap in set +e so a non-fatal non-zero exit from the official script
#      does not kill our entire provisioning run
echo "=== [0/4] Running official vast-ai wan2gp provisioning ==="
set +e
bash <(curl -fsSL \
  https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/provisioning_scripts/wan2gp.sh)
OFFICIAL_EXIT=$?
set -e
if [ "${OFFICIAL_EXIT}" -ne 0 ]; then
    echo "[WARN] Official provisioning exited with code ${OFFICIAL_EXIT} — continuing anyway"
fi

# ── 1. Update WanGP to latest main ───────────────────────────────────────────
echo "=== [1/4] Updating WanGP to latest main ==="
WANGP_DIR="/workspace/Wan2GP"
CKPTS_DIR="${WANGP_DIR}/ckpts"
TE_DIR="${CKPTS_DIR}/Qwen3-VL-32B-Instruct"
TE_FILENAME="qwen3vl_32b_minimax_h3_ultra_uncensored_heretic_nvfp4.safetensors"

cd "${WANGP_DIR}"
git pull origin main

# FIX: activate venv if official provisioning created one, so pip targets
#      the correct environment and not the system Python
if [ -f "${WANGP_DIR}/venv/bin/activate" ]; then
    source "${WANGP_DIR}/venv/bin/activate"
    echo "[INFO] venv activated: ${WANGP_DIR}/venv"
elif [ -f "/workspace/venv/bin/activate" ]; then
    source "/workspace/venv/bin/activate"
    echo "[INFO] venv activated: /workspace/venv"
else
    echo "[INFO] No venv found — using system Python"
fi

pip install -r requirements.txt --quiet

# ── 2. Inject performance flags into the vast-ai supervisor wrapper ───────────
echo "=== [2/4] Patching WanGP supervisor wrapper ==="

# FIX: narrowed grep pattern — "wgp\.py" only, removed "wgp " (too broad,
#      would match READMEs, logs, and other scripts)
LAUNCH_FILE=$(grep -rl "wgp\.py" \
    /opt/supervisor-scripts/ \
    /etc/supervisor/conf.d/ 2>/dev/null | head -1)

if [ -z "${LAUNCH_FILE}" ]; then
    echo "[ERROR] Could not find any file launching wgp.py — dumping search paths:"
    ls /opt/supervisor-scripts/ 2>/dev/null || echo "  /opt/supervisor-scripts/ not found"
    ls /etc/supervisor/conf.d/ 2>/dev/null || echo "  /etc/supervisor/conf.d/ not found"
    echo "[INFO] Skipping flag injection — patch manually"
else
    echo "[FOUND] Launch file: ${LAUNCH_FILE}"
    echo "--- BEFORE ---"
    cat "${LAUNCH_FILE}"

    if grep -q "\-\-profile" "${LAUNCH_FILE}"; then
        echo "[SKIP] Already patched — --profile flag present"
    else
        sed -i \
            's|python wgp\.py|python wgp.py --profile 2 --perc-reserved-mem-max 0.50 --attention sage2 --compile --teacache 1.5|g' \
            "${LAUNCH_FILE}"
        echo "[OK] Performance flags injected"
    fi

    echo "--- AFTER ---"
    cat "${LAUNCH_FILE}"

    # FIX: use 'supervisorctl update' instead of 'reload'
    # 'reload' restarts ALL programs (portal, Jupyter, SSH tunnel — dangerous mid-script)
    # 'update' only restarts programs whose conf actually changed — safe
    supervisorctl update
    echo "[OK] Supervisor updated"
fi

# ── 3. Download H3 INT8 weights ───────────────────────────────────────────────
echo "=== [3/4] Pre-seeding H3 INT8 weights ==="
mkdir -p "${CKPTS_DIR}" "${TE_DIR}" "${WANGP_DIR}/finetunes"

download_if_missing() {
    local dest="$1" url="$2"
    if [ -f "${dest}" ]; then
        echo "[SKIP] $(basename "${dest}")"
    else
        echo "[DL]   $(basename "${dest}")"
        # FIX: removed --show-progress — produces garbled escape sequences
        #      in non-TTY provisioning logs. -q alone is clean.
        wget -q -O "${dest}" "${url}"
        echo "[OK]   $(basename "${dest}")"
    fi
}

# T2V DiT — FL2VA pruned INT8 (~22GB)
download_if_missing \
    "${CKPTS_DIR}/MiniMax-H3-FL2VA-pruned_int8_convrot.safetensors" \
    "https://huggingface.co/DeepBeepMeep/MiniMax-H3/resolve/main/MiniMax-H3-FL2VA-pruned_int8_convrot.safetensors"

# I2V DiT — Ref2VA pruned INT8 (~22GB)
download_if_missing \
    "${CKPTS_DIR}/MiniMax-H3-Ref2VA-pruned_int8_convrot.safetensors" \
    "https://huggingface.co/DeepBeepMeep/MiniMax-H3/resolve/main/MiniMax-H3-Ref2VA-pruned_int8_convrot.safetensors"

# Text encoder — Heretic NVFP4 (exact filename matched in JSONs below)
download_if_missing \
    "${TE_DIR}/${TE_FILENAME}" \
    "https://huggingface.co/dotexec/MiniMax-H3-T2V-NVFP4/resolve/main/text_encoders/${TE_FILENAME}"

# ── 4. Write finetune JSONs ───────────────────────────────────────────────────
echo "=== [4/4] Writing finetune JSONs ==="

# FIX: removed blank line between << EOF and opening { — blank line was
#      written as first byte of file, producing invalid JSON

cat > "${WANGP_DIR}/finetunes/minimax_h3_t2v_int8.json" << EOF
{
  "id": "minimax_h3_t2v_int8",
  "name": "MiniMax H3 FL2VA T2V — INT8 DiT + Heretic NVFP4",
  "description": "Pruned 20B T2V. INT8 ConvRot DiT + uncensored Heretic NVFP4 encoder.",
  "URLs": [
    "https://huggingface.co/DeepBeepMeep/MiniMax-H3/resolve/main/MiniMax-H3-FL2VA-pruned_int8_convrot.safetensors"
  ],
  "text_encoder_URLs": [
    "https://huggingface.co/dotexec/MiniMax-H3-T2V-NVFP4/resolve/main/text_encoders/${TE_FILENAME}"
  ]
}
EOF

cat > "${WANGP_DIR}/finetunes/minimax_h3_i2v_int8.json" << EOF
{
  "id": "minimax_h3_i2v_int8",
  "name": "MiniMax H3 Ref2VA I2V — INT8 DiT + Heretic NVFP4",
  "description": "Pruned 20B I2V. INT8 ConvRot DiT + uncensored Heretic NVFP4 encoder.",
  "URLs": [
    "https://huggingface.co/DeepBeepMeep/MiniMax-H3/resolve/main/MiniMax-H3-Ref2VA-pruned_int8_convrot.safetensors"
  ],
  "text_encoder_URLs": [
    "https://huggingface.co/dotexec/MiniMax-H3-T2V-NVFP4/resolve/main/text_encoders/${TE_FILENAME}"
  ]
}
EOF

echo ""
echo "============================================"
echo "  Custom provisioning complete"
echo "  Profile:     2  (HighRAM_LowVRAM)"
echo "  Attention:   sage2  (WanGP impl, H3-safe)"
echo "  Compile:     ON  (first gen = slow warmup, normal)"
echo "  TeaCache:    1.5 (primary H3 speed lever)"
echo "  RAM ceiling: 50% pinned pool"
echo "  Preload:     OFF (correct for Profile 2)"
echo "  fast-disk:   N/A (ComfyUI flag, not WanGP)"
echo "============================================"
