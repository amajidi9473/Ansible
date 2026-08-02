#!/usr/bin/env bash

set -euo pipefail

# Publish committed project files through GitHub's HTTPS API. This is used
# because standard Git HTTPS traffic is blocked during TLS negotiation here.
repo_name="${GITHUB_REPOSITORY:-amajidi9473/Ansible}"
remote_branch="${GITHUB_BRANCH:-main}"
commit_message="${1:-$(git log -1 --format=%s)}"

required_commands=(awk base64 diff gh git jq rg sort)
for required_command in "${required_commands[@]}"; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "ERROR: required command is missing: $required_command" >&2
    exit 1
  fi
done

repository_root=$(git rev-parse --show-toplevel)
cd "$repository_root"

if [[ -n $(git status --porcelain -- provision) ]]; then
  echo "ERROR: provision/ contains uncommitted changes." >&2
  echo "Review, stage, and commit them before publishing." >&2
  git status --short -- provision >&2
  exit 1
fi

if ! gh auth status --hostname github.com >/dev/null 2>&1; then
  echo "ERROR: GitHub CLI is not authenticated." >&2
  echo "Run: gh auth login --hostname github.com --web" >&2
  exit 1
fi

tracked_files=$(git ls-tree -r --name-only HEAD -- provision)
if [[ -z "$tracked_files" ]]; then
  echo "ERROR: HEAD has no tracked files under provision/." >&2
  exit 1
fi

if printf '%s\n' "$tracked_files" \
  | rg -q '^provision/(inventory/myhost|group_vars/devices/vault\.yml)$'; then
  echo "ERROR: myhost or vault.yml is tracked in HEAD; publication stopped." >&2
  exit 1
fi

remote_commit=$(
  gh api "repos/$repo_name/git/ref/heads/$remote_branch" --jq '.object.sha'
)

echo "Publishing committed files from $(git rev-parse --short HEAD)"
echo "Repository: $repo_name"
echo "Branch:     $remote_branch"
echo "Parent:     $remote_commit"

tree_items='[]'
while IFS= read -r tracked_path; do
  encoded_content=$(git show "HEAD:$tracked_path" | base64 -w 0)
  blob_sha=$(
    gh api --method POST "repos/$repo_name/git/blobs" \
      -f content="$encoded_content" \
      -f encoding='base64' \
      --jq '.sha'
  )
  file_mode=$(git ls-tree HEAD -- "$tracked_path" | awk '{print $1}')
  tree_items=$(
    jq --arg path "$tracked_path" --arg mode "$file_mode" --arg sha "$blob_sha" \
      '. + [{path:$path, mode:$mode, type:"blob", sha:$sha}]' \
      <<< "$tree_items"
  )
done <<< "$tracked_files"

tree_sha=$(
  jq -n --argjson tree "$tree_items" '{tree:$tree}' \
    | gh api --method POST "repos/$repo_name/git/trees" --input - --jq '.sha'
)

new_commit=$(
  jq -n \
    --arg message "$commit_message" \
    --arg tree "$tree_sha" \
    --arg parent "$remote_commit" \
    '{message:$message, tree:$tree, parents:[$parent]}' \
    | gh api --method POST "repos/$repo_name/git/commits" --input - --jq '.sha'
)

# force:false makes GitHub reject the update if main changed after it was read.
jq -n --arg sha "$new_commit" '{sha:$sha, force:false}' \
  | gh api --method PATCH \
      "repos/$repo_name/git/refs/heads/$remote_branch" --input - >/dev/null

published_files=$(
  gh api "repos/$repo_name/git/trees/$tree_sha?recursive=1" \
    --jq '.tree[] | select(.type == "blob") | .path' \
    | sort
)

if ! diff -u \
  <(printf '%s\n' "$tracked_files" | sort) \
  <(printf '%s\n' "$published_files"); then
  echo "ERROR: remote file verification failed." >&2
  exit 1
fi

if printf '%s\n' "$published_files" \
  | rg -q '^provision/(inventory/myhost|group_vars/devices/vault\.yml)$'; then
  echo "ERROR: a protected file appeared in the published tree." >&2
  exit 1
fi

echo "Published successfully: $new_commit"
echo "https://github.com/$repo_name/tree/$remote_branch/provision"
