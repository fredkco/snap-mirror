#!/usr/bin/env bash
set -uo pipefail

# snap-fetch.sh
#
# Build a simple HTTP-served offline snap repository.
#
# Input list format:
#   firefox
#   thunderbird=stable
#   snap-store=latest/stable
#   firefox=7901
#
# If value after '=' is numeric, it is treated as a revision.
# Otherwise, it is treated as a channel.
#
# Output:
#   *.snap
#   *.assert
#   manifest.tsv
#   manifest.json
#   index.html
#   repo-metadata.env
#
# Usage:
#   chmod +x snap-fetch.sh
#   ./snap-fetch.sh snaps.txt
#   ./snap-fetch.sh snaps.txt ./snap-offline

if [[ $# -lt 1 || $# -gt 2 ]]; then
  echo "Usage: $0 <snap-list-file> [output-dir]"
  exit 1
fi

LIST_FILE="$(realpath "$1")"
OUT_DIR="$(realpath -m "${2:-./snap-offline}")"

if [[ ! -f "$LIST_FILE" ]]; then
  echo "ERROR: list file not found: $LIST_FILE"
  exit 1
fi

mkdir -p "$OUT_DIR"

STATE_DIR="$OUT_DIR/.state"
mkdir -p "$STATE_DIR"

DOWNLOADED_DB="$STATE_DIR/downloaded.txt"
QUEUED_DB="$STATE_DIR/queued.txt"
FAILED_DB="$STATE_DIR/failed.txt"
LOG_FILE="$STATE_DIR/run.log"
REQUESTED_DB="$STATE_DIR/requested.txt"
SEEN_DEPS_DB="$STATE_DIR/seen-deps.txt"

touch "$DOWNLOADED_DB" "$QUEUED_DB" "$FAILED_DB" "$LOG_FILE" "$REQUESTED_DB" "$SEEN_DEPS_DB"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

require_cmd snap
require_cmd unsquashfs
require_cmd awk
require_cmd sed
require_cmd find
require_cmd sort
require_cmd tail
require_cmd tee
require_cmd date
require_cmd basename
require_cmd paste
require_cmd cut
require_cmd realpath

log() {
  local msg="$1"
  echo "$msg" | tee -a "$LOG_FILE"
}

normalize_line() {
  local line="$1"
  line="${line%%#*}"
  line="$(printf '%s' "$line" | xargs 2>/dev/null || true)"
  printf '%s\n' "$line"
}

parse_name() {
  local item="$1"
  printf '%s\n' "${item%%=*}"
}

parse_selector_value() {
  local item="$1"
  if [[ "$item" == *"="* ]]; then
    printf '%s\n' "${item#*=}"
  else
    printf '\n'
  fi
}

selector_kind_for_value() {
  local selector_value="$1"
  if [[ -z "$selector_value" ]]; then
    printf 'default\n'
  elif [[ "$selector_value" =~ ^[0-9]+$ ]]; then
    printf 'revision\n'
  else
    printf 'channel\n'
  fi
}

db_has_line() {
  local value="$1"
  local file="$2"
  grep -Fxsq "$value" "$file"
}

db_add_line() {
  local value="$1"
  local file="$2"
  if [[ -n "$value" ]] && ! db_has_line "$value" "$file"; then
    printf '%s\n' "$value" >> "$file"
  fi
}

clear_failed_for_snap() {
  local snap_name="$1"
  local tmp

  [[ -z "$snap_name" ]] && return 0
  [[ -f "$FAILED_DB" ]] || return 0

  tmp="$(mktemp)"
  awk -v s="$snap_name" '
    $0 == s { next }
    index($0, s "=") == 1 { next }
    { print }
  ' "$FAILED_DB" > "$tmp"
  mv -f "$tmp" "$FAILED_DB"
}

prune_failed_db() {
  local tmp
  local line
  local snap_name
  local snap_file

  [[ -f "$FAILED_DB" ]] || return 0

  tmp="$(mktemp)"

  while IFS= read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" ]] && continue
    snap_name="$(parse_name "$line")"
    snap_file="$(find_downloaded_snap_file "$snap_name" || true)"

    if [[ -n "$snap_file" && -f "$snap_file" ]]; then
      continue
    fi

    printf '%s\n' "$line" >> "$tmp"
  done < "$FAILED_DB"

  mv -f "$tmp" "$FAILED_DB"
}

mark_requested() {
  local snap_name="$1"
  db_add_line "$snap_name" "$REQUESTED_DB"
}

is_requested() {
  local snap_name="$1"
  db_has_line "$snap_name" "$REQUESTED_DB"
}

is_pinned_revision_requested() {
  local snap_name="$1"
  local revision="$2"
  local raw_line
  local line
  local requested_name
  local selector_value

  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    line="$(normalize_line "$raw_line")"
    [[ -z "$line" ]] && continue

    requested_name="$(parse_name "$line")"
    [[ "$requested_name" == "$snap_name" ]] || continue

    selector_value="$(parse_selector_value "$line")"
    if [[ "$(selector_kind_for_value "$selector_value")" == "revision" && "$selector_value" == "$revision" ]]; then
      return 0
    fi
  done < "$LIST_FILE"

  return 1
}

is_downloaded() {
  local snap_name="$1"
  db_has_line "$snap_name" "$DOWNLOADED_DB"
}

mark_downloaded() {
  local snap_name="$1"
  db_add_line "$snap_name" "$DOWNLOADED_DB"
}

enqueue() {
  local item="$1"
  if [[ -n "$item" ]]; then
    db_add_line "$item" "$QUEUED_DB"
  fi
}

mark_failed() {
  local item="$1"
  db_add_line "$item" "$FAILED_DB"
}

remove_partial_for_item() {
  local snap_name="$1"
  local selector_kind="$2"
  local selector_value="$3"
  local partial_file

  if [[ "$selector_kind" == "revision" && -n "$selector_value" ]]; then
    partial_file="$OUT_DIR/${snap_name}_${selector_value}.snap.partial"
    if [[ -f "$partial_file" ]]; then
      log "Removing incomplete download file: $(basename "$partial_file")"
      rm -f "$partial_file"
    fi
    return 0
  fi

  find "$OUT_DIR" -maxdepth 1 -type f -name "${snap_name}_*.snap.partial" | while read -r partial_file; do
    [[ -z "$partial_file" ]] && continue
    log "Removing incomplete download file: $(basename "$partial_file")"
    rm -f "$partial_file"
  done
}

cleanup_all_partials() {
  local partial_file
  find "$OUT_DIR" -maxdepth 1 -type f -name '*.snap.partial' | while read -r partial_file; do
    [[ -z "$partial_file" ]] && continue
    log "Removing stale partial file: $(basename "$partial_file")"
    rm -f "$partial_file"
  done
}

enqueue_dependencies_from_local_snap() {
  local snap_name="$1"
  local snap_file="$2"

  [[ -z "$snap_file" || ! -f "$snap_file" ]] && return 0

  log "Rechecking dependencies from local snap: $(basename "$snap_file")"
  if ! discover_dependencies "$snap_name" "$snap_file"; then
    log "WARN: dependency scan failed for cached snap: $snap_name"
  fi
}

track_dep_relation() {
  local parent="$1"
  local dep_kind="$2"
  local dep_name="$3"
  printf '%s\t%s\t%s\n' "$parent" "$dep_kind" "$dep_name" >> "$SEEN_DEPS_DB"
}

find_downloaded_snap_file() {
  local snap_name="$1"
  find "$OUT_DIR" -maxdepth 1 -type f -name "${snap_name}_*.snap" | sort | tail -n 1
}

find_downloaded_assert_file() {
  local snap_name="$1"
  find "$OUT_DIR" -maxdepth 1 -type f -name "${snap_name}_*.assert" | sort | tail -n 1
}

find_downloaded_snap_file_for_selector() {
  local snap_name="$1"
  local selector_kind="$2"
  local selector_value="$3"

  if [[ "$selector_kind" == "revision" && -n "$selector_value" ]]; then
    local exact_file="$OUT_DIR/${snap_name}_${selector_value}.snap"
    if [[ -f "$exact_file" ]]; then
      printf '%s\n' "$exact_file"
      return 0
    fi
    return 1
  fi

  find_downloaded_snap_file "$snap_name"
}

find_downloaded_assert_file_for_selector() {
  local snap_name="$1"
  local selector_kind="$2"
  local selector_value="$3"

  if [[ "$selector_kind" == "revision" && -n "$selector_value" ]]; then
    local exact_file="$OUT_DIR/${snap_name}_${selector_value}.assert"
    if [[ -f "$exact_file" ]]; then
      printf '%s\n' "$exact_file"
      return 0
    fi
    return 1
  fi

  find_downloaded_assert_file "$snap_name"
}

download_snap() {
  local snap_name="$1"
  local selector_kind="$2"
  local selector_value="$3"
  local -a cmd
  local output
  local rc=0

  cmd=(snap download "$snap_name")

  case "$selector_kind" in
    revision)
      cmd+=(--revision="$selector_value")
      log "==> Downloading: name=[$snap_name] revision=[$selector_value]"
      ;;
    channel)
      cmd+=(--channel="$selector_value")
      log "==> Downloading: name=[$snap_name] channel=[$selector_value]"
      ;;
    *)
      log "==> Downloading: name=[$snap_name]"
      ;;
  esac

  output="$(
    (
      cd "$OUT_DIR" &&
      "${cmd[@]}"
    ) 2>&1
  )"
  rc=$?

  if [[ -n "$output" ]]; then
    printf '%s\n' "$output" | tee -a "$LOG_FILE"
  fi

  if [[ "$selector_kind" != "default" && -n "$selector_value" ]]; then
    log "==> download rc=$rc for $snap_name ($selector_kind=$selector_value)"
  else
    log "==> download rc=$rc for $snap_name"
  fi

  if [[ "$rc" -ne 0 && "$selector_kind" != "revision" ]]; then
    if printf '%s\n' "$output" | grep -Eiq '(^|[^a-z])file exists([^a-z]|$)|already exists'; then
      log "==> Existing local revision detected for $snap_name; no newer revision downloaded"
      return 0
    fi
  fi

  return "$rc"
}

