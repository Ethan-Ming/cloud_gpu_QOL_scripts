#!/bin/bash
# =============================================================================
# Wan2GP Vast.ai Provisioning
#
# Automatic GPU/environment detection
# Automatic Python / PyTorch / CUDA environment selection
# Automatic SageAttention installation
# Automatic INT4/FP4 kernel installation
#
# Models are NOT pre-seeded.
# All model weights are downloaded through WanGP finetune JSONs on demand.
#
# Based on current WanGP:
#   https://github.com/deepbeepmeep/Wan2GP
# =============================================================================

set -euo pipefail


# =============================================================================
# Configuration
# =============================================================================

WANGP_DIR="/workspace/Wan2GP"
WANGP_ENV="/venv/wan2gp"

LAUNCH_FILE="/opt/supervisor-scripts/wan2gp.sh"

WANGP_REPO="https://github.com/deepbeepmeep/Wan2GP.git"

TORCH_INDEX="https://download.pytorch.org/whl/cu130"

TORCH_PACKAGES="torch==2.10.0 torchvision==0.25.0 torchaudio==2.10.0"


# =============================================================================
# Helper functions
# =============================================================================

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

die() {
    echo
    echo "[ERROR] $1"
    exit 1
}


# =============================================================================
# 0. Detect GPU
# =============================================================================

log "[0/8] Detecting GPU"


if ! command -v nvidia-smi >/dev/null 2>&1; then
    die "nvidia-smi not found. This script currently supports NVIDIA GPUs only."
fi


GPU_NAME="$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n1 | xargs || true)"

GPU_CC="$(nvidia-smi --query-gpu=compute_cap --format=csv,noheader 2>/dev/null | head -n1 | xargs || true)"

GPU_DRIVER="$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -n1 | xargs || true)"


echo "GPU:          ${GPU_NAME}"
echo "Compute Cap:  ${GPU_CC}"
echo "Driver:       ${GPU_DRIVER}"


if [[ -z "${GPU_NAME}" ]]; then
    die "Could not determine GPU."
fi


# =============================================================================
# Determine GPU generation
# =============================================================================

GPU_PROFILE=""


case "${GPU_NAME}" in

    *RTX\ 50*|*RTX\ PRO\ 50*)
        GPU_PROFILE="RTX_50"
        ;;

    *RTX\ 40*|*RTX\ PRO\ 40*)
        GPU_PROFILE="RTX_40"
        ;;

    *RTX\ 30*|*RTX\ A*|*A10*|*A40*)
        GPU_PROFILE="RTX_30"
        ;;

    *RTX\ 20*|*T4*|*Quadro\ RTX*)
        GPU_PROFILE="RTX_20"
        ;;

    *GTX\ 10*|*P40*|*P100*)
        GPU_PROFILE="GTX_10"
        ;;

    *)
        die "Unsupported / unknown NVIDIA GPU: ${GPU_NAME}"
        ;;

esac


echo "WanGP GPU profile: ${GPU_PROFILE}"


# =============================================================================
# Determine package profile
#
# Mirrors current WanGP setup_config.json.
# =============================================================================

