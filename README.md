# 資料庫索引品質分析工具

> **PostgreSQL Index Health Checker** – 從單次診斷到長期監控的完整工具鏈。

---

## 目的

提供 PostgreSQL 資料表索引品質分析工具，包括三個互補的使用場景：

| 場景 | 適用對象 | 工具 |
|------|----------|------|
| **A – CLI 診斷** | 需要一次性健康檢查的工程師 | `cli/` Python CLI |
| **B – CI/CD 守衛** | 有 migration 流程的開發團隊 | `.github/workflows/pg_index_guard.yml` |
| **C – 長期監控** | DBA / SRE 需要趨勢分析 | `monitoring/` Docker Compose + Grafana |

核心能力：
- 辨識**未命中索引**（Index Miss）與**過度索引**（Over-indexing）
- 偵測**冗餘索引**（欄位重疊的索引組合）
- 追蹤 **dead tuple 成長趨勢**
- 輸出**可執行的建議動作**，而非只是數字

---

## 快速開始

### 場景 A：CLI 工具（一次性診斷）

```bash
pip install -e cli/

# 檢查所有 schema
pg-index-check check --dsn "******localhost/mydb"

# 只顯示有問題的索引
pg-index-check check --dsn $PG_DSN --issues-only

# JSON 輸出（方便 jq / 自動化）
pg-index-check check --dsn $PG_DSN --output json

# 偵測冗餘索引
pg-index-check redundant --dsn $PG_DSN

# 兩次執行之間的 delta 比較
pg-index-check snapshot save    --dsn $PG_DSN --id prod-baseline
pg-index-check snapshot compare --dsn $PG_DSN --id prod-baseline
```

詳見 [cli/README.md](cli/README.md)。

### 場景 B：CI/CD 索引守衛

PR 合入前自動執行索引健康檢查，並在 PR 留下報告。

GitHub Actions workflow 已包含在 `.github/workflows/pg_index_guard.yml`，
將 migration 步驟替換為你的工具（Flyway / Alembic / golang-migrate 等）即可使用。

### 場景 C：長期監控儀表板

```bash
cd monitoring/
docker compose up -d
# 開啟 http://localhost:3000 (admin/admin)
```

詳見 [monitoring/README.md](monitoring/README.md)。

---

## SQL 檔案說明

```
sql/
├── pg_index_check.sql          # 主要索引健康分析查詢
├── redundant_index_check.sql   # 冗餘索引偵測查詢
├── create_test_data.sql        # 建立測試資料（含交易包裝）
├── cleanup_test_data.sql       # 清理測試資料
└── monitoring/
    ├── create_snapshot_schema.sql  # 建立長期監控 schema
    ├── snapshot_procedure.sql      # 快照收集 stored procedure
    ├── window_analysis.sql         # 時間窗口 delta 分析查詢
    └── cleanup_snapshot_schema.sql # 清理監控 schema
```

### 使用測試資料

(測試資料會建立並使用 schema `bad_index_test`)

```sql
-- 1. 建立測試資料
\i sql/create_test_data.sql

-- 2. 執行索引品質分析
\i sql/pg_index_check.sql

-- 3. 執行冗餘索引偵測
\i sql/redundant_index_check.sql

-- 4. 清理測試資料
\i sql/cleanup_test_data.sql
```

---

## 低效索引特徵定義

以下依索引品質嚴重程度，由高到低介紹低效索引的特徵與定義。

### 索引超過資料表大小 (index_over_table_size)

- 計算公式：`(index_size_bytes - table_size_bytes) / table_size_bytes`
- 定義：衡量索引相較於資料表的大小是否過大。
- 糟糕的索引設計：當 `index_over_table_size > 0`（即索引比資料表本身還大），可能是儲存空間的浪費。過大的索引會導致寫入變慢，並影響查詢效能。

### 全表掃描 (seq_scan_count)

- 定義：統計資料表在查詢時未使用索引，而直接執行全表掃描的次數。
- 糟糕的索引設計：若 `seq_scan_count` 很高，但 `index_usage_count` 很低，代表該查詢可能缺少適當的索引；既有索引可能設計不良，導致查詢無法使用；或是查詢可能沒有寫好，導致索引無法發揮作用。
- **重要**：`seq_scan` 是自上次 `pg_stat_reset()` 起的累積值，務必參考 `stats_reset_at` 欄位確認統計時間範圍。

### 索引佔表比例 (index_table_ratio)

