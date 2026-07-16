resource "aws_ecr_repository" "backend" {
  name                 = "${var.name_prefix}-backend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = false }
  tags = { Name = "${var.name_prefix}-backend" }
}

resource "aws_ecr_repository" "frontend" {
  name                 = "${var.name_prefix}-frontend"
  image_tag_mutability = "MUTABLE"
  image_scanning_configuration { scan_on_push = false }
  tags = { Name = "${var.name_prefix}-frontend" }
}

resource "aws_ecr_lifecycle_policy" "backend" {
  repository = aws_ecr_repository.backend.name
  policy = jsonencode({
    rules = [{ rulePriority = 1, description = "Keep last 5 images",
      selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 },
      action = { type = "expire" } }]
  })
}

resource "aws_ecr_lifecycle_policy" "frontend" {
  repository = aws_ecr_repository.frontend.name
  policy = jsonencode({
    rules = [{ rulePriority = 1, description = "Keep last 5 images",
      selection = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 5 },
      action = { type = "expire" } }]
  })
}