case "${GPU_PROFILE}" in

    RTX_50)

        PYTHON_MAJOR="3.11"

        TORCH_SPEC="${TORCH_PACKAGES}"
        TORCH_INDEX_URL="${TORCH_INDEX}"

        TRITON_SPEC="triton"

        SAGE_REQUIRED="2.2.0"

        NUNCHAKU_REQUIRED="yes"

        LIGHT2XV_REQUIRED="yes"

        ;;

    RTX_40)

        PYTHON_MAJOR="3.11"

        TORCH_SPEC="${TORCH_PACKAGES}"
        TORCH_INDEX_URL="${TORCH_INDEX}"

        TRITON_SPEC="triton"

        SAGE_REQUIRED="2.2.0"

        NUNCHAKU_REQUIRED="yes"

        LIGHT2XV_REQUIRED="no"

        ;;

    RTX_30)

        PYTHON_MAJOR="3.11"

        TORCH_SPEC="${TORCH_PACKAGES}"
        TORCH_INDEX_URL="${TORCH_INDEX}"

        TRITON_SPEC="triton"

        SAGE_REQUIRED="2.2.0"

        NUNCHAKU_REQUIRED="yes"

        LIGHT2XV_REQUIRED="no"

        ;;

    RTX_20)

        PYTHON_MAJOR="3.11"

        TORCH_SPEC="${TORCH_PACKAGES}"
        TORCH_INDEX_URL="${TORCH_INDEX}"

        TRITON_SPEC="triton"

        SAGE_REQUIRED="1.0.6"

        NUNCHAKU_REQUIRED="yes"

        LIGHT2XV_REQUIRED="no"

        ;;

    GTX_10)

        PYTHON_MAJOR="3.10"

        TORCH_SPEC="torch==2.7.1 torchvision==0.22.1 torchaudio==2.7.1"

        TORCH_INDEX_URL="https://download.pytorch.org/whl/cu128"

        TRITON_SPEC=""

        SAGE_REQUIRED="none"

        NUNCHAKU_REQUIRED="no"

        LIGHT2XV_REQUIRED="no"

        ;;

esac


echo
echo "Selected environment:"
echo "  Python:       ${PYTHON_MAJOR}"
echo "  PyTorch:      ${TORCH_SPEC}"
echo "  CUDA wheel:   ${TORCH_INDEX_URL}"
echo "  Triton:       ${TRITON_SPEC}"
echo "  Sage:         ${SAGE_REQUIRED}"
echo "  Nunchaku:     ${NUNCHAKU_REQUIRED}"
echo "  Light2xv:     ${LIGHT2XV_REQUIRED}"


# =============================================================================
# 1. Stop existing Wan2GP
# =============================================================================

log "[1/8] Stopping existing Wan2GP"

supervisorctl stop wan2gp || true


# =============================================================================
# 2. Clone / update Wan2GP
# =============================================================================

log "[2/8] Updating Wan2GP"


if [ ! -d "${WANGP_DIR}/.git" ]; then

    echo "Cloning Wan2GP..."

    mkdir -p "$(dirname "${WANGP_DIR}")"

    git clone "${WANGP_REPO}" "${WANGP_DIR}"

else

    echo "Updating existing Wan2GP..."

    cd "${WANGP_DIR}"

    git fetch origin

    git reset --hard origin/main

fi


cd "${WANGP_DIR}"

echo "WanGP commit:"
git rev-parse --short HEAD


# =============================================================================
# 3. Prepare Python environment
# =============================================================================

log "[3/8] Preparing Python environment"


# -----------------------------------------------------------------------------
# First inspect Vast's existing environment
# -----------------------------------------------------------------------------

echo "Checking existing /venv/main..."

if [ -x "/venv/main/bin/python" ]; then

    /venv/main/bin/python - <<'PY'
try:
    import torch

    print("Existing Python:", __import__("sys").version.split()[0])
    print("Existing Torch:", torch.__version__)
    print("Existing Torch CUDA:", torch.version.cuda)

except Exception as e:
    print("Could not inspect existing Torch:", e)
PY

else

    echo "/venv/main does not exist."

fi


# -----------------------------------------------------------------------------
# Find conda
# -----------------------------------------------------------------------------

CONDA_BIN=""

if command -v conda >/dev/null 2>&1; then

    CONDA_BIN="$(command -v conda)"

elif [ -x "/opt/conda/bin/conda" ]; then

    CONDA_BIN="/opt/conda/bin/conda"

elif [ -x "/root/miniconda3/bin/conda" ]; then

    CONDA_BIN="/root/miniconda3/bin/conda"

fi


# -----------------------------------------------------------------------------
# We need Python 3.11 for RTX 20-50.
#
# If Vast's environment is already compatible, reuse it.
# Otherwise create an isolated conda environment.
# -----------------------------------------------------------------------------

USE_EXISTING_ENV="no"


