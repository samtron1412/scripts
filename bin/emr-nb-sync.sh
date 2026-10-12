#!/usr/bin/env bash
set -euo pipefail

# emr-nb-sync.sh — Pull/push Jupyter notebooks between local disk and EMR Studio (S3-backed)
#
# Usage:
#   emr-nb-sync.sh pull <emr-url-or-local-path> [--profile <aws-profile>] [--local-dir <dir>]
#   emr-nb-sync.sh push <local-path>             [--profile <aws-profile>]
#
# On first pull with an EMR URL the script auto-discovers the S3 bucket,
# downloads the notebook, and writes a sidecar metadata file so subsequent
# pull/push operations only need the local path.

CACHE_DIR="$HOME/.emr-nb-sync"
CACHE_FILE="$CACHE_DIR/bucket-cache.json"
DEFAULT_LOCAL_DIR="$HOME/emr-notebooks"
EDITOR_ID_LOWER=""  # set by parse_emr_url
S3_PREFIX=""        # set by discover_s3_bucket

# ── helpers ──────────────────────────────────────────────────────────────────

die()  { echo "ERROR: $*" >&2; exit 1; }
info() { echo ":: $*" >&2; }

usage() {
  cat >&2 <<'EOF'
Usage:
  emr-nb-sync.sh pull <emr-url | local-notebook-path> [--profile PROFILE] [--local-dir DIR]
  emr-nb-sync.sh push <local-notebook-path>            [--profile PROFILE]

Options:
  --profile PROFILE   AWS CLI named profile (reads from sidecar metadata if omitted)
  --local-dir DIR     Local directory for notebooks (default: ~/emr-notebooks)
EOF
  exit 1
}

# ── URL parsing ──────────────────────────────────────────────────────────────

