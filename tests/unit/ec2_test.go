//go:build unit

package unit

import (
	"os"
	"testing"

	"github.com/Vinny1892/infra-iac/tests/helpers"
	"github.com/gruntwork-io/terratest/modules/terraform"
)

func TestEc2Validate(t *testing.T) {
	t.Parallel()

	// The EC2 atom uses file("~/.ssh/id_ed25519.pub") which requires an actual SSH key
	homeDir, err := os.UserHomeDir()
	if err != nil {
		t.Skip("Cannot determine home directory, skipping EC2 test")
	}

	sshKeyPath := homeDir + "/.ssh/id_ed25519.pub"
	if _, err := os.Stat(sshKeyPath); os.IsNotExist(err) {
		t.Skip("SSH key not found at ~/.ssh/id_ed25519.pub, skipping EC2 test")
	}

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "ec2"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	terraform.Validate(t, terraformOptions)
}