if [ -x "/venv/main/bin/python" ]; then

    EXISTING_PYTHON="$(
        /venv/main/bin/python -c \
        'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' \
        2>/dev/null || echo "unknown"
    )"

    EXISTING_TORCH="$(
        /venv/main/bin/python -c \
        'import torch; print(torch.__version__)' \
        2>/dev/null || echo "missing"
    )"

    EXISTING_CUDA="$(
        /venv/main/bin/python -c \
        'import torch; print(torch.version.cuda)' \
        2>/dev/null || echo "missing"
    )"


    if [ "${EXISTING_PYTHON}" = "${PYTHON_MAJOR}" ] && \
       [[ "${EXISTING_TORCH}" == 2.10.* ]] && \
       [ "${EXISTING_CUDA}" = "13.0" ]; then

        echo "[OK] Existing Vast environment already matches."
        USE_EXISTING_ENV="yes"

    else

        echo "[INFO] Existing environment does not match WanGP profile."

        echo "       Python: ${EXISTING_PYTHON}"
        echo "       Torch:  ${EXISTING_TORCH}"
        echo "       CUDA:   ${EXISTING_CUDA}"

    fi

fi


# -----------------------------------------------------------------------------
# Create isolated environment if required
# -----------------------------------------------------------------------------

if [ "${USE_EXISTING_ENV}" = "yes" ]; then

    WANGP_PYTHON="/venv/main/bin/python"

else

    if [ -z "${CONDA_BIN}" ]; then

        die "WanGP needs Python ${PYTHON_MAJOR}, but no compatible existing environment or Conda installation was found."

    fi


    echo "Creating isolated WanGP environment:"
    echo "  ${WANGP_ENV}"


    # Initialize conda for this shell.
    CONDA_BASE="$(
        dirname \
        "$(dirname "${CONDA_BIN}")"
    )"


    # shellcheck disable=SC1091
    source "${CONDA_BASE}/etc/profile.d/conda.sh"


    ENV_NAME="wan2gp"

    if conda env list | awk '{print $1}' | grep -qx "${ENV_NAME}"; then

        echo "[INFO] Conda environment ${ENV_NAME} already exists."

    else

        echo "[INFO] Creating Python ${PYTHON_MAJOR} environment..."

        conda create \
            -y \
            -n "${ENV_NAME}" \
            "python=${PYTHON_MAJOR}"

    fi


    conda activate "${ENV_NAME}"

    WANGP_PYTHON="$(which python)"

fi


echo
echo "Using Python:"
echo "  ${WANGP_PYTHON}"

"${WANGP_PYTHON}" --version


# =============================================================================
# 4. Install / repair PyTorch + acceleration stack
# =============================================================================

log "[4/8] Installing acceleration stack"


# -----------------------------------------------------------------------------
# PyTorch
# -----------------------------------------------------------------------------

if [ "${GPU_PROFILE}" != "GTX_10" ]; then

    echo "Checking PyTorch..."

    CURRENT_TORCH="$(
        "${WANGP_PYTHON}" -c \
        'import torch; print(torch.__version__)' \
        2>/dev/null || echo "missing"
    )

    CURRENT_CUDA="$(
        "${WANGP_PYTHON}" -c \
        'import torch; print(torch.version.cuda)' \
        2>/dev/null || echo "missing"
    )


    if [[ "${CURRENT_TORCH}" == 2.10.* ]] && \
       [ "${CURRENT_CUDA}" = "13.0" ]; then

        echo "[OK] PyTorch 2.10 + CUDA 13 already installed."

    else

        echo "[INFO] Installing WanGP recommended PyTorch..."

        "${WANGP_PYTHON}" -m pip install \
            --upgrade \
            ${TORCH_SPEC} \
            --index-url "${TORCH_INDEX_URL}"

    fi

else

    CURRENT_TORCH="$(
        "${WANGP_PYTHON}" -c \
        'import torch; print(torch.__version__)' \
        2>/dev/null || echo "missing"
    )

    if [[ "${CURRENT_TORCH}" == 2.7.1* ]]; then

        echo "[OK] PyTorch 2.7.1 already installed."

    else

        "${WANGP_PYTHON}" -m pip install \
            --upgrade \
            ${TORCH_SPEC} \
            --index-url "${TORCH_INDEX_URL}"

    fi

fi


# -----------------------------------------------------------------------------
# Verify Torch before compiling kernels
# -----------------------------------------------------------------------------