extract_metadata() {
  local snap_file="$1"
  unsquashfs -n -cat "$snap_file" meta/snap.yaml 2>>"$LOG_FILE"
}

yaml_field_simple() {
  local metadata="$1"
  local field="$2"
  printf '%s\n' "$metadata" | awk -F': *' -v key="$field" '$1 == key {print $2; exit}'
}

discover_dependencies() {
  local parent_snap="$1"
  local snap_file="$2"
  local metadata
  local base_snap
  local confinement_snap
  local providers

  metadata="$(extract_metadata "$snap_file" || true)"

  if [[ -z "$metadata" ]]; then
    log "WARN: Could not read metadata from $snap_file"
    return 1
  fi

  confinement_snap="$(
    printf '%s\n' "$metadata" \
      | awk '/^[[:space:]]*confinement:[[:space:]]*/ {print $2; exit}'
  )"
  if [[ -n "${confinement_snap:-}" ]]; then
    log "    Confinement: $confinement_snap"
  fi

  base_snap="$(
    printf '%s\n' "$metadata" \
      | awk '/^[[:space:]]*base:[[:space:]]*/ {print $2; exit}'
  )"

  if [[ -n "${base_snap:-}" && "$base_snap" != "none" ]]; then
    log "    Found base dependency: $base_snap"
    enqueue "$base_snap"
    track_dep_relation "$parent_snap" "base" "$base_snap"
  fi

  providers="$(
    printf '%s\n' "$metadata" \
      | awk '/default-provider:[[:space:]]*/ {print $2}' \
      | sed 's/"//g' \
      | sed "s/'//g" \
      | cut -d: -f1 \
      | sort -u
  )"

  if [[ -n "${providers:-}" ]]; then
    while IFS= read -r provider; do
      [[ -z "$provider" ]] && continue
      log "    Found default-provider dependency: $provider"
      enqueue "$provider"
      track_dep_relation "$parent_snap" "default-provider" "$provider"
    done <<< "$providers"
  fi

  return 0
}