- 計算公式：`index_size_bytes / table_size_bytes`
- 定義：計算索引大小與資料表大小的比例。
- 糟糕的索引設計：當 `index_table_ratio > 100%`，代表索引大小已經超過資料表本身，可能有過度索引 (over-indexing) 的問題。

### 死亡元組 (dead tuples)

- 定義：dead tuples 是已刪除或更新但尚未被 VACUUM 清理的記錄，仍然佔用索引與表的空間。
- 糟糕的索引設計：若索引 scan 很少，但 dead tuple 比例很高，代表索引可能已經失去作用，應進行重建 (REINDEX) 或刪除。
- **注意**：`dead_tuple_size_estimate` 是近似值（dead tuple 比例 × heap 大小），在 TOAST 欄位佔比高的資料表上可能有 2–5 倍誤差。精確值請使用 `pgstattuple` 擴充。

### 冗餘索引 (redundant indexes)

- 定義：當索引 A 的欄位是索引 B 欄位的超集（前綴包含），索引 B 提供不了任何索引 A 無法提供的查詢計畫，因此 B 是冗餘的。
- 偵測：使用 `sql/redundant_index_check.sql` 或 `pg-index-check redundant`。

---

## 分析結果輸出欄位

| 欄位 | 說明 |
|------|------|
| `schema_name` | Schema 名稱 |
| `table_name` | 資料表名稱 |
| `index_name` | 索引名稱 |
| `table_size` | 資料表大小（heap only） |
| `index_size` | 索引大小 |
| `seq_scan_count` | 全表掃描累積次數 |
| `index_usage_count` | 索引掃描累積次數 |
| `dead_tuple_ratio` | Dead tuple 佔比 (%) |
| `dead_tuple_size` | Dead tuple 佔用空間估算 |
| `index_table_ratio` | 索引大小 / 表大小 × 100 |
| `index_over_table_size` | (索引大小 − 表大小) / 表大小 × 100 |
| `stats_reset_at` | pg_stat 計數器上次重置時間 |
| `recommendation` | 可執行的建議動作 |

### 分析結果範例

| Schema | Table | Index | Table Size | Index Size | Seq Scans | Idx Scans | Dead Tuple % | Recommendation |
|--------|-------|-------|------------|------------|-----------|-----------|--------------|----------------|
| bad_index_test | test_orders | idx_random | 21 MB | 11 MB | 15 | 0 | 28.21 | CONSIDER DROP: index has never been used since last stats reset |
| bad_index_test | test_orders | idx_amount | 21 MB | 5944 kB | 15 | 1 | 28.21 | RECOMMEND: run VACUUM ANALYZE (dead tuple ratio > 20%) |
| bad_index_test | test_orders | idx_order_date | 21 MB | 4760 kB | 15 | 1 | 28.21 | RECOMMEND: run VACUUM ANALYZE (dead tuple ratio > 20%) |

---

## 在生產環境安全使用

### 所需權限（最小化）

```sql
-- 建立唯讀監控角色
CREATE ROLE monitoring_role;

GRANT pg_monitor TO monitoring_role;
-- 或手動授予：
GRANT SELECT ON pg_stat_user_tables  TO monitoring_role;
GRANT SELECT ON pg_stat_user_indexes TO monitoring_role;
GRANT SELECT ON pg_class             TO monitoring_role;
GRANT SELECT ON pg_namespace         TO monitoring_role;
GRANT SELECT ON pg_index             TO monitoring_role;
GRANT SELECT ON pg_attribute         TO monitoring_role;
GRANT SELECT ON pg_database          TO monitoring_role;
```

### 連線池（PgBouncer / pgpool）注意事項

`create_test_data.sql` 已將 `SET search_path` 改為 `SET LOCAL search_path`，
並包裝在交易中，避免在 transaction mode 的連線池環境中污染其他 session。

在生產環境請**不要**在連線池共享連線上執行 `SET search_path`（無 `LOCAL`）。

### pg_stat 計數器的時間範圍

所有 `seq_scan`、`idx_scan` 計數器都是**累積值**，從上次 `pg_stat_reset_single_table_counters()`（PG 15+）或資料庫層級 `pg_stat_reset()` 起算。

查看計數器的有效時間範圍：

```sql
SELECT pg_stat_get_db_stat_reset_time(oid)
FROM pg_database
WHERE datname = current_database();
```

建議使用**快照比較模式**（`pg-index-check snapshot`）或場景 C 的長期歷史表來得到有時間窗口的分析結果。


