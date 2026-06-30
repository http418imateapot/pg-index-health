# pg-index-health — Copilot Instructions

## 專案概覽

**pg-index-health** 是一套 PostgreSQL 索引健康度分析工具鏈，涵蓋三個互補的使用場景：

| 場景 | 說明 | 工具 |
|------|------|------|
| A – CLI 診斷 | 工程師一次性健康檢查 | `cli/` Python CLI (`pg-index-check`) |
| B – CI/CD 守衛 | PR 合入前自動索引回歸檢查 | `.github/workflows/pg_index_guard.yml` |
| C – 長期監控 | DBA / SRE 趨勢分析 | `monitoring/` Docker Compose + Grafana |

核心分析能力：
- 辨識未使用索引（Index Miss）與過度索引（Over-indexing）
- 偵測冗餘索引（欄位重疊的索引組合，前綴包含關係）
- 追蹤 dead tuple 成長趨勢
- 輸出可執行的建議動作（`recommendation` 欄位），而非只是數字

---

## 目錄結構

```
pg-index-health/
├── cli/                          # 場景 A：Python CLI 工具
│   ├── pg_index_check/           # Python 套件
│   │   ├── __init__.py           # 版本號
│   │   ├── __main__.py           # Click CLI 入口點（所有命令）
│   │   ├── checker.py            # SQL 查詢層（唯讀）
│   │   ├── formatters.py         # 輸出格式化（table / json / csv）
│   │   └── snapshots.py          # 快照儲存／比較（~/.pg-index-check/）
│   ├── pyproject.toml            # 套件設定，CLI 命令名稱：pg-index-check
│   └── README.md                 # CLI 使用說明（英文）
├── sql/                          # 獨立 SQL 腳本（可直接在 psql 執行）
│   ├── pg_index_check.sql        # 主要索引健康分析查詢
│   ├── redundant_index_check.sql # 冗餘索引偵測查詢
│   ├── create_test_data.sql      # 測試資料（schema: bad_index_test）
│   ├── cleanup_test_data.sql     # 清理測試資料
│   └── monitoring/               # 場景 C 的 DB 端 schema
│       ├── create_snapshot_schema.sql  # 建立 index_stats_monitoring schema
│       ├── snapshot_procedure.sql      # take_snapshot() stored procedure
│       ├── window_analysis.sql         # 時間窗口 delta 分析查詢
│       └── cleanup_snapshot_schema.sql
├── monitoring/                   # 場景 C：Docker Compose 監控堆疊
│   ├── docker-compose.yml        # PostgreSQL 16 + Grafana OSS
│   ├── grafana/                  # Grafana 設定與 dashboard JSON
│   ├── initdb/                   # PostgreSQL 初始化腳本
│   └── README.md                 # 監控堆疊使用說明（英文）
├── .github/
│   └── workflows/
│       └── pg_index_guard.yml    # 場景 B：CI/CD 索引守衛 workflow
└── README.md                     # 根目錄說明（中文）
```

---

## 技術棧

| 元件 | 技術 |
|------|------|
| CLI | Python ≥ 3.9, Click ≥ 8.1, psycopg2-binary, tabulate |
| 核心查詢 | 純 PostgreSQL SQL（pg_stat_user_tables, pg_stat_user_indexes, pg_class 等） |
| 快照儲存 | JSON 檔案，路徑 `~/.pg-index-check/snapshots/<id>.json` |
| 監控堆疊 | Docker Compose, PostgreSQL 16-alpine, Grafana OSS |
| CI/CD | GitHub Actions, `actions/checkout@v4`, `actions/setup-python@v5` |

---

## CLI 命令設計

CLI 入口點為 `pg-index-check`，由 `cli/pg_index_check/__main__.py` 定義。

### 命令群組

```
pg-index-check
├── check          # 完整索引健康掃描
├── redundant      # 冗餘索引偵測
├── snapshot
│   ├── save       # 儲存當前統計快照到磁碟
│   ├── compare    # 與已儲存快照比較（顯示 delta）
│   ├── list       # 列出所有快照
│   └── delete     # 刪除指定快照
└── monitor
    └── snapshot   # 推送一筆快照至長期歷史資料表
```

### 輸出格式

所有命令支援 `--output [table|json|csv]`，預設為 `table`。
`formatters.py` 負責三種格式的渲染。

### 環境變數

| 變數 | 用途 |
|------|------|
| `PG_DSN` | 主要 PostgreSQL DSN（所有命令的 `--dsn` 預設值） |
| `PG_MONITORING_DSN` | 監控資料庫 DSN（`monitor snapshot` 用） |

