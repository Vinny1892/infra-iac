//go:build unit

package unit

import (
	"os"
	"path/filepath"
	"testing"
)

// TestMain sets a shared provider plugin cache so parallel tests that init the
// same fixture dir don't race over downloading/executing the same binary.
func TestMain(m *testing.M) {
	cacheDir := filepath.Join(os.TempDir(), "tf-plugin-cache-infra-iac")
	_ = os.MkdirAll(cacheDir, 0755)
	os.Setenv("TF_PLUGIN_CACHE_DIR", cacheDir)
	os.Exit(m.Run())
}
