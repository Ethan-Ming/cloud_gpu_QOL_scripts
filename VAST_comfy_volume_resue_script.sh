## Startup Script
#!/bin/bash

# --- Vast.ai base behavior: activate venv first (kept) ---
source /venv/main/bin/activate

# Ensure WORKSPACE has a sensible default (non-breaking)
: "${WORKSPACE:=/workspace}"

# Vast script uses this path (kept)
COMFYUI_DIR="${WORKSPACE}/ComfyUI"

###############################################################################
# Persistence Bootstrap (integrated)
# - runs before any downloads/builds
# - safe, idempotent, restores shell opts after running
###############################################################################

persist_ts() { date +"%Y-%m-%d %H:%M:%S"; }
persist_log()  { [[ "${PERSIST_VERBOSITY:-1}" -ge 1 ]] && echo "[$(persist_ts)] [PERSIST][INFO]  $*" >&2 || true; }
persist_dbg()  { [[ "${PERSIST_VERBOSITY:-1}" -ge 2 ]] && echo "[$(persist_ts)] [PERSIST][DEBUG] $*" >&2 || true; }
persist_warn() { [[ "${PERSIST_VERBOSITY:-1}" -ge 1 ]] && echo "[$(persist_ts)] [PERSIST][WARN]  $*" >&2 || true; }
persist_err()  { echo "[$(persist_ts)] [PERSIST][ERROR] $*" >&2; }
persist_die()  { persist_err "$*"; return 1; }

persist_have_cmd() { command -v "$1" >/dev/null 2>&1; }

