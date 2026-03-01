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

func TestVpcValidate(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "vpc"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	terraform.Validate(t, terraformOptions)
}

func TestVpcPlanStructure(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "vpc"),
		PlanFilePath: filepath.Join(t.TempDir(), "tfplan"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	plan := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	require.NotNil(t, plan.ResourcePlannedValuesMap)

	vpcResource := plan.ResourcePlannedValuesMap["module.vpc.aws_vpc.main"]
	require.NotNil(t, vpcResource, "VPC resource should exist in plan")
	assert.Equal(t, "10.0.0.0/16", vpcResource.AttributeValues["cidr_block"])
	assert.Equal(t, true, vpcResource.AttributeValues["enable_dns_hostnames"])
	assert.Equal(t, true, vpcResource.AttributeValues["enable_dns_support"])
}
