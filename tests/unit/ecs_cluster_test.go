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

func TestEcsClusterValidate(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "ecs_cluster"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	terraform.Validate(t, terraformOptions)
}

func TestEcsClusterPlan(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "ecs_cluster"),
		PlanFilePath: filepath.Join(t.TempDir(), "tfplan"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	plan := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	clusterResource := plan.ResourcePlannedValuesMap["module.ecs_cluster.aws_ecs_cluster.cluster"]
	require.NotNil(t, clusterResource, "ECS cluster resource should exist in plan")
	assert.Equal(t, "test-cluster", clusterResource.AttributeValues["name"])
}
