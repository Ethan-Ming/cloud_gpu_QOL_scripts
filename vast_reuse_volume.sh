## Startup Script
#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# ComfyUI + wanGP/Wan2GP Persistence Bootstrap (Vast.ai-friendly)
#
# Purpose: Symlink models, caches, and app state to persistent volume to avoid
#          re-downloading 10-50GB of assets on each instance restart.
#
# - Idempotent
# - Safe-by-default migration (merge then symlink)
# - Persists models, caches, and app state to a mounted persistent volume
#
# Run this EARLY at startup (before any downloads/builds).
###############################################################################

############################
# Configuration (env overridable)
############################

: "${PERSIST_ROOT:=/workspace}"          # persistent volume mount
: "${PERSIST_SUBDIR:=persist}"          # managed subdir under PERSIST_ROOT
: "${WORKSPACE:=/workspace}"            # common workspace root (ai-dock style)
: "${APP_ROOT:=/opt}"                   # additional search root for apps

# Optional explicit app roots (skip auto-detect if provided)
: "${COMFY_ROOT:=}"
: "${WANGP_ROOT:=}"                     # wanGP/Wan2GP/A1111-like root

# Persistence toggles (ComfyUI state)
: "${PERSIST_COMFY_CUSTOM_NODES:=1}"
: "${PERSIST_COMFY_USER:=1}"
: "${PERSIST_COMFY_INPUT:=0}"
: "${PERSIST_COMFY_OUTPUT:=0}"

# Optional wanGP state
: "${PERSIST_WANGP_EXTENSIONS:=1}"

# Shared model pool across ComfyUI + ai-dock storage + wanGP
: "${USE_SHARED_MODELS:=1}"             # 1=shared pool, 0=per-app pool

# ComfyUI model subdirs to persist (required ones included)
: "${COMFY_MODEL_DIRS:=checkpoints loras vae controlnet clip clip_vision upscale_models embeddings}"
: "${COMFY_MODEL_DIRS_EXTRA:=unet esrgan sams diffusion_models text_encoders}"
: "${LINK_COMFY_ALIASES:=1}"            # also link models/lora -> loras, models/diffusers -> diffusion_models

# wanGP/A1111-like model subdirs to link (if WANGP_ROOT/models exists)
: "${WANGP_MODEL_DIRS:=Stable-diffusion Lora LyCORIS VAE ControlNet embeddings hypernetworks ESRGAN SwinIR LDSR Codeformer GFPGAN}"
: "${WANGP_AUTODISCOVER_MODEL_DIRS:=1}" # also persist/link any existing subdirs under WANGP_ROOT/models

# Cache persistence
: "${PERSIST_XDG_CACHE:=0}"             # 1=set XDG_CACHE_HOME to persistent
: "${ENABLE_HF_TRANSFER:=1}"            # sets HF_HUB_ENABLE_HF_TRANSFER=1
: "${INSTALL_HF_TRANSFER:=0}"           # 1=attempt pip install hf_transfer (optional; may be slow)
: "${PIP_DISABLE_VERSION_CHECK:=1}"     # 1=avoid pip version-check delays

# Safe migration behavior
: "${SAFE_MODE:=1}"                     # 1=conservative (recommended), 0=more aggressive
: "${RSYNC_CHECKSUM:=0}"                # 1=rsync --checksum (slower, more accurate), 0=mtime/size
: "${FORCE_DESTRUCTIVE:=0}"             # 1=allow removing unexpected files/dirs (avoid unless needed)

# Write env vars for services/shells
: "${WRITE_ETC_ENVIRONMENT:=1}"         # writes managed block to /etc/environment if writable
: "${WRITE_PROFILE_D:=1}"               # writes /etc/profile.d/99-persist-caches.sh if writable
: "${WRITE_VENV_POSTACTIVATE:=0}"       # 1=write a postactivate file if VENV_PATH exists
: "${VENV_PATH:=/venv/main}"            # common ai-dock venv path