"${WANGP_PYTHON}" - <<'PY'

import torch

print()
print("PyTorch:", torch.__version__)
print("Torch CUDA:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if torch.cuda.is_available():
    print("GPU:", torch.cuda.get_device_name(0))
    print("Compute capability:", torch.cuda.get_device_capability(0))

PY


# -----------------------------------------------------------------------------
# Triton
# -----------------------------------------------------------------------------

if [ -n "${TRITON_SPEC}" ]; then

    echo
    echo "Checking Triton..."

    if "${WANGP_PYTHON}" -c "import triton" >/dev/null 2>&1; then

        TRITON_VERSION="$(
            "${WANGP_PYTHON}" -c \
            'import triton; print(triton.__version__)'
        )

        echo "[OK] Triton ${TRITON_VERSION} already installed."

    else

        echo "[INFO] Installing Triton..."

        "${WANGP_PYTHON}" -m pip install -U "${TRITON_SPEC}"

    fi

fi


# -----------------------------------------------------------------------------
# WanGP requirements
# -----------------------------------------------------------------------------

echo
echo "Installing WanGP Python requirements..."

"${WANGP_PYTHON}" -m pip install \
    -r "${WANGP_DIR}/requirements.txt"


# =============================================================================
# 5. SageAttention
# =============================================================================

log "[5/8] Installing / verifying SageAttention"


if [ "${SAGE_REQUIRED}" = "none" ]; then

    echo "[INFO] SageAttention is not supported for this GPU profile."

else

    SAGE_VERSION="$(
        "${WANGP_PYTHON}" -c \
        'import sageattention; print(getattr(sageattention, "__version__", "unknown"))' \
        2>/dev/null || echo "missing"
    )


    if [ "${SAGE_REQUIRED}" = "1.0.6" ]; then

        if [ "${SAGE_VERSION}" != "1.0.6" ]; then

            echo "[INFO] Installing SageAttention 1.0.6..."

            "${WANGP_PYTHON}" -m pip install \
                --upgrade \
                "sageattention==1.0.6"

        else

            echo "[OK] SageAttention 1.0.6 already installed."

        fi

    else

        # ---------------------------------------------------------------------
        # WanGP's own setup_config.json says:
        #
        # Linux:
        #
        # setuptools<=75.8.2
        # ninja
        # wheel
        # git clone SageAttention
        # pip install --no-build-isolation -e SageAttention
        #
        # This is exactly what we use.
        # ---------------------------------------------------------------------

        echo "[INFO] SageAttention 2.2.0 required."

        "${WANGP_PYTHON}" -m pip install \
            "setuptools<=75.8.2" \
            ninja \
            wheel \
            --force-reinstall


        SAGE_DIR="/tmp/SageAttention"

        rm -rf "${SAGE_DIR}"

        git clone \
            --depth 1 \
            --branch main \
            https://github.com/thu-ml/SageAttention.git \
            "${SAGE_DIR}"


        cd "${SAGE_DIR}"


        echo "[INFO] Building/installing SageAttention 2..."

        "${WANGP_PYTHON}" -m pip install \
            --no-build-isolation \
            -e .


        cd "${WANGP_DIR}"

    fi

fi


# -----------------------------------------------------------------------------
# Verify SageAttention
# -----------------------------------------------------------------------------

if [ "${SAGE_REQUIRED}" != "none" ]; then

    "${WANGP_PYTHON}" - <<'PY'

import sageattention

print("[OK] SageAttention imported successfully.")
print("[OK] Location:", sageattention.__file__)

PY

fi


# =============================================================================
# 6. INT4 / FP4 kernels
# =============================================================================

# =============================================================================
# INT4 / FP4 SAFETY CHECK
#
# IMPORTANT:
# Before installing Nunchaku / Light2xv into a new environment, inspect the
# original Vast environment (/venv/main).
#
# If Vast already provides a working INT4/FP4 stack, reuse /venv/main instead
# of installing a second copy.
# =============================================================================

log "[6/8] Checking existing INT4 / FP4 support"


ORIGINAL_ENV="/venv/main"

ORIGINAL_NUNCHAKU_OK="no"
ORIGINAL_LIGHT2XV_OK="no"


