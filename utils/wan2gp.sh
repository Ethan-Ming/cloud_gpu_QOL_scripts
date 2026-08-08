#!/bin/bash
# =============================================================================
# Wan2GP Vast.ai Provisioning
#
# Goals:
#   - Automatically detect GPU
#   - Automatically select a compatible Python / PyTorch / CUDA environment
#   - Repair CUDA-toolkit / PyTorch CUDA mismatches automatically
#   - Install SageAttention automatically
#   - Install INT4/FP4 acceleration only when actually required
#   - Preserve already-working INT4/FP4 packages in the original Vast env
#   - Never switch Python environments after environment selection
#   - No model pre-seeding
#   - All model weights are downloaded ON-DEMAND through finetune JSONs
#
# Current WanGP reference:
#   https://github.com/deepbeepmeep/Wan2GP
#
# Current WanGP setup_config:
#   Python 3.11.14 recommended
#   Torch 2.10.0 + CUDA 13.0
#   SageAttention 2.2.0 CUDA 13
#
# =============================================================================

set -euo pipefail


# =============================================================================
# Configuration
# =============================================================================

WANGP_DIR="/workspace/Wan2GP"
WANGP_ENV="/venv/wan2gp"
WANGP_ENV_NAME="wan2gp"

ORIGINAL_ENV="/venv/main"

WANGP_REPO="https://github.com/deepbeepmeep/Wan2GP.git"

SUPERVISOR_FILE="/opt/supervisor-scripts/wan2gp.sh"

TORCH_INDEX_CU130="https://download.pytorch.org/whl/cu130"
TORCH_INDEX_CU128="https://download.pytorch.org/whl/cu128"

TORCH_CU130="torch==2.10.0 torchvision==0.25.0 torchaudio==2.10.0"
TORCH_CU128="torch==2.7.1 torchvision==0.22.1 torchaudio==2.7.1"

# NVIDIA's CUDA 13.0 Python packages.
#
# We only install these when the selected environment does not already have
# a usable CUDA 13.0 toolkit.
CUDA_NVCC_PACKAGE="nvidia-cuda-nvcc==13.0.88"
CUDA_RUNTIME_PACKAGE="nvidia-cuda-runtime==13.0.96"
CUDA_CCCL_PACKAGE="nvidia-cuda-cccl==13.0.85"

# SageAttention repository.
SAGE_REPO="https://github.com/thu-ml/SageAttention.git"

# RTX 50 / 40 / 30:
SAGE2_REQUIRED="2.2.0"

# RTX 20:
SAGE1_REQUIRED="1.0.6"

# Nunchaku wheel currently used by WanGP for the CUDA 13 / Torch 2.10 stack.
NUNCHAKU_WHEEL="https://github.com/nunchaku-ai/nunchaku/releases/download/v1.2.1/nunchaku-1.2.1+cu13.0torch2.10-cp311-cp311-linux_x86_64.whl"

# LightX2V NVFP4 kernel.
LIGHT2XV_WHEEL="https://github.com/deepbeepmeep/kernels/releases/download/Light2xv/lightx2v_kernel-0.0.2+torch2.10.0-cp311-abi3-linux_x86_64.whl"


# =============================================================================
# Logging
# =============================================================================

log() {
    echo
    echo "============================================================"
    echo "$1"
    echo "============================================================"
}

info() {
    echo "[INFO] $1"
}

ok() {
    echo "[OK] $1"
}

warn() {
    echo "[WARN] $1"
}

die() {
    echo
    echo "[ERROR] $1"
    echo
    exit 1
}


# =============================================================================
# Basic requirements
# =============================================================================

command -v git >/dev/null 2>&1 || die "git is not installed."

command -v nvidia-smi >/dev/null 2>&1 || \
    die "nvidia-smi was not found. NVIDIA GPU required."


# =============================================================================
# 0. Detect GPU
# =============================================================================

log "[0/9] Detecting GPU"

GPU_NAME="$(
    nvidia-smi \
        --query-gpu=name \
        --format=csv,noheader \
        2>/dev/null |
        head -n1 |
        xargs
)"

GPU_CC="$(
    nvidia-smi \
        --query-gpu=compute_cap \
        --format=csv,noheader \
        2>/dev/null |
        head -n1 |
        xargs || true
)"

GPU_DRIVER="$(
    nvidia-smi \
        --query-gpu=driver_version \
        --format=csv,noheader \
        2>/dev/null |
        head -n1 |
        xargs || true
)"

[ -n "${GPU_NAME}" ] || die "Could not determine GPU."

echo "GPU:          ${GPU_NAME}"
echo "Compute Cap:  ${GPU_CC:-unknown}"
echo "Driver:       ${GPU_DRIVER:-unknown}"


# =============================================================================
# GPU profile
# =============================================================================

GPU_PROFILE=""

case "${GPU_NAME}" in

    *"RTX 50"*|*"RTX PRO 50"*)
        GPU_PROFILE="RTX_50"
        ;;

    *"RTX 40"*|*"RTX PRO 40"*)
        GPU_PROFILE="RTX_40"
        ;;

    *"RTX 30"*|*"RTX A"*|*"A10"*|*"A40"*)
        GPU_PROFILE="RTX_30"
        ;;

    *"RTX 20"*|*"T4"*|*"Quadro RTX"*)
        GPU_PROFILE="RTX_20"
        ;;

    *"GTX 10"*|*"P40"*|*"P100"*)
        GPU_PROFILE="GTX_10"
        ;;

    *)
        die "Unsupported / unknown NVIDIA GPU: ${GPU_NAME}"
        ;;

esac