persist_ensure_dir() {
  local d="$1"
  [[ -z "$d" ]] && return 0
  if [[ ! -d "$d" ]]; then
    mkdir -p -- "$d" 2>/dev/null || return 1
  fi
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

# Merge helper: copy files that do not exist in dest; then overwrite ONLY same-path files with different size.
# Implements: "if same file name/path but different size => replace old with new"
persist_replace_size_conflicts() {
  local from_dir="$1" to_dir="$2"

  persist_have_cmd find || { persist_warn "find not available; cannot do size-conflict replacement pass"; return 0; }

  while IFS= read -r -d '' rel; do
    local src="$from_dir/$rel"
    local dst="$to_dir/$rel"

    [[ -f "$src" ]] || continue
    [[ -f "$dst" ]] || continue

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

  # Your tweak #1
  persist_replace_size_conflicts "$from_dir" "$to_dir" || true
}

persist_migrate_and_link_dir() {
  local src="$1" dest="$2" desc="${3:-dir}"
  [[ -z "$src" || -z "$dest" ]] && return 0

  persist_ensure_dir "$src" || persist_die "Cannot create persistent directory: $src (check mount/permissions)"

  if persist_symlink_points_to "$dest" "$src"; then
    persist_dbg "Already linked: $dest -> $src"
    return 0
  fi

  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    persist_ensure_dir "$(dirname "$dest")" || persist_die "Cannot create parent dir for: $dest"
    ln -sfn -- "$src" "$dest"
    persist_log "Linked $desc: $dest -> $src"
    return 0
  fi

  if [[ -L "$dest" ]]; then
    persist_warn "Replacing incorrect symlink for $desc: $dest"
    rm -f -- "$dest"
    ln -sfn -- "$src" "$dest"
    persist_log "Linked $desc: $dest -> $src"
    return 0
  fi

  if [[ -f "$dest" ]]; then
    if [[ "${SAFE_MODE:-1}" == "1" && "${FORCE_DESTRUCTIVE:-0}" != "1" ]]; then
      persist_warn "Not linking $desc because destination is a file: $dest (SAFE_MODE=1)"
      return 0
    fi
    persist_warn "Removing file to replace with symlink for $desc: $dest"
    rm -f -- "$dest"
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
    persist_rsync_merge "$dest" "$src" || persist_die "Failed to merge $desc: $dest -> $src"

    rm -rf -- "$dest"
    ln -sfn -- "$src" "$dest"
    persist_log "Linked $desc (after merge): $dest -> $src"
    return 0
  fi

  persist_warn "Unhandled destination type for $desc: $dest (skipping)"
  return 0
}

persist_detect_root() {
  local name="$1"; shift
  local p
  for p in "$@"; do
    if [[ -n "$p" && -d "$p" ]]; then
      echo "$p"
      return 0
    fi
  done
  return 1
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

  persist_ensure_dir "$cache_base" || persist_die "Cannot create cache base: $cache_base"
  persist_ensure_dir "${cache_base}/huggingface/hub" || true
  persist_ensure_dir "${cache_base}/torch" || true
  persist_ensure_dir "${cache_base}/pip" || true
  persist_ensure_dir "${cache_base}/triton" || true
  persist_ensure_dir "${cache_base}/torchinductor" || true
  persist_ensure_dir "${cache_base}/cuda" || true
  persist_ensure_dir "${cache_base}/torch_extensions" || true
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
TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE"
DIFFUSERS_CACHE="$DIFFUSERS_CACHE"
EOF
)

  if [[ "${ENABLE_HF_TRANSFER:-1}" == "1" ]]; then
    env_block+=$'\nHF_HUB_ENABLE_HF_TRANSFER="1"'
  fi
  if [[ "${PERSIST_XDG_CACHE:-0}" == "1" ]]; then
    env_block+=$'\nXDG_CACHE_HOME="'"$XDG_CACHE_HOME"'"'
  fi
  if [[ "${PIP_DISABLE_VERSION_CHECK:-1}" == "1" ]]; then
    env_block+=$'\nPIP_DISABLE_PIP_VERSION_CHECK="1"'
  fi

  if [[ "${WRITE_ETC_ENVIRONMENT:-1}" == "1" && -w /etc/environment ]]; then
    persist_write_managed_block "/etc/environment" "PERSIST_CACHES" "$env_block" || persist_warn "Failed to update /etc/environment"
    persist_log "Updated /etc/environment managed block (PERSIST_CACHES)."
  fi

  if [[ "${WRITE_PROFILE_D:-1}" == "1" && -w /etc/profile.d ]]; then
    local prof="/etc/profile.d/99-persist-caches.sh"
    cat > "$prof" <<EOF
# Managed by persistence bootstrap: $(persist_ts)
export HF_HOME="$HF_HOME"
export HUGGINGFACE_HUB_CACHE="$HUGGINGFACE_HUB_CACHE"
export TORCH_HOME="$TORCH_HOME"
export PIP_CACHE_DIR="$PIP_CACHE_DIR"
export TRITON_CACHE_DIR="$TRITON_CACHE_DIR"
export TORCHINDUCTOR_CACHE_DIR="$TORCHINDUCTOR_CACHE_DIR"
export TORCH_EXTENSIONS_DIR="$TORCH_EXTENSIONS_DIR"
export CUDA_CACHE_PATH="$CUDA_CACHE_PATH"
export CUDA_CACHE_MAXSIZE="$CUDA_CACHE_MAXSIZE"
export TRANSFORMERS_CACHE="$TRANSFORMERS_CACHE"
export DIFFUSERS_CACHE="$DIFFUSERS_CACHE"
EOF
    [[ "${ENABLE_HF_TRANSFER:-1}" == "1" ]] && echo 'export HF_HUB_ENABLE_HF_TRANSFER=1' >> "$prof" || true
    [[ "${PERSIST_XDG_CACHE:-0}" == "1" ]] && echo "export XDG_CACHE_HOME=\"$XDG_CACHE_HOME\"" >> "$prof" || true
    [[ "${PIP_DISABLE_VERSION_CHECK:-1}" == "1" ]] && echo 'export PIP_DISABLE_PIP_VERSION_CHECK=1' >> "$prof" || true
    chmod +x "$prof" 2>/dev/null || true
  fi
}

persist_hf_transfer_is_available() {
  persist_have_cmd python3 || return 1
  python3 -c "import hf_transfer" >/dev/null 2>&1
}

