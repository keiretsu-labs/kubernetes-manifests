#!/bin/sh
set -eu

issue_body_file=${1:-}

if [ -n "$issue_body_file" ]; then
  issue_body=$(cat "$issue_body_file")
else
  : "${GH_TOKEN:?GH_TOKEN is required when no issue body file is supplied}"
  repository=${GITHUB_REPOSITORY:-keiretsu-labs/kubernetes-manifests}
  issue_number=${RENOVATE_DASHBOARD_ISSUE:-150}
  issue_body=$(gh api "repos/${repository}/issues/${issue_number}" --jq .body)
fi

matched=0
for marker in \
  'No docker auth found' \
  'Package lookup failures' \
  'Failed to look up docker package' \
  'Could not determine new digest'; do
  if printf '%s\n' "$issue_body" | grep -Fq "$marker"; then
    printf 'Renovate dashboard failure: %s\n' "$marker"
    matched=1
  fi
done

if [ "$matched" -ne 0 ]; then
  printf '%s\n' 'Renovate dashboard check failed; dependency coverage is degraded.'
  exit 1
fi

printf '%s\n' 'Renovate dashboard check passed; no auth or lookup failures reported.'