seed_queue_from_list() {
  while IFS= read -r raw_line || [[ -n "$raw_line" ]]; do
    local line
    local name
    line="$(normalize_line "$raw_line")"
    [[ -z "$line" ]] && continue
    enqueue "$line"
    name="$(parse_name "$line")"
    mark_requested "$name"
  done < "$LIST_FILE"
}

process_queue() {
  local pass=0
  local current_queue
  local did_work
  local item
  local snap_name
  local selector_value
  local selector_kind
  local snap_file
  local assert_file

  while true; do
    pass=$((pass + 1))
    did_work=0

    log ""
    log "===== PASS $pass ====="

    current_queue="$(mktemp)"
    cp "$QUEUED_DB" "$current_queue"
    : > "$QUEUED_DB"

    while IFS= read -r item || [[ -n "$item" ]]; do
      [[ -z "$item" ]] && continue

      snap_name="$(parse_name "$item")"
      selector_value="$(parse_selector_value "$item")"
      selector_kind="$(selector_kind_for_value "$selector_value")"

      if [[ "$selector_kind" == "revision" ]]; then
        snap_file="$(find_downloaded_snap_file_for_selector "$snap_name" "$selector_kind" "$selector_value" || true)"
        if [[ -n "$snap_file" && -f "$snap_file" ]]; then
          log "Skipping already downloaded: $snap_name (revision $selector_value)"
          enqueue_dependencies_from_local_snap "$snap_name" "$snap_file"
          clear_failed_for_snap "$snap_name"
          continue
        fi
      else
        if [[ "$selector_kind" == "channel" && -n "$selector_value" ]]; then
          log "Checking for updates: $snap_name (channel $selector_value)"
        else
          log "Checking for updates: $snap_name"
        fi
      fi

      did_work=1

      remove_partial_for_item "$snap_name" "$selector_kind" "$selector_value"

      if ! download_snap "$snap_name" "$selector_kind" "$selector_value"; then
        log "WARN: download failed: $item"
        mark_failed "$item"
        continue
      fi

      snap_file="$(find_downloaded_snap_file_for_selector "$snap_name" "$selector_kind" "$selector_value" || true)"
      assert_file="$(find_downloaded_assert_file_for_selector "$snap_name" "$selector_kind" "$selector_value" || true)"

      if [[ -z "$snap_file" ]]; then
        log "WARN: no .snap file found after download: $item"
        mark_failed "$item"
        continue
      fi

      if [[ -z "$assert_file" ]]; then
        log "WARN: no .assert file found after download: $item"
      fi

      if ! discover_dependencies "$snap_name" "$snap_file"; then
        log "WARN: dependency scan failed: $item"
      fi

      mark_downloaded "$snap_name"
      clear_failed_for_snap "$snap_name"
      log "OK: downloaded $snap_name"
    done < "$current_queue"

    rm -f "$current_queue"

    if [[ "$did_work" -eq 0 && ! -s "$QUEUED_DB" ]]; then
      break
    fi
  done
}

providers_for() {
  local parent="$1"
  awk -F'\t' -v p="$parent" '$1==p && $2=="default-provider" {print $3}' "$SEEN_DEPS_DB" | paste -sd',' -
}

generate_manifest_tsv() {
  local manifest="$OUT_DIR/manifest.tsv"
  local snap_file
  local assert_file
  local assert_file_path
  local metadata
  local snap_name
  local version
  local base
  local confinement
  local revision
  local providers
  local requested
  local dep_kind

  {
    printf 'snap_name\tversion\trevision\tbase\tdefault_providers\trequested\trelation\tsnap_file\tassert_file\tconfinement\n'

    find "$OUT_DIR" -maxdepth 1 -type f -name '*.snap' | sort | while read -r snap_file; do
      metadata="$(extract_metadata "$snap_file" || true)"
      snap_name="$(yaml_field_simple "$metadata" "name" || true)"
      version="$(yaml_field_simple "$metadata" "version" || true)"
      base="$(yaml_field_simple "$metadata" "base" || true)"
      confinement="$(yaml_field_simple "$metadata" "confinement" || true)"

      if [[ -z "$snap_name" ]]; then
        snap_name="$(basename "$snap_file" .snap)"
        snap_name="${snap_name%_*}"
      fi

      [[ -z "$version" ]] && version="unknown"
      [[ -z "$base" ]] && base="-"
      [[ -z "$confinement" ]] && confinement="unknown"

      revision="$(basename "$snap_file" .snap)"
      revision="${revision##*_}"

      assert_file_path="$OUT_DIR/${snap_name}_${revision}.assert"
      if [[ -f "$assert_file_path" ]]; then
        assert_file="$(basename "$assert_file_path")"
      else
        assert_file="-"
      fi

      providers="$(providers_for "$snap_name")"
      [[ -z "$providers" ]] && providers="-"

      if is_requested "$snap_name"; then
        requested="yes"
        dep_kind="requested"
      else
        requested="no"
        dep_kind="dependency"
      fi

      printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$snap_name" \
        "$version" \
        "${revision:-unknown}" \
        "$base" \
        "$providers" \
        "$requested" \
        "$dep_kind" \
        "$(basename "$snap_file")" \
        "$assert_file" \
        "$confinement"
    done
  } > "$manifest"
}