persist_maybe_install_hf_transfer() {
  # Your tweak #2: double-check hf_transfer if HF transfer enabled
  [[ "${ENABLE_HF_TRANSFER:-1}" == "1" ]] || return 0

  if persist_hf_transfer_is_available; then
    persist_dbg "hf_transfer is importable (OK)."
    return 0
  fi

  persist_warn "HF_HUB_ENABLE_HF_TRANSFER=1 but python cannot import hf_transfer."
  persist_warn "Downloads will still work, but without hf_transfer acceleration."

  [[ "${INSTALL_HF_TRANSFER:-0}" == "1" ]] || return 0

  persist_log "Attempting to install hf_transfer (best-effort)..."
  if persist_have_cmd pip; then
    pip install -q hf_transfer || persist_warn "pip install hf_transfer failed"
  else
    python3 -m pip install -q hf_transfer || persist_warn "python3 -m pip install hf_transfer failed"
  fi

  if persist_hf_transfer_is_available; then
    persist_log "hf_transfer installed and importable."
  else
    persist_warn "hf_transfer still not importable after install attempt."
  fi
}

persist_bootstrap() {
  # Run strict mode temporarily without breaking the rest of Vast’s script
  local __OLD_SET_OPTS
  __OLD_SET_OPTS="$(set +o)"

  set -euo pipefail

  # Defaults (env-overridable)
  : "${PERSIST_ROOT:=/workspace}"
  : "${PERSIST_SUBDIR:=persist}"
  : "${APP_ROOT:=/opt}"
  : "${PERSIST_VERBOSITY:=1}"

  : "${COMFY_ROOT:=${COMFYUI_DIR}}"
  : "${WANGP_ROOT:=}"

  : "${USE_SHARED_MODELS:=1}"

  : "${PERSIST_COMFY_CUSTOM_NODES:=1}"
  : "${PERSIST_COMFY_USER:=1}"
  : "${PERSIST_COMFY_INPUT:=0}"
  : "${PERSIST_COMFY_OUTPUT:=0}"

  : "${PERSIST_WANGP_EXTENSIONS:=1}"

  : "${PERSIST_XDG_CACHE:=0}"
  : "${ENABLE_HF_TRANSFER:=1}"
  : "${INSTALL_HF_TRANSFER:=0}"
  : "${PIP_DISABLE_VERSION_CHECK:=1}"

  : "${SAFE_MODE:=1}"
  : "${RSYNC_CHECKSUM:=0}"
  : "${FORCE_DESTRUCTIVE:=0}"

  : "${WRITE_ETC_ENVIRONMENT:=1}"
  : "${WRITE_PROFILE_D:=1}"

  : "${RESPECT_NOPROVISIONING:=0}"
  : "${NOPROVISIONING_FILE:=/.noprovisioning}"

  : "${COMFY_MODEL_DIRS:=checkpoints loras vae controlnet clip clip_vision upscale_models embeddings}"
  : "${COMFY_MODEL_DIRS_EXTRA:=unet esrgan sams diffusion_models text_encoders}"
  : "${LINK_COMFY_ALIASES:=1}"

  : "${WANGP_MODEL_DIRS:=Stable-diffusion Lora LyCORIS VAE ControlNet embeddings hypernetworks ESRGAN SwinIR LDSR Codeformer GFPGAN}"
  : "${WANGP_AUTODISCOVER_MODEL_DIRS:=1}"

  persist_log "=== Persistence bootstrap starting ==="

  if [[ "$RESPECT_NOPROVISIONING" == "1" && -f "$NOPROVISIONING_FILE" ]]; then
    persist_warn "Found $NOPROVISIONING_FILE and RESPECT_NOPROVISIONING=1; skipping persistence."
    eval "$__OLD_SET_OPTS"
    return 0
  fi

  [[ -d "$PERSIST_ROOT" ]] || { persist_err "PERSIST_ROOT does not exist: $PERSIST_ROOT"; eval "$__OLD_SET_OPTS"; return 0; }

  local PERSIST_BASE="${PERSIST_ROOT%/}/${PERSIST_SUBDIR}"
  persist_ensure_dir "$PERSIST_BASE" || { persist_err "Cannot create PERSIST_BASE: $PERSIST_BASE"; eval "$__OLD_SET_OPTS"; return 0; }

  # Caches first
  local CACHE_BASE="${PERSIST_BASE}/caches"
  persist_setup_caches "$CACHE_BASE"
  persist_maybe_install_hf_transfer

  # Detect roots if needed
  if [[ -z "$COMFY_ROOT" ]]; then
    COMFY_ROOT="$(persist_detect_root "ComfyUI" \
      "${WORKSPACE%/}/ComfyUI" \
      "${WORKSPACE%/}/comfyui" \
      "${APP_ROOT%/}/ComfyUI" \
      "/opt/ComfyUI" \
      "/root/ComfyUI" \
      "/ComfyUI" \
    )" || COMFY_ROOT=""
  fi

  if [[ -z "$WANGP_ROOT" ]]; then
    WANGP_ROOT="$(persist_detect_root "wanGP/Wan2GP" \
      "${WORKSPACE%/}/Wan2GP" \
      "${WORKSPACE%/}/Wan2GP-main" \
      "${WORKSPACE%/}/wanGP" \
      "${WORKSPACE%/}/stable-diffusion-webui" \
      "${WORKSPACE%/}/webui" \
      "${APP_ROOT%/}/wanGP" \
      "${APP_ROOT%/}/stable-diffusion-webui" \
      "/opt/wanGP" \
      "/opt/stable-diffusion-webui" \
    )" || WANGP_ROOT=""
  fi

  local SHARED_MODELS_BASE=""
  if [[ "$USE_SHARED_MODELS" == "1" ]]; then
    SHARED_MODELS_BASE="${PERSIST_BASE}/models"
    persist_ensure_dir "$SHARED_MODELS_BASE" || persist_die "Cannot create shared model pool: $SHARED_MODELS_BASE"
  fi

  # ComfyUI
  if [[ -n "$COMFY_ROOT" && -d "$COMFY_ROOT" ]]; then
    persist_log "Detected ComfyUI at: $COMFY_ROOT"

    local comfy_models_base
    if [[ "$USE_SHARED_MODELS" == "1" ]]; then
      comfy_models_base="$SHARED_MODELS_BASE"
    else
      comfy_models_base="${PERSIST_BASE}/comfyui/models"
      persist_ensure_dir "$comfy_models_base" || persist_die "Cannot create ComfyUI model persist base: $comfy_models_base"
    fi

    persist_ensure_dir "${COMFY_ROOT}/models" || true

    local d
    for d in $COMFY_MODEL_DIRS $COMFY_MODEL_DIRS_EXTRA; do
      persist_migrate_and_link_dir "${comfy_models_base}/${d}" "${COMFY_ROOT}/models/${d}" "ComfyUI models/${d}"
    done

    # Important for Vast script: it downloads to models/lora (singular)
    if [[ "$LINK_COMFY_ALIASES" == "1" ]]; then
      persist_migrate_and_link_dir "${comfy_models_base}/loras" "${COMFY_ROOT}/models/lora" "ComfyUI alias models/lora -> loras"
      persist_migrate_and_link_dir "${comfy_models_base}/diffusion_models" "${COMFY_ROOT}/models/diffusers" "ComfyUI alias models/diffusers -> diffusion_models"
    fi

    local comfy_state_base="${PERSIST_BASE}/comfyui"
    persist_ensure_dir "$comfy_state_base" || persist_die "Cannot create ComfyUI state base: $comfy_state_base"

    [[ "$PERSIST_COMFY_CUSTOM_NODES" == "1" ]] && persist_migrate_and_link_dir "${comfy_state_base}/custom_nodes" "${COMFY_ROOT}/custom_nodes" "ComfyUI custom_nodes" || true
    [[ "$PERSIST_COMFY_USER" == "1" ]]         && persist_migrate_and_link_dir "${comfy_state_base}/user"        "${COMFY_ROOT}/user"        "ComfyUI user" || true
    [[ "$PERSIST_COMFY_INPUT" == "1" ]]        && persist_migrate_and_link_dir "${comfy_state_base}/input"       "${COMFY_ROOT}/input"       "ComfyUI input" || true
    [[ "$PERSIST_COMFY_OUTPUT" == "1" ]]       && persist_migrate_and_link_dir "${comfy_state_base}/output"      "${COMFY_ROOT}/output"      "ComfyUI output" || true
  else
    persist_warn "ComfyUI not detected; skipping ComfyUI relinks."
  fi

  # ai-dock storage relinks (if present)
  local sd_storage="${WORKSPACE%/}/storage/stable_diffusion/models"
  if [[ -d "${WORKSPACE%/}/storage" || -d "${WORKSPACE%/}/storage/stable_diffusion" ]]; then
    persist_log "Found ai-dock style storage parent; ensuring model storage relinks under: $sd_storage"
    persist_ensure_dir "$sd_storage" || true

    if [[ "$USE_SHARED_MODELS" == "1" ]]; then
      persist_migrate_and_link_dir "${SHARED_MODELS_BASE}/checkpoints"   "${sd_storage}/ckpt"       "ai-dock storage ckpt"
      persist_migrate_and_link_dir "${SHARED_MODELS_BASE}/unet"          "${sd_storage}/unet"       "ai-dock storage unet"
      persist_migrate_and_link_dir "${SHARED_MODELS_BASE}/loras"         "${sd_storage}/lora"       "ai-dock storage lora"
      persist_migrate_and_link_dir "${SHARED_MODELS_BASE}/controlnet"    "${sd_storage}/controlnet" "ai-dock storage controlnet"
      persist_migrate_and_link_dir "${SHARED_MODELS_BASE}/vae"           "${sd_storage}/vae"        "ai-dock storage vae"
      persist_migrate_and_link_dir "${SHARED_MODELS_BASE}/esrgan"        "${sd_storage}/esrgan"     "ai-dock storage esrgan"
    fi
  fi

  # wanGP (optional)
  if [[ -n "$WANGP_ROOT" && -d "$WANGP_ROOT" && ( -d "${WANGP_ROOT}/models" || -L "${WANGP_ROOT}/models" ) ]]; then
    persist_log "Detected wanGP/Wan2GP at: $WANGP_ROOT"

    local wangp_models_base
    if [[ "$USE_SHARED_MODELS" == "1" ]]; then
      wangp_models_base="$SHARED_MODELS_BASE"
    else
      wangp_models_base="${PERSIST_BASE}/wangp/models"
      persist_ensure_dir "$wangp_models_base" || true
    fi

    local md
    for md in $WANGP_MODEL_DIRS; do
      local equiv="$md"
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
      persist_migrate_and_link_dir "${wangp_models_base}/${equiv}" "${WANGP_ROOT}/models/${md}" "wanGP models/${md}"
    done

    if [[ "$WANGP_AUTODISCOVER_MODEL_DIRS" == "1" ]]; then
      local sub name
      shopt -s nullglob
      for sub in "${WANGP_ROOT}/models/"*/ ; do
        [[ -d "$sub" ]] || continue
        name="$(basename "$sub")"
        case " $WANGP_MODEL_DIRS " in
          *" $name "*) continue ;;
        esac
        persist_migrate_and_link_dir "${PERSIST_BASE}/wangp/models/${name}" "${WANGP_ROOT}/models/${name}" "wanGP models/${name} (autodiscovered)"
      done
      shopt -u nullglob
    fi

    if [[ "${PERSIST_WANGP_EXTENSIONS:-1}" == "1" && ( -d "${WANGP_ROOT}/extensions" || -L "${WANGP_ROOT}/extensions" ) ]]; then
      persist_migrate_and_link_dir "${PERSIST_BASE}/wangp/extensions" "${WANGP_ROOT}/extensions" "wanGP extensions"
    fi
  fi

  persist_log "=== Persistence bootstrap complete ==="

  # Restore original shell options so Vast’s script behaves as expected
  eval "$__OLD_SET_OPTS"
}

