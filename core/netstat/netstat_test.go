package netstat

import (
	"encoding/json"
	"testing"
)

// parse 把 Report() 的 JSON 解回结构体供断言。
func parse(t *testing.T) ReportJSON {
	t.Helper()
	var r ReportJSON
	if err := json.Unmarshal(Report(), &r); err != nil {
		t.Fatalf("unmarshal report: %v", err)
	}
	return r
}

// findInst / findAPI / findPS 小工具。
func findInst(r ReportJSON, name string) *InstanceStat {
	for i := range r.Instances {
		if r.Instances[i].Instance == name {
			return &r.Instances[i]
		}
	}
	return nil
}
func findAPI(is *InstanceStat, ep string) *APIStat {
	for i := range is.APIs {
		if is.APIs[i].Endpoint == ep {
			return &is.APIs[i]
		}
	}
	return nil
}
func findPS(as *APIStat, ps int) *PageSizeStat {
	for i := range as.ByPageSize {
		if as.ByPageSize[i].PageSize == ps {
			return &as.ByPageSize[i]
		}
	}
	return nil
}

func TestAggregatesByInstanceAPIAndPageSize(t *testing.T) {
	Enable(0, 0)
	defer Disable()

	// 实例 A:/admin/usage 两次 page_size=1(wire 100+120,payload 300+360),
	//        /admin/usage 一次 page_size=1000(wire 900,payload 5000)。
	Record("A", "/api/v1/admin/usage?page=1&page_size=1&sort_by=id", 100, 300, 200)
	Record("A", "/api/v1/admin/usage?page=1&page_size=1&sort_by=id", 120, 360, 200)
	Record("A", "/api/v1/admin/usage?page=1&page_size=1000&sort_by=id", 900, 5000, 200)
	// 实例 A:账户用量,数字账户 id 应归一为 {id}(两次不同账户聚到同一 endpoint)。
	Record("A", "/api/v1/admin/accounts/42/usage?source=passive", 50, 150, 200)
	Record("A", "/api/v1/admin/accounts/7/usage?source=passive", 60, 180, 200)
	// 实例 B:一次列表。
	Record("B", "/api/v1/admin/accounts?page=1&page_size=200", 400, 2000, 200)

	r := parse(t)
	if r.Samples != 6 {
		t.Fatalf("samples=%d want 6", r.Samples)
	}
	if len(r.Instances) != 2 {
		t.Fatalf("instances=%d want 2", len(r.Instances))
	}

	a := findInst(r, "A")
	if a == nil {
		t.Fatal("instance A missing")
	}
	if a.Requests != 5 {
		t.Errorf("A.requests=%d want 5", a.Requests)
	}
	if a.WireTotal != 100+120+900+50+60 {
		t.Errorf("A.wireTotal=%d want %d", a.WireTotal, 100+120+900+50+60)
	}
	if a.PayloadTotal != 300+360+5000+150+180 {
		t.Errorf("A.payloadTotal=%d want %d", a.PayloadTotal, 300+360+5000+150+180)
	}

	usage := findAPI(a, "/api/v1/admin/usage")
	if usage == nil {
		t.Fatal("A /admin/usage missing")
	}
	if usage.Requests != 3 {
		t.Errorf("usage.requests=%d want 3", usage.Requests)
	}
	// page_size=1:两次,wire 平均 (100+120)/2=110。
	ps1 := findPS(usage, 1)
	if ps1 == nil || ps1.Requests != 2 {
		t.Fatalf("usage ps=1 bad: %+v", ps1)
	}
	if ps1.WireAvg != 110 {
		t.Errorf("usage ps=1 wireAvg=%v want 110", ps1.WireAvg)
	}
	if ps1.PayloadAvg != 330 {
		t.Errorf("usage ps=1 payloadAvg=%v want 330", ps1.PayloadAvg)
	}
	// page_size=1000:一次,wire 900。
	ps1000 := findPS(usage, 1000)
	if ps1000 == nil || ps1000.Requests != 1 || ps1000.WireTotal != 900 {
		t.Errorf("usage ps=1000 bad: %+v", ps1000)
	}

	// 账户用量数字 id 归一 → 一个 endpoint、两次请求。
	acctUsage := findAPI(a, "/api/v1/admin/accounts/{id}/usage")
	if acctUsage == nil || acctUsage.Requests != 2 {
		t.Errorf("accounts/{id}/usage bad: %+v", acctUsage)
	}
}

func TestStopsAtSampleCap(t *testing.T) {
	Enable(3, 0) // 最多 3 条
	defer Disable()

	for i := 0; i < 10; i++ {
		Record("A", "/api/v1/admin/usage?page_size=1", 10, 20, 200)
	}
	r := parse(t)
	if r.Samples != 3 {
		t.Errorf("samples=%d want 3 (capped)", r.Samples)
	}
	if !r.Truncated {
		t.Error("truncated should be true after hitting cap")
	}
	if r.DroppedOver != 7 {
		t.Errorf("droppedOver=%d want 7", r.DroppedOver)
	}
}

func TestStopsAtMemCap(t *testing.T) {
	// 极小内存上限:只放得下很少几条,之后停采。
	Enable(1000000, sampleCost+64)
	defer Disable()
	for i := 0; i < 100; i++ {
		Record("inst", "/api/v1/admin/usage?page_size=1", 10, 20, 200)
	}
	r := parse(t)
	if !r.Truncated {
		t.Error("truncated should be true after hitting mem cap")
	}
	if r.Samples == 0 || r.Samples >= 100 {
		t.Errorf("samples=%d want a small non-zero count under 100", r.Samples)
	}
}

func TestDisableKeepsSamplesResetClears(t *testing.T) {
	Enable(0, 0)
	Record("A", "/api/v1/admin/usage?page_size=1", 10, 20, 200)
	Disable() // 停采但保留

	r := parse(t)
	if r.Enabled {
		t.Error("enabled should be false after Disable")
	}
	if r.Samples != 1 {
		t.Errorf("samples=%d want 1 (Disable keeps samples)", r.Samples)
	}
	// 停采后新记录不入。
	Record("A", "/api/v1/admin/usage?page_size=1", 10, 20, 200)
	if r2 := parse(t); r2.Samples != 1 {
		t.Errorf("samples=%d want 1 (recording stopped)", r2.Samples)
	}

	Reset()
	if r3 := parse(t); r3.Samples != 0 {
		t.Errorf("samples=%d want 0 after Reset", r3.Samples)
	}
}

func TestDisabledRecordIsNoop(t *testing.T) {
	Reset()
	Disable()
	Record("A", "/x?page_size=1", 10, 20, 200)
	if r := parse(t); r.Samples != 0 {
		t.Errorf("samples=%d want 0 when disabled", r.Samples)
	}
}
