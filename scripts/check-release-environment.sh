#!/usr/bin/env bash
# Fails unless an environment of this repo holds its jobs for a reviewer other than the one who started
# them, lets no admin bypass that, and admits a release tag and no branch:
#   check-release-environment.sh <environment> <tag>
# GitHub creates an environment a job names on first use, with no protection, and an environment that
# admits any ref hands its secrets to a workflow on any branch. Env: GH_TOKEN, GITHUB_REPOSITORY.
#
# Not checked, because this token cannot read them: whether the signing secrets are also repository or
# organization secrets, and who may push a release tag.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: check-release-environment.sh <environment> <tag>"
ENVIRONMENT="${1:?$usage}"
TAG="${2:?$usage}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name this repo}"
hint="give it reviewers, prevent self-review, allow no admin bypass, and the tag policy v* alone"
got="$(gh api "repos/$REPO/environments/$ENVIRONMENT" --jq '[
  ([.protection_rules[]? | select(.type == "required_reviewers" and ((.reviewers // []) | length) > 0)] | length),
  ([.protection_rules[]? | select(.type == "required_reviewers") | .prevent_self_review == true] | all),
  .can_admins_bypass,
  (.deployment_branch_policy.custom_branch_policies // false)] | map(tostring) | join(" ")')" ||
  fail "$REPO has no environment $ENVIRONMENT, or this token cannot read it: create it, and $hint"
read -r reviewed own_review bypass custom <<<"$got"
[ "$reviewed" != 0 ] ||
  fail "environment $ENVIRONMENT has no required reviewers, so a release run would sign without a review: $hint"
[ "$own_review" = true ] ||
  fail "environment $ENVIRONMENT lets whoever pushed the tag approve its own signing: $hint"
[ "$bypass" = false ] || fail "environment $ENVIRONMENT lets an admin skip its reviewers: $hint"
[ "$custom" = true ] || fail "environment $ENVIRONMENT admits other refs than its tags: $hint"
policies="$(gh api --paginate "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
  --jq '.branch_policies[] | "\(.type) \(.name)"')" || fail "cannot read the policies of environment $ENVIRONMENT"
admitted=""
while read -r type policy; do
  [ -n "$type" ] || continue
  [ "$type" = tag ] || fail "environment $ENVIRONMENT admits the $type $policy: $hint"
  # shellcheck disable=SC2053 # a policy is a glob
  [[ "$TAG" != $policy ]] || admitted=1
done <<<"$policies"
[ -n "$admitted" ] || fail "environment $ENVIRONMENT admits no tag $TAG: $hint"
