#!/usr/bin/env bash
# Keeps this fork in sync with upstream G-Helper and rebuilds every upstream release with the fork's changes.
#
#   sync.sh check   decide whether there's work (writes work=true|false to $GITHUB_OUTPUT)
#   sync.sh run     merge upstream, let the agent fix conflicts or build breaks, verify, push, release
#
# Env: GH_TOKEN (issues, releases), SYNC_TOKEN (push; needs workflow permission since upstream edits workflows),
#      OPENCODE_CLIENT_ID (agent sign-in via GitHub OIDC) or OPENCODE_API_KEY, MANUAL, DRY_RUN, FORCE_RELEASE, TEST_AGENT (true|false)
set -euo pipefail

UPSTREAM=seerge/g-helper
FORK=${GITHUB_REPOSITORY:-wqin0/g-helper}
MODEL=${SYNC_MODEL:-opencode-go/deepseek-v4.1-flash}
OPENCODE_VERSION=1.19.5
LABEL=sync-blocked
DIR=$(cd "$(dirname "$0")" && pwd)
TMP=${RUNNER_TEMP:-$(mktemp -d)}
MANUAL=${MANUAL:-false} DRY_RUN=${DRY_RUN:-false} FORCE_RELEASE=${FORCE_RELEASE:-false} TEST_AGENT=${TEST_AGENT:-false}
[ "$TEST_AGENT" = true ] && DRY_RUN=true
VERSION=""

out() { echo "$1"; [ -z "${GITHUB_OUTPUT:-}" ] || echo "$1" >> "$GITHUB_OUTPUT"; }

