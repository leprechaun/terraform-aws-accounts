# Activates specific tag keys as AWS cost allocation tags — a separate,
# payer-account-level step from just applying the tags themselves (already
# done via default_tags in providers.tf) or standardizing their casing
# (tag_policies.tf). Activation is what makes Cost Explorer/Cost Categories
# able to group and filter by these keys; it has no effect on the CUR 2.0
# exports in cost_exports.tf, which already include all resource tags
# regardless of activation.
#
# AWS only lets a key be activated once it's actually seen tagged on a
# billed resource — since these three are already applied everywhere via
# default_tags, that's satisfied already, not a bootstrapping concern like
# the imports elsewhere in this repo.
#
# ManagedBy/Repository (the other two keys enforced by tag_policies.tf)
# are deliberately not included here: they don't vary in a way that's
# useful as a cost-breakdown dimension (ManagedBy is always "terraform";
# Repository is a fixed URL per repo, redundant with Project/Component).

resource "aws_ce_cost_allocation_tag" "project" {
  tag_key = "Project"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "component" {
  tag_key = "Component"
  status  = "Active"
}

resource "aws_ce_cost_allocation_tag" "environment" {
  tag_key = "Environment"
  status  = "Active"
}

# AWS-generated, not user-defined — same activation mechanism, but AWS sets
# the value itself (the ARN of the IAM principal/role session that created
# the resource) rather than reading it from a tags block. Two things that
# don't apply to the three keys above:
#  - Not retroactive: only resources created after this activates get a
#    value. Nothing already provisioned will backfill one.
#  - Not every service supports it; coverage is AWS's own list, not
#    something this repo controls.
# Useful here specifically because so many identities can create resources
# across these repos (the plan/apply CI roles, Identity Center sessions,
# OrganizationAccountAccessRole) — this is what answers "which one made
# this" after the fact.
resource "aws_ce_cost_allocation_tag" "created_by" {
  tag_key = "aws:createdBy"
  status  = "Active"
}
