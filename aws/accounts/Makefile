# Variable configuration
TF_OPTIONS := --auto-approve

# Commands

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
.PHONY: apply
apply:
	terraform -chdir=./accounts/personal/applications apply $(TF_OPTIONS)


.PHONY: destroy
destroy:
	terraform  -chdir=./accounts/personal/applications apply $(TF_OPTIONS)
	terraform  -chdir=./accounts/personal/internal_domain destroy $(TF_OPTIONS)
	terraform  -chdir=./accounts/personal/ecs_cluster destroy $(TF_OPTIONS)
	terraform  -chdir=./accounts/personal/network/vpc destroy $(TF_OPTIONS)