generate_manifest_json() {
  local json="$OUT_DIR/manifest.json"
  local snap_file
  local assert_file
  local assert_file_path
  local metadata
  local snap_name
  local version
  local base
  local confinement
  local revision
  local providers
  local requested
  local first=1

  {
    echo "["
    find "$OUT_DIR" -maxdepth 1 -type f -name '*.snap' | sort | while read -r snap_file; do
      metadata="$(extract_metadata "$snap_file" || true)"
      snap_name="$(yaml_field_simple "$metadata" "name" || true)"
      version="$(yaml_field_simple "$metadata" "version" || true)"
      base="$(yaml_field_simple "$metadata" "base" || true)"
      confinement="$(yaml_field_simple "$metadata" "confinement" || true)"

      if [[ -z "$snap_name" ]]; then
        snap_name="$(basename "$snap_file" .snap)"
        snap_name="${snap_name%_*}"
      fi

      [[ -z "$version" ]] && version="unknown"
      [[ -z "$base" ]] && base="-"
      [[ -z "$confinement" ]] && confinement="unknown"

      revision="$(basename "$snap_file" .snap)"
      revision="${revision##*_}"

      assert_file_path="$OUT_DIR/${snap_name}_${revision}.assert"
      if [[ -f "$assert_file_path" ]]; then
        assert_file="$(basename "$assert_file_path")"
      else
        assert_file="-"
      fi

      providers="$(providers_for "$snap_name")"
      [[ -z "$providers" ]] && providers="-"

      if is_requested "$snap_name"; then
        requested="true"
      else
        requested="false"
      fi

      if [[ $first -eq 0 ]]; then
        echo ","
      fi
      first=0

      printf '  {"name":"%s","version":"%s","revision":"%s","base":"%s","confinement":"%s","default_providers":"%s","requested":%s,"snap_file":"%s","assert_file":"%s"}' \
        "$snap_name" \
        "$version" \
        "${revision:-unknown}" \
        "$base" \
        "$confinement" \
        "$providers" \
        "$requested" \
        "$(basename "$snap_file")" \
        "$assert_file"
    done
    echo
    echo "]"
  } > "$json"
}

generate_repo_metadata_env() {
  local f="$OUT_DIR/repo-metadata.env"
  cat > "$f" <<EOF
REPO_GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
REPO_FORMAT_VERSION="1"
MANIFEST_FILE="manifest.tsv"
MANIFEST_JSON_FILE="manifest.json"
INDEX_FILE="index.html"
EOF
}

generate_snap_offline_client() {
  local f="$OUT_DIR/snap-offline.sh"

  cat > "$f" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail

SNAP_REPO_URL="${SNAP_REPO_URL:-http://your-server/snaps}"
SNAP_CACHE_DIR="${SNAP_CACHE_DIR:-/var/tmp/snap-offline}"
SNAP_WGET_NO_CHECK_CERTIFICATE="${SNAP_WGET_NO_CHECK_CERTIFICATE:-1}"
MANIFEST_URL="${SNAP_REPO_URL%/}/manifest.tsv"
MANIFEST_FILE="$SNAP_CACHE_DIR/manifest.tsv"
FORCE_STOP_RUNNING=0

mkdir -p "$SNAP_CACHE_DIR"

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command not found: $cmd"
    exit 1
  fi
}

log() {
  echo "[snap-offline] $*"
}

download_url() {
  local url="$1"
  local out="$2"
  local tmp_out
  local wget_args=()
  log "Downloading $url"
  tmp_out="${out}.tmp.$$"

  if [[ "$SNAP_WGET_NO_CHECK_CERTIFICATE" == "1" ]]; then
    wget_args+=(--no-check-certificate)
  fi

  if ! wget -q "${wget_args[@]}" -O "$tmp_out" "$url"; then
    rm -f "$tmp_out"
    echo "ERROR: download failed: $url"
    return 1
  fi

  if [[ ! -s "$tmp_out" ]]; then
    rm -f "$tmp_out"
    echo "ERROR: downloaded file is empty: $url"
    return 1
  fi

  mv -f "$tmp_out" "$out"
}

download_manifest() {
  log "Downloading manifest..."
  download_url "$MANIFEST_URL" "$MANIFEST_FILE"

  if [[ ! -s "$MANIFEST_FILE" ]]; then
    echo "ERROR: manifest is missing or empty: $MANIFEST_FILE"
    exit 1
  fi

  log "Validating manifest consistency..."
  if ! validate_manifest; then
    echo "ERROR: manifest validation failed: $MANIFEST_FILE"
    exit 1
  fi
}

