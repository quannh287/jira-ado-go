package keychain

import (
	"os"
	"testing"
)

// Touches the real OS keychain, so it only runs on demand: KEYCHAIN_TEST=1 go test ./internal/keychain
func TestSecret(t *testing.T) {
	if os.Getenv("KEYCHAIN_TEST") != "1" {
		t.Skip("set KEYCHAIN_TEST=1 to use the real keychain")
	}
	s := Secret{Service: "com.example.jiraado.test", Account: "test"}
	t.Cleanup(func() { s.Delete() })
	if v, err := s.Get(); err != nil || v != "" {
		t.Fatalf("empty Get = %q, %v", v, err)
	}
	const pat = `p@t with 'quotes' "and" spaces`
	if err := s.Set(pat); err != nil {
		t.Fatal(err)
	}
	if v, err := s.Get(); err != nil || v != pat {
		t.Fatalf("Get = %q, %v", v, err)
	}
	if err := s.Delete(); err != nil {
		t.Fatal(err)
	}
	if err := s.Delete(); err != nil {
		t.Fatalf("second Delete: %v", err)
	}
}