# =============================================================================
# Select WanGP acceleration profile
# =============================================================================

PYTHON_MAJOR=""
TORCH_SPEC=""
TORCH_INDEX_URL=""
SAGE_REQUIRED="none"
ATTENTION_MODE=""
NUNCHAKU_REQUIRED="no"
LIGHT2XV_REQUIRED="no"
TRITON_REQUIRED="no"

case "${GPU_PROFILE}" in

    RTX_50)

        PYTHON_MAJOR="3.11"

        TORCH_SPEC="${TORCH_CU130}"
        TORCH_INDEX_URL="${TORCH_INDEX_CU130}"

        TRITON_REQUIRED="yes"

        SAGE_REQUIRED="${SAGE2_REQUIRED}"
        ATTENTION_MODE="sage2"

        NUNCHAKU_REQUIRED="yes"
        LIGHT2XV_REQUIRED="yes"

        ;;

    RTX_40)

        PYTHON_MAJOR="3.11"

        TORCH_SPEC="${TORCH_CU130}"
        TORCH_INDEX_URL="${TORCH_INDEX_CU130}"

        TRITON_REQUIRED="yes"

        SAGE_REQUIRED="${SAGE2_REQUIRED}"
        ATTENTION_MODE="sage2"

        NUNCHAKU_REQUIRED="yes"
        LIGHT2XV_REQUIRED="no"

        ;;

    RTX_30)

        PYTHON_MAJOR="3.11"

        TORCH_SPEC="${TORCH_CU130}"
        TORCH_INDEX_URL="${TORCH_INDEX_CU130}"

        TRITON_REQUIRED="yes"

        SAGE_REQUIRED="${SAGE2_REQUIRED}"
        ATTENTION_MODE="sage2"

        NUNCHAKU_REQUIRED="yes"
        LIGHT2XV_REQUIRED="no"

        ;;

    RTX_20)

        PYTHON_MAJOR="3.11"

        TORCH_SPEC="${TORCH_CU130}"
        TORCH_INDEX_URL="${TORCH_INDEX_CU130}"

        TRITON_REQUIRED="yes"

        SAGE_REQUIRED="${SAGE1_REQUIRED}"
        ATTENTION_MODE="sage"

        NUNCHAKU_REQUIRED="yes"
        LIGHT2XV_REQUIRED="no"

        ;;

    GTX_10)

        PYTHON_MAJOR="3.10"

        TORCH_SPEC="${TORCH_CU128}"
        TORCH_INDEX_URL="${TORCH_INDEX_CU128}"

        TRITON_REQUIRED="no"

        SAGE_REQUIRED="none"
        ATTENTION_MODE="sdpa"

        NUNCHAKU_REQUIRED="no"
        LIGHT2XV_REQUIRED="no"

        ;;

esac


echo
echo "Selected WanGP profile:"
echo "  GPU profile:       ${GPU_PROFILE}"
echo "  Python:            ${PYTHON_MAJOR}"
echo "  PyTorch:           ${TORCH_SPEC}"
echo "  Torch index:       ${TORCH_INDEX_URL}"
echo "  SageAttention:     ${SAGE_REQUIRED}"
echo "  Attention mode:    ${ATTENTION_MODE}"
echo "  Triton:            ${TRITON_REQUIRED}"
echo "  Nunchaku:          ${NUNCHAKU_REQUIRED}"
echo "  Light2xv:           ${LIGHT2XV_REQUIRED}"


# =============================================================================
# 1. Stop existing WanGP
# =============================================================================

log "[1/9] Stopping existing WanGP"

supervisorctl stop wan2gp >/dev/null 2>&1 || true


# =============================================================================
# 2. Update WanGP
# =============================================================================

log "[2/9] Updating WanGP"

if [ ! -d "${WANGP_DIR}/.git" ]; then

    info "Cloning WanGP..."

    mkdir -p "$(dirname "${WANGP_DIR}")"

    git clone \
        "${WANGP_REPO}" \
        "${WANGP_DIR}"

else

    info "Updating existing WanGP..."

    cd "${WANGP_DIR}"

    git fetch origin

    git reset --hard origin/main

fi

cd "${WANGP_DIR}"

WANGP_COMMIT="$(git rev-parse --short HEAD)"

echo "WanGP commit: ${WANGP_COMMIT}"


# =============================================================================
# 3. Inspect ORIGINAL Vast environment BEFORE changing anything
# =============================================================================

log "[3/9] Inspecting original Vast environment"

ORIGINAL_PYTHON="missing"
ORIGINAL_TORCH="missing"
ORIGINAL_TORCH_CUDA="missing"
ORIGINAL_NVCC="missing"

ORIGINAL_NUNCHAKU="no"
ORIGINAL_LIGHT2XV="no"


if [ -x "${ORIGINAL_ENV}/bin/python" ]; then

    echo "Original environment: ${ORIGINAL_ENV}"

    ORIGINAL_PYTHON="$(
        "${ORIGINAL_ENV}/bin/python" \
            -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")' \
            2>/dev/null ||
        echo "missing"
    )"

    ORIGINAL_TORCH="$(
        "${ORIGINAL_ENV}/bin/python" \
            -c 'import torch; print(torch.__version__)' \
            2>/dev/null ||
        echo "missing"
    )"

    ORIGINAL_TORCH_CUDA="$(
        "${ORIGINAL_ENV}/bin/python" \
            -c 'import torch; print(torch.version.cuda)' \
            2>/dev/null ||
        echo "missing"
    )"

    echo "  Python:       ${ORIGINAL_PYTHON}"
    echo "  PyTorch:      ${ORIGINAL_TORCH}"
    echo "  Torch CUDA:   ${ORIGINAL_TORCH_CUDA}"

