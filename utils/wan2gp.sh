#!/bin/bash
# =============================================================================
# Custom WanGP Provisioning Script
# Base:    Vast.ai official wan2gp provisioning (runs first)
# Adds:    latest WanGP main, finetune JSONs, supervisor flag injection
# Target:  16GB VRAM | 32GB+ RAM | CUDA 12.6 | Ampere/Ada/Hopper GPU
#
# v3:
#   - NO model pre-seeding during provisioning
#   - Models are downloaded by WanGP on demand through finetune JSONs
#   - Removed --teacache because the installed wgp.py does not support it
#   - Patch the exact Vast supervisor launcher
#
# Verified against the actual wgp.py --help output:
#   --profile
#   --perc-reserved-mem-max
#   --attention
#   --compile
#
# Intentionally NOT used:
#   --teacache             : not supported by this WanGP build
#   --preload              : omitted — fights Profile 2 VRAM budget
#   --listen               : already handled by official provisioning
#   --server-port          : already handled by official provisioning
#   --fast-disk            : ComfyUI flag, not WanGP
# =============================================================================

set -euo pipefail


# ── 0. Run official Vast.ai Wan2GP provisioning ──────────────────────────────

echo "=== [0/4] Running official Vast.ai Wan2GP provisioning ==="

# The official provisioning script can occasionally return non-zero after
# successfully creating most of the environment. Don't kill our provisioning
# script immediately in that case.
set +e

bash <(curl -fsSL \
  https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/provisioning_scripts/wan2gp.sh)

OFFICIAL_EXIT=$?

set -e

if [ "${OFFICIAL_EXIT}" -ne 0 ]; then
    echo "[WARN] Official provisioning exited with code ${OFFICIAL_EXIT} — continuing anyway"
fi


# ── 0b. Stop Wan2GP before modifying it ─────────────────────────────────────

echo "=== [0b/4] Stopping Wan2GP until configuration is staged ==="

if supervisorctl stop wan2gp; then
    echo "[OK] Wan2GP stopped — will not start while configuration is modified"
else
    echo "[WARN] Could not stop wan2gp — maybe it is not registered yet?"
fi


# ── 1. Update WanGP ──────────────────────────────────────────────────────────

echo "=== [1/4] Updating WanGP to latest main ==="

WANGP_DIR="/workspace/Wan2GP"

cd "${WANGP_DIR}"

git pull origin main


# ── Activate environment ─────────────────────────────────────────────────────

# Vast's official provisioning currently uses /venv/main.
# Keep the fallback paths in case the environment layout changes.

if [ -f "/venv/main/bin/activate" ]; then

    source "/venv/main/bin/activate"

    echo "[INFO] Activated Vast environment: /venv/main"

elif [ -f "${WANGP_DIR}/venv/bin/activate" ]; then

    source "${WANGP_DIR}/venv/bin/activate"

    echo "[INFO] Activated WanGP environment: ${WANGP_DIR}/venv"

elif [ -f "/workspace/venv/bin/activate" ]; then

    source "/workspace/venv/bin/activate"

    echo "[INFO] Activated workspace environment: /workspace/venv"

else

    echo "[INFO] No additional venv activation required"

fi


# ── Update Python requirements ────────────────────────────────────────────────

echo "[INFO] Installing WanGP requirements"

pip install -r requirements.txt --quiet


# ── Verify actual CLI before patching supervisor ──────────────────────────────

echo "=== Verifying installed WanGP CLI ==="

cd "${WANGP_DIR}"

echo "[INFO] WanGP commit:"
git rev-parse --short HEAD

echo "[INFO] Python:"
which python
python --version

echo "[INFO] Checking supported CLI flags..."

if python wgp.py --help 2>&1 | grep -q -- "--profile"; then
    echo "[OK] --profile supported"
else
    echo "[WARN] --profile was not found in wgp.py --help"
fi

if python wgp.py --help 2>&1 | grep -q -- "--perc-reserved-mem-max"; then
    echo "[OK] --perc-reserved-mem-max supported"
else
    echo "[WARN] --perc-reserved-mem-max was not found"
fi

if python wgp.py --help 2>&1 | grep -q -- "--attention"; then
    echo "[OK] --attention supported"
else
    echo "[WARN] --attention was not found"
fi

if python wgp.py --help 2>&1 | grep -q -- "--compile"; then
    echo "[OK] --compile supported"
else
    echo "[WARN] --compile was not found"
fi

# This is deliberately informational.
# The current build used for this script does NOT expose --teacache.
if python wgp.py --help 2>&1 | grep -q -- "--teacache"; then
    echo "[INFO] --teacache is supported by this build"
else
    echo "[INFO] --teacache is NOT supported by this build — not using it"
fi


# ── 2. Patch Vast supervisor launcher ────────────────────────────────────────

echo "=== [2/4] Patching WanGP supervisor wrapper ==="

# Vast's official provisioning creates this exact launcher.
LAUNCH_FILE="/opt/supervisor-scripts/wan2gp.sh"

