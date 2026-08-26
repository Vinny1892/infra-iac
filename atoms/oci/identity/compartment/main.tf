# Compartment é a fronteira nativa de isolamento na OCI: política de IAM, cota e
# visibilidade de custo são por compartment. Criar recursos no compartment raiz da
# tenancy é desaconselhado pela própria Oracle justamente por não haver essa separação.
resource "oci_identity_compartment" "this" {
  compartment_id = var.parent_compartment_id
  name           = var.name
  description    = var.description
  enable_delete  = var.enable_delete
  freeform_tags  = var.freeform_tags
}