# Respect a global "skip provisioning" flag file?
: "${RESPECT_NOPROVISIONING:=0}"
: "${NOPROVISIONING_FILE:=/.noprovisioning}"

# Logging verbosity: 0=errors only, 1=info, 2=debug
: "${VERBOSITY:=1}"

############################
# Helpers
############################

ts() { date +"%Y-%m-%d %H:%M:%S"; }

log()  { [[ "${VERBOSITY}" -ge 1 ]] && echo "[$(ts)] [INFO]  $*" >&2 || true; }
dbg()  { [[ "${VERBOSITY}" -ge 2 ]] && echo "[$(ts)] [DEBUG] $*" >&2 || true; }
warn() { [[ "${VERBOSITY}" -ge 1 ]] && echo "[$(ts)] [WARN]  $*" >&2 || true; }
err()  { echo "[$(ts)] [ERROR] $*" >&2; }
die()  { err "$*"; exit 1; }

have_cmd() { command -v "$1" >/dev/null 2>&1; }

ensure_dir() {
  local d="$1"
  [[ -z "$d" ]] && return 0
  if [[ ! -d "$d" ]]; then
    mkdir -p -- "$d" 2>/dev/null || return 1
  fi
}

is_empty_dir() {
  local d="$1"
  [[ -d "$d" ]] || return 1
  [[ -z "$(ls -A "$d" 2>/dev/null || true)" ]]
}

canonical_path() {
  local p="$1"
  if have_cmd readlink; then
    readlink -f "$p" 2>/dev/null || true
    return 0
  fi
  if have_cmd python3; then
    python3 - <<PY 2>/dev/null || true
import os,sys
print(os.path.realpath(sys.argv[1]))
PY
    return 0
  fi
  echo "$p"
}

symlink_points_to() {
  local link="$1" target="$2"
  [[ -L "$link" ]] || return 1
  local cur exp
  cur="$(canonical_path "$link")"
  exp="$(canonical_path "$target")"
  [[ -n "$cur" && -n "$exp" && "$cur" == "$exp" ]]
}

file_size() {
  local f="$1"
  if have_cmd stat; then
    stat -c '%s' -- "$f" 2>/dev/null || echo ""
  else
    echo ""
  fi
}

# Merge helper: copy files that do not exist in dest; then overwrite ONLY same-path files with different size.
# This implements your requested behavior: "same file name but different size => replace old with new".
replace_size_conflicts() {
  local from_dir="$1" to_dir="$2"

  have_cmd find || { warn "find not available; cannot do size-conflict replacement pass"; return 0; }

  # Iterate files in from_dir by relative path (null-delimited to handle spaces safely)
  while IFS= read -r -d '' rel; do
    local src="$from_dir/$rel"
    local dst="$to_dir/$rel"

    [[ -f "$src" ]] || continue
    [[ -f "$dst" ]] || continue

    local ssz dsz
    ssz="$(file_size "$src")"
    dsz="$(file_size "$dst")"

    # If we can't reliably get sizes, do nothing (stay safe-ish)
    [[ -n "$ssz" && -n "$dsz" ]] || continue

    if [[ "$ssz" != "$dsz" ]]; then
      dbg "Size-conflict detected, overwriting persistent file: $dst (old=$dsz new=$ssz)"
      ensure_dir "$(dirname "$dst")" || true

      if have_cmd rsync; then
        # rsync single file, preserving attrs; always overwrite
        rsync -a --protect-args -- "$src" "$dst"
      else
        cp -a -f -- "$src" "$dst"
      fi
    fi
  done < <(cd "$from_dir" && find . -type f -print0 | sed -z 's|^\./||')
}

