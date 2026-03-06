//go:build unit

package unit

import (
	"os"
	"path/filepath"
	"testing"

	"github.com/Vinny1892/infra-iac/tests/helpers"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
)

func k3sFixturePath(t *testing.T) string {
	t.Helper()
	fixturePath := helpers.FixturePath(t, "k3s_extracted")
	if _, err := os.Stat(fixturePath + "/main.tf"); os.IsNotExist(err) {
		t.Skip("K3s extracted fixture not found. Run: bash scripts/extract-k3s-fixture.sh")
	}
	return fixturePath
}

func TestK3sOrganismValidate(t *testing.T) {
	t.Parallel()

	// terraform validate does not accept -var flags; use options without vars
	opts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: k3sFixturePath(t),
		NoColor:      true,
	})

	terraform.Init(t, opts)
	terraform.Validate(t, opts)
}

func TestK3sWorkerPlan(t *testing.T) {
	t.Parallel()

	opts := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: k3sFixturePath(t),
		PlanFilePath: filepath.Join(t.TempDir(), "tfplan"),
		Vars: map[string]interface{}{
			"vpc_id":             "vpc-mock",
			"vpc_cidr":           "10.0.0.0/16",
			"public_subnet_ids":  []string{"subnet-mock-pub"},
			"private_subnet_ids": []string{"subnet-mock-priv"},
		},
		NoColor: true,
	})

	plan := terraform.InitAndPlanAndShowWithStruct(t, opts)
	resources := plan.ResourceChangesMap

	assert.Contains(t, resources, "aws_launch_template.k3s_worker",
		"worker launch template should be planned")
	assert.Contains(t, resources, "aws_autoscaling_group.k3s_workers",
		"worker ASG should be planned")
	assert.Contains(t, resources, "aws_iam_role.k3s_worker_role",
		"worker IAM role should be planned")
	assert.Contains(t, resources, "aws_iam_instance_profile.k3s_worker_profile",
		"worker instance profile should be planned")
}