else

    info "/venv/main does not exist."

fi


# =============================================================================
# Detect original environment's CUDA toolkit
# =============================================================================

if [ -x "${ORIGINAL_ENV}/bin/nvcc" ]; then

    ORIGINAL_NVCC="$(
        "${ORIGINAL_ENV}/bin/nvcc" --version 2>/dev/null |
        grep -oE 'release [0-9]+\.[0-9]+' |
        head -n1 |
        awk '{print $2}' ||
        echo "missing"
    )

elif command -v nvcc >/dev/null 2>&1; then

    ORIGINAL_NVCC="$(
        nvcc --version 2>/dev/null |
        grep -oE 'release [0-9]+\.[0-9]+' |
        head -n1 |
        awk '{print $2}' ||
        echo "missing"
    )"

fi

echo "  System nvcc:  ${ORIGINAL_NVCC}"


# =============================================================================
# Check original Nunchaku
# =============================================================================

if [ -x "${ORIGINAL_ENV}/bin/python" ]; then

    if "${ORIGINAL_ENV}/bin/python" \
        -c 'import nunchaku' >/dev/null 2>&1
    then

        ORIGINAL_NUNCHAKU="yes"

        ok "Nunchaku already exists in original Vast environment."

    else

        info "Nunchaku is not importable in original Vast environment."

    fi

fi


# =============================================================================
# Check original Light2xv
# =============================================================================

if [ "${LIGHT2XV_REQUIRED}" = "yes" ] &&
   [ -x "${ORIGINAL_ENV}/bin/python" ]
then

    if "${ORIGINAL_ENV}/bin/python" \
        -c 'import lightx2v' >/dev/null 2>&1
    then

        ORIGINAL_LIGHT2XV="yes"

        ok "Light2xv already exists in original Vast environment."

    else

        info "Light2xv is not importable in original Vast environment."

    fi

fi


# =============================================================================
# Decide whether /venv/main is safe to reuse
#
# IMPORTANT:
# We only reuse the original environment if the COMPLETE Python/Torch stack
# matches the selected WanGP profile.
#
# If not, create a clean isolated environment.
# =============================================================================

USE_ORIGINAL_ENV="no"


if [ -x "${ORIGINAL_ENV}/bin/python" ]; then

    if [ "${ORIGINAL_PYTHON}" = "${PYTHON_MAJOR}" ] &&
       [ "${ORIGINAL_TORCH_CUDA}" = "13.0" ] &&
       [[ "${ORIGINAL_TORCH}" == 2.10.* ]]
    then

        USE_ORIGINAL_ENV="yes"

        ok "Original Vast Python/Torch environment matches WanGP profile."

    else

        warn "Original Vast environment does NOT match the required profile."

        echo
        echo "Required:"
        echo "  Python:       ${PYTHON_MAJOR}"
        echo "  PyTorch:      2.10.x"
        echo "  Torch CUDA:   13.0"
        echo
        echo "Detected:"
        echo "  Python:       ${ORIGINAL_PYTHON}"
        echo "  PyTorch:      ${ORIGINAL_TORCH}"
        echo "  Torch CUDA:   ${ORIGINAL_TORCH_CUDA}"
        echo
        echo "A clean isolated WanGP environment will be used."

    fi

fi


# =============================================================================
# Select Python environment ONCE
# =============================================================================

if [ "${USE_ORIGINAL_ENV}" = "yes" ]; then

    WANGP_PYTHON="${ORIGINAL_ENV}/bin/python"
    WANGP_ENV_ROOT="${ORIGINAL_ENV}"

else

    log "Creating isolated WanGP Python environment"

    CONDA_BIN=""

    if command -v conda >/dev/null 2>&1; then
        CONDA_BIN="$(command -v conda)"
    elif [ -x "/opt/conda/bin/conda" ]; then
        CONDA_BIN="/opt/conda/bin/conda"
    elif [ -x "/root/miniconda3/bin/conda" ]; then
        CONDA_BIN="/root/miniconda3/bin/conda"
    fi

    [ -n "${CONDA_BIN}" ] || \
        die "No compatible /venv/main and no Conda installation was found."

    CONDA_BASE="$(
        dirname "$(dirname "${CONDA_BIN}")"
    )"

    # shellcheck disable=SC1091
    source "${CONDA_BASE}/etc/profile.d/conda.sh"

    if conda env list |
        awk '{print $1}' |
        grep -qx "${WANGP_ENV_NAME}"
    then

        info "Conda environment ${WANGP_ENV_NAME} already exists."

    else

        info "Creating Python ${PYTHON_MAJOR} environment..."

        conda create \
            -y \
            -n "${WANGP_ENV_NAME}" \
            "python=${PYTHON_MAJOR}"

    fi

    conda activate "${WANGP_ENV_NAME}"

    WANGP_PYTHON="$(which python)"
    WANGP_ENV_ROOT="$(dirname "$(dirname "${WANGP_PYTHON}")")"

fi


# =============================================================================
# LOCK THE ENVIRONMENT
#
# From this point onward WANGP_PYTHON NEVER CHANGES.
# =============================================================================

export WANGP_PYTHON
export WANGP_ENV_ROOT

echo
echo "============================================================"
echo "LOCKED WanGP environment"
echo "============================================================"
echo "Python: ${WANGP_PYTHON}"
echo "Root:   ${WANGP_ENV_ROOT}"
echo "============================================================"

"${WANGP_PYTHON}" --version


