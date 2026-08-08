#!/bin/bash
# =============================================================================
# Custom WanGP Provisioning Script for Vast.ai
#
# Based on Vast.ai official Wan2GP provisioning.
#
# Features:
#   - Uses official Vast Wan2GP provisioning
#   - Updates WanGP to latest main
#   - Uses WanGP's own setup machinery for GPU-dependent components
#   - Installs/activates appropriate SageAttention through WanGP setup
#   - Enables SageAttention 2 when available
#   - Enables PyTorch compilation
#   - Uses Profile 2 / HighRAM_LowVRAM
#   - 50% reserved pinned memory
#   - NO model pre-seeding
#   - Models download only when selected through finetunes
#
# Finetunes:
#   - MiniMax H3 T2V INT8
#   - MiniMax H3 I2V INT8
#   - Wan2.2 Animate 14B + custom T5
#   - Bernini-R NVFP4 + custom T5
#
# IMPORTANT:
#   --teacache is intentionally NOT used because the installed wgp.py
#   does not expose that argument.
# =============================================================================

set -euo pipefail


# =============================================================================
# 0. Official Vast.ai provisioning
# =============================================================================

echo "=== [0/5] Running official Vast.ai Wan2GP provisioning ==="

set +e

bash <(curl -fsSL \
    https://raw.githubusercontent.com/vast-ai/base-image/refs/heads/main/provisioning_scripts/wan2gp.sh)

OFFICIAL_EXIT=$?

set -e

if [ "${OFFICIAL_EXIT}" -ne 0 ]; then
    echo "[WARN] Official provisioning returned ${OFFICIAL_EXIT}"
    echo "[WARN] Continuing..."
fi


# =============================================================================
# 0b. Stop Wan2GP before modifying installation
# =============================================================================

echo "=== [0b/5] Stopping Wan2GP ==="

supervisorctl stop wan2gp || true


# =============================================================================
# Paths
# =============================================================================

WANGP_DIR="/workspace/Wan2GP"
LAUNCH_FILE="/opt/supervisor-scripts/wan2gp.sh"

cd "${WANGP_DIR}"


# =============================================================================
# 1. Update WanGP
# =============================================================================

echo "=== [1/5] Updating WanGP ==="

git pull origin main


# =============================================================================
# Activate Vast Python environment
# =============================================================================

if [ -f "/venv/main/bin/activate" ]; then

    source /venv/main/bin/activate

    echo "[INFO] Python environment: /venv/main"

elif [ -f "${WANGP_DIR}/venv/bin/activate" ]; then

    source "${WANGP_DIR}/venv/bin/activate"

    echo "[INFO] Python environment: ${WANGP_DIR}/venv"

else

    echo "[WARN] Could not find activation script"

fi


# =============================================================================
# 1b. Install/update base requirements
# =============================================================================

echo "=== Installing WanGP requirements ==="

python -m pip install -r requirements.txt --quiet


# =============================================================================
# 2. Let WanGP's own setup configuration determine accelerator packages
# =============================================================================
#
# WanGP maintains:
#
#   setup_config.json
#
# containing:
#
#   Python versions
#   PyTorch versions
#   Triton versions
#   SageAttention versions
#   GPU profiles
#
# We DO NOT hard-code a SageAttention wheel here.
#
# Instead, use WanGP's setup/update script if available.
# =============================================================================

echo "=== [2/5] Running WanGP setup/update machinery ==="

SETUP_SCRIPT=""

# Check likely WanGP setup scripts.
for candidate in \
    "install.py" \
    "setup.py" \
    "setup.sh" \
    "update.py" \
    "update.sh"
do
    if [ -f "${WANGP_DIR}/${candidate}" ]; then
        SETUP_SCRIPT="${WANGP_DIR}/${candidate}"
        break
    fi
done


if [ -n "${SETUP_SCRIPT}" ]; then

    echo "[INFO] Found WanGP setup script:"
    echo "       ${SETUP_SCRIPT}"

    case "${SETUP_SCRIPT}" in

        *.py)
            echo "[INFO] Running Python setup script"
            python "${SETUP_SCRIPT}"
            ;;

        *.sh)
            echo "[INFO] Running shell setup script"
            bash "${SETUP_SCRIPT}"
            ;;

    esac

else

    echo "[INFO] No standalone setup script found."
    echo "[INFO] WanGP setup_config.json is present; preserving Vast's"
    echo "[INFO] existing Python/Torch environment."
    echo "[INFO] SageAttention verification will follow."

fi


# =============================================================================
# 2b. Show installed accelerator versions
# =============================================================================

echo ""
echo "=== Accelerator environment ==="

python - <<'PY'
try:
    import torch

    print("PyTorch:", torch.__version__)
    print("Torch CUDA:", torch.version.cuda)
    print("CUDA available:", torch.cuda.is_available())

    if torch.cuda.is_available():
        print("GPU:", torch.cuda.get_device_name(0))

except Exception as e:
    print("Could not inspect PyTorch:", e)

try:
    import triton
    print("Triton:", triton.__version__)
except Exception as e:
    print("Triton: NOT AVAILABLE")
    print("Triton error:", e)