# Run persistence bootstrap BEFORE Vast provisioning downloads
persist_bootstrap || true

###############################################################################
# Existing Vast.ai setup script (kept as-is, only moved down)
###############################################################################

# Packages are installed after nodes so we can fix them...
APT_PACKAGES=(
    #"package-1"
    #"package-2"
)

PIP_PACKAGES=(
    #"package-1"
    #"package-2"
)

NODES=(
    #"https://github.com/ltdrdata/ComfyUI-Manager"
    #"https://github.com/cubiq/ComfyUI_essentials"
)

WORKFLOWS=(
)

CHECKPOINT_MODELS=(
    "https://civitai.com/api/download/models/798204?type=Model&format=SafeTensor&size=full&fp=fp16"
)

UNET_MODELS=(
)

LORA_MODELS=(
)

VAE_MODELS=(
)

ESRGAN_MODELS=(
)

CONTROLNET_MODELS=(
)

### DO NOT EDIT BELOW HERE UNLESS YOU KNOW WHAT YOU ARE DOING ###

function provisioning_start() {
    provisioning_print_header
    provisioning_get_apt_packages
    provisioning_get_nodes
    provisioning_get_pip_packages
    provisioning_get_files \
        "${COMFYUI_DIR}/models/checkpoints" \
        "${CHECKPOINT_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/unet" \
        "${UNET_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/lora" \
        "${LORA_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/controlnet" \
        "${CONTROLNET_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/vae" \
        "${VAE_MODELS[@]}"
    provisioning_get_files \
        "${COMFYUI_DIR}/models/esrgan" \
        "${ESRGAN_MODELS[@]}"
    provisioning_print_end
}