rsync_merge() {
  local from_dir="$1" to_dir="$2"
  ensure_dir "$to_dir" || return 1

  if have_cmd rsync; then
    local opts=(-a --ignore-existing)
    if [[ "$RSYNC_CHECKSUM" == "1" ]]; then
      opts=(-a --checksum --ignore-existing)
    fi
    rsync "${opts[@]}" -- "$from_dir"/ "$to_dir"/
  else
    warn "rsync not found; falling back to cp -a (may be slower)."
    if cp -an "$from_dir"/. "$to_dir"/ 2>/dev/null; then
      true
    else
      cp -a "$from_dir"/. "$to_dir"/
    fi
  fi

  # Your tweak: if same relative filename/path exists but size differs, overwrite persistent with instance copy
  replace_size_conflicts "$from_dir" "$to_dir" || true
}

# Migrate content (if needed) then replace dest with symlink to src.
migrate_and_link_dir() {
  local src="$1" dest="$2" desc="${3:-dir}"
  [[ -z "$src" || -z "$dest" ]] && return 0

  ensure_dir "$src" || die "Cannot create persistent directory: $src (check mount/permissions)"

  if symlink_points_to "$dest" "$src"; then
    dbg "Already linked: $dest -> $src"
    return 0
  fi

  # dest missing: link directly
  if [[ ! -e "$dest" && ! -L "$dest" ]]; then
    ensure_dir "$(dirname "$dest")" || die "Cannot create parent dir for: $dest"
    ln -sfn -- "$src" "$dest"
    log "Linked $desc: $dest -> $src"
    return 0
  fi

  # incorrect symlink: replace
  if [[ -L "$dest" ]]; then
    warn "Replacing incorrect symlink for $desc: $dest"
    rm -f -- "$dest"
    ln -sfn -- "$src" "$dest"
    log "Linked $desc: $dest -> $src"
    return 0
  fi

  # file at dest: skip in safe mode
  if [[ -f "$dest" ]]; then
    if [[ "$SAFE_MODE" == "1" && "$FORCE_DESTRUCTIVE" != "1" ]]; then
      warn "Not linking $desc because destination is a file: $dest (SAFE_MODE=1)"
      return 0
    fi
    warn "Removing file to replace with symlink for $desc: $dest (SAFE_MODE=$SAFE_MODE FORCE_DESTRUCTIVE=$FORCE_DESTRUCTIVE)"
    rm -f -- "$dest"
    ln -sfn -- "$src" "$dest"
    log "Linked $desc: $dest -> $src"
    return 0
  fi

  # directory at dest
  if [[ -d "$dest" ]]; then
    if is_empty_dir "$dest"; then
      rmdir -- "$dest" 2>/dev/null || true
      ln -sfn -- "$src" "$dest"
      log "Linked $desc (was empty): $dest -> $src"
      return 0
    fi

    log "Merging existing $desc into persistent store: $dest -> $src"
    rsync_merge "$dest" "$src" || die "Failed to merge $desc: $dest -> $src"

    rm -rf -- "$dest"
    ln -sfn -- "$src" "$dest"
    log "Linked $desc (after merge): $dest -> $src"
    return 0
  fi

  warn "Unhandled destination type for $desc: $dest (skipping)"
  return 0
}