if [ ! -f "${LAUNCH_FILE}" ]; then

    echo "[ERROR] Could not find WanGP launcher:"
    echo "        ${LAUNCH_FILE}"
    echo ""
    echo "[INFO] Available supervisor scripts:"
    ls -la /opt/supervisor-scripts/ 2>/dev/null || true
    exit 1

fi


echo "--- BEFORE ---"
cat "${LAUNCH_FILE}"


# Replace the actual python invocation.
#
# We intentionally do NOT add --teacache.
#
# The current installed wgp.py accepts:
#   --profile 2
#   --perc-reserved-mem-max 0.50
#   --attention sage2
#   --compile
#
# stderr is kept redirected into stdout so Vast's logging continues to work.

sed -i \
    's|python wgp\.py.*|python wgp.py --profile 2 --perc-reserved-mem-max 0.50 --attention sage2 --compile 2>\&1|' \
    "${LAUNCH_FILE}"


echo "--- AFTER ---"
cat "${LAUNCH_FILE}"


# Make sure the launcher remains executable.
chmod +x "${LAUNCH_FILE}"


# Reload supervisor configuration, but do not intentionally start Wan2GP yet.
supervisorctl reread

echo "[OK] Supervisor configuration reloaded"
echo "[OK] Wan2GP remains stopped while finetune definitions are created"


# ── 3. Write finetune JSONs ──────────────────────────────────────────────────

echo "=== [3/4] Writing finetune JSONs — NO model downloads ==="

mkdir -p "${WANGP_DIR}/finetunes"


# -----------------------------------------------------------------------------
# T2V
#
# IMPORTANT:
# There is intentionally NO wget/curl/download_if_missing here.
#
# The URLs are only metadata for WanGP's finetune system.
# WanGP will download the required files when this finetune is selected.
# -----------------------------------------------------------------------------

cat > "${WANGP_DIR}/finetunes/minimax_h3_t2v_int8.json" << 'EOF'
{
  "id": "minimax_h3_t2v_int8",
  "name": "MiniMax H3 FL2VA T2V — INT8 DiT + Heretic NVFP4",
  "description": "Pruned 20B T2V. INT8 ConvRot DiT + uncensored Heretic NVFP4 encoder.",
  "URLs": [
    "https://huggingface.co/DeepBeepMeep/MiniMax-H3/resolve/main/MiniMax-H3-FL2VA-pruned_int8_convrot.safetensors"
  ],
  "text_encoder_URLs": [
    "https://huggingface.co/dotexec/MiniMax-H3-T2V-NVFP4/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_ultra_uncensored_heretic_nvfp4.safetensors"
  ]
}
EOF


# -----------------------------------------------------------------------------
# I2V
# -----------------------------------------------------------------------------

cat > "${WANGP_DIR}/finetunes/minimax_h3_i2v_int8.json" << 'EOF'
{
  "id": "minimax_h3_i2v_int8",
  "name": "MiniMax H3 Ref2VA I2V — INT8 DiT + Heretic NVFP4",
  "description": "Pruned 20B I2V. INT8 ConvRot DiT + uncensored Heretic NVFP4 encoder.",
  "URLs": [
    "https://huggingface.co/DeepBeepMeep/MiniMax-H3/resolve/main/MiniMax-H3-Ref2VA-pruned_int8_convrot.safetensors"
  ],
  "text_encoder_URLs": [
    "https://huggingface.co/dotexec/MiniMax-H3-T2V-NVFP4/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_ultra_uncensored_heretic_nvfp4.safetensors"
  ]
}
EOF


echo "[OK] Finetune JSONs created"

echo "--- T2V JSON ---"
cat "${WANGP_DIR}/finetunes/minimax_h3_t2v_int8.json"

echo "--- I2V JSON ---"
cat "${WANGP_DIR}/finetunes/minimax_h3_i2v_int8.json"


# ── 4. Start Wan2GP ──────────────────────────────────────────────────────────

echo "=== [4/4] Starting Wan2GP ==="

# Apply any supervisor configuration changes.
supervisorctl update


# Explicitly start Wan2GP.
#
# On first provisioning, supervisor may already have started it during
# 'update'. In that case this simply returns a harmless "already started"
# error, which is ignored.

supervisorctl start wan2gp || true


echo "[OK] Wan2GP started"


# ── Final summary ─────────────────────────────────────────────────────────────

echo ""
echo "============================================"
echo "  Custom WanGP provisioning complete"
echo "============================================"
echo ""
echo "  WanGP:"
echo "    Source:      latest main"
echo ""
echo "  Profile:"
echo "    Profile:     2  (HighRAM_LowVRAM)"
echo "    RAM ceiling: 50% pinned pool"
echo ""
echo "  Performance:"
echo "    Attention:   sage2"
echo "    Compile:     ON"
echo "    TeaCache:    OFF / unsupported by current CLI"
echo ""
echo "  Model downloads:"
echo "    Pre-seeding: OFF"
echo "    T2V:         finetune JSON only"
echo "    I2V:         finetune JSON only"
echo "    Text encoder: finetune JSON only"
echo "    Download:    ON-DEMAND when selected"
echo ""
echo "============================================"