# =============================================================================
# 4. Install / repair PyTorch
# =============================================================================

log "[4/9] Installing / repairing PyTorch"

CURRENT_TORCH="$(
    "${WANGP_PYTHON}" \
        -c 'import torch; print(torch.__version__)' \
        2>/dev/null ||
    echo "missing"
)"

CURRENT_TORCH_CUDA="$(
    "${WANGP_PYTHON}" \
        -c 'import torch; print(torch.version.cuda)' \
        2>/dev/null ||
    echo "missing"
)"


if [ "${GPU_PROFILE}" = "GTX_10" ]; then

    if [[ "${CURRENT_TORCH}" == 2.7.1* ]] &&
       [ "${CURRENT_TORCH_CUDA}" = "12.8" ]
    then

        ok "PyTorch 2.7.1 + CUDA 12.8 already installed."

    else

        info "Installing PyTorch 2.7.1 + CUDA 12.8..."

        "${WANGP_PYTHON}" -m pip install \
            --upgrade \
            ${TORCH_SPEC} \
            --index-url "${TORCH_INDEX_URL}"

    fi

else

    if [[ "${CURRENT_TORCH}" == 2.10.* ]] &&
       [ "${CURRENT_TORCH_CUDA}" = "13.0" ]
    then

        ok "PyTorch 2.10 + CUDA 13.0 already installed."

    else

        info "Installing PyTorch 2.10 + CUDA 13.0..."

        "${WANGP_PYTHON}" -m pip install \
            --upgrade \
            ${TORCH_SPEC} \
            --index-url "${TORCH_INDEX_URL}"

    fi

fi


# =============================================================================
# Verify CUDA runtime
# =============================================================================

"${WANGP_PYTHON}" - <<'PY'

import torch

print()
print("PyTorch:", torch.__version__)
print("PyTorch CUDA:", torch.version.cuda)
print("CUDA available:", torch.cuda.is_available())

if torch.cuda.is_available():

    print("GPU:", torch.cuda.get_device_name(0))
    print("Compute capability:", torch.cuda.get_device_capability(0))

PY


# =============================================================================
# Install WanGP requirements
# =============================================================================

info "Installing WanGP requirements..."

"${WANGP_PYTHON}" -m pip install \
    -r "${WANGP_DIR}/requirements.txt"


# =============================================================================
# Triton
# =============================================================================

if [ "${TRITON_REQUIRED}" = "yes" ]; then

    if "${WANGP_PYTHON}" \
        -c 'import triton' >/dev/null 2>&1
    then

        TRITON_VERSION="$(
            "${WANGP_PYTHON}" \
                -c 'import triton; print(triton.__version__)'
        )"

        ok "Triton ${TRITON_VERSION} already installed."

    else

        info "Installing Triton..."

        "${WANGP_PYTHON}" -m pip install -U triton

    fi

fi


# =============================================================================
# 5. CUDA TOOLKIT / NVCC MATCHING
#
# This is the important fix for the failure you encountered:
#
#   Detected CUDA 13.2
#   PyTorch compiled with CUDA 12.8
#
# We never compile Sage until torch.version.cuda == nvcc release.
#
# For CUDA 13.0, if the system toolkit is missing or mismatched, install the
# matching NVIDIA CUDA compiler/runtime into the selected Python environment.
# =============================================================================

log "[5/9] Checking CUDA toolkit / PyTorch CUDA compatibility"


TORCH_CUDA="$(
    "${WANGP_PYTHON}" \
        -c 'import torch; print(torch.version.cuda)' \
        2>/dev/null ||
    echo "missing"
)"


SYSTEM_NVCC=""

if command -v nvcc >/dev/null 2>&1; then

    SYSTEM_NVCC="$(
        nvcc --version 2>/dev/null |
        grep -oE 'release [0-9]+\.[0-9]+' |
        head -n1 |
        awk '{print $2}' ||
        echo ""
    )"

fi


echo "PyTorch CUDA: ${TORCH_CUDA}"
echo "System nvcc:  ${SYSTEM_NVCC:-not found}"


CUDA_HOME_SELECTED=""


# -----------------------------------------------------------------------------
# First preference:
# Existing system toolkit that exactly matches PyTorch.
# -----------------------------------------------------------------------------

if [ -n "${SYSTEM_NVCC}" ] &&
   [ "${SYSTEM_NVCC}" = "${TORCH_CUDA}" ]
then

    CUDA_HOME_SELECTED="$(
        dirname "$(dirname "$(command -v nvcc)")"
    )"

    ok "System CUDA toolkit matches PyTorch CUDA ${TORCH_CUDA}."

fi


# -----------------------------------------------------------------------------
# If system CUDA doesn't match, install a matching CUDA toolkit into the
# selected environment.
#
# We currently target CUDA 13.0 for RTX 20-50.
# -----------------------------------------------------------------------------

if [ -z "${CUDA_HOME_SELECTED}" ] &&
   [ "${TORCH_CUDA}" = "13.0" ]
then

    info "System CUDA toolkit is missing or mismatched."
    info "Installing matching CUDA 13.0 compiler/runtime into WanGP env."

    "${WANGP_PYTHON}" -m pip install \
        --upgrade \
        "${CUDA_NVCC_PACKAGE}" \
        "${CUDA_RUNTIME_PACKAGE}" \
        "${CUDA_CCCL_PACKAGE}"


    # Locate NVIDIA pip CUDA toolkit.
    CUDA_HOME_SELECTED="$(
        "${WANGP_PYTHON}" - <<'PY'
import glob
import site
import os

roots = []

try:
    roots.extend(site.getsitepackages())
except Exception:
    pass