is_emr_url() { [[ "$1" == https://* ]] && [[ "$1" == *emrnotebooks* ]]; }

parse_emr_url() {
  local url="$1"
  # Example: https://e-XXXX.emrnotebooks-prod.us-east-1.amazonaws.com/workspace/lab/tree/notebook.ipynb
  local host path
  host="$(echo "$url" | sed 's|https://||' | cut -d/ -f1)"
  path="$(echo "$url" | sed 's|https://[^/]*/||')"

  # Editor ID from URL is lowercase; S3 uses uppercase — store both
  local editor_id_raw
  editor_id_raw="$(echo "$host" | cut -d. -f1)"
  EDITOR_ID="$(echo "$editor_id_raw" | tr '[:lower:]' '[:upper:]')"
  EDITOR_ID_LOWER="$(echo "$editor_id_raw" | tr '[:upper:]' '[:lower:]')"
  REGION="$(echo "$host" | sed 's/.*emrnotebooks-prod\.\([^.]*\)\.amazonaws.*/\1/')"
  NOTEBOOK_NAME="$(basename "$path")"

  [[ -n "$EDITOR_ID" ]]    || die "Could not parse editor ID from URL"
  [[ -n "$REGION" ]]       || die "Could not parse region from URL"
  [[ -n "$NOTEBOOK_NAME" ]] || die "Could not parse notebook name from URL"
}

# ── S3 bucket discovery ─────────────────────────────────────────────────────

ensure_cache_file() {
  mkdir -p "$CACHE_DIR"
  [[ -f "$CACHE_FILE" ]] || echo '{}' > "$CACHE_FILE"
}

lookup_cached_bucket() {
  ensure_cache_file
  # Cache stores "bucket|prefix" keyed by editor ID (uppercase)
  jq -r --arg eid "$EDITOR_ID" '.[$eid] // empty' "$CACHE_FILE"
}

cache_bucket() {
  local value="$1"  # "bucket|prefix"
  ensure_cache_file
  local tmp="$CACHE_FILE.tmp"
  jq --arg eid "$EDITOR_ID" --arg v "$value" '.[$eid] = $v' "$CACHE_FILE" > "$tmp" \
    && mv "$tmp" "$CACHE_FILE"
}

s3_prefix_exists() {
  # Fast check: list-objects-v2 with max-items 1 returns immediately
  local bucket="$1" prefix="$2"
  shift 2
  local count
  count="$(aws s3api list-objects-v2 --bucket "$bucket" --prefix "$prefix" --max-items 1 "$@" --query 'length(Contents)' --output text 2>/dev/null)" || return 1
  [[ "$count" != "None" ]] && [[ "$count" -gt 0 ]]
}

discover_s3_bucket() {
  local profile_flag=()
  [[ -n "${AWS_PROFILE_FLAG:-}" ]] && profile_flag=(--profile "$AWS_PROFILE_FLAG")
  local rf=(--region "$REGION")

  # 1. Check cache (stores "bucket|prefix")
  local cached
  cached="$(lookup_cached_bucket)"
  if [[ -n "$cached" ]]; then
    S3_BUCKET="${cached%%|*}"
    S3_PREFIX="${cached#*|}"
    info "Using cached bucket: s3://$S3_BUCKET/$S3_PREFIX/"
    return 0
  fi

  # 2. List all buckets, try EMR-related ones first
  info "Discovering S3 bucket for editor $EDITOR_ID ..."
  local all_buckets
  all_buckets="$(aws s3api list-buckets "${profile_flag[@]}" --query 'Buckets[].Name' --output text | tr '\t' '\n')"
  [[ -n "$all_buckets" ]] || die "No S3 buckets found (check AWS credentials / profile)"

  local emr_buckets other_buckets
  emr_buckets="$(echo "$all_buckets" | grep -iE 'emr|notebook|studio' || true)"
  other_buckets="$(echo "$all_buckets" | grep -ivE 'emr|notebook|studio' || true)"

  # Candidate S3 prefix patterns to probe
  local prefixes=(
    "emr-studio/${EDITOR_ID}"
    "emr-studio/${EDITOR_ID_LOWER}"
    "${EDITOR_ID}"
    "${EDITOR_ID_LOWER}"
  )

  # Probe EMR buckets in parallel batches
  local tmpdir
  tmpdir="$(mktemp -d)"
  trap "rm -rf '$tmpdir'" RETURN

  _probe_batch() {
    local bucket_list="$1"
    while IFS= read -r bucket; do
      [[ -n "$bucket" ]] || continue
      for pfx in "${prefixes[@]}"; do
        if s3_prefix_exists "$bucket" "${pfx}/" "${profile_flag[@]}" "${rf[@]}"; then
          echo "${bucket}|${pfx}" > "$tmpdir/found"
          return 0
        fi
      done
    done <<< "$bucket_list"
  }

  # Try EMR-related buckets first (run in batches of 10 in parallel)
  local batch="" count=0 max_parallel=10
  while IFS= read -r bucket; do
    [[ -n "$bucket" ]] || continue
    batch="$batch"$'\n'"$bucket"
    count=$((count + 1))
    if [[ $count -ge $max_parallel ]]; then
      _probe_batch "$batch" &
      batch=""
      count=0
    fi
  done <<< "$emr_buckets"
  [[ -n "$batch" ]] && _probe_batch "$batch" &
  wait

  if [[ -f "$tmpdir/found" ]]; then
    local result
    result="$(cat "$tmpdir/found")"
    S3_BUCKET="${result%%|*}"
    S3_PREFIX="${result#*|}"
    info "Found notebook in bucket: $S3_BUCKET (prefix: $S3_PREFIX)"
    cache_bucket "$result"
    return 0
  fi

  # Fall back to non-EMR buckets (parallel batches)
  info "Not found in EMR buckets, scanning all buckets..."
  batch="" count=0
  while IFS= read -r bucket; do
    [[ -n "$bucket" ]] || continue
    batch="$batch"$'\n'"$bucket"
    count=$((count + 1))
    if [[ $count -ge $max_parallel ]]; then
      _probe_batch "$batch" &
      batch=""
      count=0
    fi
  done <<< "$other_buckets"
  [[ -n "$batch" ]] && _probe_batch "$batch" &
  wait

  if [[ -f "$tmpdir/found" ]]; then
    local result
    result="$(cat "$tmpdir/found")"
    S3_BUCKET="${result%%|*}"
    S3_PREFIX="${result#*|}"
    info "Found notebook in bucket: $S3_BUCKET (prefix: $S3_PREFIX)"
    cache_bucket "$result"
    return 0
  fi

  die "Could not find editor $EDITOR_ID in any S3 bucket. Check your AWS profile/permissions."
}

# ── sidecar metadata ────────────────────────────────────────────────────────

sidecar_dir() { echo "$(dirname "$1")/.emr-sync"; }

sidecar_path() { echo "$(sidecar_dir "$1")/$(basename "$1").json"; }

write_sidecar() {
  local local_path="$1" emr_url="$2" s3_path="$3" profile="$4" region="$5" editor_id="$6"
  local dir
  dir="$(sidecar_dir "$local_path")"
  mkdir -p "$dir"
  cat > "$(sidecar_path "$local_path")" <<ENDJSON
{
  "emr_url": "$emr_url",
  "s3_path": "$s3_path",
  "aws_profile": "$profile",
  "region": "$region",
  "editor_id": "$editor_id"
}
ENDJSON
}

read_sidecar() {
  local local_path="$1"
  local sc
  sc="$(sidecar_path "$local_path")"
  [[ -f "$sc" ]] || die "No sidecar metadata at $sc — was this notebook pulled with emr-nb-sync?"
  S3_PATH="$(jq -r '.s3_path' "$sc")"
  AWS_PROFILE_FLAG="$(jq -r '.aws_profile // empty' "$sc")"
  REGION="$(jq -r '.region' "$sc")"
}

# ── pull / push ──────────────────────────────────────────────────────────────

do_pull_from_url() {
  local url="$1" local_dir="$2" profile="$3"
  parse_emr_url "$url"

  AWS_PROFILE_FLAG="$profile"
  discover_s3_bucket

  local s3_path="s3://${S3_BUCKET}/${S3_PREFIX}/${NOTEBOOK_NAME}"
  local local_path="${local_dir}/${NOTEBOOK_NAME}"

  local profile_flag=()
  [[ -n "$profile" ]] && profile_flag=(--profile "$profile")

  info "Pulling $s3_path → $local_path"
  aws s3 cp "$s3_path" "$local_path" "${profile_flag[@]}" --region "$REGION"

  write_sidecar "$local_path" "$url" "$s3_path" "$profile" "$REGION" "$EDITOR_ID"
  info "Sidecar metadata written to $(sidecar_path "$local_path")"
  echo "$local_path"
}

do_pull_from_local() {
  local local_path="$1" profile_override="$2"
  read_sidecar "$local_path"

  local profile="${profile_override:-$AWS_PROFILE_FLAG}"
  local profile_flag=()
  [[ -n "$profile" ]] && profile_flag=(--profile "$profile")

  info "Pulling $S3_PATH → $local_path"
  aws s3 cp "$S3_PATH" "$local_path" "${profile_flag[@]}" --region "$REGION"
  echo "$local_path"
}

do_push() {
  local local_path="$1" profile_override="$2"
  [[ -f "$local_path" ]] || die "File not found: $local_path"
  read_sidecar "$local_path"

  local profile="${profile_override:-$AWS_PROFILE_FLAG}"
  local profile_flag=()
  [[ -n "$profile" ]] && profile_flag=(--profile "$profile")

  info "Pushing $local_path → $S3_PATH"
  aws s3 cp "$local_path" "$S3_PATH" "${profile_flag[@]}" --region "$REGION"
  info "Done."
}

# ── main ─────────────────────────────────────────────────────────────────────

main() {
  [[ $# -ge 2 ]] || usage

  local action="$1"; shift
  local target="$1"; shift

  local profile="" local_dir="$DEFAULT_LOCAL_DIR"

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile) profile="$2"; shift 2 ;;
      --local-dir) local_dir="$2"; shift 2 ;;
      *) die "Unknown option: $1" ;;
    esac
  done

  mkdir -p "$local_dir"

  case "$action" in
    pull)
      if is_emr_url "$target"; then
        do_pull_from_url "$target" "$local_dir" "$profile"
      else
        do_pull_from_local "$target" "$profile"
      fi
      ;;
    push)
      do_push "$target" "$profile"
      ;;
    *)
      die "Unknown action: $action (expected pull or push)"
      ;;
  esac
}

main "$@"
