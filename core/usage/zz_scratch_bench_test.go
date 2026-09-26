package usage

import (
	"database/sql"
	"fmt"
	"math/rand"
	"path/filepath"
	"testing"
	"time"
)

func TestZZScratchRollupBench(t *testing.T) {
	if testing.Short() {
		t.Skip()
	}
	path := filepath.Join(t.TempDir(), "bench.db")
	st, err := Open(path)
	if err != nil {
		t.Fatal(err)
	}
	defer st.Close()
	db := st.db

	const nRows = 200000
	const nDays = 400
	rnd := rand.New(rand.NewSource(1))
	card := map[string]int{"account": 50, "api_key": 500, "user": 300, "group": 10}
	models := []string{"claude-sonnet-4", "claude-opus-4", "gpt-4o", "gemini-2.5-pro", "claude-haiku"}

	start := time.Now()
	tx, _ := db.Begin()
	stmt, err := tx.Prepare(`INSERT INTO usage_events(instance,id,created_at,hour_local,day_local,input,output,cache_create,cache_read,cost,dims) VALUES(?,?,?,?,?,?,?,?,?,?,?)`)
	if err != nil {
		t.Fatal(err)
	}
	base := time.Now().AddDate(0, 0, -nDays)
	for i := 0; i < nRows; i++ {
		ts := base.Add(time.Duration(rnd.Int63n(int64(nDays)*86400)) * time.Second)
		dims := fmt.Sprintf(`{"account":"%d","account_name":"acct-%d","api_key":"%d","api_key_name":"key-%d","user":"%d","user_name":"u%d","group":"%d","group_name":"g%d","model":"%s"}`,
			rnd.Intn(card["account"]), rnd.Intn(card["account"]),
			rnd.Intn(card["api_key"]), rnd.Intn(card["api_key"]),
			rnd.Intn(card["user"]), rnd.Intn(card["user"]),
			rnd.Intn(card["group"]), rnd.Intn(card["group"]),
			models[rnd.Intn(len(models))])
		if _, err := stmt.Exec("inst", int64(i+1), ts.Unix(), hourBucket(ts), dayBucket(ts),
			rnd.Int63n(5000), rnd.Int63n(2000), rnd.Int63n(1000), rnd.Int63n(9000), rnd.Float64()*0.5, dims); err != nil {
			t.Fatal(err)
		}
	}
	stmt.Close()
	if err := tx.Commit(); err != nil {
		t.Fatal(err)
	}
	t.Logf("seed %d rows: %v", nRows, time.Since(start))

	since := dayBucket(time.Now().AddDate(0, 0, -180))

	// (a) 现状:原始表按天聚合(热力图路径)
	for _, dim := range []string{"api_key", "account"} {
		t0 := time.Now()
		n := len(st.QueryDailySeries("inst", dim, since))
		t.Logf("[a] raw QueryDailySeries dim=%s 180d: %v (series=%d)", dim, time.Since(t0), n)
	}

	// (b) 对账审计:覆盖索引按天计数
	t0 := time.Now()
	rows, err := db.Query(`SELECT day_local, COUNT(*) FROM usage_events WHERE instance=? GROUP BY day_local`, "inst")
	if err != nil {
		t.Fatal(err)
	}
	cnt := 0
	for rows.Next() {
		var d, c int64
		rows.Scan(&d, &c)
		cnt++
	}
	rows.Close()
	t.Logf("[b] audit COUNT(*) GROUP BY day_local: %v (%d days)", time.Since(t0), cnt)
	var plan string
	db.QueryRow(`EXPLAIN QUERY PLAN SELECT day_local, COUNT(*) FROM usage_events WHERE instance=? GROUP BY day_local`, "inst").Scan(new(int), new(int), new(int), &plan)
	t.Logf("[b] plan: %s", plan)

	// (b2) 降级自愈:DISTINCT day_local WHERE id > ?
	t0 = time.Now()
	rows, _ = db.Query(`SELECT DISTINCT day_local FROM usage_events WHERE instance=? AND id>?`, "inst", nRows/2)
	dd := 0
	for rows.Next() {
		dd++
	}
	rows.Close()
	t.Logf("[b2] DISTINCT day_local WHERE id>half: %v (%d days)", time.Since(t0), dd)
	db.QueryRow(`EXPLAIN QUERY PLAN SELECT DISTINCT day_local FROM usage_events WHERE instance=? AND id>?`, "inst", 1).Scan(new(int), new(int), new(int), &plan)
	t.Logf("[b2] plan: %s", plan)

	// (c) 建汇总表 + 全量构建
	if _, err := db.Exec(`
CREATE TABLE daily_rollup(instance TEXT NOT NULL, dim TEXT NOT NULL, k TEXT NOT NULL, nm TEXT,
 day_local INTEGER NOT NULL, input INTEGER, output INTEGER, cache_create INTEGER, cache_read INTEGER,
 cost REAL, cnt INTEGER, PRIMARY KEY(instance,dim,k,day_local)) WITHOUT ROWID;`); err != nil {
		t.Fatal(err)
	}
	t0 = time.Now()
	for dim, p := range dimPaths {
		if _, err := db.Exec(`INSERT INTO daily_rollup(instance,dim,k,nm,day_local,input,output,cache_create,cache_read,cost,cnt)
SELECT ?, ?, COALESCE(json_extract(dims,?),''), json_extract(dims,?), day_local,
 SUM(input),SUM(output),SUM(cache_create),SUM(cache_read),SUM(cost),COUNT(*)
FROM usage_events WHERE instance=? GROUP BY 3, day_local`, "inst", dim, p[0], p[1], "inst"); err != nil {
			t.Fatal(err)
		}
	}
	t.Logf("[c] full build (5 dims, %d days): %v", time.Since(t0), nDays)
	var rc int64
	db.QueryRow(`SELECT COUNT(*) FROM daily_rollup`).Scan(&rc)
	var pageCount, pageSize int64
	db.QueryRow(`PRAGMA page_count`).Scan(&pageCount)
	db.QueryRow(`PRAGMA page_size`).Scan(&pageSize)
	t.Logf("[c] rollup rows=%d  db bytes=%d", rc, pageCount*pageSize)

	// (d) 读汇总(PK 顺序 instance,dim,k,day_local,无日索引)
	for _, dim := range []string{"api_key", "account"} {
		t0 = time.Now()
		rows, err := db.Query(`SELECT k,nm,day_local,input,output,cache_create,cache_read,cost,cnt
FROM daily_rollup WHERE instance=? AND dim=? AND day_local>=? ORDER BY k, day_local`, "inst", dim, since)
		if err != nil {
			t.Fatal(err)
		}
		n := 0
		for rows.Next() {
			var k string
			var nm sql.NullString
			var d, a, b2, c2, e, f int64
			var cost float64
			rows.Scan(&k, &nm, &d, &a, &b2, &c2, &e, &cost, &f)
			n++
		}
		rows.Close()
		t.Logf("[d] rollup read dim=%s 180d (PK order k,day): %v (%d rows)", dim, time.Since(t0), n)
	}

	// (e) 加 (instance,dim,day_local) 索引后再读
	if _, err := db.Exec(`CREATE INDEX idx_rollup_day ON daily_rollup(instance,dim,day_local)`); err != nil {
		t.Fatal(err)
	}
	for _, dim := range []string{"api_key", "account"} {
		t0 = time.Now()
		rows, _ := db.Query(`SELECT k,nm,day_local,input,output,cache_create,cache_read,cost,cnt
FROM daily_rollup WHERE instance=? AND dim=? AND day_local>=? ORDER BY k, day_local`, "inst", dim, since)
		n := 0
		for rows.Next() {
			n++
		}
		rows.Close()
		t.Logf("[e] rollup read dim=%s 180d (+idx day): %v (%d rows)", dim, time.Since(t0), n)
	}
	db.QueryRow(`PRAGMA page_count`).Scan(&pageCount)
	t.Logf("[e] db bytes after idx=%d", pageCount*pageSize)

	// (f) 单天重算(稳态每轮的代价):5 个维度
	oneDay := dayBucket(time.Now().AddDate(0, 0, -3))
	t0 = time.Now()
	txd, _ := db.Begin()
	txd.Exec(`DELETE FROM daily_rollup WHERE instance=? AND day_local=?`, "inst", oneDay)
	for dim, p := range dimPaths {
		if _, err := txd.Exec(`INSERT INTO daily_rollup(instance,dim,k,nm,day_local,input,output,cache_create,cache_read,cost,cnt)
SELECT ?,?,COALESCE(json_extract(dims,?),''), json_extract(dims,?), day_local,
 SUM(input),SUM(output),SUM(cache_create),SUM(cache_read),SUM(cost),COUNT(*)
FROM usage_events WHERE instance=? AND day_local=? GROUP BY 3`, "inst", dim, p[0], p[1], "inst", oneDay); err != nil {
			t.Fatal(err)
		}
	}
	txd.Commit()
	t.Logf("[f] single-day recompute (5 dims, ~%d raw rows): %v", nRows/nDays, time.Since(t0))

	// (g) 整天被 Evict 删空后,DELETE-then-INSERT 是否让该天消失
	db.Exec(`DELETE FROM usage_events WHERE instance=? AND day_local=?`, "inst", oneDay)
	txd, _ = db.Begin()
	txd.Exec(`DELETE FROM daily_rollup WHERE instance=? AND day_local=?`, "inst", oneDay)
	for dim, p := range dimPaths {
		txd.Exec(`INSERT INTO daily_rollup(instance,dim,k,nm,day_local,input,output,cache_create,cache_read,cost,cnt)
SELECT ?,?,COALESCE(json_extract(dims,?),''), json_extract(dims,?), day_local,
 SUM(input),SUM(output),SUM(cache_create),SUM(cache_read),SUM(cost),COUNT(*)
FROM usage_events WHERE instance=? AND day_local=? GROUP BY 3`, "inst", dim, p[0], p[1], "inst", oneDay)
	}
	txd.Commit()
	var left int64
	db.QueryRow(`SELECT COUNT(*) FROM daily_rollup WHERE day_local=?`, oneDay).Scan(&left)
	t.Logf("[g] after raw-day emptied, rollup rows for that day = %d (want 0)", left)

	// (h) GROUP BY 空组会不会插入 NULL 行?
	empty := dayBucket(time.Now().AddDate(0, 0, -5000))
	db.Exec(`INSERT INTO daily_rollup(instance,dim,k,nm,day_local,input,output,cache_create,cache_read,cost,cnt)
SELECT ?,?,COALESCE(json_extract(dims,'$.account'),''), json_extract(dims,'$.account_name'), day_local,
 SUM(input),SUM(output),SUM(cache_create),SUM(cache_read),SUM(cost),COUNT(*)
FROM usage_events WHERE instance=? AND day_local=? GROUP BY 3`, "inst", "account", "inst", empty)
	var e2 int64
	db.QueryRow(`SELECT COUNT(*) FROM daily_rollup WHERE day_local=?`, empty).Scan(&e2)
	t.Logf("[h] insert-select over empty day inserted %d rows (want 0)", e2)

	// (i) dims 为 'null'(e.Dims 为 nil)时 NOT NULL 约束
	db.Exec(`INSERT INTO usage_events(instance,id,created_at,hour_local,day_local,input,output,cache_create,cache_read,cost,dims) VALUES('inst2',1,?,?,?,1,1,0,0,0.1,'null')`,
		time.Now().Unix(), hourBucket(time.Now()), dayBucket(time.Now()))
	_, err = db.Exec(`INSERT INTO daily_rollup(instance,dim,k,nm,day_local,input,output,cache_create,cache_read,cost,cnt)
SELECT 'inst2','account', json_extract(dims,'$.account'), json_extract(dims,'$.account_name'), day_local,
 SUM(input),SUM(output),SUM(cache_create),SUM(cache_read),SUM(cost),COUNT(*)
FROM usage_events WHERE instance='inst2' GROUP BY 3`)
	t.Logf("[i] NOT NULL k with dims='null' → err=%v", err)
}