function provisioning_get_apt_packages() {
    if [[ -n $APT_PACKAGES ]]; then
            sudo $APT_INSTALL ${APT_PACKAGES[@]}
    fi
}

function provisioning_get_pip_packages() {
    if [[ -n $PIP_PACKAGES ]]; then
            pip install ${PIP_PACKAGES[@]}
    fi
}

function provisioning_get_nodes() {
    for repo in "${NODES[@]}"; do
        dir="${repo##*/}"
        path="${COMFYUI_DIR}custom_nodes/${dir}"
        requirements="${path}/requirements.txt"
        if [[ -d $path ]]; then
            if [[ ${AUTO_UPDATE,,} != "false" ]]; then
                printf "Updating node: %s...\n" "${repo}"
                ( cd "$path" && git pull )
                if [[ -e $requirements ]]; then
                   pip install  -r "$requirements"
                fi
            fi
        else
            printf "Downloading node: %s...\n" "${repo}"
            git clone "${repo}" "${path}" --recursive
            if [[ -e $requirements ]]; then
                pip install  -r "${requirements}"
            fi
        fi
    done
}

function provisioning_get_files() {
    if [[ -z $2 ]]; then return 1; fi

    dir="$1"
    mkdir -p "$dir"
    shift
    arr=("$@")
    printf "Downloading %s model(s) to %s...\n" "${#arr[@]}" "$dir"
    for url in "${arr[@]}"; do
        printf "Downloading: %s\n" "${url}"
        provisioning_download "${url}" "${dir}"
        printf "\n"
    done
}