---

## SQL 查詢設計（`checker.py`）

`checker.py` 包含三個 SQL 模板：

### `_INDEX_CHECK_SQL`
- 以 CTE 分層計算：`params` → `table_stats` → `table_stats_final` → `index_stats` → 最終 SELECT
- 從 `pg_stat_user_tables`、`pg_stat_user_indexes`、`pg_class` 取得統計
- `recommendation` 欄位以 CASE WHEN 邏輯輸出可執行建議，嚴重度由高到低：
  1. `REVIEW: index never used but table is heavily seq-scanned`
  2. `CONSIDER DROP: index has never been used since last stats reset`
  3. `ACTION REQUIRED: run VACUUM FULL or REINDEX (bloat > 500 MB)`
  4. `RECOMMEND: run VACUUM ANALYZE (dead tuple ratio > 20%)`
  5. `WARNING: index larger than its table (over-indexing?)`
  6. `WARNING: high seq_scan with low index usage`
  7. `OK`

### `_REDUNDANT_INDEX_SQL`
- 以 `array_agg(a.attname ORDER BY ordinality)` 取得索引欄位順序
- 前綴包含條件：`b.columns = a.columns[1:array_length(b.columns, 1)]`
- 跳過 PRIMARY KEY、UNIQUE constraint、partial index（或給予不同建議）

### `_INSERT_SNAPSHOT_SQL`
- 將當前 `pg_stat_user_indexes` 資料插入 `index_stats_monitoring.index_stats_history`
- 所有連線均為唯讀，僅 `insert_snapshot` 需要寫入權限

---

## 快照機制（`snapshots.py`）

- 儲存路徑：`~/.pg-index-check/snapshots/<id>.json`
- JSON 結構：`{"captured_at": "<ISO8601>", "rows": [...]}`
- `compare_snapshots(baseline, current)` 計算 `seq_scan_count` 與 `index_usage_count` 的 delta，並在每列附加 `_delta` 欄位

---

## 監控堆疊設計（`monitoring/`）

- `docker-compose.yml` 啟動兩個服務：`postgres`（port 5432）與 `grafana`（port 3000）
- 同一個 PostgreSQL 實例包含兩個 DB：`appdb`（目標 DB）和 `monitoring`（歷史資料 DB）
- 快照由 `pg-index-check monitor snapshot` 或 `CALL index_stats_monitoring.take_snapshot()` 觸發
- Grafana dashboard 預載三個面板：Index Health Overview、Seq Scan Increment、Dead Tuple Ratio Trend

---

## CI/CD 守衛設計（`pg_index_guard.yml`）

1. 觸發條件：PR 異動 `sql/**` 或 `migrations/**`
2. 啟動 PostgreSQL 16 service container
3. 套用 migration（預設使用 `sql/create_test_data.sql`，替換為實際 migration 工具）
4. 執行 `pg-index-check check` 與 `pg-index-check redundant`，輸出 JSON 和 table
5. 統計非 OK 的建議數量與可丟棄的冗餘索引數量（預設不 fail build，需取消註解才強制失敗）
6. 在 PR 貼上分析報告評論（bot 評論會被更新，不重複建立）

---

## 所需 DB 權限（最小化）

```sql
GRANT pg_monitor TO monitoring_role;
-- 或逐一授予：
GRANT SELECT ON pg_stat_user_tables, pg_stat_user_indexes,
                pg_class, pg_namespace, pg_index,
                pg_attribute, pg_database TO monitoring_role;
GRANT EXECUTE ON FUNCTION pg_relation_size(oid) TO monitoring_role;
GRANT EXECUTE ON FUNCTION pg_size_pretty(bigint) TO monitoring_role;
GRANT EXECUTE ON FUNCTION pg_stat_get_db_stat_reset_time(oid) TO monitoring_role;
```

---

## 開發慣例

- Python 程式碼支援 Python 3.9+，使用 `from __future__ import annotations`
- SQL 以 `textwrap.dedent()` 定義為模組層級常數，命名規則 `_UPPER_SNAKE_SQL`
- CLI 選項使用 Click 的 `envvar` 對應環境變數（如 `PG_DSN`）
- 錯誤以 `click.echo(..., err=True)` 輸出至 stderr，後接 `sys.exit(1)`
- 測試套件：`pytest`（`cli/` 目錄下，`pip install -e ".[dev]"` 安裝）
- README 語言：根目錄 `README.md` 使用中文，`cli/README.md` 和 `monitoring/README.md` 使用英文
