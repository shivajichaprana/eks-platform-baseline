# Lint config for eks-platform-baseline.
# See: https://github.com/terraform-linters/tflint
config {
  format     = "compact"
  call_module_type = "all"
  force      = false
}

plugin "terraform" {
  enabled = true
  preset  = "recommended"
}

plugin "aws" {
  enabled = true
  version = "0.32.0"
  source  = "github.com/terraform-linters/tflint-ruleset-aws"
}

# We define modules/<x>/variables.tf without defaults on purpose.
rule "terraform_required_providers" {
  enabled = true
}

rule "terraform_required_version" {
  enabled = true
}

rule "terraform_unused_declarations" {
  enabled = true
}