detect_root() {
  # usage: detect_root "Name" "/path1" "/path2" ...
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

write_managed_block() {
  # usage: write_managed_block "/etc/environment" "MARKER" "content"
  local file="$1" marker="$2" content="$3"
  [[ -w "$file" ]] || return 1
  local begin="# >>> ${marker}"
  local end="# <<< ${marker}"

  if have_cmd sed; then
    sed -i "/^${begin//\//\\/}\$/,/^${end//\//\\/}\$/d" "$file" 2>/dev/null || true
  fi

  {
    echo "$begin"
    echo "$content"
    echo "$end"
  } >> "$file"
}

setup_caches() {
  local cache_base="$1"

  ensure_dir "$cache_base" || die "Cannot create cache base: $cache_base"
  ensure_dir "${cache_base}/huggingface/hub" || true
  ensure_dir "${cache_base}/torch" || true
  ensure_dir "${cache_base}/pip" || true
  ensure_dir "${cache_base}/triton" || true
  ensure_dir "${cache_base}/torchinductor" || true
  ensure_dir "${cache_base}/cuda" || true
  ensure_dir "${cache_base}/torch_extensions" || true
  ensure_dir "${cache_base}/xdg" || true

  export HF_HOME="${cache_base}/huggingface"
  export HUGGINGFACE_HUB_CACHE="${cache_base}/huggingface/hub"
  export TORCH_HOME="${cache_base}/torch"
  export PIP_CACHE_DIR="${cache_base}/pip"
  export TRITON_CACHE_DIR="${cache_base}/triton"
  export TORCHINDUCTOR_CACHE_DIR="${cache_base}/torchinductor"
  export CUDA_CACHE_PATH="${cache_base}/cuda"
  export CUDA_CACHE_MAXSIZE="${CUDA_CACHE_MAXSIZE:-2147483648}"   # 2 GiB
  export TORCH_EXTENSIONS_DIR="${cache_base}/torch_extensions"
  export TRANSFORMERS_CACHE="${HF_HOME}/transformers"
  export DIFFUSERS_CACHE="${HF_HOME}/diffusers"

  if [[ "$PERSIST_XDG_CACHE" == "1" ]]; then
    export XDG_CACHE_HOME="${cache_base}/xdg"
  fi

  if [[ "$ENABLE_HF_TRANSFER" == "1" ]]; then
    export HF_HUB_ENABLE_HF_TRANSFER=1
  fi

  if [[ "$PIP_DISABLE_VERSION_CHECK" == "1" ]]; then
    export PIP_DISABLE_PIP_VERSION_CHECK=1
  fi

  log "Cache env configured (persistent):"
  log "  HF_HOME=$HF_HOME"
  log "  HUGGINGFACE_HUB_CACHE=$HUGGINGFACE_HUB_CACHE"
  log "  TORCH_HOME=$TORCH_HOME"
  log "  PIP_CACHE_DIR=$PIP_CACHE_DIR"
  log "  TRITON_CACHE_DIR=$TRITON_CACHE_DIR"
  log "  TORCHINDUCTOR_CACHE_DIR=$TORCHINDUCTOR_CACHE_DIR"
  log "  TORCH_EXTENSIONS_DIR=$TORCH_EXTENSIONS_DIR"
  log "  CUDA_CACHE_PATH=$CUDA_CACHE_PATH"
  [[ "$PERSIST_XDG_CACHE" == "1" ]] && log "  XDG_CACHE_HOME=$XDG_CACHE_HOME" || true

  # Persist for services/shells
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

  if [[ "$ENABLE_HF_TRANSFER" == "1" ]]; then
    env_block+=$'\nHF_HUB_ENABLE_HF_TRANSFER="1"'
  fi
  if [[ "$PERSIST_XDG_CACHE" == "1" ]]; then
    env_block+=$'\nXDG_CACHE_HOME="'"$XDG_CACHE_HOME"'"'
  fi
  if [[ "$PIP_DISABLE_VERSION_CHECK" == "1" ]]; then
    env_block+=$'\nPIP_DISABLE_PIP_VERSION_CHECK="1"'
  fi

  if [[ "$WRITE_ETC_ENVIRONMENT" == "1" && -w /etc/environment ]]; then
    write_managed_block "/etc/environment" "PERSIST_CACHES" "$env_block" || warn "Failed to update /etc/environment"
    log "Updated /etc/environment managed block (PERSIST_CACHES)."
  else
    dbg "Skipping /etc/environment update (WRITE_ETC_ENVIRONMENT=$WRITE_ETC_ENVIRONMENT, writable=$( [[ -w /etc/environment ]] && echo yes || echo no ))."
  fi

  if [[ "$WRITE_PROFILE_D" == "1" && -w /etc/profile.d ]]; then
    local prof="/etc/profile.d/99-persist-caches.sh"
    cat > "$prof" <<EOF
# Managed by persistence bootstrap: $(ts)
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
    [[ "$ENABLE_HF_TRANSFER" == "1" ]] && echo 'export HF_HUB_ENABLE_HF_TRANSFER=1' >> "$prof" || true
    [[ "$PERSIST_XDG_CACHE" == "1" ]] && echo "export XDG_CACHE_HOME=\"$XDG_CACHE_HOME\"" >> "$prof" || true
    [[ "$PIP_DISABLE_VERSION_CHECK" == "1" ]] && echo 'export PIP_DISABLE_PIP_VERSION_CHECK=1' >> "$prof" || true
    chmod +x "$prof" 2>/dev/null || true
    log "Wrote $prof"
  else
    dbg "Skipping /etc/profile.d write (WRITE_PROFILE_D=$WRITE_PROFILE_D)."
  fi

  if [[ "$WRITE_VENV_POSTACTIVATE" == "1" && -f "${VENV_PATH}/bin/activate" ]]; then
    local post="${VENV_PATH}/bin/postactivate"
    cat > "$post" <<EOF
# Managed by persistence bootstrap: $(ts)
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
    [[ "$ENABLE_HF_TRANSFER" == "1" ]] && echo 'export HF_HUB_ENABLE_HF_TRANSFER=1' >> "$post" || true
    [[ "$PERSIST_XDG_CACHE" == "1" ]] && echo "export XDG_CACHE_HOME=\"$XDG_CACHE_HOME\"" >> "$post" || true
    [[ "$PIP_DISABLE_VERSION_CHECK" == "1" ]] && echo 'export PIP_DISABLE_PIP_VERSION_CHECK=1' >> "$post" || true
    chmod +x "$post" 2>/dev/null || true
    log "Wrote venv postactivate: $post"
  fi
}

hf_transfer_is_available() {
  have_cmd python3 || return 1
  python3 -c "import hf_transfer" >/dev/null 2>&1
}

maybe_install_hf_transfer() {
  # Your tweak: double-check hf_transfer installed if HF_TRANSFER is enabled.
  [[ "$ENABLE_HF_TRANSFER" == "1" ]] || return 0

  if hf_transfer_is_available; then
    dbg "hf_transfer is importable (OK)."
    return 0
  fi

  warn "HF_HUB_ENABLE_HF_TRANSFER=1 but python cannot import hf_transfer."
  warn "Downloads will still work, but without hf_transfer acceleration."

  [[ "$INSTALL_HF_TRANSFER" == "1" ]] || return 0

  have_cmd python3 || { warn "INSTALL_HF_TRANSFER=1 but python3 not found"; return 0; }

  log "Attempting to install hf_transfer (best-effort)..."
  if have_cmd pip; then
    pip install -q hf_transfer || warn "pip install hf_transfer failed"
  else
    python3 -m pip install -q hf_transfer || warn "python3 -m pip install hf_transfer failed"
  fi

  if hf_transfer_is_available; then
    log "hf_transfer installed and importable."
  else
    warn "hf_transfer still not importable after install attempt."
  fi
}

main() {
  log "=== Persistence bootstrap starting ==="

  if [[ "$RESPECT_NOPROVISIONING" == "1" && -f "$NOPROVISIONING_FILE" ]]; then
    warn "Found $NOPROVISIONING_FILE and RESPECT_NOPROVISIONING=1; skipping."
    exit 0
  fi

  [[ -d "$PERSIST_ROOT" ]] || die "PERSIST_ROOT does not exist: $PERSIST_ROOT (mount your volume first)"
  [[ -w "$PERSIST_ROOT" ]] || warn "PERSIST_ROOT not writable: $PERSIST_ROOT (some operations may fail)"

  local PERSIST_BASE="${PERSIST_ROOT%/}/${PERSIST_SUBDIR}"
  ensure_dir "$PERSIST_BASE" || die "Cannot create PERSIST_BASE: $PERSIST_BASE"

  # ---- Caches FIRST (so all subsequent downloads/builds land on persistent disk) ----
  local CACHE_BASE="${PERSIST_BASE}/caches"
  setup_caches "$CACHE_BASE"
  maybe_install_hf_transfer

  # ---- Detect app roots if not provided ----
  if [[ -z "$COMFY_ROOT" ]]; then
    COMFY_ROOT="$(detect_root "ComfyUI" \
      "${WORKSPACE%/}/ComfyUI" \
      "${WORKSPACE%/}/comfyui" \
      "${APP_ROOT%/}/ComfyUI" \
      "/opt/ComfyUI" \
      "/root/ComfyUI" \
      "/ComfyUI" \
    )" || COMFY_ROOT=""
  fi

  if [[ -z "$WANGP_ROOT" ]]; then
    WANGP_ROOT="$(detect_root "wanGP/Wan2GP" \
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

  # ---- Model pool base ----
  local SHARED_MODELS_BASE=""
  if [[ "$USE_SHARED_MODELS" == "1" ]]; then
    SHARED_MODELS_BASE="${PERSIST_BASE}/models"
    ensure_dir "$SHARED_MODELS_BASE" || die "Cannot create shared model pool: $SHARED_MODELS_BASE"
  fi

  # ---- ComfyUI persistence ----
  if [[ -n "$COMFY_ROOT" && -d "$COMFY_ROOT" ]]; then
    log "Detected ComfyUI at: $COMFY_ROOT"

    local comfy_models_base
    if [[ "$USE_SHARED_MODELS" == "1" ]]; then
      comfy_models_base="$SHARED_MODELS_BASE"
    else
      comfy_models_base="${PERSIST_BASE}/comfyui/models"
      ensure_dir "$comfy_models_base" || die "Cannot create ComfyUI model persist base: $comfy_models_base"
    fi

    ensure_dir "${COMFY_ROOT}/models" || true

    local d
    for d in $COMFY_MODEL_DIRS $COMFY_MODEL_DIRS_EXTRA; do
      migrate_and_link_dir "${comfy_models_base}/${d}" "${COMFY_ROOT}/models/${d}" "ComfyUI models/${d}"
    done

    if [[ "$LINK_COMFY_ALIASES" == "1" ]]; then
      migrate_and_link_dir "${comfy_models_base}/loras" "${COMFY_ROOT}/models/lora" "ComfyUI alias models/lora -> loras"
      migrate_and_link_dir "${comfy_models_base}/diffusion_models" "${COMFY_ROOT}/models/diffusers" "ComfyUI alias models/diffusers -> diffusion_models"
    fi

    local comfy_state_base="${PERSIST_BASE}/comfyui"
    ensure_dir "$comfy_state_base" || die "Cannot create ComfyUI state base: $comfy_state_base"

    [[ "$PERSIST_COMFY_CUSTOM_NODES" == "1" ]] && migrate_and_link_dir "${comfy_state_base}/custom_nodes" "${COMFY_ROOT}/custom_nodes" "ComfyUI custom_nodes" || true
    [[ "$PERSIST_COMFY_USER" == "1" ]]         && migrate_and_link_dir "${comfy_state_base}/user"        "${COMFY_ROOT}/user"        "ComfyUI user" || true
    [[ "$PERSIST_COMFY_INPUT" == "1" ]]        && migrate_and_link_dir "${comfy_state_base}/input"       "${COMFY_ROOT}/input"       "ComfyUI input" || true
    [[ "$PERSIST_COMFY_OUTPUT" == "1" ]]       && migrate_and_link_dir "${comfy_state_base}/output"      "${COMFY_ROOT}/output"      "ComfyUI output" || true
  else
    warn "ComfyUI not detected (set COMFY_ROOT to override). Skipping ComfyUI relinks."
  fi

  # ---- ai-dock storage relinks (optional, if present) ----
  local sd_storage="${WORKSPACE%/}/storage/stable_diffusion/models"
  if [[ -d "${WORKSPACE%/}/storage" || -d "${WORKSPACE%/}/storage/stable_diffusion" ]]; then
    log "Found ai-dock style storage parent; ensuring model storage relinks under: $sd_storage"
    ensure_dir "$sd_storage" || true

    if [[ "$USE_SHARED_MODELS" == "1" ]]; then
      migrate_and_link_dir "${SHARED_MODELS_BASE}/checkpoints"   "${sd_storage}/ckpt"       "ai-dock storage ckpt"
      migrate_and_link_dir "${SHARED_MODELS_BASE}/unet"          "${sd_storage}/unet"       "ai-dock storage unet"
      migrate_and_link_dir "${SHARED_MODELS_BASE}/loras"         "${sd_storage}/lora"       "ai-dock storage lora"
      migrate_and_link_dir "${SHARED_MODELS_BASE}/controlnet"    "${sd_storage}/controlnet" "ai-dock storage controlnet"
      migrate_and_link_dir "${SHARED_MODELS_BASE}/vae"           "${sd_storage}/vae"        "ai-dock storage vae"
      migrate_and_link_dir "${SHARED_MODELS_BASE}/esrgan"        "${sd_storage}/esrgan"     "ai-dock storage esrgan"
    else
      local storage_persist="${PERSIST_BASE}/aidock/storage/stable_diffusion/models"
      migrate_and_link_dir "${storage_persist}/ckpt"       "${sd_storage}/ckpt"       "ai-dock storage ckpt"
      migrate_and_link_dir "${storage_persist}/unet"       "${sd_storage}/unet"       "ai-dock storage unet"
      migrate_and_link_dir "${storage_persist}/lora"       "${sd_storage}/lora"       "ai-dock storage lora"
      migrate_and_link_dir "${storage_persist}/controlnet" "${sd_storage}/controlnet" "ai-dock storage controlnet"
      migrate_and_link_dir "${storage_persist}/vae"        "${sd_storage}/vae"        "ai-dock storage vae"
      migrate_and_link_dir "${storage_persist}/esrgan"     "${sd_storage}/esrgan"     "ai-dock storage esrgan"
    fi
  fi

  # ---- wanGP / A1111-like persistence ----
  if [[ -n "$WANGP_ROOT" && -d "$WANGP_ROOT" ]]; then
    log "Detected wanGP/Wan2GP candidate at: $WANGP_ROOT"

    if [[ -d "${WANGP_ROOT}/models" || -L "${WANGP_ROOT}/models" ]]; then
      log "Found ${WANGP_ROOT}/models; linking common wanGP/A1111 model subdirs."

      local wangp_models_base
      if [[ "$USE_SHARED_MODELS" == "1" ]]; then
        wangp_models_base="$SHARED_MODELS_BASE"
      else
        wangp_models_base="${PERSIST_BASE}/wangp/models"
        ensure_dir "$wangp_models_base" || true
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
        migrate_and_link_dir "${wangp_models_base}/${equiv}" "${WANGP_ROOT}/models/${md}" "wanGP models/${md}"
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
          migrate_and_link_dir "${PERSIST_BASE}/wangp/models/${name}" "${WANGP_ROOT}/models/${name}" "wanGP models/${name} (autodiscovered)"
        done
        shopt -u nullglob
      fi
    else
      log "No ${WANGP_ROOT}/models directory; skipping wanGP model relinks (caches are still persisted)."
    fi

    if [[ "$PERSIST_WANGP_EXTENSIONS" == "1" && ( -d "${WANGP_ROOT}/extensions" || -L "${WANGP_ROOT}/extensions" ) ]]; then
      migrate_and_link_dir "${PERSIST_BASE}/wangp/extensions" "${WANGP_ROOT}/extensions" "wanGP extensions"
    fi
  else
    warn "wanGP/Wan2GP not detected (set WANGP_ROOT to override). Skipping wanGP relinks."
  fi

  log "=== Persistence bootstrap complete (idempotent) ==="
  log "Persistent base: ${PERSIST_BASE}"
  [[ "$USE_SHARED_MODELS" == "1" ]] && log "Shared models:    ${SHARED_MODELS_BASE}" || true
  log "Caches:           ${CACHE_BASE}"
}

main "$@"