validate_manifest() {
  local expected_header
  expected_header=$'snap_name\tversion\trevision\tbase\tdefault_providers\trequested\trelation\tsnap_file\tassert_file\tconfinement'

  awk -F'\t' -v expected_header="$expected_header" '
    function fail(msg) {
      print "ERROR: " msg > "/dev/stderr"
      ok = 0
    }

    BEGIN {
      ok = 1
      rows = 0
    }

    NR == 1 {
      if ($0 != expected_header) {
        fail("manifest header mismatch")
      }
      next
    }

    {
      rows++

      if (NF < 10) {
        fail("manifest row " NR " has " NF " fields, expected 10")
        next
      }

      name = $1
      revision = $3
      requested = $6
      relation = $7
      snap_file = $8
      assert_file = $9
      confinement = $10

      if (name == "") {
        fail("manifest row " NR " has empty snap_name")
      }

      if (revision !~ /^[0-9]+$/) {
        fail("invalid revision for " name " in row " NR ": " revision)
      }

      key = name SUBSEP revision
      if (key in seen_revision) {
        fail("duplicate snap_name/revision \"" name "\" revision " revision " in rows " seen_revision[key] " and " NR)
      } else {
        seen_revision[key] = NR
      }

      if (requested != "yes" && requested != "no") {
        fail("invalid requested value for " name " in row " NR ": " requested)
      }

      if (relation != "requested" && relation != "dependency") {
        fail("invalid relation value for " name " in row " NR ": " relation)
      }

      if (requested == "yes" && relation != "requested") {
        fail("requested/relation mismatch for " name " in row " NR)
      }

      if (requested == "no" && relation != "dependency") {
        fail("requested/relation mismatch for " name " in row " NR)
      }

      expected_snap = name "_" revision ".snap"
      if (snap_file != expected_snap) {
        fail("snap_file mismatch for " name " in row " NR ": expected " expected_snap ", got " snap_file)
      }

      expected_assert = name "_" revision ".assert"
      if (assert_file != expected_assert) {
        fail("assert_file mismatch for " name " in row " NR ": expected " expected_assert ", got " assert_file)
      }

      if (confinement != "strict" && confinement != "classic" && confinement != "devmode" && confinement != "unknown") {
        fail("invalid confinement for " name " in row " NR ": " confinement)
      }
    }

    END {
      if (NR < 1) {
        fail("manifest is empty")
      }

      if (ok == 1) {
        print "[snap-offline] Manifest OK (" rows " snaps)"
      }

      exit(ok ? 0 : 1)
    }
  ' "$MANIFEST_FILE"
}

get_field() {
  local name="$1"
  local idx="$2"
  awk -F'\t' -v n="$name" -v i="$idx" '
    NR > 1 && $1 == n {
      rev = $3 + 0
      if (!found || rev > best_rev) {
        found = 1
        best_rev = rev
        value = $i
      }
    }
    END {
      if (found) {
        print value
      }
    }
  ' "$MANIFEST_FILE"
}

download_file() {
  local file="$1"
  download_url "${SNAP_REPO_URL%/}/$file" "$SNAP_CACHE_DIR/$file"
}

force_stop_running_apps() {
  local snap_name="$1"
  local pattern="/snap/${snap_name}/"

  if ! pgrep -f "$pattern" >/dev/null 2>&1; then
    return 0
  fi

  log "Force-stopping running apps for $snap_name"
  sudo pkill -TERM -f "$pattern" || true
  sleep 2

  if pgrep -f "$pattern" >/dev/null 2>&1; then
    log "Processes still running for $snap_name after SIGTERM, sending SIGKILL"
    sudo pkill -KILL -f "$pattern" || true
    sleep 1
  fi

  if pgrep -f "$pattern" >/dev/null 2>&1; then
    log "WARN: processes still running for $snap_name after SIGKILL"
    return 1
  fi

  return 0
}

snap_install_from_file() {
  local snap_path="$1"
  local confinement="$2"

  case "$confinement" in
    classic)
      sudo snap install "$snap_path" --classic
      ;;
    devmode)
      sudo snap install "$snap_path" --devmode
      ;;
    *)
      sudo snap install "$snap_path"
      ;;
  esac
}

install_local_snap_file() {
  local name="$1"
  local snap_file="$2"
  local action="$3"
  local confinement="${4:-strict}"
  local install_mode="$confinement"
  local install_output=""

  if [[ -z "$install_mode" || "$install_mode" == "-" || "$install_mode" == "unknown" ]]; then
    install_mode="strict"
  fi

  if [[ "$action" == "update" ]]; then
    log "Updating $name using local snap file"
  else
    log "Installing $name using local snap file"
  fi

  if [[ "$install_mode" == "classic" ]]; then
    log "Using --classic for $name"
  elif [[ "$install_mode" == "devmode" ]]; then
    log "Using --devmode for $name"
  fi

  if install_output="$(snap_install_from_file "$SNAP_CACHE_DIR/$snap_file" "$install_mode" 2>&1)"; then
    [[ -n "$install_output" ]] && printf '%s\n' "$install_output"
    return 0
  fi

  if [[ "$FORCE_STOP_RUNNING" -ne 1 ]]; then
    [[ -n "$install_output" ]] && printf '%s\n' "$install_output" >&2
    log "ERROR: failed to $action $name using $snap_file"
    return 1
  fi

  if ! printf '%s\n' "$install_output" | grep -Fq "has running apps"; then
    [[ -n "$install_output" ]] && printf '%s\n' "$install_output" >&2
    log "ERROR: failed to $action $name using $snap_file"
    return 1
  fi

  log "INFO: $name has running apps; trying with --force-stop-running"
  force_stop_running_apps "$name" || true

  if install_output="$(snap_install_from_file "$SNAP_CACHE_DIR/$snap_file" "$install_mode" 2>&1)"; then
    [[ -n "$install_output" ]] && printf '%s\n' "$install_output"
    log "Retry succeeded for $name after stopping running apps"
    return 0
  fi

  [[ -n "$install_output" ]] && printf '%s\n' "$install_output" >&2
  log "ERROR: failed to $action $name using $snap_file"
  return 1
}