try:
    roots.append(site.getusersitepackages())
except Exception:
    pass

matches = []

for root in roots:

    matches.extend(
        glob.glob(
            os.path.join(
                root,
                "nvidia",
                "cuda_nvcc*"
            )
        )
    )

if matches:

    print(matches[0])

PY
    )"

fi


# -----------------------------------------------------------------------------
# Configure CUDA environment
# -----------------------------------------------------------------------------

if [ -n "${CUDA_HOME_SELECTED}" ] &&
   [ -d "${CUDA_HOME_SELECTED}" ]
then

    export CUDA_HOME="${CUDA_HOME_SELECTED}"

    export PATH="${CUDA_HOME}/bin:${PATH}"


    # Pip-installed CUDA packages use:
    #
    #   .../site-packages/nvidia/cuda_runtime/include
    #   .../site-packages/nvidia/cuda_runtime/lib
    #   .../site-packages/nvidia/cuda_cccl/include
    #
    # Add them when present.
    NVIDIA_ROOT="$(
        "${WANGP_PYTHON}" - <<'PY'
import os
import site

for root in site.getsitepackages():

    candidate = os.path.join(root, "nvidia")

    if os.path.isdir(candidate):

        print(candidate)
        break

PY
    )"


    CUDA_INCLUDE_PATHS=""

    for include_dir in \
        "${NVIDIA_ROOT}/cuda_runtime/include" \
        "${NVIDIA_ROOT}/cuda_cccl/include" \
        "${CUDA_HOME}/include"
    do

        if [ -d "${include_dir}" ]; then

            if [ -n "${CUDA_INCLUDE_PATHS}" ]; then
                CUDA_INCLUDE_PATHS="${CUDA_INCLUDE_PATHS}:"
            fi

            CUDA_INCLUDE_PATHS="${CUDA_INCLUDE_PATHS}${include_dir}"

        fi

    done


    if [ -n "${CUDA_INCLUDE_PATHS}" ]; then

        if [ -n "${CPATH:-}" ]; then
            export CPATH="${CUDA_INCLUDE_PATHS}:${CPATH}"
        else
            export CPATH="${CUDA_INCLUDE_PATHS}"
        fi

    fi


    CUDA_LIBRARY_PATHS=""

    for lib_dir in \
        "${NVIDIA_ROOT}/cuda_runtime/lib" \
        "${CUDA_HOME}/lib64" \
        "${CUDA_HOME}/lib"
    do

        if [ -d "${lib_dir}" ]; then

            if [ -n "${CUDA_LIBRARY_PATHS}" ]; then
                CUDA_LIBRARY_PATHS="${CUDA_LIBRARY_PATHS}:"
            fi

            CUDA_LIBRARY_PATHS="${CUDA_LIBRARY_PATHS}${lib_dir}"

        fi

    done


    if [ -n "${CUDA_LIBRARY_PATHS}" ]; then

        if [ -n "${LIBRARY_PATH:-}" ]; then
            export LIBRARY_PATH="${CUDA_LIBRARY_PATHS}:${LIBRARY_PATH}"
        else
            export LIBRARY_PATH="${CUDA_LIBRARY_PATHS}"
        fi

        if [ -n "${LD_LIBRARY_PATH:-}" ]; then
            export LD_LIBRARY_PATH="${CUDA_LIBRARY_PATHS}:${LD_LIBRARY_PATH}"
        else
            export LD_LIBRARY_PATH="${CUDA_LIBRARY_PATHS}"
        fi

    fi

fi


# =============================================================================
# Verify nvcc AFTER repair
# =============================================================================

if command -v nvcc >/dev/null 2>&1; then

    FINAL_NVCC="$(
        nvcc --version 2>/dev/null |
        grep -oE 'release [0-9]+\.[0-9]+' |
        head -n1 |
        awk '{print $2}' ||
        echo ""
    )

else

    FINAL_NVCC=""

fi


echo
echo "CUDA environment:"
echo "  PyTorch CUDA: ${TORCH_CUDA}"
echo "  nvcc CUDA:    ${FINAL_NVCC:-not found}"
echo "  CUDA_HOME:    ${CUDA_HOME:-not set}"


if [ "${SAGE_REQUIRED}" != "none" ]; then

    [ -n "${FINAL_NVCC}" ] || \
        die "SageAttention requires nvcc, but no CUDA compiler is available."

    [ "${FINAL_NVCC}" = "${TORCH_CUDA}" ] || \
        die "CUDA mismatch remains after automatic repair: PyTorch=${TORCH_CUDA}, nvcc=${FINAL_NVCC}"

    ok "PyTorch CUDA and nvcc CUDA match."

fi


# =============================================================================
# 6. SageAttention
# =============================================================================

log "[6/9] Installing / verifying SageAttention"


if [ "${SAGE_REQUIRED}" = "none" ]; then

    info "SageAttention is not required for this GPU profile."

