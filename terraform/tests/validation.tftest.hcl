# Variable validation rules.
#
# These assert the guards actually reject bad input. A validation block nobody
# tests is a comment: it is easy to write one whose regex never matches, and the
# failure mode is silent acceptance of the thing you meant to forbid.
#
# Everything here runs with `command = plan` against a mocked provider, so the
# suite needs no AWS credentials and creates nothing.

mock_provider "aws" {
  # Generated placeholders are random strings, which fail the provider's own
  # format checks for JSON policies and ARNs long before any assertion runs.
  # These defaults are shaped correctly but carry no meaning — nothing under
  # test asserts on them.
  mock_data "aws_iam_policy_document" {
    defaults = {
      json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}"
    }
  }

  mock_data "aws_partition" {
    defaults = {
      partition          = "aws"
      dns_suffix         = "amazonaws.com"
      reverse_dns_prefix = "com.amazonaws"
    }
  }

  mock_data "aws_caller_identity" {
    defaults = {
      account_id = "123456789012"
      arn        = "arn:aws:iam::123456789012:user/test"
      user_id    = "AIDAEXAMPLETESTONLY00"
    }
  }

  mock_data "aws_iam_session_context" {
    defaults = {
      issuer_arn = "arn:aws:iam::123456789012:user/test"
    }
  }

  mock_data "aws_region" {
    defaults = {
      name   = "eu-central-1"
      region = "eu-central-1"
    }
  }

  mock_data "aws_availability_zones" {
    defaults = {
      names = ["eu-central-1a", "eu-central-1b", "eu-central-1c", "eu-central-1d"]
    }
  }
}

mock_provider "helm" {}
mock_provider "kubernetes" {}

variables {
  github_repository = "acme/greeter"
}

run "rejects_uppercase_project_name" {
  command = plan

  variables {
    project_name = "Hivemind-Greeter"
  }

  expect_failures = [var.project_name]
}

run "rejects_project_name_starting_with_a_digit" {
  command = plan

  variables {
    project_name = "9greeter"
  }

  expect_failures = [var.project_name]
}

run "rejects_malformed_vpc_cidr" {
  command = plan

  variables {
    vpc_cidr = "10.0.0.0/33"
  }

  expect_failures = [var.vpc_cidr]
}

run "rejects_single_az" {
  command = plan

  # One AZ is not a highly available deployment, and the zone spread constraint
  # would be meaningless.
  variables {
    az_count = 1
  }

  expect_failures = [var.az_count]
}

run "rejects_more_azs_than_the_cidr_plan_supports" {
  command = plan

  variables {
    az_count = 5
  }

  expect_failures = [var.az_count]
}

run "rejects_malformed_github_repository" {
  command = plan

  variables {
    github_repository = "not-an-owner-slash-repo"
  }

  expect_failures = [var.github_repository]
}

run "rejects_unscoped_oidc_trust" {
  command = plan

  # The single most dangerous misconfiguration in this repository: a bare "*"
  # here makes the deploy role assumable from ANY repository on GitHub.
  variables {
    github_deploy_subjects = ["*"]
  }

  expect_failures = [var.github_deploy_subjects]
}

run "rejects_empty_oidc_trust" {
  command = plan

  # An empty subject list produces a trust policy with no sub condition at all,
  # which is the same hole by a different route.
  variables {
    github_deploy_subjects = []
  }

  expect_failures = [var.github_deploy_subjects]
}

run "rejects_malformed_alert_email" {
  command = plan

  variables {
    alert_email = "not-an-email"
  }

  expect_failures = [var.alert_email]
}

run "rejects_non_semver_chart_version" {
  command = plan

  # A floating chart version would let the cluster's ingress layer change
  # underneath an unrelated apply.
  variables {
    alb_controller_chart_version = "3.5"
  }

  expect_failures = [var.alb_controller_chart_version]
}

run "accepts_the_defaults" {
  command = plan

  # The converse check: with nothing overridden, every validation passes. Without
  # this, a validation tightened too far would only show up at apply time.
}
