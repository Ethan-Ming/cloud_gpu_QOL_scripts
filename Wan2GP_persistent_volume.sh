## Startup Script
#!/bin/bash
set -euo pipefail

. /venv/main/bin/activate

: "${WORKSPACE:=/workspace}"

###############################################################################
# Persistence Bootstrap (best-effort; will NOT break Vast setup on failure)
###############################################################################

persist_ts() { date +"%Y-%m-%d %H:%M:%S"; }
persist_log()  { [[ "${PERSIST_VERBOSITY:-1}" -ge 1 ]] && echo "[$(persist_ts)] [PERSIST][INFO]  $*" >&2 || true; }
persist_dbg()  { [[ "${PERSIST_VERBOSITY:-1}" -ge 2 ]] && echo "[$(persist_ts)] [PERSIST][DEBUG] $*" >&2 || true; }
persist_warn() { [[ "${PERSIST_VERBOSITY:-1}" -ge 1 ]] && echo "[$(persist_ts)] [PERSIST][WARN]  $*" >&2 || true; }
persist_err()  { echo "[$(persist_ts)] [PERSIST][ERROR] $*" >&2; }

persist_have_cmd() { command -v "$1" >/dev/null 2>&1; }

persist_ensure_dir() {
  local d="$1"
  [[ -z "$d" ]] && return 0
  [[ -d "$d" ]] && return 0
  mkdir -p -- "$d" 2>/dev/null
}

persist_is_empty_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  [[ -z "$(ls -A "$d" 2>/dev/null || true)" ]]
}

persist_canonical_path() {
  local p="$1"
  if persist_have_cmd readlink; then
    readlink -f "$p" 2>/dev/null || true
    return 0
  fi
  if persist_have_cmd python3; then
    python3 - <<PY 2>/dev/null || true
import os,sys
print(os.path.realpath(sys.argv[1]))
PY
    return 0
  fi
  echo "$p"
}

persist_symlink_points_to() {
  local link="$1" target="$2"
  [[ -L "$link" ]] || return 1
  local cur exp
  cur="$(persist_canonical_path "$link")"
  exp="$(persist_canonical_path "$target")"
  [[ -n "$cur" && -n "$exp" && "$cur" == "$exp" ]]
}