else

    # -------------------------------------------------------------------------
    # Check whether Sage already works in the SELECTED environment.
    # -------------------------------------------------------------------------

    SAGE_IMPORT="no"

    if "${WANGP_PYTHON}" \
        -c 'import sageattention' >/dev/null 2>&1
    then

        SAGE_IMPORT="yes"

        ok "SageAttention already imports in selected environment."

    fi


    if [ "${SAGE_IMPORT}" = "no" ]; then

        if [ "${SAGE_REQUIRED}" = "1.0.6" ]; then

            info "Installing SageAttention 1.0.6..."

            "${WANGP_PYTHON}" -m pip install \
                --upgrade \
                "sageattention==1.0.6"

        else

            info "Installing SageAttention 2.2.0..."

            # WanGP's own Linux installation recipe requires these versions.
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
                "${SAGE_REPO}" \
                "${SAGE_DIR}"


            cd "${SAGE_DIR}"


            # CRITICAL:
            #
            # --no-build-isolation is required because SageAttention's build
            # process imports torch.
            #
            # Without it:
            #
            #   ModuleNotFoundError: No module named 'torch'
            #
            # was observed in the Vast environment.

            "${WANGP_PYTHON}" -m pip install \
                --no-build-isolation \
                -e .


            cd "${WANGP_DIR}"

        fi

    fi


    # -------------------------------------------------------------------------
    # Verify Sage after installation.
    # -------------------------------------------------------------------------

    if ! "${WANGP_PYTHON}" \
        -c 'import sageattention' >/dev/null 2>&1
    then

        die "SageAttention installation completed but the module cannot be imported."

    fi


    SAGE_PATH="$(
        "${WANGP_PYTHON}" \
            -c 'import sageattention; print(sageattention.__file__)'
    )"


    ok "SageAttention is installed."

    echo "  Path: ${SAGE_PATH}"

fi


# =============================================================================
# 7. INT4 / FP4 acceleration
#
# SAFETY RULE:
#
# First inspect /venv/main.
#
# If the original environment already has a working Nunchaku/FP4 stack,
# do NOT modify /venv/main.
#
# If we are using /venv/main, don't reinstall it.
#
# If we created a clean WanGP environment, it needs its own compatible
# package because Python environments cannot safely share site-packages.
# =============================================================================

log "[7/9] Checking INT4 / FP4 acceleration"


# =============================================================================
# Nunchaku
# =============================================================================

if [ "${NUNCHAKU_REQUIRED}" = "yes" ]; then

    SELECTED_NUNCHAKU="no"


    if "${WANGP_PYTHON}" \
        -c 'import nunchaku' >/dev/null 2>&1
    then

        SELECTED_NUNCHAKU="yes"

        ok "Nunchaku already exists in selected environment."

    fi


    if [ "${SELECTED_NUNCHAKU}" = "no" ]; then

        if [ "${ORIGINAL_NUNCHAKU}" = "yes" ] &&
           [ "${USE_ORIGINAL_ENV}" = "yes" ]
        then

            # This should normally be impossible because the selected env is
            # already /venv/main and the import check above would succeed.

            ok "Reusing existing Nunchaku from original Vast environment."

        else

            if [ "${ORIGINAL_NUNCHAKU}" = "yes" ]; then

                echo
                echo "[INFO] Original Vast environment has working Nunchaku."
                echo "[INFO] Selected WanGP environment is different."
                echo "[INFO] Installing a compatible copy into the isolated env."
                echo

            else

                info "No usable Nunchaku was found in original Vast environment."

            fi


            info "Installing compatible Nunchaku..."

            "${WANGP_PYTHON}" -m pip install \
                "${NUNCHAKU_WHEEL}"

        fi

    fi


    # Final import check.
    if ! "${WANGP_PYTHON}" \
        -c 'import nunchaku' >/dev/null 2>&1
    then

        die "Nunchaku is required for this GPU profile but cannot be imported."

    fi


    ok "Nunchaku INT4/FP4 support is available."

else

    info "Nunchaku is not required for this GPU profile."

fi


# =============================================================================
# Light2xv
# =============================================================================

if [ "${LIGHT2XV_REQUIRED}" = "yes" ]; then

    if "${WANGP_PYTHON}" \
        -c 'import lightx2v' >/dev/null 2>&1
    then

        ok "Light2xv already exists in selected environment."

    else

        if [ "${ORIGINAL_LIGHT2XV}" = "yes" ] &&
           [ "${USE_ORIGINAL_ENV}" = "yes" ]
        then

            ok "Reusing existing Light2xv from original Vast environment."

        else

            if [ "${ORIGINAL_LIGHT2XV}" = "yes" ]; then

                echo
                echo "[INFO] Original Vast environment already has Light2xv."
                echo "[INFO] Selected environment is isolated."
                echo "[INFO] Installing compatible Light2xv there."
                echo

            else

                info "Light2xv is not present in original environment."

            fi


            info "Installing Light2xv NVFP4 kernel..."

            "${WANGP_PYTHON}" -m pip install \
                "${LIGHT2XV_WHEEL}"

        fi

    fi


    if ! "${WANGP_PYTHON}" \
        -c 'import lightx2v' >/dev/null 2>&1
    then

        die "Light2xv is required for the RTX 50 profile but cannot be imported."

    fi


    ok "Light2xv is available."

fi


# =============================================================================
# 8. Final environment verification
# =============================================================================

log "[8/9] Final acceleration verification"


"${WANGP_PYTHON}" - <<'PY'

import sys

print("Python:")
print(" ", sys.version)

print()

try:

    import torch

    print("PyTorch:")
    print(" ", torch.__version__)

    print("PyTorch CUDA:")
    print(" ", torch.version.cuda)

    print("CUDA available:")
    print(" ", torch.cuda.is_available())

    if torch.cuda.is_available():

        print("GPU:")
        print(" ", torch.cuda.get_device_name(0))

        print("Compute capability:")
        print(" ", torch.cuda.get_device_capability(0))

except Exception as e:

    raise SystemExit(f"PyTorch verification failed: {e}")


try:

    import triton

    print("Triton:")
    print(" ", triton.__version__)

except Exception:

    print("Triton: not installed")


try:

    import sageattention

    print("SageAttention:")
    print(" INSTALLED")
    print(" ", sageattention.__file__)

