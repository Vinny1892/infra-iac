//go:build unit

package unit

import (
	"path/filepath"
	"testing"

	"github.com/Vinny1892/infra-iac/tests/helpers"
	"github.com/gruntwork-io/terratest/modules/terraform"
	"github.com/stretchr/testify/require"
)

func TestEcsTaskValidate(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "ecs_task"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	terraform.Validate(t, terraformOptions)
}

func TestEcsTaskPlanResources(t *testing.T) {
	t.Parallel()

	terraformOptions := terraform.WithDefaultRetryableErrors(t, &terraform.Options{
		TerraformDir: helpers.FixturePath(t, "ecs_task"),
		PlanFilePath: filepath.Join(t.TempDir(), "tfplan"),
		NoColor:      true,
	})

	terraform.Init(t, terraformOptions)
	plan := terraform.InitAndPlanAndShowWithStruct(t, terraformOptions)

	taskDef := plan.ResourcePlannedValuesMap["module.ecs_task.aws_ecs_task_definition.task"]
	require.NotNil(t, taskDef, "ECS task definition should exist in plan")

	execRole := plan.ResourcePlannedValuesMap["module.ecs_task.aws_iam_role.task_execution_ecs"]
	require.NotNil(t, execRole, "ECS task execution IAM role should exist in plan")

	taskRole := plan.ResourcePlannedValuesMap["module.ecs_task.aws_iam_role.task_role"]
	require.NotNil(t, taskRole, "ECS task IAM role should exist in plan")
}
