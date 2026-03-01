//go:build unit

package unit

import (
	"os"
	"testing"

	"github.com/Vinny1892/infra-iac/tests/helpers"
	"github.com/gruntwork-io/terratest/modules/terraform"
)

func TestK3sOrganismValidate(t *testing.T) {
	t.Parallel()

	fixturePath := helpers.FixturePath(t, "k3s_extracted")

	// Skip if fixture hasn't been generated
	if _, err := os.Stat(fixturePath + "/main.tf"); os.IsNotExist(err) {
		t.Skip("K3s extracted fixture not found. Run: bash scripts/extract-k3s-fixture.sh")
	}

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: fixturePath,
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	terraform.Validate(t, terraformOptions)
}
