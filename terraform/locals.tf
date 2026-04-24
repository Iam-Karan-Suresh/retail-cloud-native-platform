# =============================================================================
# LOCAL VALUES AND DATA SOURCES
# =============================================================================

data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

resource "random_string" "suffix" {
  length  = 4
  special = false
  upper   = false
}
# Local computed values
locals {
  cluster_name = "$"
}

