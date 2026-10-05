#!/usr/bin/env bash
# Fails unless an environment of this repo holds its jobs for a reviewer, and admits a release tag and
# no branch:
#   check-release-environment.sh <environment> <tag>
# GitHub creates an environment a job names on first use, with no protection, and an environment that
# admits any ref hands its secrets to a workflow on any branch. Env: GH_TOKEN, GITHUB_REPOSITORY.
set -euo pipefail
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source-path=SCRIPTDIR source=updater-verify.sh
. "$here/updater-verify.sh"

usage="usage: check-release-environment.sh <environment> <tag>"
ENVIRONMENT="${1:?$usage}"
TAG="${2:?$usage}"
REPO="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY must name this repo}"
policy_hint="give it reviewers and the tag policy v*, and no branch policy"
got="$(gh api "repos/$REPO/environments/$ENVIRONMENT" \
  --jq '"\([.protection_rules[]?.type] | join(",")) \(.deployment_branch_policy.custom_branch_policies // false)"')" ||
  fail "$REPO has no environment $ENVIRONMENT, or this token cannot read it: create it, and $policy_hint"
[[ ",${got% *}," == *,required_reviewers,* ]] ||
  fail "environment $ENVIRONMENT has no required reviewers, so a release run would sign without a review"
[ "${got##* }" = true ] || fail "environment $ENVIRONMENT admits other refs than its tags: $policy_hint"
policies="$(gh api "repos/$REPO/environments/$ENVIRONMENT/deployment-branch-policies" \
  --jq '.branch_policies[] | "\(.type) \(.name)"')" || fail "cannot read the policies of environment $ENVIRONMENT"
admitted=""
while read -r type policy; do
  [ -n "$type" ] || continue
  [ "$type" = tag ] || fail "environment $ENVIRONMENT admits the $type $policy: $policy_hint"
  # shellcheck disable=SC2053 # a policy is a glob
  [[ "$TAG" != $policy ]] || admitted=1
done <<<"$policies"
[ -n "$admitted" ] || fail "environment $ENVIRONMENT admits no tag $TAG: $policy_hint"
