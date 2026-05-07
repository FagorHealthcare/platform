#!/usr/bin/env bash
# =====================================================================
# bootstrap.sh
#
# Clones every sibling repo of the Fagor Healthcare Medical Dispenser
# platform into place as a peer directory of this meta-repo. Run this
# once on a fresh laptop after cloning FagorHealthcare/platform.
#
# - Idempotent: skips any repo whose directory already exists.
# - Uses HTTPS clone URLs so it works without SSH key configuration.
# - All repos live under github.com/FagorHealthcare/ except
#   pruebas-fmd-manual, which is a personal fork under jorgeuriarte/.
# =====================================================================
set -euo pipefail

# Resolve to the meta-repo root (the directory containing this script),
# so `./bootstrap.sh` works regardless of the caller's CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

# Format: "<owner>/<repo>"
REPOS=(
  "FagorHealthcare/md-core"
  "FagorHealthcare/md-auth"
  "FagorHealthcare/md-resi-back"
  "FagorHealthcare/md-resi-front"
  "FagorHealthcare/md-pwa"
  "FagorHealthcare/md-backup"
  "FagorHealthcare/k8s"
  "FagorHealthcare/do-functions"
  "FagorHealthcare/fhctl"
  "FagorHealthcare/fmd-manual"
  "FagorHealthcare/postman-cinfa"
  "FagorHealthcare/sync-api-spec"
  "FagorHealthcare/md-resi-api-spec"
  "jorgeuriarte/pruebas-fmd-manual"
)

cloned=0
skipped=0

for slug in "${REPOS[@]}"; do
  name="${slug#*/}"
  url="https://github.com/${slug}.git"

  if [[ -d "$name" ]]; then
    printf "  skipped   %-25s (directory already exists)\n" "$name"
    skipped=$((skipped + 1))
    continue
  fi

  printf "  cloning   %-25s from %s\n" "$name" "$url"
  git clone --quiet "$url" "$name"
  cloned=$((cloned + 1))
done

echo
echo "Done. Cloned: $cloned   Skipped: $skipped   Total: ${#REPOS[@]}"