install_snap() {
  local name="$1"
  local base providers snap_file assert_file confinement p

  base="$(get_field "$name" 4)"
  providers="$(get_field "$name" 5)"
  snap_file="$(get_field "$name" 8)"
  assert_file="$(get_field "$name" 9)"
  confinement="$(get_field "$name" 10)"

  if [[ -z "$snap_file" || "$snap_file" == "-" ]]; then
    echo "ERROR: package not found in manifest: $name"
    return 1
  fi

  if [[ -n "$base" && "$base" != "-" ]]; then
    if ! snap list "$base" >/dev/null 2>&1; then
      log "Installing base for $name: $base"
      if ! install_snap "$base"; then
        log "ERROR: failed to install base $base required by $name"
        return 1
      fi
    fi
  fi

  if [[ -n "$providers" && "$providers" != "-" ]]; then
    IFS=',' read -ra arr <<< "$providers"
    for p in "${arr[@]}"; do
      [[ -z "$p" ]] && continue
      if ! snap list "$p" >/dev/null 2>&1; then
        log "Installing provider for $name: $p"
        if ! install_snap "$p"; then
          log "ERROR: failed to install provider $p required by $name"
          return 1
        fi
      fi
    done
  fi

  if ! download_file "$snap_file"; then
    log "ERROR: could not download snap for $name: $snap_file"
    return 1
  fi

  if [[ -z "$assert_file" || "$assert_file" == "-" ]]; then
    log "ERROR: missing assertion file for $name (required for signed local install)"
    return 1
  fi

  if ! download_file "$assert_file"; then
    log "ERROR: could not download assertion for $name: $assert_file"
    return 1
  fi

  log "Acknowledging $assert_file"
  if ! sudo snap ack "$SNAP_CACHE_DIR/$assert_file"; then
    log "ERROR: failed to acknowledge assertion for $name: $assert_file"
    return 1
  fi

  if snap list "$name" >/dev/null 2>&1; then
    if ! install_local_snap_file "$name" "$snap_file" "update" "$confinement"; then
      return 1
    fi
  else
    if ! install_local_snap_file "$name" "$snap_file" "install" "$confinement"; then
      return 1
    fi
  fi
}

update_all() {
  local s server_rev local_rev had_failures=0

  while read -r s; do
    [[ -z "$s" ]] && continue

    server_rev="$(get_field "$s" 3)"
    local_rev="$(snap list "$s" 2>/dev/null | awk 'NR==2 {print $3}')"

    if [[ -z "$server_rev" ]]; then
      log "Skipping $s: not present in manifest"
      continue
    fi

    if [[ "$server_rev" == "$local_rev" ]]; then
      log "Up to date: $s (rev $local_rev)"
      continue
    fi

    log "Updating $s: local rev=${local_rev:-none}, server rev=$server_rev"
    if ! install_snap "$s"; then
      log "ERROR: failed to update $s"
      had_failures=1
    fi
  done < <(snap list | awk 'NR>1 {print $1}')

  return "$had_failures"
}

list_available() {
  echo "Available snaps from manifest:"
  awk -F'\t' '
    BEGIN {
      n = 7
      headers[1] = "NAME"
      headers[2] = "REVISION"
      headers[3] = "VERSION"
      headers[4] = "REQUESTED"
      headers[5] = "RELATION"
      headers[6] = "CONFINEMENT"
      headers[7] = "SNAP_FILE"
      for (i = 1; i <= n; i++) {
        w[i] = length(headers[i])
      }
    }
    NR > 1 {
      row++
      vals[row,1] = $1
      vals[row,2] = $3
      vals[row,3] = $2
      vals[row,4] = $6
      vals[row,5] = $7
      vals[row,6] = $10
      vals[row,7] = $8

      for (i = 1; i <= n; i++) {
        if (length(vals[row,i]) > w[i]) {
          w[i] = length(vals[row,i])
        }
      }
    }
    END {
      for (i = 1; i <= n; i++) {
        fmt = (i == n) ? "%-" w[i] "s\n" : "%-" w[i] "s  "
        printf fmt, headers[i]
      }

      for (r = 1; r <= row; r++) {
        for (i = 1; i <= n; i++) {
          fmt = (i == n) ? "%-" w[i] "s\n" : "%-" w[i] "s  "
          printf fmt, vals[r,i]
        }
      }
    }
  ' "$MANIFEST_FILE"
}

require_cmd wget
require_cmd awk
require_cmd grep
require_cmd snap
require_cmd sudo
require_cmd pgrep
require_cmd pkill

COMMAND=""
COMMAND_SET=0
COMMAND_ARGS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-stop-running)
      FORCE_STOP_RUNNING=1
      ;;
    install|update|list)
      if [[ "$COMMAND_SET" -eq 0 ]]; then
        COMMAND="$1"
        COMMAND_SET=1
      else
        COMMAND_ARGS+=("$1")
      fi
      ;;
    --install|--update|--list)
      if [[ "$COMMAND_SET" -eq 0 ]]; then
        COMMAND="${1#--}"
        COMMAND_SET=1
      else
        echo "ERROR: command already specified: $1"
        echo "Usage: $0 [--force-stop-running] install|--install <snap...> | update|--update | list|--list"
        exit 1
      fi
      ;;
    -*)
      echo "ERROR: unknown option: $1"
      echo "Usage: $0 [--force-stop-running] install|--install <snap...> | update|--update | list|--list"
      exit 1
      ;;
    *)
      if [[ "$COMMAND_SET" -eq 0 ]]; then
        echo "ERROR: missing command before argument: $1"
        echo "Usage: $0 [--force-stop-running] install|--install <snap...> | update|--update | list|--list"
        exit 1
      fi
      COMMAND_ARGS+=("$1")
      ;;
  esac
  shift
