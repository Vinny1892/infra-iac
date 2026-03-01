//go:build unit

package unit

import (
	"path/filepath"
	"testing"

	"github.com/Vinny1892/infra-iac/tests/helpers"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/assert"
	"github.com/stretchr/testify/require"
)

func TestNetworkMoleculeValidate(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "network_molecule"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	terraform.Validate(t, terraformOptions)
}

func TestNetworkMoleculePlan(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "network_molecule"),
		PlanFilePath: filepath.Join(t.TempDir(), "tfplan"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	plan := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	vpcResource := plan.ResourcePlannedValuesMap["module.network.aws_vpc.main"]
	require.NotNil(t, vpcResource, "VPC resource should exist in plan")
	assert.Equal(t, "10.0.0.0/16", vpcResource.AttributeValues["cidr_block"])

	sgResource := plan.ResourcePlannedValuesMap["module.network.aws_security_group.example"]
	require.NotNil(t, sgResource, "Security group should exist in plan")

	require.Contains(t, plan.RawPlan.OutputChanges, "vpc_id")
	require.Contains(t, plan.RawPlan.OutputChanges, "vpc_cidr")
	require.Contains(t, plan.RawPlan.OutputChanges, "security_group_id")
}