persist_file_size() {
  local f="$1"
  if persist_have_cmd stat; then
    stat -c '%s' -- "$f" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Merge helper tweak:
# - first copy only new files (ignore-existing)
# - then if SAME relative path exists in both and size differs -> overwrite persistent with instance copy
persist_replace_size_conflicts() {
  local from_dir="$1" to_dir="$2"
  persist_have_cmd find || { persist_warn "find not available; cannot do size-conflict overwrite pass"; return 0; }

  while IFS= read -r -d '' rel; do
    local src="$from_dir/$rel"
    local dst="$to_dir/$rel"
    [[ -f "$src" && -f "$dst" ]] || continue

    local ssz dsz
    ssz="$(persist_file_size "$src")"
    dsz="$(persist_file_size "$dst")"
    [[ -n "$ssz" && -n "$dsz" ]] || continue

    if [[ "$ssz" != "$dsz" ]]; then
      persist_dbg "Overwriting persistent file due to size mismatch: $dst (old=$dsz new=$ssz)"
      persist_ensure_dir "$(dirname "$dst")" || true
      if persist_have_cmd rsync; then
        rsync -a --protect-args -- "$src" "$dst"
      else
        cp -a -f -- "$src" "$dst"
      fi
    fi
  done < <(cd "$from_dir" && find . -type f -print0 | sed -z 's|^\./||')
}

persist_rsync_merge() {
  local from_dir="$1" to_dir="$2"
  persist_ensure_dir "$to_dir" || return 1

  if persist_have_cmd rsync; then
    local opts=(-a --ignore-existing)
    if [[ "${RSYNC_CHECKSUM:-0}" == "1" ]]; then
      opts=(-a --checksum --ignore-existing)
    fi
    rsync "${opts[@]}" -- "$from_dir"/ "$to_dir"/
  else
    persist_warn "rsync not found; falling back to cp -a (may be slower)."
    if cp -an "$from_dir"/. "$to_dir"/ 2>/dev/null; then
      true
    else
      cp -a "$from_dir"/. "$to_dir"/
    fi
  fi

  persist_replace_size_conflicts "$from_dir" "$to_dir" || true
}

persist_migrate_and_link_dir() {
  local src="$1" dest="$2" desc="${3:-dir}"
  [[ -z "$src" || -z "$dest" ]] && return 0

  persist_ensure_dir "$src" || { persist_err "Cannot create persistent directory: $src"; return 0; }

  if persist_symlink_points_to "$dest" "$src"; then
    persist_dbg "Already linked: $dest -> $src"
    return 0
  fi

  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    persist_ensure_dir "$(dirname "$dest")" || true
    ln -sfn -- "$src" "$dest"
    persist_log "Linked $desc: $dest -> $src"
    return 0
  fi

  if [[ -L "$dest" ]]; then
    persist_warn "Replacing incorrect symlink for $desc: $dest"
    rm -f -- "$dest" || true
    ln -sfn -- "$src" "$dest"
    persist_log "Linked $desc: $dest -> $src"
    return 0
  fi

  if [[ -f "$dest" ]]; then
    if [[ "${SAFE_MODE:-1}" == "1" && "${FORCE_DESTRUCTIVE:-0}" != "1" ]]; then
      persist_warn "Not linking $desc (destination is a file, SAFE_MODE=1): $dest"
      return 0
    fi
    rm -f -- "$dest" || true
    ln -sfn -- "$src" "$dest"
    persist_log "Linked $desc: $dest -> $src"
    return 0
  fi

  if [[ -d "$dest" ]]; then
    if persist_is_empty_dir "$dest"; then
      rmdir -- "$dest" 2>/dev/null || true
      ln -sfn -- "$src" "$dest"
      persist_log "Linked $desc (was empty): $dest -> $src"
      return 0
    fi

    persist_log "Merging existing $desc into persistent store: $dest -> $src"
    persist_rsync_merge "$dest" "$src" || { persist_warn "Merge failed for $desc (continuing without link): $dest"; return 0; }

    rm -rf -- "$dest" || true
    ln -sfn -- "$src" "$dest"
    persist_log "Linked $desc (after merge): $dest -> $src"
    return 0
  fi

  persist_warn "Unhandled destination type for $desc: $dest (skipping)"
  return 0
}

persist_write_managed_block() {
  local file="$1" marker="$2" content="$3"
  [[ -w "$file" ]] || return 1
  local begin="# >>> ${marker}"
  local end="# <<< ${marker}"
  if persist_have_cmd sed; then
    sed -i "/^${begin//\//\\/}\$/,/^${end//\//\\/}\$/d" "$file" 2>/dev/null || true
  fi
  {
    echo "$begin"
    echo "$content"
    echo "$end"
  } >> "$file"
}

persist_setup_caches() {
  local cache_base="$1"

  persist_ensure_dir "$cache_base" || return 1
  persist_ensure_dir "${cache_base}/huggingface/hub" || true
  persist_ensure_dir "${cache_base}/torch" || true
  persist_ensure_dir "${cache_base}/pip" || true
  persist_ensure_dir "${cache_base}/triton" || true
  persist_ensure_dir "${cache_base}/torchinductor" || true
  persist_ensure_dir "${cache_base}/cuda" || true
  persist_ensure_dir "${cache_base}/torch_extensions" || true
  persist_ensure_dir "${cache_base}/uv" || true
  persist_ensure_dir "${cache_base}/xdg" || true

  export HF_HOME="${cache_base}/huggingface"
  export HUGGINGFACE_HUB_CACHE="${cache_base}/huggingface/hub"
  export TORCH_HOME="${cache_base}/torch"
  export PIP_CACHE_DIR="${cache_base}/pip"
  export TRITON_CACHE_DIR="${cache_base}/triton"
  export TORCHINDUCTOR_CACHE_DIR="${cache_base}/torchinductor"
  export CUDA_CACHE_PATH="${cache_base}/cuda"
  export CUDA_CACHE_MAXSIZE="${CUDA_CACHE_MAXSIZE:-2147483648}"
  export TORCH_EXTENSIONS_DIR="${cache_base}/torch_extensions"
  export UV_CACHE_DIR="${cache_base}/uv"
  export TRANSFORMERS_CACHE="${HF_HOME}/transformers"
  export DIFFUSERS_CACHE="${HF_HOME}/diffusers"

  if [[ "${PERSIST_XDG_CACHE:-0}" == "1" ]]; then
    export XDG_CACHE_HOME="${cache_base}/xdg"
  fi

  if [[ "${ENABLE_HF_TRANSFER:-1}" == "1" ]]; then
    export HF_HUB_ENABLE_HF_TRANSFER=1
  fi

  if [[ "${PIP_DISABLE_VERSION_CHECK:-1}" == "1" ]]; then
    export PIP_DISABLE_PIP_VERSION_CHECK=1
  fi

  # Make sure supervisor-launched Wan2GP sees env (it sources /etc/environment in your script)
  if [[ "${WRITE_ETC_ENVIRONMENT:-1}" == "1" && -w /etc/environment ]]; then
    local env_block
    env_block=$(cat <<EOF
HF_HOME="$HF_HOME"
HUGGINGFACE_HUB_CACHE="$HUGGINGFACE_HUB_CACHE"
TORCH_HOME="$TORCH_HOME"
PIP_CACHE_DIR="$PIP_CACHE_DIR"
TRITON_CACHE_DIR="$TRITON_CACHE_DIR"
TORCHINDUCTOR_CACHE_DIR="$TORCHINDUCTOR_CACHE_DIR"
TORCH_EXTENSIONS_DIR="$TORCH_EXTENSIONS_DIR"
CUDA_CACHE_PATH="$CUDA_CACHE_PATH"
CUDA_CACHE_MAXSIZE="$CUDA_CACHE_MAXSIZE"
UV_CACHE_DIR="$UV_CACHE_DIR"
TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE"
DIFFUSERS_CACHE="$DIFFUSERS_CACHE"
EOF
)
    [[ "${ENABLE_HF_TRANSFER:-1}" == "1" ]] && env_block+=$'\nHF_HUB_ENABLE_HF_TRANSFER="1"'
    [[ "${PERSIST_XDG_CACHE:-0}" == "1" ]] && env_block+=$'\nXDG_CACHE_HOME="'"$XDG_CACHE_HOME"'"'
    [[ "${PIP_DISABLE_VERSION_CHECK:-1}" == "1" ]] && env_block+=$'\nPIP_DISABLE_PIP_VERSION_CHECK="1"'

    persist_write_managed_block "/etc/environment" "PERSIST_CACHES" "$env_block" || true
  fi
}

persist_hf_transfer_is_available() {
  persist_have_cmd python3 || return 1
  python3 -c "import hf_transfer" >/dev/null 2>&1
}

persist_maybe_install_hf_transfer() {
  [[ "${ENABLE_HF_TRANSFER:-1}" == "1" ]] || return 0

  if persist_hf_transfer_is_available; then
    persist_dbg "hf_transfer is importable (OK)."
    return 0
  fi

  persist_warn "HF_HUB_ENABLE_HF_TRANSFER=1 but python cannot import hf_transfer."
  persist_warn "HF downloads will work but without hf_transfer acceleration."

  [[ "${INSTALL_HF_TRANSFER:-0}" == "1" ]] || return 0

  persist_log "Attempting to install hf_transfer (best-effort)..."
  if persist_have_cmd uv; then
    uv pip install -q hf_transfer || persist_warn "uv pip install hf_transfer failed"
  elif persist_have_cmd pip; then
    pip install -q hf_transfer || persist_warn "pip install hf_transfer failed"
  else
    python3 -m pip install -q hf_transfer || persist_warn "python -m pip install hf_transfer failed"
  fi

  if persist_hf_transfer_is_available; then
    persist_log "hf_transfer installed and importable."
  else
    persist_warn "hf_transfer still not importable after install attempt."
  fi
}

persist_bootstrap() {
  : "${PERSIST_ROOT:=/workspace}"
  : "${PERSIST_SUBDIR:=persist}"
  : "${PERSIST_VERBOSITY:=1}"

  : "${SAFE_MODE:=1}"
  : "${FORCE_DESTRUCTIVE:=0}"
  : "${RSYNC_CHECKSUM:=0}"

  : "${WRITE_ETC_ENVIRONMENT:=1}"
  : "${PERSIST_XDG_CACHE:=0}"
  : "${ENABLE_HF_TRANSFER:=1}"
  : "${INSTALL_HF_TRANSFER:=0}"
  : "${PIP_DISABLE_VERSION_CHECK:=1}"

  # App roots (we’re in Wan2GP script; Comfy may or may not exist)
  : "${COMFY_ROOT:=}"
  : "${WANGP_ROOT:=}"

  : "${USE_SHARED_MODELS:=1}"

  # Model dir lists
  : "${COMFY_MODEL_DIRS:=checkpoints loras vae controlnet clip clip_vision upscale_models embeddings}"
  : "${COMFY_MODEL_DIRS_EXTRA:=unet esrgan sams diffusion_models text_encoders}"
  : "${LINK_COMFY_ALIASES:=1}"

  : "${WANGP_MODEL_DIRS:=Stable-diffusion Lora LyCORIS VAE ControlNet embeddings hypernetworks ESRGAN SwinIR LDSR Codeformer GFPGAN}"
  : "${WANGP_AUTODISCOVER_MODEL_DIRS:=1}"
  : "${PERSIST_WANGP_EXTENSIONS:=1}"

  [[ -d "$PERSIST_ROOT" ]] || { persist_warn "PERSIST_ROOT not found ($PERSIST_ROOT); skipping persistence."; return 0; }

  local PERSIST_BASE="${PERSIST_ROOT%/}/${PERSIST_SUBDIR}"
  persist_ensure_dir "$PERSIST_BASE" || { persist_warn "Cannot create $PERSIST_BASE; skipping persistence."; return 0; }

  # Caches first
  local CACHE_BASE="${PERSIST_BASE}/caches"
  persist_setup_caches "$CACHE_BASE" || true
  persist_maybe_install_hf_transfer || true

  # Shared model pool
  local SHARED_MODELS_BASE=""
  if [[ "${USE_SHARED_MODELS:-1}" == "1" ]]; then
    SHARED_MODELS_BASE="${PERSIST_BASE}/models"
    persist_ensure_dir "$SHARED_MODELS_BASE" || true
  fi

  # If ComfyUI exists, link (optional; harmless if absent)
  if [[ -z "${COMFY_ROOT:-}" ]]; then
    if [[ -d "${WORKSPACE%/}/ComfyUI" ]]; then COMFY_ROOT="${WORKSPACE%/}/ComfyUI"; fi
  fi
  if [[ -n "${COMFY_ROOT:-}" && -d "${COMFY_ROOT}" ]]; then
    local comfy_models_base
    comfy_models_base="${SHARED_MODELS_BASE:-${PERSIST_BASE}/comfyui/models}"
    persist_ensure_dir "${COMFY_ROOT}/models" || true
    local d
    for d in $COMFY_MODEL_DIRS $COMFY_MODEL_DIRS_EXTRA; do
      persist_migrate_and_link_dir "${comfy_models_base}/${d}" "${COMFY_ROOT}/models/${d}" "ComfyUI models/${d}"
    done
    if [[ "${LINK_COMFY_ALIASES:-1}" == "1" ]]; then
      persist_migrate_and_link_dir "${comfy_models_base}/loras" "${COMFY_ROOT}/models/lora" "ComfyUI alias models/lora -> loras"
    fi
    persist_migrate_and_link_dir "${PERSIST_BASE}/comfyui/custom_nodes" "${COMFY_ROOT}/custom_nodes" "ComfyUI custom_nodes"
    persist_migrate_and_link_dir "${PERSIST_BASE}/comfyui/user" "${COMFY_ROOT}/user" "ComfyUI user"
  fi

  # We do Wan2GP/wanGP model linking AFTER the repo is present (below).
  return 0
}

# Run early (caches + optional ComfyUI)
persist_bootstrap || true

###############################################################################
# Original Vast Wan2.2GP setup script (kept; only added persistence hooks)
###############################################################################

apt-get install -y \
    libasound2-dev \
    pulseaudio-utils \
    --no-install-recommends

cd "$WORKSPACE"
[[ -d "${WORKSPACE}/Wan2GP" ]] || git clone https://github.com/deepbeepmeep/Wan2GP
cd Wan2GP
[[ -n "${WAN2GP_VERSION:-}" ]] && git checkout "$WAN2GP_VERSION"

# After repo exists: link Wan2GP models/extensions to persistent pool (best-effort)
persist_link_wan2gp_after_clone() {
  : "${PERSIST_ROOT:=/workspace}"
  : "${PERSIST_SUBDIR:=persist}"
  : "${USE_SHARED_MODELS:=1}"
  : "${PERSIST_WANGP_EXTENSIONS:=1}"
  : "${WANGP_MODEL_DIRS:=Stable-diffusion Lora LyCORIS VAE ControlNet embeddings hypernetworks ESRGAN SwinIR LDSR Codeformer GFPGAN}"
  : "${WANGP_AUTODISCOVER_MODEL_DIRS:=1}"

  local PERSIST_BASE="${PERSIST_ROOT%/}/${PERSIST_SUBDIR}"
  [[ -d "$PERSIST_BASE" ]] || return 0

  local root="${WORKSPACE%/}/Wan2GP"
  [[ -d "$root" ]] || return 0

  # Treat Wan2GP like an A1111-ish layout if models dir exists/created
  local models_dir="${root}/models"
  persist_ensure_dir "$models_dir" || true

  local SHARED_MODELS_BASE=""
  if [[ "${USE_SHARED_MODELS}" == "1" ]]; then
    SHARED_MODELS_BASE="${PERSIST_BASE}/models"
    persist_ensure_dir "$SHARED_MODELS_BASE" || true
  fi

  local wangp_models_base
  if [[ "${USE_SHARED_MODELS}" == "1" ]]; then
    wangp_models_base="$SHARED_MODELS_BASE"
  else
    wangp_models_base="${PERSIST_BASE}/wangp/models"
    persist_ensure_dir "$wangp_models_base" || true
  fi

  local md equiv
  for md in $WANGP_MODEL_DIRS; do
    equiv="$md"
    case "$md" in
      "Stable-diffusion") equiv="checkpoints" ;;
      "Lora")            equiv="loras" ;;
      "LyCORIS")         equiv="loras" ;;
      "VAE")             equiv="vae" ;;
      "ControlNet")      equiv="controlnet" ;;
      "embeddings")      equiv="embeddings" ;;
      "ESRGAN")          equiv="esrgan" ;;
      "SwinIR")          equiv="upscale_models" ;;
      "LDSR")            equiv="upscale_models" ;;
    esac
    persist_migrate_and_link_dir "${wangp_models_base}/${equiv}" "${models_dir}/${md}" "Wan2GP models/${md}"
  done

  if [[ "${WANGP_AUTODISCOVER_MODEL_DIRS}" == "1" ]]; then
    local sub name
    shopt -s nullglob
    for sub in "${models_dir}/"*/ ; do
      [[ -d "$sub" ]] || continue
      name="$(basename "$sub")"
      case " $WANGP_MODEL_DIRS " in
        *" $name "*) continue ;;
      esac
      persist_migrate_and_link_dir "${PERSIST_BASE}/wangp/models/${name}" "${models_dir}/${name}" "Wan2GP models/${name} (autodiscovered)"
    done
    shopt -u nullglob
  fi

  if [[ "${PERSIST_WANGP_EXTENSIONS}" == "1" && ( -d "${root}/extensions" || -L "${root}/extensions" ) ]]; then
    persist_migrate_and_link_dir "${PERSIST_BASE}/wangp/extensions" "${root}/extensions" "Wan2GP extensions"
  fi
}

