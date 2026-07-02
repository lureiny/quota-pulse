// Package usage 是用量的本地「原始事件时序库」:把 sub2api /admin/usage 的每条请求
// 事件落进 SQLite(每请求一行,跨重启保留、增量同步),并提供「按任意维度 + 小时分桶」
// 的即时聚合查询,供图表按 账户/api_key/model/user/group 等维度展示。
//
// 维度灵活:事件的所有维度(id + 名字)存在一个 JSON 列 dims 里(label 风格),
// 查询用 json_extract 按维度分组聚合 —— 加新维度只需往 dims 塞键 + 白名单加一行,
// 零迁移。时区:入库时按机器 time.Local 把 created_at 截到小时存 hour_local,
// 分桶在写入侧定死,确定性正确。
package usage

import (
	"database/sql"
	"encoding/json"
	"os"
	"path/filepath"
	"time"

	// 纯 Go sqlite 驱动(无 cgo),不给 c-shared 交叉编译加 C 依赖。注册驱动名 "sqlite"。
	_ "modernc.org/sqlite"

	"github.com/lureiny/quota-pulse/core/model"
)

// schemaVersion 升版即触发迁移。v1→v2:旧小时聚合表不兼容,重建 + 重新回填原始事件。
// v2→v3:sync_state 增 backfilled_from(覆盖水位 W),保留既有事件、就地补列 + 播种。
const schemaVersion = 3

// dimPaths 是可分组维度的白名单:维度名 → (取键的 JSON path, 取展示名的 JSON path)。
// 既约束允许的维度,也避免把外部字符串拼进 SQL。加维度:这里加一行 + 采集侧往 dims 塞键。
var dimPaths = map[string][2]string{
	"account": {"$.account", "$.account_name"},
	"api_key": {"$.api_key", "$.api_key_name"},
	"user":    {"$.user", "$.user_name"},
	"group":   {"$.group", "$.group_name"},
	"model":   {"$.model", "$.model"}, // model 维度:键即名
}

// Store 是 SQLite 支撑的原始事件库。单连接串行写,简单稳妥。
type Store struct {
	db *sql.DB
}

// Open 打开(必要时新建)数据库并建表/迁移。父目录不存在会自动创建。
func Open(path string) (*Store, error) {
	if dir := filepath.Dir(path); dir != "" {
		_ = os.MkdirAll(dir, 0o755)
	}
	db, err := sql.Open("sqlite", path)
	if err != nil {
		return nil, err
	}
	db.SetMaxOpenConns(1) // 单连接:database/sql 串行化,避免 "database is locked"
	for _, pragma := range []string{
		"PRAGMA journal_mode=WAL",
		"PRAGMA busy_timeout=5000",
		"PRAGMA synchronous=NORMAL",
	} {
		if _, err := db.Exec(pragma); err != nil {
			db.Close()
			return nil, err
		}
	}
	s := &Store{db: db}
	if err := s.initSchema(); err != nil {
		db.Close()
		return nil, err
	}
	return s, nil
}

