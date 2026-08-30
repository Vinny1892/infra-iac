package helpers

import (
	"path/filepath"
	"runtime"
	"sync"
	"testing"
)

var fixtureLocks sync.Map

// FixturePath returns the absolute path to a test fixture directory.
func FixturePath(t *testing.T, name string) string {
	t.Helper()

	// Validation and plan tests for the same fixture run in parallel. Terraform
	// init mutates .terraform and can otherwise replace a provider binary while
	// the sibling test is executing it, resulting in a "text file busy" error.
	lock, _ := fixtureLocks.LoadOrStore(name, &sync.Mutex{})
	fixtureLock := lock.(*sync.Mutex)
	fixtureLock.Lock()
	t.Cleanup(fixtureLock.Unlock)

	_, filename, _, _ := runtime.Caller(0)
	base := filepath.Dir(filepath.Dir(filename))
	return filepath.Join(base, "fixtures", name)
}
