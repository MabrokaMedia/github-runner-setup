#!/bin/bash
# Roll out rust-s3-cache migration across all Rust workflows.
# One branch + PR per repo. Safe to re-run — skips repos where chore/s3-rust-cache already exists.

set -euo pipefail

GITHUB_ROOT="/c/Users/Belabed/Documents/GitHub"
MIGRATE="${GITHUB_ROOT}/github-runner-setup/migrate-workflow.py"
BRANCH="chore/s3-rust-cache"

# Repos (path relative to GITHUB_ROOT : workflow files to migrate, space-separated)
declare -A REPOS=(
  [davoxi-calendar-business]="ci.yml deploy.yml"
  [davoxi-auth-broker-business]="ci.yml deploy.yml"
  [davoxi-zendit-business]="ci.yml deploy.yml"
  [davoxi-dingconnect-business]="ci.yml deploy.yml"
  [davoxi-tremendous-business]="ci.yml deploy.yml"
  [davoxi/davoxi-backend]="ci.yml deploy-rust.yml"
  [davoxi/voice-ai-platform]="ci.yml deploy.yml"
  [parlo-businesses/davoxi-payments-stripe-reference]="ci.yml deploy.yml"
  [parlo-businesses/davoxi-messaging-business]="ci.yml deploy.yml"
  [parlo-businesses/davoxi-yango-business]="deploy.yml"
  [parlo-businesses/davoxi-bolt-business]="deploy.yml"
  [parlo-businesses/davoxi-ticketmaster-business]="ci.yml deploy.yml"
  [parlo-businesses/davoxi-uber-business]="deploy.yml"
  [parlo-businesses/davoxi-services-business]="deploy.yml"
  [parlo-businesses/davoxi-stripe-identity-business]="ci.yml deploy.yml"
  [parlo-businesses/davoxi-travel-business]="deploy.yml"
  [parlo-businesses/davoxi-france-business]="ci.yml deploy.yml"
  [parlo-businesses/davoxi-certn-business]="ci.yml deploy.yml"
  [parlo-businesses/davoxi-payments-business]="ci.yml deploy.yml"
  [parlo-businesses/davoxi-certify-os-business]="ci.yml deploy.yml"
  [parlo-businesses/davoxi-manloop-business]="ci.yml deploy.yml"
  [recombe/recombe-api]="deploy.yml"
)

# Ordered list (bash arrays don't guarantee key order; explicit list for predictable output)
ORDER=(
  davoxi-calendar-business
  davoxi-auth-broker-business
  davoxi-zendit-business
  davoxi-dingconnect-business
  davoxi-tremendous-business
  davoxi/davoxi-backend
  davoxi/voice-ai-platform
  parlo-businesses/davoxi-payments-stripe-reference
  parlo-businesses/davoxi-messaging-business
  parlo-businesses/davoxi-yango-business
  parlo-businesses/davoxi-bolt-business
  parlo-businesses/davoxi-ticketmaster-business
  parlo-businesses/davoxi-uber-business
  parlo-businesses/davoxi-services-business
  parlo-businesses/davoxi-stripe-identity-business
  parlo-businesses/davoxi-travel-business
  parlo-businesses/davoxi-france-business
  parlo-businesses/davoxi-certn-business
  parlo-businesses/davoxi-payments-business
  parlo-businesses/davoxi-certify-os-business
  parlo-businesses/davoxi-manloop-business
  recombe/recombe-api
)

process_repo() {
  local repo="$1"
  local workflows="$2"
  local dir="${GITHUB_ROOT}/${repo}"

  echo ""
  echo "═══════════════════════════════════════════════════════════════"
  echo " $repo"
  echo "═══════════════════════════════════════════════════════════════"

  if [[ ! -d "$dir/.git" ]]; then
    echo "SKIP: not a git repo"
    return
  fi

  cd "$dir"

  # Determine default branch
  local default_branch
  default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "")
  if [[ -z "$default_branch" ]]; then
    git remote set-head origin -a >/dev/null 2>&1 || true
    default_branch=$(git symbolic-ref refs/remotes/origin/HEAD 2>/dev/null | sed 's@^refs/remotes/origin/@@' || echo "master")
  fi
  echo "default branch: $default_branch"

  # Make sure default branch is fresh
  git fetch origin "$default_branch" --quiet

  # Check if branch already exists on remote
  if git ls-remote --exit-code --heads origin "$BRANCH" >/dev/null 2>&1; then
    echo "SKIP: $BRANCH already exists on remote"
    return
  fi

  # Check for uncommitted changes to workflow files that might interfere
  local dirty
  dirty=$(git status --porcelain ".github/workflows/" 2>/dev/null || true)
  if [[ -n "$dirty" ]]; then
    echo "WARN: uncommitted changes in .github/workflows/ — skipping to be safe"
    echo "$dirty"
    return
  fi

  # Create branch from the fresh default branch without disturbing current branch
  git worktree add --quiet --detach "/tmp/wt-$(basename "$repo")" "origin/$default_branch" 2>/dev/null || true
  local wt="/tmp/wt-$(basename "$repo")"

  # Run migration in the worktree
  cd "$wt"
  git switch -c "$BRANCH"

  local any_migrated=0
  for wf in $workflows; do
    local path=".github/workflows/$wf"
    if [[ -f "$path" ]]; then
      if grep -q "Swatinem/rust-cache@v2" "$path"; then
        python3 "$MIGRATE" "$path"
        any_migrated=1
      else
        echo "SKIP: $path has no Swatinem/rust-cache@v2"
      fi
    else
      echo "SKIP: $path not found"
    fi
  done

  if [[ "$any_migrated" -eq 0 ]]; then
    echo "nothing to migrate in $repo"
    cd "$GITHUB_ROOT"
    git worktree remove --force "$wt" 2>/dev/null || true
    return
  fi

  git add .github/workflows/
  git commit -m "chore(ci): swap Swatinem/rust-cache for S3-backed cache

Runner egress was ~\$147/mo because GitHub Actions cache uploads to Azure
Blob Storage (outbound internet from EC2). Swap to the rust-s3-cache
composite action so cargo caches go to s3://mabroka-ci-cache in us-east-1
(same region as the runners → \$0 transfer).

Same pattern already validated on davoxi-search-business — first run MISS,
second run HIT with full incremental compile in ~3s.

Co-Authored-By: Claude Opus 4.7 (1M context) <noreply@anthropic.com>" --quiet

  git push -u origin "$BRANCH" --quiet

  gh pr create --title "chore(ci): swap Swatinem/rust-cache for S3-backed cache" \
    --body "## Summary
- Replace \`Swatinem/rust-cache@v2\` with \`MabrokaMedia/github-runner-setup/rust-s3-cache/restore + save\`.
- Cargo target + registry caches now land in \`s3://mabroka-ci-cache\` (us-east-1, same region as the runners) so the 54 GB/day of outbound egress goes to zero.

Part of the cross-org rollout — same pattern verified on [davoxi-search-business#1](https://github.com/MabrokaMedia/davoxi-search-business/pull/1).

🤖 Generated with [Claude Code](https://claude.com/claude-code)" \
    --base "$default_branch" >/dev/null

  echo "OK: PR opened for $repo"

  cd "$GITHUB_ROOT"
  git worktree remove --force "$wt" 2>/dev/null || true
}

for repo in "${ORDER[@]}"; do
  workflows="${REPOS[$repo]}"
  process_repo "$repo" "$workflows" || echo "FAILED: $repo (continuing)"
done

echo ""
echo "DONE"
