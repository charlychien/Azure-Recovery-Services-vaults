#!/usr/bin/env bash
set -euo pipefail

# Backup and bulk update Azure Recovery Services Vault backup policies in one resource group.
#
# Flow:
# 1) Enumerate all vaults in the specified RG
# 2) Backup all current backup policies per vault to timestamped folder
# 3) Apply one policy JSON (same content) to a target policy name across all vaults
#
# Requirements:
# - Azure CLI logged in: az login
# - jq installed
#
# Usage mode A – pass everything as arguments (see --help)
# Usage mode B – fill in the INLINE DEFAULTS section below and run without arguments

# ============================================================
# INLINE DEFAULTS: fill these in to run without CLI arguments
# ============================================================
SUBSCRIPTION_ID=""                   # e.g. a62c905d-fae1-4a2d-b7f5-64cf276ef95e
RESOURCE_GROUP=""                     # e.g. rg-backup-ts
POLICY_FILE=""                        # e.g. ./policy-update-template.json
POLICY_NAME=""                        # e.g. bp-vm-bronze  (or leave blank to read from policy file .name)
BACKUP_DIR=""                         # e.g. ./rsv-policy-backup  (blank = auto timestamped)
AUTO_APPROVE="false"                  # set to "true" to skip the confirmation prompt
DRY_RUN="false"                       # set to "true" to preview without making changes
# ============================================================

API_VERSION="2023-02-01"

usage() {
  cat <<'EOF'
Usage:
  bulk-backup-and-update-rsv-policy.sh \
    --subscription <subscription-id> \
    --resource-group <resource-group> \
    --policy-file <policy-json-file> \
    [--policy-name <policy-name>] \
    [--backup-dir <backup-output-folder>] \
    [--api-version <api-version>] \
    [--yes] [--dry-run]

Notes:
  - Script always performs backup first, then update.
  - Policy file must be JSON object and include at least: properties
  - If --policy-name is omitted, script reads .name from policy file.
EOF
}

require_cmd() {
  local cmd="$1"
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "[ERROR] Required command not found: $cmd" >&2
    exit 1
  fi
}

trim_cr() {
  local s="$1"
  printf '%s' "${s%$'\r'}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --subscription)
      SUBSCRIPTION_ID="$2"
      shift 2
      ;;
    --resource-group)
      RESOURCE_GROUP="$2"
      shift 2
      ;;
    --policy-file)
      POLICY_FILE="$2"
      shift 2
      ;;
    --policy-name)
      POLICY_NAME="$2"
      shift 2
      ;;
    --backup-dir)
      BACKUP_DIR="$2"
      shift 2
      ;;
    --api-version)
      API_VERSION="$2"
      shift 2
      ;;
    --yes)
      AUTO_APPROVE="true"
      shift
      ;;
    --dry-run)
      DRY_RUN="true"
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "[ERROR] Unknown argument: $1" >&2
      usage
      exit 1
      ;;
  esac
done

require_cmd az
require_cmd jq

if [[ -z "$SUBSCRIPTION_ID" || -z "$RESOURCE_GROUP" || -z "$POLICY_FILE" ]]; then
  echo "[ERROR] Missing required arguments." >&2
  usage
  exit 1
fi

if [[ ! -f "$POLICY_FILE" ]]; then
  echo "[ERROR] Policy file not found: $POLICY_FILE" >&2
  exit 1
fi

if ! jq -e '.properties' "$POLICY_FILE" >/dev/null 2>&1; then
  echo "[ERROR] Policy JSON must include .properties" >&2
  exit 1
fi

if [[ -z "$POLICY_NAME" ]]; then
  POLICY_NAME="$(jq -r '.name // empty' "$POLICY_FILE")"
fi

if [[ -z "$POLICY_NAME" ]]; then
  echo "[ERROR] Cannot determine policy name. Pass --policy-name or set .name in policy JSON." >&2
  exit 1
fi

if [[ -z "$BACKUP_DIR" ]]; then
  BACKUP_DIR="./rsv-policy-backup-$(date +%Y%m%d-%H%M%S)"
fi