function provisioning_print_header() {
    printf "\n##############################################\n#                                            #\n#          Provisioning container            #\n#                                            #\n#         This will take some time           #\n#                                            #\n# Your container will be ready on completion #\n#                                            #\n##############################################\n\n"
}

function provisioning_print_end() {
    printf "\nProvisioning complete:  Application will start now\n\n"
}

function provisioning_has_valid_hf_token() {
    [[ -n "$HF_TOKEN" ]] || return 1
    url="https://huggingface.co/api/whoami-v2"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $HF_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

function provisioning_has_valid_civitai_token() {
    [[ -n "$CIVITAI_TOKEN" ]] || return 1
    url="https://civitai.com/api/v1/models?hidden=1&limit=1"

    response=$(curl -o /dev/null -s -w "%{http_code}" -X GET "$url" \
        -H "Authorization: Bearer $CIVITAI_TOKEN" \
        -H "Content-Type: application/json")

    # Check if the token is valid
    if [ "$response" -eq 200 ]; then
        return 0
    else
        return 1
    fi
}

# Download from $1 URL to $2 file path
function provisioning_download() {
    if [[ -n $HF_TOKEN && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?huggingface\.co(/|$|\?) ]]; then
        auth_token="$HF_TOKEN"
    elif
        [[ -n $CIVITAI_TOKEN && $1 =~ ^https://([a-zA-Z0-9_-]+\.)?civitai\.com(/|$|\?) ]]; then
        auth_token="$CIVITAI_TOKEN"
    fi
    if [[ -n $auth_token ]];then
        wget --header="Authorization: Bearer $auth_token" -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    else
        wget -qnc --content-disposition --show-progress -e dotbytes="${3:-4M}" -P "$2" "$1"
    fi
}

# Allow user to disable provisioning if they started with a script they didn't want
if [[ ! -f /.noprovisioning ]]; then
    provisioning_start
fi

