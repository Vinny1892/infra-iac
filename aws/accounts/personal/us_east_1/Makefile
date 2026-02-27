K3S_DEPLOY := ./applications/k3s/deploy.sh

.PHONY: help k3s-deploy k3s-destroy

help:
	@echo "Targets:"
	@echo "  k3s-deploy   Deploy K3s cluster + Helm releases"
	@echo "  k3s-destroy  Cleanup K8s resources then destroy K3s cluster"

k3s-deploy:
	$(K3S_DEPLOY) deploy

k3s-destroy:
	$(K3S_DEPLOY) destroy
