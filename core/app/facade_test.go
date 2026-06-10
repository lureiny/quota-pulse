package app

import "testing"

func TestNewFromJSONUnknownProvider(t *testing.T) {
	_, err := NewFromJSON(`{"providers":[{"type":"nope","base_url":"http://x"}]}`)
	if err == nil {
		t.Fatal("expected error for unknown provider type")
	}
}

func TestSnapshotEmpty(t *testing.T) {
	a, err := NewFromJSON(`{"providers":[
	  {"type":"sub2api","name":"t","base_url":"http://localhost:1/",
	   "poll":{"passive_interval":"60s","active_interval":"10m"}}
	]}`)
	if err != nil {
		t.Fatal(err)
	}
	if got := a.SnapshotJSON(); got != "[]" {
		t.Errorf("snapshot = %s, want []", got)
	}
}

func TestSetSignalsNoPanic(t *testing.T) {
	a, err := NewFromJSON(`{"providers":[{"type":"sub2api","base_url":"http://x"}]}`)
	if err != nil {
		t.Fatal(err)
	}
	a.SetPopoverOpen(true)
	a.SetOnBattery(true)
	a.SetAsleep(true) // 仅验证不 panic
}