try:
    import sageattention
    print("SageAttention: INSTALLED")
    print("SageAttention module:", sageattention.__file__)
except Exception as e:
    print("SageAttention: NOT INSTALLED")
    print("SageAttention error:", e)
PY


# =============================================================================
# 2c. If WanGP's setup machinery did not install SageAttention,
#     fail clearly instead of silently launching "sage2 - NOT INSTALLED".
# =============================================================================

if python -c "import sageattention" >/dev/null 2>&1; then

    echo "[OK] SageAttention is importable"

else

    echo ""
    echo "============================================================"
    echo "[ERROR] SageAttention is NOT installed"
    echo "============================================================"
    echo ""
    echo "WanGP was requested to use sage2, but the selected environment"
    echo "does not currently contain an importable SageAttention package."
    echo ""
    echo "Refusing to start WanGP with:"
    echo "    --attention sage2"
    echo ""
    echo "This prevents the UI from misleadingly showing:"
    echo "    sage2 - NOT INSTALLED"
    echo ""
    exit 1

fi


# =============================================================================
# 3. Verify actual WanGP CLI
# =============================================================================

echo "=== [3/5] Verifying installed WanGP CLI ==="

echo "[INFO] WanGP commit:"
git rev-parse --short HEAD

echo "[INFO] Python:"
which python
python --version

echo "[INFO] Checking supported CLI flags..."

if python wgp.py --help 2>&1 | grep -q -- "--profile"; then
    echo "[OK] --profile supported"
else
    echo "[ERROR] --profile unsupported"
    exit 1
fi

if python wgp.py --help 2>&1 | grep -q -- "--perc-reserved-mem-max"; then
    echo "[OK] --perc-reserved-mem-max supported"
else
    echo "[ERROR] --perc-reserved-mem-max unsupported"
    exit 1
fi

if python wgp.py --help 2>&1 | grep -q -- "--attention"; then
    echo "[OK] --attention supported"
else
    echo "[ERROR] --attention unsupported"
    exit 1
fi

if python wgp.py --help 2>&1 | grep -q -- "--compile"; then
    echo "[OK] --compile supported"
else
    echo "[ERROR] --compile unsupported"
    exit 1
fi

if python wgp.py --help 2>&1 | grep -q -- "--teacache"; then
    echo "[INFO] --teacache supported"
else
    echo "[INFO] --teacache NOT supported — not used"
fi


# =============================================================================
# 3b. Verify Sage2 specifically
# =============================================================================

echo "=== Verifying SageAttention 2 ==="

python - <<'PY'
import sageattention

print("[OK] sageattention Python module imported")

try:
    print("[INFO] Module:", sageattention.__file__)
except Exception:
    pass
PY


# =============================================================================
# 4. Patch supervisor launcher
# =============================================================================

echo "=== [4/5] Patching WanGP supervisor launcher ==="

if [ ! -f "${LAUNCH_FILE}" ]; then

    echo "[ERROR] Launcher not found:"
    echo "        ${LAUNCH_FILE}"

    exit 1

fi


echo "--- BEFORE ---"
cat "${LAUNCH_FILE}"


# Remove any previous injected command and replace it.
#
# IMPORTANT:
#   No --teacache.
#

sed -i \
    's|python wgp\.py.*|python wgp.py --profile 2 --perc-reserved-mem-max 0.50 --attention sage2 --compile 2>\&1|' \
    "${LAUNCH_FILE}"


chmod +x "${LAUNCH_FILE}"


echo "--- AFTER ---"
cat "${LAUNCH_FILE}"


supervisorctl reread


# =============================================================================
# 5. Create finetune definitions
# =============================================================================

echo "=== [5/5] Creating finetune definitions ==="

mkdir -p "${WANGP_DIR}/finetunes"


# =============================================================================
# MiniMax H3 T2V
# =============================================================================

cat > "${WANGP_DIR}/finetunes/minimax_h3_t2v_int8.json" << 'EOF'
{
  "model": {
    "name": "MiniMax H3 FL2VA T2V — INT8 DiT + Heretic NVFP4",
    "architecture": "minimax_h3",
    "description": "Pruned 20B MiniMax H3 T2V with INT8 ConvRot DiT and uncensored Heretic NVFP4 text encoder.",
    "URLs": [
      "https://huggingface.co/DeepBeepMeep/MiniMax-H3/resolve/main/MiniMax-H3-FL2VA-pruned_int8_convrot.safetensors"
    ],
    "text_encoder_URLs": [
      "https://huggingface.co/dotexec/MiniMax-H3-T2V-NVFP4/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_ultra_uncensored_heretic_nvfp4.safetensors"
    ]
  }
}
EOF


# =============================================================================
# MiniMax H3 I2V
# =============================================================================

