// Package usage 是小时级用量的本地持久化:把 sub2api /admin/usage 的原始请求日志
// 按「实例 × 账户 × 本地小时」聚合进 SQLite,跨重启保留,启动只补增量、不重拉。
//
// 时区:分桶用 time.Local(机器本地时区)截断到小时 —— 完全在客户端,确定性,
// 不依赖服务端怎么解释 timezone 参数。
package usage

import (
	"database/sql"
	"os"
	"path/filepath"
	"time"

	// 纯 Go 的 sqlite 驱动(无 cgo),不给 macOS 通用库 / Windows mingw 的 c-shared
	// 交叉编译添 C 依赖。注册驱动名 "sqlite"。
	_ "modernc.org/sqlite"

	"github.com/lureiny/quota-pulse/core/model"
)

// Store 是 SQLite 支撑的小时聚合存储。单连接串行写,简单稳妥。
type Store struct {
	db *sql.DB
}

// Open 打开(必要时新建)数据库,建表。父目录不存在会自动创建。
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
	_, err := s.db.Exec(`
CREATE TABLE IF NOT EXISTS hourly_usage(
  instance     TEXT    NOT NULL,
  account_id   TEXT    NOT NULL,
  hour_start   INTEGER NOT NULL,           -- 本地小时起点的 unix 秒
  input        INTEGER NOT NULL DEFAULT 0,
  output       INTEGER NOT NULL DEFAULT 0,
  cache_create INTEGER NOT NULL DEFAULT 0,
  cache_read   INTEGER NOT NULL DEFAULT 0,
  requests     INTEGER NOT NULL DEFAULT 0,
  PRIMARY KEY(instance, account_id, hour_start)
);
CREATE TABLE IF NOT EXISTS sync_state(
  instance   TEXT    PRIMARY KEY,
  last_id    INTEGER NOT NULL DEFAULT 0,   -- 已并入的最大日志 id(增量游标)
  updated_at INTEGER NOT NULL DEFAULT 0
);`)
	return err
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

// hourBucket 把请求时间截断到本地小时起点的 unix 秒。
func hourBucket(t time.Time) int64 {
	l := t.In(time.Local)
	return time.Date(l.Year(), l.Month(), l.Day(), l.Hour(), 0, 0, 0, time.Local).Unix()
}

type acc struct{ input, output, cc, cr, req int64 }

// AddRows 把一批原始日志按 (账户, 本地小时) 聚合后**累加**进库(幂等的前提是
// 调用方只传 id>LastID 的新行 —— 见 provider.FetchUsageSince),并把 last_id
// 推进到本批最大 id。空批是 no-op。
func (s *Store) AddRows(instance string, rows []model.UsageRow) error {
	if len(rows) == 0 {
		return nil
	}
	type key struct {
		acc  string
		hour int64
	}
	agg := make(map[key]*acc)
	var maxID int64
	for _, r := range rows {
		if r.ID > maxID {
			maxID = r.ID
		}
		k := key{r.AccountID, hourBucket(r.CreatedAt)}
		a := agg[k]
		if a == nil {
			a = &acc{}
			agg[k] = a
		}
		a.input += r.Input
		a.output += r.Output
		a.cc += r.CacheCreate
		a.cr += r.CacheRead
		a.req++
	}

	tx, err := s.db.Begin()
	if err != nil {
		return err
	}
	defer tx.Rollback()

	stmt, err := tx.Prepare(`
INSERT INTO hourly_usage(instance,account_id,hour_start,input,output,cache_create,cache_read,requests)
VALUES(?,?,?,?,?,?,?,?)
ON CONFLICT(instance,account_id,hour_start) DO UPDATE SET
  input=input+excluded.input, output=output+excluded.output,
  cache_create=cache_create+excluded.cache_create,
  cache_read=cache_read+excluded.cache_read,
  requests=requests+excluded.requests`)
	if err != nil {
		return err
	}
	defer stmt.Close()
	for k, a := range agg {
		if _, err := stmt.Exec(instance, k.acc, k.hour, a.input, a.output, a.cc, a.cr, a.req); err != nil {
			return err
		}
	}

	if _, err := tx.Exec(`
INSERT INTO sync_state(instance,last_id,updated_at) VALUES(?,?,?)
ON CONFLICT(instance) DO UPDATE SET
  last_id=max(last_id, excluded.last_id), updated_at=excluded.updated_at`,
		instance, maxID, time.Now().Unix()); err != nil {
		return err
	}
	return tx.Commit()
}

// Query 返回某账户自 sinceUnix(含)起的小时序列,按小时升序。
func (s *Store) Query(instance, accountID string, sinceUnix int64) []model.HourPoint {
	rows, err := s.db.Query(`
SELECT hour_start,input,output,cache_create,cache_read FROM hourly_usage
WHERE instance=? AND account_id=? AND hour_start>=?
ORDER BY hour_start`, instance, accountID, sinceUnix)
	if err != nil {
		return nil
	}
	defer rows.Close()

	var out []model.HourPoint
	for rows.Next() {
		var hs, in, ou, cc, cr int64
		if err := rows.Scan(&hs, &in, &ou, &cc, &cr); err != nil {
			continue
		}
		out = append(out, model.HourPoint{
			Hour:        time.Unix(hs, 0),
			Input:       in,
			Output:      ou,
			CacheCreate: cc,
			CacheRead:   cr,
			Total:       in + ou + cc + cr,
		})
	}
	return out
}

// Evict 删除某实例早于 beforeUnix 的小时桶(保留窗口外的清理)。
func (s *Store) Evict(instance string, beforeUnix int64) {
	_, _ = s.db.Exec(`DELETE FROM hourly_usage WHERE instance=? AND hour_start<?`, instance, beforeUnix)
}
