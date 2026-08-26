locals {
  # OCID da tenancy — pai do compartment. Recursos não vão no compartment raiz.
  tenancy_id = "ocid1.tenancy.oc1..aaaaaaaa67vhrp637voglpe2gux3tnf2adhohpxlild2hepev4friacmlcwq"

  # Ubuntu 24.04 aarch64 — imagem nativa OCI
  image_id = "ocid1.image.oc1.iad.aaaaaaaaccnswiekwi4w3pkmygjvfk24epduwj7uvq2smjmznu4kq6dcs27a"

  # IP de administração (SSH). IP residencial: muda aqui quando mudar.
  admin_cidr = "186.219.220.188/32"
}