echo "[INFO] Using subscription: $SUBSCRIPTION_ID"
echo "[INFO] Using resource group: $RESOURCE_GROUP"
echo "[INFO] Target policy name: $POLICY_NAME"
echo "[INFO] Backup directory: $BACKUP_DIR"
echo "[INFO] API version: $API_VERSION"

az account set --subscription "$SUBSCRIPTION_ID"

vault_list_url="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.RecoveryServices/vaults?api-version=${API_VERSION}"

echo "[INFO] Discovering Recovery Services Vaults in RG..."

mapfile -t RAW_VAULTS < <(az rest --method get --url "$vault_list_url" --query "value[].name" -o tsv)
VAULTS=()
for raw in "${RAW_VAULTS[@]}"; do
  clean="$(trim_cr "$raw")"
  if [[ -n "$clean" ]]; then
    VAULTS+=("$clean")
  fi
done

if [[ ${#VAULTS[@]} -eq 0 ]]; then
  echo "[ERROR] No Recovery Services Vault found in RG: $RESOURCE_GROUP" >&2
  exit 1
fi

echo "[INFO] Found ${#VAULTS[@]} vault(s): ${VAULTS[*]}"

mkdir -p "$BACKUP_DIR"

echo "[STEP 1/2] Backing up existing policies..."
for vault in "${VAULTS[@]}"; do
  vault_dir="$BACKUP_DIR/$vault"
  mkdir -p "$vault_dir"

  list_policy_url="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.RecoveryServices/vaults/${vault}/backupPolicies?api-version=${API_VERSION}"

  policies_json="$vault_dir/all-policies.json"
  if ! az rest --method get --url "$list_policy_url" -o json > "$policies_json"; then
    echo "[ERROR] Failed to fetch policies for vault: $vault" >&2
    echo "[ERROR] URL: $list_policy_url" >&2
    exit 1
  fi

  if ! jq -e '.value and (.value | type == "array")' "$policies_json" >/dev/null 2>&1; then
    echo "[ERROR] Backup response is not expected JSON array for vault: $vault" >&2
    echo "[ERROR] File: $policies_json" >&2
    exit 1
  fi

  jq -c '.value[]?' "$policies_json" | while IFS= read -r row; do
    p_name="$(jq -r '.name' <<<"$row")"
    p_name="$(trim_cr "$p_name")"
    jq '.' <<<"$row" > "$vault_dir/policy-${p_name}.json"
  done

  echo "[OK] Backup completed for vault: $vault -> $vault_dir"
done

echo "[STEP 2/2] Updating policy to all vaults..."
if [[ "$AUTO_APPROVE" != "true" ]]; then
  echo "[CONFIRM] Backup complete. Ready to update policy '$POLICY_NAME' on all vaults."
  read -r -p "Type 'yes' to continue: " confirm
  if [[ "$confirm" != "yes" ]]; then
    echo "[INFO] Update cancelled by user. Backup already completed."
    exit 0
  fi
fi

for vault in "${VAULTS[@]}"; do
  put_policy_url="https://management.azure.com/subscriptions/${SUBSCRIPTION_ID}/resourceGroups/${RESOURCE_GROUP}/providers/Microsoft.RecoveryServices/vaults/${vault}/backupPolicies/${POLICY_NAME}?api-version=${API_VERSION}"

  payload_file="$(mktemp)"
  jq \
    --arg sub "$SUBSCRIPTION_ID" \
    --arg rg "$RESOURCE_GROUP" \
    --arg vault "$vault" \
    --arg p "$POLICY_NAME" \
    '.name=$p
     | .id="/subscriptions/\($sub)/resourceGroups/\($rg)/providers/Microsoft.RecoveryServices/vaults/\($vault)/backupPolicies/\($p)"
     | .type="Microsoft.RecoveryServices/vaults/backupPolicies"' \
    "$POLICY_FILE" > "$payload_file"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[DRY-RUN] Would update vault=$vault policy=$POLICY_NAME"
    echo "[DRY-RUN] PUT $put_policy_url"
  else
    az rest --method put --url "$put_policy_url" --body @"$payload_file" -o none
    echo "[OK] Updated policy '$POLICY_NAME' on vault: $vault"
  fi

  rm -f "$payload_file"
done

echo "[DONE] Backup + bulk update completed."
echo "[DONE] Backup folder: $BACKUP_DIR"
