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

func TestWireguardValidate(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "wireguard"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	terraform.Validate(t, terraformOptions)
}

func TestWireguardPlan(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "wireguard"),
		PlanFilePath: filepath.Join(t.TempDir(), "tfplan"),
		NoColor:      true,
	})

	plan := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	instance := plan.ResourcePlannedValuesMap["aws_instance.wireguard"]
	require.NotNil(t, instance, "aws_instance.wireguard deve existir no plan")
	assert.Equal(t, "t3.micro", instance.AttributeValues["instance_type"])

	require.NotNil(t, plan.ResourcePlannedValuesMap["aws_secretsmanager_secret.wireguard_private_key"],
		"secret da private key deve existir no plan")
	require.NotNil(t, plan.ResourcePlannedValuesMap["aws_secretsmanager_secret.wireguard_public_key"],
		"secret da public key deve existir no plan")
	require.NotNil(t, plan.ResourcePlannedValuesMap["aws_iam_role.wireguard_role"],
		"IAM role deve existir no plan")
	require.NotNil(t, plan.ResourcePlannedValuesMap["aws_security_group.wireguard_sg"],
		"security group deve existir no plan")

	sg := plan.ResourcePlannedValuesMap["aws_security_group.wireguard_sg"]
	require.NotNil(t, sg, "aws_security_group.wireguard_sg deve existir no plan")
}
