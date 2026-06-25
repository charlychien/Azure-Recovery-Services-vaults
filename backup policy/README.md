# bulk-backup-and-update-rsv-policy.sh

批次備份並更新同一 Resource Group 內所有 Recovery Services Vault 的 Backup Policy。

## 前置需求

| 工具 | 說明 |
|------|------|
| Azure CLI | `az login` 先登入 |
| jq | Windows 可用 winget install jqlang.jq |
| Git Bash | Windows 環境需使用 Git Bash 執行 (WSL 路徑異常時) |

## 腳本流程

```
1. 列出指定 RG 內所有 Recovery Services Vault
2. 每個 vault 的所有 policy 全量備份到本地資料夾
3. 人工確認 (或 --yes 自動跳過)
4. 把你提供的 policy JSON 套用到所有 vault 的同名 policy
```

> 備份一定先於更新執行，無法跳過備份步驟。

---

## 使用方式 A — 直接帶參數執行

```bash
# Git Bash (Windows)
"C:/Program Files/Git/bin/bash.exe" ./bulk-backup-and-update-rsv-policy.sh \
  --subscription <subscription-id> \
  --resource-group <resource-group> \
  --policy-file ./policy-update-template.json \
  --policy-name bp-vm-bronze
```

PowerShell 範例：

```powershell
& "C:/Program Files/Git/bin/bash.exe" "c:/Users/charlychien/azurebackup/bulk-backup-and-update-rsv-policy.sh" `
  --subscription a62c905d-fae1-4a2d-b7f5-64cf276ef95e `
  --resource-group rg-backup-ts `
  --policy-file "c:/Users/charlychien/azurebackup/policy-update-template.json" `
  --policy-name bp-vm-bronze
```

---

## 使用方式 B — 直接在腳本內填入預設值

開啟 `bulk-backup-and-update-rsv-policy.sh`，找到 **INLINE DEFAULTS** 區塊填入你的值：

```bash
# ============================================================
# INLINE DEFAULTS: fill these in to run without CLI arguments
# ============================================================
SUBSCRIPTION_ID="a62c905d-fae1-4a2d-b7f5-64cf276ef95e"
RESOURCE_GROUP="rg-backup-ts"
POLICY_FILE="./policy-update-template.json"
POLICY_NAME="bp-vm-bronze"
BACKUP_DIR=""        # 空白 = 自動加時間戳，e.g. ./rsv-policy-backup-20260623-120000
AUTO_APPROVE="false"
DRY_RUN="false"
# ============================================================
```

填完後直接執行，不需帶任何參數：

```bash
"C:/Program Files/Git/bin/bash.exe" ./bulk-backup-and-update-rsv-policy.sh
```

---

## 參數說明

| 參數 | 必要 | 說明 |
|------|------|------|
| `--subscription` | ✅ | Azure Subscription ID |
| `--resource-group` | ✅ | 所有 vault 所在的 Resource Group |
| `--policy-file` | ✅ | 要套用的 policy JSON 檔路徑 |
| `--policy-name` | ⬜ | 要更新的 policy 名稱；省略時從 policy JSON `.name` 讀取 |
| `--backup-dir` | ⬜ | 備份輸出資料夾；省略時自動產生含時間戳的資料夾 |
| `--api-version` | ⬜ | REST API 版本，預設 `2023-02-01` |
| `--yes` | ⬜ | 跳過人工確認提示 |
| `--dry-run` | ⬜ | 只顯示動作，不實際更新 |
| `-h, --help` | ⬜ | 顯示說明 |

---

## Policy JSON 格式

以 `policy-update-template.json` 為範本，必須包含 `properties` 物件：

```json
{
  "name": "bp-vm-bronze",
  "properties": {
    "backupManagementType": "AzureIaasVM",
    "policyType": "V1",
    "instantRpRetentionRangeInDays": 2,
    "schedulePolicy": {
      "schedulePolicyType": "SimpleSchedulePolicy",
      "scheduleRunFrequency": "Daily",
      "scheduleRunTimes": ["2026-01-01T01:00:00Z"]
    },
    "retentionPolicy": {
      "retentionPolicyType": "LongTermRetentionPolicy",
      "dailySchedule": {
        "retentionTimes": ["2026-01-01T01:00:00Z"],
        "retentionDuration": { "count": 7, "durationType": "Days" }
      }
    },
    "timeZone": "UTC"
  }
}
```

> `id` 和 `type` 欄位由腳本自動依 vault 填入，不需手動設定。

---

## 備份輸出結構

```
rsv-policy-backup-20260623-134831/
  vault-ts/
    all-policies.json           <- 所有 policy 的完整 API 回應
    policy-DefaultPolicy.json   <- 每個 policy 單獨備份
    policy-bp-vm-bronze.json
    policy-EnhancedPolicy.json
    policy-HourlyLogBackup.json
  rsv-japanwest/
    all-policies.json
    policy-DefaultPolicy.json
    ...
```

---

## 常見問題

**Q: 執行時看到 `WSL ... getpwuid(0) failed` 錯誤**  
A: 你的 PowerShell 預設 `bash` 指向壞掉的 WSL。請改用：
```powershell
& "C:/Program Files/Git/bin/bash.exe" ./bulk-backup-and-update-rsv-policy.sh ...
```

**Q: 備份的 `all-policies.json` 是空檔**  
A: 已修復（v2 腳本）。原因是 vault 名稱從 `az rest -o tsv` 讀回時帶有隱藏的 `\r` 字元，導致 REST URL 組成錯誤。

**Q: 想要只更新特定幾個 vault，不是全部**  
A: 目前不支援直接篩選 vault，可以先用 `--dry-run` 確認清單，或把不需更新的 vault 暫時移到其他 RG。
