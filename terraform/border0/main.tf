terraform {
  required_version = ">= 1.16.4"

  required_providers {
    border0 = {
      source  = "borderzero/border0"
      version = "3.0.38"
    }
  }

  backend "s3" {
    bucket = "border0-terraform-state"
    key    = "border0/terraform.tfstate"
    region = "garage"
    endpoints = {
      s3 = "https://s3.cdn.keiretsu.top"
    }
    use_path_style              = true
    skip_credentials_validation = true
    skip_region_validation      = true
    skip_requesting_account_id  = true
    skip_metadata_api_check     = true
    skip_s3_checksum            = true
  }
}

provider "border0" {}

locals {
  connectors = {
    ottawa = "37f5861f-c140-4bdc-9158-5325c2518262"
  }
}