# =============================================================================
# Check original Vast environment for Nunchaku
# =============================================================================

if [ -x "${ORIGINAL_ENV}/bin/python" ]; then

    echo "[INFO] Checking original Vast environment:"
    echo "       ${ORIGINAL_ENV}"


    if "${ORIGINAL_ENV}/bin/python" -c "import nunchaku" >/dev/null 2>&1; then

        echo "[OK] Nunchaku package exists in original Vast environment."

        if "${ORIGINAL_ENV}/bin/python" - <<'PY'
import torch
import nunchaku

assert torch.cuda.is_available()

gpu = torch.cuda.get_device_name(0)

print("GPU:", gpu)
print("Torch:", torch.__version__)
print("CUDA:", torch.version.cuda)
print("Nunchaku:", nunchaku.__file__)

PY
        then

            ORIGINAL_NUNCHAKU_OK="yes"

            echo "[OK] Existing Nunchaku environment is CUDA-usable."

        else

            echo "[WARN] Nunchaku exists but failed CUDA initialization."

        fi

    else

        echo "[INFO] Nunchaku is not installed in original Vast environment."

    fi

else

    echo "[INFO] Original Vast environment does not exist."

fi


# =============================================================================
# RTX 50: check existing Light2xv
# =============================================================================

if [ "${LIGHT2XV_REQUIRED}" = "yes" ]; then

    echo
    echo "[INFO] RTX 50 detected — checking existing Light2xv."


    if "${ORIGINAL_ENV}/bin/python" -c "import lightx2v" >/dev/null 2>&1; then

        echo "[OK] Light2xv exists in original Vast environment."


        if "${ORIGINAL_ENV}/bin/python" - <<'PY'
import torch
import lightx2v

assert torch.cuda.is_available()

print("GPU:", torch.cuda.get_device_name(0))
print("Torch:", torch.__version__)
print("CUDA:", torch.version.cuda)
print("Light2xv:", lightx2v.__file__)

PY
        then

            ORIGINAL_LIGHT2XV_OK="yes"

            echo "[OK] Existing Light2xv environment is CUDA-usable."

        else

            echo "[WARN] Light2xv exists but failed CUDA initialization."

        fi

    else

        echo "[INFO] Light2xv is not installed in original Vast environment."

    fi

fi


# =============================================================================
# Decide whether original Vast environment can be reused
# =============================================================================

if [ "${ORIGINAL_NUNCHAKU_OK}" = "yes" ]; then

    echo
    echo "------------------------------------------------------------"
    echo "[OK] Existing Vast INT4/FP4 stack detected."
    echo "------------------------------------------------------------"
    echo
    echo "Nunchaku is already installed and CUDA-usable in:"
    echo
    echo "    ${ORIGINAL_ENV}"
    echo
    echo "Skipping Nunchaku installation."
    echo


    # -------------------------------------------------------------------------
    # IMPORTANT:
    #
    # If we are going to reuse /venv/main for WanGP, don't create another
    # Python environment containing a second Nunchaku installation.
    # -------------------------------------------------------------------------

    if [ "${WANGP_PYTHON}" != "${ORIGINAL_ENV}/bin/python" ]; then

        echo "[INFO] Switching WanGP back to original Vast environment."

        WANGP_PYTHON="${ORIGINAL_ENV}/bin/python"

    fi

else

    echo
    echo "[INFO] No usable Nunchaku found in original Vast environment."
    echo "[INFO] Installing Nunchaku into WanGP environment."


    if [ "${NUNCHAKU_REQUIRED}" = "yes" ]; then

        if "${WANGP_PYTHON}" -c "import nunchaku" >/dev/null 2>&1; then

            echo "[OK] Nunchaku already installed in WanGP environment."

        else

            echo "[INFO] Installing Nunchaku..."

            "${WANGP_PYTHON}" -m pip install \
                "https://github.com/nunchaku-ai/nunchaku/releases/download/v1.2.1/nunchaku-1.2.1+cu13.0torch2.10-cp311-cp311-linux_x86_64.whl"

        fi

    fi

fi


