###############################################################################
# Backend/environment guard (DEP-2), symlinked into every layer.
#
# The Makefile keys BOTH the backend config (conf/<env>.backend.conf, which
# picks the state bucket + workspace) and the var file (vars/<env>.tfvars) off
# the same env=, so terraform.workspace and var.environment normally agree. A
# manual terraform run that mixes them (prod backend/workspace + dev tfvars, or
# vice versa) would plan dev values against prod state, this guard fails the
# plan instead. terraform_data is builtin (no provider) and the resource itself
# is inert; the precondition is evaluated at plan time.
###############################################################################

resource "terraform_data" "backend_env_guard" {
  input = var.environment

  lifecycle {
    precondition {
      condition     = terraform.workspace == var.environment
      error_message = "Workspace '${terraform.workspace}' does not match var.environment '${var.environment}', the backend config and tfvars disagree (mixed env= values?). Refusing to touch the wrong state."
    }
  }
}