func (s *Store) initSchema() error {
	var ver int
	_ = s.db.QueryRow("PRAGMA user_version").Scan(&ver)
	if ver < 2 {
		// 旧 v1 schema(小时聚合)不兼容:清掉旧表 + 游标,强制按新结构重新回填原始事件。
		// v2→v3 不在此列:保留 usage_events 与游标,只就地补列(见下),避免重新回填。
		if _, err := s.db.Exec(`DROP TABLE IF EXISTS hourly_usage; DROP TABLE IF EXISTS sync_state;`); err != nil {
			return err
		}
	}
	if _, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS usage_events(
  instance     TEXT    NOT NULL,
  id           INTEGER NOT NULL,            -- sub2api 日志 id(增量游标 & 去重)
  created_at   INTEGER NOT NULL,            -- 精确事件时间(unix 秒)
  hour_local   INTEGER NOT NULL,            -- 本地小时桶 unix(入库按 time.Local 预算)
  input        INTEGER NOT NULL DEFAULT 0,
  output       INTEGER NOT NULL DEFAULT 0,
  cache_create INTEGER NOT NULL DEFAULT 0,
  cache_read   INTEGER NOT NULL DEFAULT 0,
  cost         REAL    NOT NULL DEFAULT 0,
  dims         TEXT    NOT NULL DEFAULT '{}',  -- 维度 JSON(label 风格,id+名字)
  PRIMARY KEY(instance, id)
);
CREATE INDEX IF NOT EXISTS idx_events_hour ON usage_events(instance, hour_local);
CREATE TABLE IF NOT EXISTS sync_state(
  instance        TEXT    PRIMARY KEY,
  last_id         INTEGER NOT NULL DEFAULT 0,
  updated_at      INTEGER NOT NULL DEFAULT 0,
  backfilled_from INTEGER NOT NULL DEFAULT 0  -- 覆盖水位 W:已回填到的最早时刻(unix 秒)
);`); err != nil {
		return err
	}
	// v2→v3:老 sync_state 无 backfilled_from 列 → 就地补列,并用现有事件的最早时刻播种
	// 覆盖水位(我们确实持有这些数据,视为已覆盖;否则升级后整段会被误标“未采集”)。
	if !s.hasColumn("sync_state", "backfilled_from") {
		if _, err := s.db.Exec(`ALTER TABLE sync_state ADD COLUMN backfilled_from INTEGER NOT NULL DEFAULT 0`); err != nil {
			return err
		}
		if _, err := s.db.Exec(`UPDATE sync_state SET backfilled_from =
  COALESCE((SELECT MIN(created_at) FROM usage_events e WHERE e.instance = sync_state.instance), 0)
WHERE backfilled_from = 0`); err != nil {
			return err
		}
	}
	if ver < schemaVersion {
		if _, err := s.db.Exec(`PRAGMA user_version=3`); err != nil {
			return err
		}
	}
	return nil
}

// hasColumn 报告 table 是否含某列(用于幂等迁移)。table 仅来自内部字面量,拼接安全。
func (s *Store) hasColumn(table, col string) bool {
	rows, err := s.db.Query(`PRAGMA table_info(` + table + `)`)
	if err != nil {
		return false
	}
	defer rows.Close()
	for rows.Next() {
		var cid, notnull, pk int
		var name, ctype string
		var dflt sql.NullString
		if err := rows.Scan(&cid, &name, &ctype, &notnull, &dflt, &pk); err != nil {
			continue
		}
		if name == col {
			return true
		}
	}
	return false
}

// Close 关闭数据库。
func (s *Store) Close() error {
	if s == nil || s.db == nil {
		return nil
	}
	return s.db.Close()
}

// LastID 返回某实例已并入的最大日志 id(无记录则 0)。
func (s *Store) LastID(instance string) int64 {
	var id int64
	_ = s.db.QueryRow(`SELECT last_id FROM sync_state WHERE instance=?`, instance).Scan(&id)
	return id
}

// SyncedAt 返回某实例上次成功并入事件的时刻(unix 秒;无则 0)。
// 用于把增量回看窗口拉到「上次同步以来」,避免离线空档漏数据。
func (s *Store) SyncedAt(instance string) int64 {
	var t int64
	_ = s.db.QueryRow(`SELECT updated_at FROM sync_state WHERE instance=?`, instance).Scan(&t)
	return t
}

// CoverageFrom 返回该实例本地「完整覆盖」的最早时刻 W(unix 秒;0=尚未覆盖任何区间)。
// [W, now] 区间被视为完整(id 游标 + 主键去重 + 近窗回看保证);W 之前为未知,
// 图表据此把更早的请求跨度标为「未采集」而非误当成零。
func (s *Store) CoverageFrom(instance string) int64 {
	var t int64
	_ = s.db.QueryRow(`SELECT backfilled_from FROM sync_state WHERE instance=?`, instance).Scan(&t)
	return t
}

// MaxCreatedAt 返回该实例本地最新事件的 created_at(unix 秒;空实例 0)。
// 它是「前向覆盖上界 covered_to」的派生值:只要前向补齐一律由旧到新连续推进
// (见 poller.forwardDrain),MAX 恒等于连续覆盖区间的右端 → 免持久化列、跨重启可续补。
func (s *Store) MaxCreatedAt(instance string) int64 {
	var t sql.NullInt64
	_ = s.db.QueryRow(`SELECT MAX(created_at) FROM usage_events WHERE instance=?`, instance).Scan(&t)
	if t.Valid {
		return t.Int64
	}
	return 0
}

// NoteCoverage 记录覆盖水位 W:只向更早推进(取 min),稳态的近窗同步不会抬高它。
// fromUnix<=0 视为无效(no-op)。
func (s *Store) NoteCoverage(instance string, fromUnix int64) {
	if fromUnix <= 0 {
		return
	}
	_, _ = s.db.Exec(`
INSERT INTO sync_state(instance,last_id,updated_at,backfilled_from) VALUES(?,0,0,?)
ON CONFLICT(instance) DO UPDATE SET backfilled_from =
  CASE WHEN backfilled_from=0 OR excluded.backfilled_from < backfilled_from
       THEN excluded.backfilled_from ELSE backfilled_from END`, instance, fromUnix)
}

// hourBucket 把事件时间截断到本地小时起点的 unix 秒。
func hourBucket(t time.Time) int64 {
	l := t.In(time.Local)
	return time.Date(l.Year(), l.Month(), l.Day(), l.Hour(), 0, 0, 0, time.Local).Unix()
}

// AddEvents 把一批原始事件写入(INSERT OR IGNORE 以 (instance,id) 去重,故重复传入无害),
// 并把 last_id 推进到本批最大 id。空批是 no-op。
func (s *Store) AddEvents(instance string, evs []model.UsageEvent) error {
	if len(evs) == 0 {
		return nil
	}
	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
INSERT OR IGNORE INTO usage_events(instance,id,created_at,hour_local,input,output,cache_create,cache_read,cost,dims)
VALUES(?,?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		return err
	}
	defer stmt.Close()

	var maxID int64
	for _, e := range evs {
		if e.ID > maxID {
			maxID = e.ID
		}
		dims, _ := json.Marshal(e.Dims)
		if _, err := stmt.Exec(instance, e.ID, e.CreatedAt.Unix(), hourBucket(e.CreatedAt),
			e.Input, e.Output, e.CacheCreate, e.CacheRead, e.Cost, string(dims)); err != nil {
			return err
		}
	}

	if _, err := tx.Exec(`
INSERT INTO sync_state(instance,last_id,updated_at) VALUES(?,?,?)
ON CONFLICT(instance) DO UPDATE SET last_id=max(last_id, excluded.last_id), updated_at=excluded.updated_at`,
		instance, maxID, time.Now().Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

// QuerySeries 按 dimension 维度把自 sinceUnix 起的事件聚合成「每维度值一条序列」,
// 每条序列按小时升序。dimension 不在白名单时回退 account。
func (s *Store) QuerySeries(instance, dimension string, sinceUnix int64) []model.Series {
	p, ok := dimPaths[dimension]
	if !ok {
		p = dimPaths["account"]
	}
	keyPath, namePath := p[0], p[1]

	rows, err := s.db.Query(`
SELECT json_extract(dims, ?) AS k, json_extract(dims, ?) AS nm, hour_local AS h,
       SUM(input), SUM(output), SUM(cache_create), SUM(cache_read), SUM(cost), COUNT(*)
FROM usage_events
WHERE instance=? AND hour_local>=?
GROUP BY k, h
ORDER BY k, h`, keyPath, namePath, instance, sinceUnix)
	if err != nil {
		return nil
	}
	defer rows.Close()

	order := make([]string, 0, 16)
	byKey := make(map[string]*model.Series)
	for rows.Next() {
		var k, nm sql.NullString
		var hs, in, ou, cc, cr, cnt int64
		var cost float64
		if err := rows.Scan(&k, &nm, &hs, &in, &ou, &cc, &cr, &cost, &cnt); err != nil {
			continue
		}
		key := k.String
		ser := byKey[key]
		if ser == nil {
			name := key
			if nm.Valid && nm.String != "" {
				name = nm.String
			}
			ser = &model.Series{Key: key, Name: name}
			byKey[key] = ser
			order = append(order, key)
		}
		ser.Points = append(ser.Points, model.HourPoint{
			Hour:        time.Unix(hs, 0),
			Input:       in,
			Output:      ou,
			CacheCreate: cc,
			CacheRead:   cr,
			Total:       in + ou + cc + cr,
			Cost:        cost,
			Count:       cnt,
		})
	}

	out := make([]model.Series, 0, len(order))
	for _, key := range order {
		out = append(out, *byKey[key])
	}
	return out
}

// Evict 删除某实例早于 beforeUnix 的事件(保留窗口外清理),并把覆盖下界 W 向前夹到
// beforeUnix:数据都删了就不能再声称覆盖到更早(否则 CoverageFrom 谎报、ensureBackfill 也据此
// 误判已补齐)。夹取只在 W 早于 beforeUnix 时发生,幂等安全。
func (s *Store) Evict(instance string, beforeUnix int64) {
	_, _ = s.db.Exec(`DELETE FROM usage_events WHERE instance=? AND hour_local<?`, instance, beforeUnix)
	_, _ = s.db.Exec(`UPDATE sync_state SET backfilled_from=? WHERE instance=? AND backfilled_from>0 AND backfilled_from<?`,
		beforeUnix, instance, beforeUnix)
}
