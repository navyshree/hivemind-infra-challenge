resource "aws_ecr_repository" "greeter" {
  name = local.name

  # Immutable tags mean a given tag can never be repointed at different bytes.
  # Combined with tagging images by commit SHA, this makes "which code is in
  # production" answerable from the tag alone, and removes a supply-chain
  # rewrite vector.
  image_tag_mutability = "IMMUTABLE"

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
