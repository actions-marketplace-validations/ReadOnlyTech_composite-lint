plugin "terraform" {
  enabled = true
  preset  = "all"
  source  = "github.com/terraform-linters/tflint-ruleset-terraform"
  version = "0.16.1"
}
