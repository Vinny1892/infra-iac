//go:build unit

package unit

import (
	"testing"

	"github.com/Vinny1892/infra-iac/tests/helpers"
	"github.com/gruntwork-io/terratest/modules/terraform"
)

func TestArgoCDGitHubAppValidate(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "argocd_github_app"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	terraform.Validate(t, terraformOptions)
}