done

if [[ "$FORCE_STOP_RUNNING" -eq 1 ]]; then
  log "Option enabled: --force-stop-running"
fi

case "$COMMAND" in
  install)
    if [[ "${#COMMAND_ARGS[@]}" -lt 1 ]]; then
      echo "Usage: $0 [--force-stop-running] install|--install <snap...>"
      exit 1
    fi
    download_manifest
    for s in "${COMMAND_ARGS[@]}"; do
      install_snap "$s"
    done
    ;;
  update)
    if [[ "${#COMMAND_ARGS[@]}" -gt 0 ]]; then
      echo "Usage: $0 [--force-stop-running] update|--update"
      exit 1
    fi
    download_manifest
    if ! update_all; then
      echo "ERROR: one or more snaps failed to update"
      exit 1
    fi
    ;;
  list)
    if [[ "${#COMMAND_ARGS[@]}" -gt 0 ]]; then
      echo "Usage: $0 list|--list"
      exit 1
    fi
    download_manifest
    list_available
    ;;
  *)
    echo "Usage: $0 [--force-stop-running] install|--install <snap...> | update|--update | list|--list"
    exit 1
    ;;
esac
EOF

  chmod +x "$f"
}

format_run_date_human() {
  local day
  local month
  local year
  local suffix

  day="$(date +%d)"
  day="$((10#$day))"
  month="$(LC_ALL=C date +%B | tr '[:upper:]' '[:lower:]')"
  year="$(date +%Y)"

  case "$day" in
    11|12|13) suffix="th" ;;
    *)
      case $((day % 10)) in
        1) suffix="st" ;;
        2) suffix="nd" ;;
        3) suffix="rd" ;;
        *) suffix="th" ;;
      esac
      ;;
  esac

  printf '%s %d%s %s\n' "$month" "$day" "$suffix" "$year"
}

generate_index_html() {
  local html="$OUT_DIR/index.html"
  local manifest="$OUT_DIR/manifest.tsv"
  local run_date_human

  run_date_human="$(format_run_date_human)"

  {
    echo '<!DOCTYPE html>'
    echo '<html lang="en">'
    echo '<head>'
    echo '  <meta charset="utf-8">'
    echo '  <meta name="viewport" content="width=device-width, initial-scale=1">'
    echo '  <title>Offline Snap Repository</title>'
    echo '  <style>'
    echo '    body { font-family: Arial, sans-serif; margin: 2rem; }'
    echo '    table { border-collapse: collapse; width: 100%; }'
    echo '    th, td { border: 1px solid #ccc; padding: 0.45rem; text-align: left; vertical-align: top; }'
    echo '    th { background: #f2f2f2; }'
    echo '    code, pre { background: #f7f7f7; padding: 0.2rem 0.4rem; }'
    echo '  </style>'
    echo '</head>'
    echo '<body>'
    echo '  <h1>Offline Snap Repository</h1>'
    echo '  <p>This repository contains Snap packages for offline installation.</p>'
    printf '  <p>Generated by snap-fetch.sh on %s</p>\n' "$run_date_human"
	echo '  <p>'
	echo '    <a href="manifest.tsv">manifest.tsv</a> |'
	echo '    <a href="manifest.json">manifest.json</a> |'
	echo '    <a id="download-configured-client" href="snap-offline.sh" download="snap-offline.sh">snap-offline.sh</a> |'
	echo '    <a href="repo-metadata.env">repo-metadata.env</a>'
	echo '  </p>'
    echo '  <table>'
    echo '    <thead>'
    echo '      <tr><th>Name</th><th>Version</th><th>Revision</th><th>Base</th><th>Default providers</th><th>Requested</th><th>Confinement</th><th>.snap</th><th>.assert</th></tr>'
    echo '    </thead>'
    echo '    <tbody>'

    tail -n +2 "$manifest" | while IFS=$'\t' read -r name version revision base providers requested relation snap_file assert_file confinement; do
      printf '      <tr><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td><a href="%s">%s</a></td><td><a href="%s">%s</a></td></tr>\n' \
        "$name" "$version" "$revision" "$base" "$providers" "$requested" "$confinement" "$snap_file" "$snap_file" "$assert_file" "$assert_file"
    done

    echo '    </tbody>'
    echo '  </table>'
	echo '  <h2>Installation</h2>'

	echo '  <h3>Option 1: Manual install</h3>'
	echo '  <pre>'
echo 'sudo snap ack package.assert'
echo 'sudo snap install package.snap'
echo '# add --classic when confinement is classic'
echo '  </pre>'

	echo '  <h3>Option 2: Using snap-offline.sh (HTTP repository)</h3>'
	echo '  <p>Download the client script and run:</p>'
	echo '  <pre>'
	echo 'wget http://your-server/snaps/snap-offline.sh'
	echo 'chmod +x snap-offline.sh'
	echo 'export SNAP_REPO_URL=http://your-server/snaps'
	echo './snap-offline.sh --install firefox'
	echo './snap-offline.sh --update'
	echo './snap-offline.sh --list'
	echo './snap-offline.sh --force-stop-running --update'
	echo './snap-offline.sh --force-stop-running --install firefox'
	echo '  </pre>'
	echo '  <p>Download <code>snap-offline.sh</code> from the link at the top of this page.'
	echo '  The browser download is preconfigured for this repository URL.</p>'
	echo '  <p>If you use wget/curl directly, keep setting <code>SNAP_REPO_URL</code> manually.</p>'
	echo '  <p>Use <code>--force-stop-running</code> when updating snaps that may currently be running.</p>'
	echo '  <script>'
	echo '    (function () {'
	echo '      var link = document.getElementById("download-configured-client");'
	echo '      if (!link || !window.fetch || !window.Blob || !window.URL) { return; }'
	echo '      link.addEventListener("click", async function (event) {'
	echo '        event.preventDefault();'
	echo '        var scriptUrl = new URL("snap-offline.sh", window.location.href);'
	echo '        var repoUrl = new URL(".", scriptUrl).href.replace(/\/$/, "");'
	echo '        try {'
	echo '          var response = await fetch(scriptUrl.toString(), { cache: "no-store" });'
	echo '          if (!response.ok) { throw new Error("HTTP " + response.status); }'
	echo '          var content = await response.text();'
	echo '          var replacement = "SNAP_REPO_URL=\"${SNAP_REPO_URL:-" + repoUrl + "}\"";'
	echo '          content = content.replace("SNAP_REPO_URL=\"${SNAP_REPO_URL:-http://your-server/snaps}\"", replacement);'
	echo '          var blob = new Blob([content], { type: "text/x-shellscript;charset=utf-8" });'
	echo '          var objectUrl = URL.createObjectURL(blob);'
	echo '          var downloader = document.createElement("a");'
	echo '          downloader.href = objectUrl;'
	echo '          downloader.download = "snap-offline.sh";'
	echo '          document.body.appendChild(downloader);'
	echo '          downloader.click();'
	echo '          document.body.removeChild(downloader);'
	echo '          setTimeout(function () { URL.revokeObjectURL(objectUrl); }, 0);'
	echo '        } catch (err) {'
	echo '          console.error("Failed to build configured client:", err);'
	echo '          window.location.href = "snap-offline.sh";'
	echo '        }'
	echo '      });'
	echo '    })();'
	echo '  </script>'
    echo '</body>'
    echo '</html>'
  } > "$html"
}