except Exception:

    print("SageAttention: not installed")


try:

    import nunchaku

    print("Nunchaku:")
    print(" INSTALLED")

except Exception:

    print("Nunchaku: not installed")


try:

    import lightx2v

    print("Light2xv:")
    print(" INSTALLED")

except Exception:

    print("Light2xv: not installed")

PY


# =============================================================================
# Hard verification gates
# =============================================================================

if [ "${SAGE_REQUIRED}" != "none" ]; then

    if ! "${WANGP_PYTHON}" \
        -c 'import sageattention' >/dev/null 2>&1
    then

        die "Final SageAttention verification failed."

    fi

fi


if [ "${NUNCHAKU_REQUIRED}" = "yes" ]; then

    if ! "${WANGP_PYTHON}" \
        -c 'import nunchaku' >/dev/null 2>&1
    then

        die "Final Nunchaku verification failed."

    fi

fi


if [ "${LIGHT2XV_REQUIRED}" = "yes" ]; then

    if ! "${WANGP_PYTHON}" \
        -c 'import lightx2v' >/dev/null 2>&1
    then

        die "Final Light2xv verification failed."

    fi

fi


# =============================================================================
# Verify WanGP CLI and supported flags
# =============================================================================

echo
echo "=== Verifying installed WanGP CLI ==="

CLI_HELP="$(
    "${WANGP_PYTHON}" \
        "${WANGP_DIR}/wgp.py" \
        --help \
        2>&1
)"


echo "WanGP commit: ${WANGP_COMMIT}"
echo "Python: ${WANGP_PYTHON}"
"${WANGP_PYTHON}" --version


check_flag() {

    local flag="$1"

    if echo "${CLI_HELP}" | grep -q -- "${flag}"; then

        echo "[OK] ${flag} supported"

        return 0

    else

        echo "[WARN] ${flag} NOT supported"

        return 1

    fi

}


check_flag "--profile" || true
check_flag "--perc-reserved-mem-max" || true
check_flag "--attention" || true
check_flag "--compile" || true


# TeaCache deliberately NOT used.
#
# We do not even probe/use it in the launch command because your actual
# WanGP build does not expose --teacache.

echo "[INFO] TeaCache: not requested / not passed to WanGP."


# =============================================================================
# Verify required attention option
# =============================================================================

if ! echo "${CLI_HELP}" |
    grep -q -- "--attention"
then

    die "This WanGP build does not expose --attention."

fi


# =============================================================================
# 9. Configure Supervisor
# =============================================================================

log "[9/9] Configuring WanGP supervisor"


[ -f "${SUPERVISOR_FILE}" ] || \
    die "Supervisor launcher not found: ${SUPERVISOR_FILE}"


echo "--- BEFORE ---"
cat "${SUPERVISOR_FILE}"


# =============================================================================
# Build clean supervisor wrapper
#
# We deliberately DO NOT rely on /venv/main activation.
#
# We directly invoke the locked Python executable.
#
# This prevents the previous bug where the script installed packages into one
# environment and then silently changed WANGP_PYTHON back to /venv/main.
# =============================================================================

cat > "${SUPERVISOR_FILE}" <<EOF
#!/bin/bash

utils=/opt/supervisor-scripts/utils

. "\${utils}/logging.sh"
. "\${utils}/cleanup_generic.sh"
. "\${utils}/environment.sh"
. "\${utils}/exit_serverless.sh"
. "\${utils}/exit_portal.sh" "Wan2GP"

echo "Starting Wan2GP"

. /etc/environment

cd "${WANGP_DIR}"

export XDG_RUNTIME_DIR=/tmp
export SDL_AUDIODRIVER=dummy

export CUDA_HOME="${CUDA_HOME:-}"
export PATH="${CUDA_HOME:+${CUDA_HOME}/bin:}\$PATH"

export CPATH="${CPATH:-}"
export LIBRARY_PATH="${LIBRARY_PATH:-}"
export LD_LIBRARY_PATH="${LD_LIBRARY_PATH:-}"

exec "${WANGP_PYTHON}" \
    wgp.py \
    --profile 2 \
    --perc-reserved-mem-max 0.50 \
    --attention "${ATTENTION_MODE}" \
    --compile \
    2>&1
EOF


chmod +x "${SUPERVISOR_FILE}"


echo "--- AFTER ---"
cat "${SUPERVISOR_FILE}"


# =============================================================================
# Supervisor reload
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

cat > "${WANGP_DIR}/finetunes/minimax_h3_t2v_int8.json" <<'EOF'
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

cat > "${WANGP_DIR}/finetunes/minimax_h3_i2v_int8.json" <<'EOF'
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
# We use the CURRENT upstream Animate architecture and override only the
# text encoder.
#
# No weights are downloaded during provisioning.
# =============================================================================

cat > "${WANGP_DIR}/finetunes/wan22_animate_14b_custom_t5.json" <<'EOF'
{
  "model": {
    "name": "Wan2.2 Animate 14B — Custom UMT5 NVFP4",
    "architecture": "animate",
    "description": "Wan2.2 Animate 14B using the custom NVFP4 UMT5-XXL text encoder.",
    "URLs": [
      "https://huggingface.co/DeepBeepMeep/Wan2.2/resolve/main/wan2.2_animate_14B_bf16.safetensors",
      "https://huggingface.co/DeepBeepMeep/Wan2.2/resolve/main/wan2.2_animate_14B_quanto_fp16_int8.safetensors",
      "https://huggingface.co/DeepBeepMeep/Wan2.2/resolve/main/wan2.2_animate_14B_quanto_bf16_int8.safetensors"
    ],
    "text_encoder_URLs": [
      "https://huggingface.co/dummy9996/6NSFW-Wan-UMT5-XXL-mxfp8-nvfp4-int4-convrot/resolve/main/nsfw_wan_umt5-xxl-nvfp4.safetensors"
    ],
    "group": "wan2_2"
  }
}
EOF