# =============================================================================
# Light2xv
# =============================================================================

if [ "${LIGHT2XV_REQUIRED}" = "yes" ]; then

    echo
    echo "Checking Light2xv..."


    if [ "${ORIGINAL_LIGHT2XV_OK}" = "yes" ]; then

        echo "[OK] Existing Vast Light2xv is usable."

        if [ "${WANGP_PYTHON}" != "${ORIGINAL_ENV}/bin/python" ]; then

            echo "[WARN] Light2xv exists in /venv/main but WanGP is using another env."

            echo "[INFO] Installing Light2xv into WanGP environment as well."

        else

            echo "[OK] Reusing original Light2xv."

        fi

    fi


    # Install only if the selected WanGP environment does not already provide
    # Light2xv.

    if ! "${WANGP_PYTHON}" -c "import lightx2v" >/dev/null 2>&1; then

        echo "[INFO] Installing Light2xv NVFP4 kernel..."

        "${WANGP_PYTHON}" -m pip install \
            "https://github.com/deepbeepmeep/kernels/releases/download/Light2xv/lightx2v_kernel-0.0.2+torch2.10.0-cp311-abi3-linux_x86_64.whl"

    else

        echo "[OK] Light2xv already available in selected environment."

    fi

fi

 

# =============================================================================
# 7. Verify entire acceleration environment
# =============================================================================

log "[7/8] Final acceleration verification"


"${WANGP_PYTHON}" - <<'PY'

import sys

print("Python:", sys.version)

try:
    import torch

    print("PyTorch:", torch.__version__)
    print("Torch CUDA:", torch.version.cuda)

    if torch.cuda.is_available():

        print("GPU:", torch.cuda.get_device_name(0))
        print("CUDA:", torch.cuda.get_device_capability(0))

except Exception as e:

    print("PyTorch ERROR:", e)


try:

    import triton

    print("Triton:", triton.__version__)

except Exception as e:

    print("Triton: NOT AVAILABLE")


try:

    import sageattention

    print("SageAttention: INSTALLED")
    print("SageAttention path:", sageattention.__file__)

except Exception as e:

    print("SageAttention: NOT AVAILABLE")
    print("Error:", e)


try:

    import nunchaku

    print("Nunchaku: INSTALLED")

except Exception as e:

    print("Nunchaku: NOT AVAILABLE")
    print("Error:", e)


try:

    import lightx2v

    print("Light2xv: INSTALLED")

except Exception:

    print("Light2xv: not installed / not required")


PY


# =============================================================================
# Verify SageAttention before continuing
# =============================================================================

if [ "${SAGE_REQUIRED}" != "none" ]; then

    if ! "${WANGP_PYTHON}" -c "import sageattention" >/dev/null 2>&1; then

        die "SageAttention installation failed. WanGP will NOT be started."

    fi

fi


# =============================================================================
# Verify WanGP CLI
# =============================================================================

echo
echo "Checking WanGP CLI..."

"${WANGP_PYTHON}" \
    "${WANGP_DIR}/wgp.py" \
    --help >/dev/null


echo "[OK] WanGP CLI works."


# =============================================================================
# 8. Patch supervisor
# =============================================================================

log "[8/8] Configuring WanGP supervisor"


if [ ! -f "${LAUNCH_FILE}" ]; then

    die "WanGP supervisor launcher not found: ${LAUNCH_FILE}"

fi


echo "--- BEFORE ---"
cat "${LAUNCH_FILE}"


# -----------------------------------------------------------------------------
# Replace Python activation / executable.
#
# This is important because Vast originally points at /venv/main.
# We point it at the environment selected above.
# -----------------------------------------------------------------------------

sed -i \
    "s|/venv/main/bin/activate|${WANGP_PYTHON%/bin/python}/bin/activate|g" \
    "${LAUNCH_FILE}"


# Replace Python executable.
sed -i \
    -E \
    "s|python wgp\.py.*|${WANGP_PYTHON} wgp.py --profile 2 --perc-reserved-mem-max 0.50 --attention sage2 --compile 2>\&1|" \
    "${LAUNCH_FILE}"


chmod +x "${LAUNCH_FILE}"