cleanup_old_revisions() {
  local keep_count=3
  local snap_name
  local revision_list
  local unpinned_revisions
  local old_revisions
  local rev

  log "Cleaning old revisions: keep latest $keep_count unpinned revisions per snap plus pinned revisions"

  find "$OUT_DIR" -maxdepth 1 -type f -name '*.snap' | while read -r snap_file; do
    snap_name="$(basename "$snap_file" .snap)"
    snap_name="${snap_name%_*}"
    printf '%s\n' "$snap_name"
  done | sort -u | while read -r snap_name; do
    [[ -z "$snap_name" ]] && continue

    revision_list="$(
      find "$OUT_DIR" -maxdepth 1 -type f -name "${snap_name}_*.snap" \
        | sed 's#.*/##' \
        | sed 's/\.snap$//' \
        | awk -F'_' '{print $NF "\t" $0}' \
        | sort -k1,1V \
        | awk '{print $1}'
    )"

    unpinned_revisions="$(
      while IFS= read -r rev; do
        [[ -z "$rev" ]] && continue
        if ! is_pinned_revision_requested "$snap_name" "$rev"; then
          printf '%s\n' "$rev"
        fi
      done <<< "$revision_list"
    )"

    old_revisions="$(
      printf '%s\n' "$unpinned_revisions" | head -n -"$keep_count" 2>/dev/null || true
    )"

    if [[ -n "$old_revisions" ]]; then
      while IFS= read -r rev; do
        [[ -z "$rev" ]] && continue

        if is_pinned_revision_requested "$snap_name" "$rev"; then
          log "Keeping pinned revision: ${snap_name}_${rev}"
          continue
        fi

        find "$OUT_DIR" -maxdepth 1 -type f \
          \( -name "${snap_name}_${rev}.snap" -o -name "${snap_name}_${rev}.assert" \) \
          | while read -r old_file; do
              log "Removing old revision file: $(basename "$old_file")"
              rm -f "$old_file"
            done
      done <<< "$old_revisions"
    fi
  done
}

print_summary() {
  prune_failed_db

  echo
  echo "Done."
  echo

  if [[ -s "$DOWNLOADED_DB" ]]; then
    echo "Downloaded snaps:"
    sort -u "$DOWNLOADED_DB"
    echo
  fi

  if [[ -s "$FAILED_DB" ]]; then
    echo "Failed snaps:"
    sort -u "$FAILED_DB"
    echo
  fi

  echo "Output directory: $OUT_DIR"
  echo "Generated files:"
  echo "  $OUT_DIR/manifest.tsv"
  echo "  $OUT_DIR/manifest.json"
  echo "  $OUT_DIR/index.html"
  echo "  $OUT_DIR/snap-offline.sh"
  echo "  $OUT_DIR/repo-metadata.env"
  echo "Log file:"
  echo "  $LOG_FILE"
  echo
  echo "Files currently in output directory:"
  ls -lh "$OUT_DIR"
}

log "Starting snap-fetch"
log "List file: $LIST_FILE"
log "Output directory: $OUT_DIR"

log "Cleaning stale partial downloads"
cleanup_all_partials

seed_queue_from_list
process_queue

log "Cleaning repository"
cleanup_old_revisions

if [[ -f "$OUT_DIR/install-offline.sh" ]]; then
  log "Removing deprecated file: install-offline.sh"
  rm -f "$OUT_DIR/install-offline.sh"
fi

log "Generating manifest.tsv"
generate_manifest_tsv || log "WARN: manifest.tsv generation failed"

log "Generating manifest.json"
generate_manifest_json || log "WARN: manifest.json generation failed"

log "Generating repo-metadata.env"
generate_repo_metadata_env || log "WARN: repo metadata generation failed"

log "Generating snap-offline.sh"
generate_snap_offline_client || log "WARN: snap-offline script generation failed"

log "Generating index.html"
generate_index_html || log "WARN: index.html generation failed"

print_summary