persist_link_wan2gp_after_clone || true

# Find the most appropriate backend given W2GP's torch version restrictions
if [[ -z "${CUDA_VERSION:-}" ]]; then
    echo "Error: CUDA_VERSION is not set or is empty." >&2
    exit 1
fi

cuda_version=$(echo "$CUDA_VERSION" | cut -d. -f1,2)
torch_backend=cu128

# Convert versions like "12.7" and "12.8" to integers "127" and "128" for comparison
cuda_version_int=$(echo "$cuda_version" | awk -F. '{printf "%d%d", $1, $2}')
threshold_version_int=128
if (( cuda_version_int < threshold_version_int )); then
    torch_backend=cu126
fi

uv pip install torch==${TORCH_VERSION:-2.7.1} torchvision torchaudio --torch-backend="${TORCH_BACKEND:-$torch_backend}"
uv pip install -r requirements.txt

# Create Wan2GP startup scripts
cat > /opt/supervisor-scripts/wan2gp.sh << 'EOL'
#!/bin/bash

utils=/opt/supervisor-scripts/utils
. "${utils}/logging.sh"
. "${utils}/cleanup_generic.sh"
. "${utils}/environment.sh"
. "${utils}/exit_serverless.sh"
. "${utils}/exit_portal.sh" "Wan2GP"

echo "Starting Wan2GP"

. /etc/environment
. /venv/main/bin/activate

cd "${WORKSPACE}/Wan2GP"
export XDG_RUNTIME_DIR=/tmp
export SDL_AUDIODRIVER=dummy
python wgp.py 2>&1
EOL

chmod +x /opt/supervisor-scripts/wan2gp.sh

# Generate the supervisor config files
cat > /etc/supervisor/conf.d/wan2gp.conf << 'EOL'
[program:wan2gp]
environment=PROC_NAME="%(program_name)s"
command=/opt/supervisor-scripts/wan2gp.sh
autostart=true
autorestart=true
exitcodes=0
startsecs=0
stopasgroup=true
killasgroup=true
stopsignal=TERM
stopwaitsecs=10

# This is necessary for Vast logging to work alongside the Portal logs (Must output to /dev/stdout)
stdout_logfile=/dev/stdout
redirect_stderr=true
stdout_events_enabled=true
stdout_logfile_maxbytes=0
stdout_logfile_backups=0
EOL

supervisorctl reread
supervisorctl update