version_gt() { [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "$1" "$2" | sort -V | tail -n 1)" = "$1" ]; }

# Newest upstream release, pre-releases included
upstream_tag() { gh api "repos/$UPSTREAM/releases?per_page=1" --jq '.[0].tag_name'; }

# Fork releases are <upstream version>.<n>, so v0.291.2 was built from upstream 0.291
need_release() {
  local last
  last=$(gh api "repos/$FORK/releases?per_page=1" --jq '.[0].tag_name // empty')
  [ -z "$last" ] && return 0
  last=${last#v}
  version_gt "${UP_TAG#v}" "${last%.*}"
}

open_issue() { gh issue list -R "$FORK" --label "$LABEL" --state open --json number --jq '.[0].number // empty' 2>/dev/null || true; }

fail() {
  echo "::error::${1%%$'\n'*}"
  echo "$1"
  if [ "$DRY_RUN" != true ]; then
    local body issue
    body="$1"$'\n\n'"Run: ${GITHUB_SERVER_URL:-https://github.com}/$FORK/actions/runs/${GITHUB_RUN_ID:-local}"$'\n\n'"Scheduled syncs are paused while this issue is open. Fix \`main\` (or the workflow), then close the issue to resume. Manual runs ignore the pause."
    issue=$(open_issue)
    if [ -n "$issue" ]; then
      gh issue comment "$issue" -R "$FORK" --body "$body"
    else
      gh label create "$LABEL" -R "$FORK" --color B60205 --description "Upstream sync paused" --force >/dev/null
      gh issue create -R "$FORK" --label "$LABEL" --title "Upstream sync paused" --body "$body"
    fi
  fi
  exit 1
}

build() { dotnet build app/GHelper.sln -c Release -nologo -v q > "$TMP/build.log" 2>&1; }

missing_required() {
  local file text
  while IFS=$'\t' read -r file text; do
    text=${text%$'\r'}
    { [ -z "$file" ] || [ "${file:0:1}" = "#" ]; } && continue
    grep -qF -- "$text" "$file" 2>/dev/null || echo "$file: $text"
  done < "$DIR/required.txt"
}

# OPENCODE_API_KEY secret if set, otherwise a short-lived key exchanged for this run's GitHub OIDC token
opencode_key() {
  if [ -n "${OPENCODE_API_KEY:-}" ]; then echo "$OPENCODE_API_KEY"; return 0; fi
  [ -n "${OPENCODE_CLIENT_ID:-}" ] && [ -n "${ACTIONS_ID_TOKEN_REQUEST_URL:-}" ] || return 1
  local oidc
  oidc=$(curl -sSf --oauth2-bearer "$ACTIONS_ID_TOKEN_REQUEST_TOKEN" \
    "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=https://opencode.ai/console" | jq -r .value) || return 1
  curl -sSf https://opencode.ai/console/auth/oauth/token \
    -d grant_type=urn:ietf:params:oauth:grant-type:token-exchange \
    -d subject_token_type=urn:ietf:params:oauth:token-type:jwt \
    -d "client_id=$OPENCODE_CLIENT_ID" -d "subject_token=$oidc" | jq -r .access_token
}

agent() {
  local key
  key=$(opencode_key) && [ -n "$key" ] && [ "$key" != null ] ||
    fail "Needs the agent, but couldn't get an OpenCode key (OIDC sign-in failed, or neither OPENCODE_CLIENT_ID nor OPENCODE_API_KEY is set)."$'\n\n'"$1"
  echo "::add-mask::$key"
  command -v opencode >/dev/null || npm install -g --no-fund --no-audit --loglevel=error "opencode-ai@$OPENCODE_VERSION"
  echo "::group::Agent ($MODEL)"
  # Push, GitHub and token-minting credentials stay out of the agent's environment
  env -u SYNC_TOKEN -u GH_TOKEN -u GITHUB_TOKEN -u OPENCODE_CLIENT_ID \
    -u ACTIONS_ID_TOKEN_REQUEST_TOKEN -u ACTIONS_ID_TOKEN_REQUEST_URL -u ACTIONS_RUNTIME_TOKEN \
    OPENCODE_API_KEY="$key" \
    OPENCODE_CONFIG_CONTENT='{"autoupdate":false,"permission":{"webfetch":"deny","websearch":"deny","external_directory":"deny"}}' \
    timeout 1800 opencode run --auto -m "$MODEL" "$(cat "$DIR/agent-prompt.md")"$'\n\n## Task\n\n'"$1" || echo "Agent exited with $?"
  echo "::endgroup::"
}

# Build must pass and fork changes must be intact; the agent gets two tries to fix either
verify() {
  local context=$1 attempt problems missing fixed=false
  for attempt in 1 2 3; do
    problems=""
    build || problems="The build fails. Last lines of the build output:"$'\n```\n'"$(tail -n 60 "$TMP/build.log")"$'\n```'
    missing=$(missing_required)
    [ -z "$missing" ] || problems="$problems"$'\n\n'"These fork changes are missing (file: expected text) and must be restored:"$'\n'"$missing"
    if [ -z "$problems" ]; then
      if [ "$fixed" = true ]; then
        git add -u
        git diff --cached --quiet || git commit -q -m "Fix build after $context"
      fi
      return 0
    fi
    [ "$attempt" = 3 ] && fail "After $context:"$'\n\n'"$problems"
    agent "After $context, this needs fixing:"$'\n\n'"$problems"$'\n\n'"Fix it with the smallest change that keeps upstream behaviour and the fork changes, and stage the files you changed."
    fixed=true
  done
}

merge() {
  local ref=$1 name=$2 files
  if git merge-base --is-ancestor "$ref" HEAD; then echo "Already contains upstream $name"; return 0; fi
  echo "Merging upstream $name"
  if ! git merge --no-edit -m "Merge upstream $name" "$ref"; then
    files=$(git diff --name-only --diff-filter=U | tr '\n' ' ')
    agent "\`git merge\` of upstream $name stopped with conflicts in: $files"$'\n\n'"Resolve every conflict so no conflict markers remain, stage the resolved files with \`git add\`, and make the build pass."
    [ -z "$(git diff --name-only --diff-filter=U)" ] || fail "Unresolved conflicts after merging upstream $name: $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
    # shellcheck disable=SC2086
    ! git grep -nE '^(<<<<<<<|>>>>>>>)( |$)' -- $files || fail "Conflict markers left in $files after merging upstream $name"
    git add -u
    git commit -q --no-edit 2>/dev/null || true # agent may have committed despite the rules
    git merge-base --is-ancestor "$ref" HEAD || fail "Merge of upstream $name was abandoned, upstream isn't in main"
  fi
  verify "merging upstream $name"
}

publish() {
  local base n exe=app/bin/x64/Release/net10.0-windows/win-x64/publish/GHelper.exe
  base=$(sed -n 's:.*<AssemblyVersion>\(.*\)</AssemblyVersion>.*:\1:p' app/GHelper.csproj | head -n 1)
  n=$(gh release list -R "$FORK" -L 500 --json tagName --jq "[.[] | select(.tagName | startswith(\"v$base.\"))] | length")
  VERSION="$base.$((n + 1))"
  RELEASE_SHA=$(git rev-parse HEAD)
  echo "Publishing $VERSION from $RELEASE_SHA"
  dotnet publish app/GHelper.sln -c Release -r win-x64 -p:PublishSingleFile=true --no-self-contained \
    "-p:AssemblyVersion=$VERSION" "-p:FileVersion=$VERSION" -nologo -v q
  mkdir -p "$TMP/release"
  cp "$exe" "$TMP/release/GHelper.exe"
  rm -f "$TMP/release/GHelper.zip"
  pwsh -NoProfile -Command "Compress-Archive -Path '$(cygpath -w "$TMP/release/GHelper.exe")' -DestinationPath '$(cygpath -w "$TMP/release/GHelper.zip")'"
}

push() {
  if [ "$DRY_RUN" = true ]; then echo "Dry run: not pushing $(git rev-parse --short HEAD)"; return 0; fi
  git fetch --quiet origin main
  # Also covers main having moved on during the run with this commit already in it
  if git merge-base --is-ancestor HEAD origin/main; then echo "Nothing to push"; return 0; fi
  [ -n "${SYNC_TOKEN:-}" ] || fail "The SYNC_TOKEN secret isn't set, so the merged upstream changes can't be pushed."
  git push --quiet "https://x-access-token:$SYNC_TOKEN@github.com/$FORK.git" HEAD:main
}

release() {
  local notes
  notes="Upstream [$UP_TAG](https://github.com/$UPSTREAM/releases/tag/$UP_TAG) plus this fork's changes ([what's different](https://github.com/$FORK#what-this-fork-adds)). See the upstream release for what's new."
  if [ "$DRY_RUN" = true ]; then echo "Dry run: would release v$VERSION from $RELEASE_SHA"; ls -l "$TMP/release"; return 0; fi
  gh release create "v$VERSION" "$TMP/release/GHelper.exe" "$TMP/release/GHelper.zip" -R "$FORK" \
    --target "$RELEASE_SHA" --latest --title "GHelper v$VERSION" --notes "$notes"
}

check() {
  if [ "$MANUAL" = true ]; then out work=true; return 0; fi
  if [ -n "$(open_issue)" ]; then echo "Paused: close the open '$LABEL' issue to resume"; out work=false; return 0; fi
  local behind
  behind=$(gh api "repos/$FORK/compare/main...${UPSTREAM%%/*}:main" --jq .ahead_by)
  UP_TAG=$(upstream_tag)
  if [ "$behind" -gt 0 ] || need_release; then
    echo "Upstream has $behind new commits, latest release $UP_TAG"; out work=true
  else
    echo "Up to date with upstream (latest release $UP_TAG)"; out work=false
  fi
}

run() {
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "https://github.com/$UPSTREAM.git"
  git fetch --quiet --no-tags upstream main
  UP_TAG=$(upstream_tag)
  RELEASE_SHA=""

  # Release from the upstream tag itself, so the build matches what upstream shipped
  if need_release; then
    git fetch --quiet --no-tags upstream "refs/tags/$UP_TAG:refs/upstream-tags/$UP_TAG"
    merge "refs/upstream-tags/$UP_TAG" "$UP_TAG"
    publish
  fi

  merge upstream/main main

  if [ "$TEST_AGENT" = true ]; then
    echo "Test: removing a using directive to check the agent can fix the build"
    sed -i '/^using GHelper.Gpu;$/d' app/Input/InputDispatcher.cs
    git commit -q -am "Test: break the build on purpose"
    verify "a test commit that removed a using directive"
    git log --oneline -3
  fi

  [ -n "$RELEASE_SHA" ] || [ "$FORCE_RELEASE" != true ] || publish
  push
  [ -z "$RELEASE_SHA" ] || release
}

case "${1:-run}" in
  check) check ;;
  run) run ;;
  *) echo "usage: $0 check|run" >&2; exit 2 ;;
esac
