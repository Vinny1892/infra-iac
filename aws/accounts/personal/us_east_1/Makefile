# Variable configuration
TF_OPTIONS := --auto-approve

# Display available targets and their descriptions
.PHONY: help
help:
    @echo "Available targets:"
    @echo "  - init:      Initialize Terraform"
    @echo "  - plan:      Create an execution plan"
    @echo "  - apply:     Apply Terraform configuration"
    @echo "  - destroy:   Destroy Terraform resources"
    @echo "  - up:        Shortcut for init and apply"

# Initialize Terraform
.PHONY: init
init:
	terraform  -chdir=./accounts/personal/network/vpc init
	terraform  -chdir=./accounts/personal/ecs_cluster init
	terraform  -chdir=./accounts/personal/internal_domain init
	terraform  -chdir=./accounts/personal/applications init

# Create an execution plan
.PHONY: plan
plan:
	terraform plan $(TF_OPTIONS)

# Apply Terraform configuration
.PHONY: apply-core
apply-core:
	terraform -chdir=./network/vpc apply $(TF_OPTIONS)
	terraform -chdir=./internal_domain apply $(TF_OPTIONS)
	terraform -chdir=./ecs_cluster apply $(TF_OPTIONS)
	


.PHONY: destroy-core
destroy-core:
	terraform -chdir=./internal_domain destroy $(TF_OPTIONS)
	terraform -chdir=./network/vpc destroy $(TF_OPTIONS)
	terraform -chdir=./ecs_cluster destroy $(TF_OPTIONS)