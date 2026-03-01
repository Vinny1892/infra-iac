package helpers

import (
	"path/filepath"
	"runtime"
	"testing"
)

// FixturePath returns the absolute path to a test fixture directory.
func FixturePath(t *testing.T, name string) string {
	t.Helper()
	_, filename, _, _ := runtime.Caller(0)
	base := filepath.Dir(filepath.Dir(filename))
	return filepath.Join(base, "fixtures", name)
}