# =============================================================================
# Bernini-R NVFP4
#
# High-noise:
#   wan2.2_bernini_r_high_noise_nvfp4.safetensors
#
# Low-noise:
#   wan2.2_bernini_r_low_noise_nvfp4.safetensors
#
# Both filenames are from rzgar/Bernini-R-nvfp4.
# =============================================================================

cat > "${WANGP_DIR}/finetunes/bernini_r_nvfp4_custom_t5.json" <<'EOF'
{
  "model": {
    "name": "Wan2.2 Bernini-R 14B — NVFP4 + Custom UMT5",
    "architecture": "bernini",
    "description": "Wan2.2 Bernini-R using NVFP4 high/low-noise weights and custom NVFP4 UMT5-XXL text encoder.",
    "URLs": [
      "https://huggingface.co/rzgar/Bernini-R-nvfp4/resolve/main/wan2.2_bernini_r_high_noise_nvfp4.safetensors"
    ],
    "URLs2": [
      "https://huggingface.co/rzgar/Bernini-R-nvfp4/resolve/main/wan2.2_bernini_r_low_noise_nvfp4.safetensors"
    ],
    "text_encoder_URLs": [
      "https://huggingface.co/dummy9996/6NSFW-Wan-UMT5-XXL-mxfp8-nvfp4-int4-convrot/resolve/main/nsfw_wan_umt5-xxl-nvfp4.safetensors"
    ],
    "group": "wan2_2"
  },
  "prompt": "Replace the person's outer shirt with the shirt from the reference image while preserving the original motion, camera framing, lighting, background, and body pose.",
  "video_prompt_type": "VI",
  "resolution": "832x480",
  "video_length": 81,
  "num_inference_steps": 40,
  "sample_solver": "unipc",
  "flow_shift": 5,
  "guidance_phases": 2,
  "model_switch_phase": 1,
  "switch_threshold": 875,
  "guidance_scale": 4,
  "guidance2_scale": 4,
  "control_net_weight": 1.25,
  "alt_guidance_scale": 4.5,
  "remove_background_images_ref": 0,
  "prompt_enhancer": ""
}
EOF


# =============================================================================
# Validate JSON files
# =============================================================================

echo
echo "=== Validating finetune JSONs ==="

for file in \
    "${WANGP_DIR}/finetunes/minimax_h3_t2v_int8.json" \
    "${WANGP_DIR}/finetunes/minimax_h3_i2v_int8.json" \
    "${WANGP_DIR}/finetunes/wan22_animate_14b_custom_t5.json" \
    "${WANGP_DIR}/finetunes/bernini_r_nvfp4_custom_t5.json"
do

    "${WANGP_PYTHON}" \
        -m json.tool \
        "${file}" >/dev/null

    ok "$(basename "${file}")"

done


# =============================================================================
# IMPORTANT:
# Do NOT pre-download any model.
#
# The finetune JSONs contain URLs only.
# WanGP downloads the selected checkpoint when the user selects that model.
# =============================================================================

echo
echo "=== Model download policy ==="
echo "[OK] No model weights were pre-seeded."
echo "[OK] All configured models are ON-DEMAND."
echo "[OK] Finetune JSONs only."


# =============================================================================
# Start WanGP
# =============================================================================

echo
echo "Starting Wan2GP..."

supervisorctl start wan2gp


# =============================================================================
# Final status
# =============================================================================

echo
echo "============================================================"
echo "       Custom WanGP provisioning COMPLETE"
echo "============================================================"

echo
echo "GPU:"
echo "  ${GPU_NAME}"
echo "  Profile: ${GPU_PROFILE}"

echo
echo "Environment:"
echo "  Python:       ${WANGP_PYTHON}"
echo "  Python ver:   ${PYTHON_MAJOR}"
echo "  PyTorch:      ${TORCH_SPEC}"
echo "  Torch CUDA:   ${TORCH_CUDA}"
echo "  CUDA_HOME:    ${CUDA_HOME:-system/default}"

echo
echo "Attention:"
echo "  Mode:         ${ATTENTION_MODE}"
echo "  Sage:         ${SAGE_REQUIRED}"

echo
echo "Acceleration:"
echo "  Triton:       ${TRITON_REQUIRED}"
echo "  Nunchaku:     ${NUNCHAKU_REQUIRED}"
echo "  Light2xv:     ${LIGHT2XV_REQUIRED}"

echo
echo "WanGP:"
echo "  Commit:       ${WANGP_COMMIT}"
echo "  Profile:      2 (HighRAM_LowVRAM)"
echo "  VRAM ceiling: 50%"
echo "  Compile:      ON"
echo "  TeaCache:     OFF / not passed"

echo
echo "Model downloads:"
echo "  Pre-seeding:  OFF"
echo "  H3 T2V:       ON-DEMAND"
echo "  H3 I2V:       ON-DEMAND"
echo "  Animate 14B:  ON-DEMAND"
echo "  Bernini-R:    ON-DEMAND"

echo
echo "Custom T5:"
echo "  nsfw_wan_umt5-xxl-nvfp4.safetensors"

echo
echo "Custom models:"
echo "  Wan2.2 Animate 14B"
echo "  Wan2.2 Bernini-R NVFP4"

echo
echo "============================================================"