cat > "${WANGP_DIR}/finetunes/minimax_h3_i2v_int8.json" << 'EOF'
{
  "model": {
    "name": "MiniMax H3 Ref2VA I2V — INT8 DiT + Heretic NVFP4",
    "architecture": "minimax_h3",
    "description": "Pruned 20B MiniMax H3 I2V with INT8 ConvRot DiT and uncensored Heretic NVFP4 text encoder.",
    "URLs": [
      "https://huggingface.co/DeepBeepMeep/MiniMax-H3/resolve/main/MiniMax-H3-Ref2VA-pruned_int8_convrot.safetensors"
    ],
    "text_encoder_URLs": [
      "https://huggingface.co/dotexec/MiniMax-H3-T2V-NVFP4/resolve/main/text_encoders/qwen3vl_32b_minimax_h3_ultra_uncensored_heretic_nvfp4.safetensors"
    ]
  }
}
EOF


# =============================================================================
# Wan2.2 Animate 14B
#
# Custom T5:
# dummy9996/6NSFW-Wan-UMT5-XXL-mxfp8-nvfp4-int4-convrot
#
# Actual file:
# nsfw_wan_umt5-xxl-nvfp4.safetensors
# =============================================================================

cat > "${WANGP_DIR}/finetunes/wan22_animate_14b_custom_t5.json" << 'EOF'
{
  "model": {
    "name": "Wan2.2 Animate 14B — Custom NSFW T5 NVFP4",
    "architecture": "animate",
    "description": "Wan2.2 Animate 14B using the custom NSFW UMT5-XXL NVFP4 text encoder.",
    "text_encoder_URLs": [
      "https://huggingface.co/dummy9996/6NSFW-Wan-UMT5-XXL-mxfp8-nvfp4-int4-convrot/resolve/main/nsfw_wan_umt5-xxl-nvfp4.safetensors"
    ]
  }
}
EOF


# =============================================================================
# Bernini-R
#
# High-noise:
# wan2.2_bernini_r_high_noise_nvfp4.safetensors
#
# Low-noise:
# wan2.2_bernini_r_low_noise_nvfp4.safetensors
#
# Custom T5:
# nsfw_wan_umt5-xxl-nvfp4.safetensors
# =============================================================================

cat > "${WANGP_DIR}/finetunes/bernini_r_nvfp4_custom_t5.json" << 'EOF'
{
  "model": {
    "name": "Bernini-R — NVFP4 + Custom NSFW T5",
    "architecture": "bernini",
    "description": "Bernini-R using NVFP4 high-noise and low-noise checkpoints with custom NSFW UMT5-XXL NVFP4 text encoder.",
    "URLs": [
      "https://huggingface.co/rzgar/Bernini-R-nvfp4/resolve/main/wan2.2_bernini_r_high_noise_nvfp4.safetensors"
    ],
    "URLs2": [
      "https://huggingface.co/rzgar/Bernini-R-nvfp4/resolve/main/wan2.2_bernini_r_low_noise_nvfp4.safetensors"
    ],
    "text_encoder_URLs": [
      "https://huggingface.co/dummy9996/6NSFW-Wan-UMT5-XXL-mxfp8-nvfp4-int4-convrot/resolve/main/nsfw_wan_umt5-xxl-nvfp4.safetensors"
    ]
  }
}
EOF


# =============================================================================
# Validate JSON
# =============================================================================

echo "=== Validating finetune JSON files ==="

for JSON_FILE in \
    "${WANGP_DIR}/finetunes/minimax_h3_t2v_int8.json" \
    "${WANGP_DIR}/finetunes/minimax_h3_i2v_int8.json" \
    "${WANGP_DIR}/finetunes/wan22_animate_14b_custom_t5.json" \
    "${WANGP_DIR}/finetunes/bernini_r_nvfp4_custom_t5.json"
do

    echo "[CHECK] ${JSON_FILE}"

    python -m json.tool "${JSON_FILE}" >/dev/null

    echo "[OK] ${JSON_FILE}"

done


# =============================================================================
# Refresh WanGP model catalog
# =============================================================================

echo "=== Refreshing WanGP model catalog ==="

# The CLI supports --refresh-catalog.
# This does not download the actual model weights.
python wgp.py --refresh-catalog || true


# =============================================================================
# Start WanGP
# =============================================================================

echo "=== Starting Wan2GP ==="

supervisorctl update

supervisorctl start wan2gp || true


# =============================================================================
# Final status
# =============================================================================

echo ""
echo "============================================================"
echo "  Custom WanGP provisioning complete"
echo "============================================================"
echo ""
echo "WanGP:"
echo "  Commit:       $(git rev-parse --short HEAD)"
echo ""
echo "Performance:"
echo "  Profile:      2"
echo "  RAM ceiling:  50%"
echo "  Attention:    sage2"
echo "  Compile:      ON"
echo "  TeaCache:     OFF"
echo ""
echo "SageAttention:"
echo "  Installed:    VERIFIED"
echo ""
echo "Models:"
echo "  H3 T2V:       ON-DEMAND"
echo "  H3 I2V:       ON-DEMAND"
echo "  Animate 14B:  ON-DEMAND"
echo "  Bernini-R:    ON-DEMAND"
echo ""
echo "T5:"
echo "  Custom:       nsfw_wan_umt5-xxl-nvfp4.safetensors"
echo ""
echo "Pre-seeding:"
echo "  DISABLED"
echo ""
echo "============================================================"
