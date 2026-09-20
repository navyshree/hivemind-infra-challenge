terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.65"
    }
    helm = {
      source  = "hashicorp/helm"
      version = "~> 3.3"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = "~> 3.2"
    }
  }

  # State is local by design for this exercise; see README "Tradeoffs".
  #
  # A shared environment wants a remote backend with locking. Uncomment and
  # bootstrap the bucket and table out of band (they cannot live in the state
  # they store):
  #
  # backend "s3" {
  #   bucket       = "hivemind-greeter-tfstate"
  #   key          = "greeter/terraform.tfstate"
  #   region       = "eu-central-1"
  #   encrypt      = true
  #   use_lockfile = true   # S3-native locking; supersedes the DynamoDB table
  # }
}
