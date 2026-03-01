//go:build unit

package unit

import (
	"os"
	"testing"
)

// TestMain ensures tests run in a clean environment.
func TestMain(m *testing.M) {
	// Removing shared TF_PLUGIN_CACHE_DIR to avoid 'text file busy' errors
	// during parallel provider installation.
	os.Unsetenv("TF_PLUGIN_CACHE_DIR")
	os.Exit(m.Run())
}
