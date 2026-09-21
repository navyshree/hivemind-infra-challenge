resource "aws_ecr_repository" "greeter" {
  name = local.name

  # Immutable tags mean a given tag can never be repointed at different bytes.
  # Combined with tagging images by commit SHA, this makes "which code is in
  # production" answerable from the tag alone, and removes a supply-chain
  # rewrite vector.
  image_tag_mutability = "IMMUTABLE"

  # Note what this does and does not buy you.
  #
  # ECR BASIC scanning reads OS packages only. This image is FROM scratch, so
  # it has no OS and no package manager, and a scan against it fails outright:
  #   UnsupportedImageError: The operating system and/or package manager are
  #   not supported.
  # (Verified against this registry, not inferred.) Leaving the flag on with
  # BASIC scanning is therefore worse than leaving it off — the console reports
  # scanning as enabled and no finding is ever produced.
  #
  # It is kept true because it becomes meaningful the moment the registry is
  # switched to ENHANCED scanning (Amazon Inspector), which does read
  # language-level dependencies including Go binaries. See
  # var.enable_enhanced_scanning in variables.tf.
  #
  # Until then the real control is Trivy, which scans the Go binary's embedded
  # module list and gates CI on HIGH/CRITICAL. The gap Trivy cannot cover is
  # CVEs disclosed *after* build time; only registry rescanning catches those.
  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    # AES256 uses an AWS-owned key at no cost. Switch to KMS with a
    # customer-managed key where key rotation and access must be auditable.
    encryption_type = "AES256"
  }

  # The repository is disposable: images are rebuilt from source by CI, so a
  # destroy should not be blocked by remaining tags.
  force_delete = true

  tags = local.tags
}

# Registry-wide, and billable, so it is opt-in rather than on by default.
#
# Enhanced scanning is the correct answer for a distroless or scratch image:
# Inspector inspects language package manifests and Go binaries, where BASIC
# scanning can only see OS packages. It also rescans continuously, which is the
# one thing a build-time Trivy gate structurally cannot do.
#
# Scope: this configures the whole registry for the account, not just this
# repository, which is why it is not enabled by default in someone else's
# account. Cost is roughly USD 0.09 per image scanned per month plus rescans.
resource "aws_ecr_registry_scanning_configuration" "this" {
  count = var.enable_enhanced_scanning ? 1 : 0

  scan_type = "ENHANCED"

  rule {
    scan_frequency = "CONTINUOUS_SCAN"
    repository_filter {
      filter      = "*"
      filter_type = "WILDCARD"
    }
  }
}

resource "aws_ecr_lifecycle_policy" "greeter" {
  repository = aws_ecr_repository.greeter.name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images after 1 day"
        selection = {
          tagStatus   = "untagged"
          countType   = "sinceImagePushed"
          countUnit   = "days"
          countNumber = 1
        }
        action = { type = "expire" }
      },
      {
        rulePriority = 2
        description  = "Retain only the most recent ${var.ecr_image_retention_count} images"
        selection = {
          tagStatus   = "any"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_image_retention_count
        }
        action = { type = "expire" }
      },
    ]
  })
}
