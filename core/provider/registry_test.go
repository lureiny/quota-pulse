package provider

import (
	"testing"

	"github.com/lureiny/quota-pulse/core/config"
)

func TestRegisterRejectsDuplicateType(t *testing.T) {
	const typ = "test-duplicate"
	delete(registry, typ)
	t.Cleanup(func() { delete(registry, typ) })
	factory := func(config.ProviderConfig) (Provider, error) { return nil, nil }
	Register(typ, factory)

	defer func() {
		if recover() == nil {
			t.Fatal("duplicate provider registration did not panic")
		}
	}()
	Register(typ, factory)
}
