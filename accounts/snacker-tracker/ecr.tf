# The apps' Lambda container image repositories. Each app has one repository
# shared by all its environments, which is why it lives here and not in the
# app: no single environment's state can own it, and it must exist before
# the app's first deploy.
#
# Both apps' deploys tag the image they deploy `<environment>-<UTC time>`,
# on top of its build tag (commit SHA for interface, CI run number for
# reporter-serverless). Prod may run an older image than dev, so an image is
# kept while it's among its environment's latest deploys: a rule can't
# expire an image a higher-priority rule matched.

locals {
  lambda_repositories = {
    "snacker-tracker-lambda/interface" = {
      component            = "interface"
      image_tag_mutability = "IMMUTABLE"
      # In rule priority order.
      keep_deploys = [{ environment = "prod", count = 5 }, { environment = "dev", count = 3 }]
      keep_other   = 10
      # Scoped to these functions rather than the whole account, as
      # interface defined it.
      lambda_functions = "snacker-tracker-*"
    }

    "snacker-tracker-lambda/append-to-bronze" = {
      # reporter-serverless's; its deploy role can push to anything under
      # snacker-tracker-lambda* (app_roles.tf).
      component            = "reporter-serverless"
      image_tag_mutability = "MUTABLE"
      keep_deploys         = [{ environment = "prod", count = 5 }, { environment = "dev", count = 3 }]
      keep_other           = 10
      lambda_functions     = null
    }
  }

  untagged_image_days = 7
}

resource "aws_ecr_repository" "lambda" {
  for_each = local.lambda_repositories
  provider = aws.app

  name                 = each.key
  image_tag_mutability = each.value.image_tag_mutability

  tags = {
    Component = each.value.component
  }

  image_scanning_configuration {
    scan_on_push = true
  }

  lifecycle {
    # Holds the images prod runs.
    prevent_destroy = true
  }
}

# Lambda pulls the image with its own service identity, not the caller's,
# so it needs this resource-based grant whatever the deploy role's own IAM
# permissions. Scoped to lambda_functions where set, otherwise to this
# account. The Sids differ only because the two policies were written
# separately.
data "aws_iam_policy_document" "lambda_pull" {
  for_each = local.lambda_repositories

  statement {
    sid     = each.value.lambda_functions == null ? "AllowLambdaPull" : "LambdaPulls"
    actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }

    dynamic "condition" {
      for_each = each.value.lambda_functions == null ? [] : [1]

      content {
        test     = "ArnLike"
        variable = "aws:SourceArn"
        values   = ["arn:aws:lambda:${local.app_region}:${local.account_id}:function:${each.value.lambda_functions}"]
      }
    }

    dynamic "condition" {
      for_each = each.value.lambda_functions == null ? [1] : []

      content {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }
    }
  }
}

resource "aws_ecr_repository_policy" "lambda" {
  for_each = local.lambda_repositories
  provider = aws.app

  repository = aws_ecr_repository.lambda[each.key].name
  policy     = data.aws_iam_policy_document.lambda_pull[each.key].json
}

resource "aws_ecr_lifecycle_policy" "lambda" {
  for_each = local.lambda_repositories
  provider = aws.app

  repository = aws_ecr_repository.lambda[each.key].name

  policy = jsonencode({
    rules = concat(
      [
        for i, keep in each.value.keep_deploys : {
          rulePriority = i + 1
          description  = "Keep the images of ${keep.environment}'s last ${keep.count} deploys"
          selection = {
            tagStatus     = "tagged"
            tagPrefixList = ["${keep.environment}-"]
            countType     = "imageCountMoreThan"
            countNumber   = keep.count
          }
          action = {
            type = "expire"
          }
        }
      ],
      [
        {
          rulePriority = length(each.value.keep_deploys) + 1
          description  = "Keep the ${each.value.keep_other} newest of the other tagged images"
          selection = {
            tagStatus      = "tagged"
            tagPatternList = ["*"]
            countType      = "imageCountMoreThan"
            countNumber    = each.value.keep_other
          }
          action = {
            type = "expire"
          }
        },
        {
          rulePriority = length(each.value.keep_deploys) + 2
          description  = "Expire untagged images after ${local.untagged_image_days} days"
          selection = {
            tagStatus   = "untagged"
            countType   = "sinceImagePushed"
            countUnit   = "days"
            countNumber = local.untagged_image_days
          }
          action = {
            type = "expire"
          }
        },
      ],
    )
  })
}

import {
  for_each = local.lambda_repositories
  provider = aws.app
  to       = aws_ecr_repository.lambda[each.key]
  id       = each.key
}

import {
  for_each = local.lambda_repositories
  provider = aws.app
  to       = aws_ecr_repository_policy.lambda[each.key]
  id       = each.key
}

import {
  for_each = local.lambda_repositories
  provider = aws.app
  to       = aws_ecr_lifecycle_policy.lambda[each.key]
  id       = each.key
}