echo "--- AFTER ---"
cat "${LAUNCH_FILE}"


# =============================================================================
# Refresh supervisor
# =============================================================================

supervisorctl reread

supervisorctl update


# =============================================================================
# Create finetune directory
# =============================================================================

mkdir -p "${WANGP_DIR}/finetunes"


# =============================================================================
# MiniMax H3 T2V
# =============================================================================

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


# =============================================================================
# MiniMax H3 I2V
# =============================================================================

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


# =============================================================================
# Wan2.2 Animate 14B
#
# IMPORTANT:
# This is an architecture-specific finetune.
#
# The custom T5 is:
#
# dummy9996/6NSFW-Wan-UMT5-XXL-mxfp8-nvfp4-int4-convrot
#
# Actual file:
#
# nsfw_wan_umt5-xxl-nvfp4.safetensors
# =============================================================================

cat > "${WANGP_DIR}/finetunes/wan22_animate_14b_custom_t5.json" << 'EOF'
{
  "id": "wan22_animate_14b_custom_t5",
  "name": "Wan2.2 Animate 14B — Custom NSFW T5 NVFP4",
  "description": "Wan2.2 Animate 14B with custom NVFP4 UMT5-XXL text encoder.",
  "model": {
    "architecture": "animate",
    "text_encoder_URLs": [
      "https://huggingface.co/dummy9996/6NSFW-Wan-UMT5-XXL-mxfp8-nvfp4-int4-convrot/resolve/main/nsfw_wan_umt5-xxl-nvfp4.safetensors"
    ]
  }
}
EOF


# =============================================================================
# Bernini-R
# =============================================================================

cat > "${WANGP_DIR}/finetunes/bernini_r_nvfp4_custom_t5.json" << 'EOF'
{
  "id": "bernini_r_nvfp4_custom_t5",
  "name": "Bernini-R — NVFP4 + Custom NSFW T5",
  "description": "Bernini-R using NVFP4 high/low-noise checkpoints and custom NVFP4 UMT5-XXL.",
  "model": {
    "architecture": "bernini",
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

echo
echo "Validating finetune JSON..."

for file in \
    "${WANGP_DIR}/finetunes/minimax_h3_t2v_int8.json" \
    "${WANGP_DIR}/finetunes/minimax_h3_i2v_int8.json" \
    "${WANGP_DIR}/finetunes/wan22_animate_14b_custom_t5.json" \
    "${WANGP_DIR}/finetunes/bernini_r_nvfp4_custom_t5.json"
do

    python -m json.tool "${file}" >/dev/null

    echo "[OK] ${file}"

done


# =============================================================================
# Start Wan2GP
# =============================================================================

echo
echo "Starting Wan2GP..."

supervisorctl start wan2gp


# =============================================================================
# Final
# =============================================================================

echo
echo "============================================================"
echo "           Wan2GP provisioning COMPLETE"
echo "============================================================"
echo
echo "GPU:"
echo "  ${GPU_NAME}"
echo "  Profile: ${GPU_PROFILE}"
echo
echo "Environment:"
echo "  Python:       ${PYTHON_MAJOR}"
echo "  PyTorch:      ${TORCH_SPEC}"
echo "  CUDA wheel:   ${TORCH_INDEX_URL}"
echo
echo "Acceleration:"
echo "  Triton:       ${TRITON_SPEC:-none}"
echo "  Sage:         ${SAGE_REQUIRED}"
echo "  Nunchaku:     ${NUNCHAKU_REQUIRED}"
echo "  Light2xv:     ${LIGHT2XV_REQUIRED}"
echo
echo "WanGP:"
echo "  Profile:      2"
echo "  Attention:    sage2"
echo "  Compilation:  ON"
echo
echo "Models:"
echo "  Pre-seeding:  OFF"
echo "  H3 T2V:       ON-DEMAND"
echo "  H3 I2V:       ON-DEMAND"
echo "  Animate 14B:  ON-DEMAND"
echo "  Bernini-R:    ON-DEMAND"
echo
echo "T5:"
echo "  nsfw_wan_umt5-xxl-nvfp4.safetensors"
echo
echo "============================================================"
