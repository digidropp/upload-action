#!/usr/bin/env bash
# Uploads a build to Digidropp and, on pull requests, posts or updates a comment with the
# install link and QR code. Runs inside the composite action (see action.yml), but only needs
# the DD_* variables and the standard GITHUB_* variables, so it can also be run locally.
set -euo pipefail

fail() { echo "::error::$*" >&2; exit 1; }

[ -n "${DD_API_TOKEN:-}" ] || fail "api-token is required. Create one in Digidropp → Settings and store it as a secret."
[ -n "${DD_FILE:-}" ] || fail "file is required, e.g. app/build/outputs/apk/release/*.apk"
[ -n "${DD_API_URL:-}" ] || fail "api-url is required, e.g. https://api.your-domain.com/api"
command -v jq >/dev/null || fail "jq is required"

shopt -s nullglob
# Intentionally unquoted so the glob expands.
# shellcheck disable=SC2206
files=( $DD_FILE )
[ "${#files[@]}" -eq 1 ] || fail "file must match exactly one .apk or .ipa (matched ${#files[@]}): $DD_FILE"
file="${files[0]}"

# --- Git and pull request details --------------------------------------------------------------
branch="${GITHUB_HEAD_REF:-${GITHUB_REF_NAME:-}}"
commit="${GITHUB_SHA:-}"
pr_number=""; pr_title=""; pr_url=""
if [ -n "${GITHUB_EVENT_PATH:-}" ] && [ -f "$GITHUB_EVENT_PATH" ] && jq -e '.pull_request' "$GITHUB_EVENT_PATH" >/dev/null; then
  pr_number="$(jq -r '.pull_request.number' "$GITHUB_EVENT_PATH")"
  pr_title="$(jq -r '.pull_request.title // ""' "$GITHUB_EVENT_PATH")"
  pr_url="$(jq -r '.pull_request.html_url // ""' "$GITHUB_EVENT_PATH")"
  branch="$(jq -r '.pull_request.head.ref // ""' "$GITHUB_EVENT_PATH")"
  commit="$(jq -r '.pull_request.head.sha // ""' "$GITHUB_EVENT_PATH")"
fi

notes="${DD_RELEASE_NOTES:-}"
if [ -z "$notes" ]; then
  if [ -n "$pr_title" ]; then
    notes="$pr_title"
  else
    notes="$(git log -1 --pretty=%B 2>/dev/null || true)"
  fi
fi

# --- Upload ------------------------------------------------------------------------------------
echo "Uploading $file to Digidropp…"
response_file="$(mktemp)"
# --form-string sends text fields literally (plain -F would treat a leading @ or < as a file).
http_code="$(curl -sS -o "$response_file" -w '%{http_code}' -X POST "${DD_API_URL%/}/builds" \
  -H "Authorization: Bearer $DD_API_TOKEN" \
  -F "file=@$file" \
  --form-string "releaseNotes=$notes" \
  --form-string "branch=$branch" \
  --form-string "commit=$commit" \
  --form-string "prNumber=$pr_number" \
  --form-string "prTitle=$pr_title" \
  --form-string "prUrl=$pr_url" \
  --form-string "repo=${GITHUB_REPOSITORY:-}")" || fail "Could not reach $DD_API_URL"

if [ "$http_code" != "201" ]; then
  fail "Upload failed ($http_code): $(jq -r '.error // empty' "$response_file" 2>/dev/null || cat "$response_file")"
fi

r() { jq -r "$1" "$response_file"; }
app_name="$(r '.project.name')"
platform="$(r '.build.platform')"
slug="$(r '.project.slug')"
build_number="$(r '.build.buildNumber')"
version="$(r '.build.versionName') ($(r '.build.buildVersion'))"
install_url="$(r '.links.install')"
build_url="$(r '.links.build')"
qr_url="$(r '.links.qr')"
platform_label="Android"; [ "$platform" = "ios" ] && platform_label="iOS"

echo "✓ Uploaded $app_name $version as build #$build_number"
echo "  This build:  $build_url"
echo "  Latest link: $install_url"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  {
    echo "install-url=$install_url"
    echo "build-url=$build_url"
    echo "qr-url=$qr_url"
  } >> "$GITHUB_OUTPUT"
fi

warnings_md="$(jq -r '.build.warnings[]? | select(.level != "info") | "> ⚠️ " + .message' "$response_file")"

if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
  {
    echo "### 📱 $app_name ($platform_label) · build #$build_number"
    echo "**[Install v$version]($build_url)**"
    [ -n "$warnings_md" ] && printf '\n%s\n' "$warnings_md"
  } >> "$GITHUB_STEP_SUMMARY"
fi

# --- Pull request comment ----------------------------------------------------------------------
if [ -z "$pr_number" ] || [ "${DD_COMMENT:-true}" != "true" ]; then
  exit 0
fi
command -v gh >/dev/null || { echo "::warning::gh CLI not found; skipping PR comment."; exit 0; }

marker="<!-- digidropp-preview:$slug -->"
short_commit="${commit:0:7}"
body="$marker
### 📱 Preview build ready: $app_name ($platform_label)

<img src=\"$qr_url\" width=\"150\" align=\"right\" alt=\"QR code to install this build\" />

**[Install build #$build_number →]($build_url)**
Version $version · commit \`$short_commit\`

Scan the QR code on your phone, or open the link. This comment updates on every push to this pull request.
${warnings_md:+
$warnings_md
}
<sub>Shared with [Digidropp]($install_url). The main install link isn't affected by preview builds.</sub>"

repo="${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is not set}"
existing_id="$(gh api "repos/$repo/issues/$pr_number/comments" --paginate \
  --jq ".[] | select(.body | contains(\"$marker\")) | .id" 2>/dev/null | head -n 1 || true)"

if [ -n "$existing_id" ]; then
  gh api -X PATCH "repos/$repo/issues/comments/$existing_id" -f body="$body" >/dev/null \
    && echo "✓ Updated PR comment" || echo "::warning::Could not update the PR comment. Does the job have pull-requests: write?"
else
  gh api "repos/$repo/issues/$pr_number/comments" -f body="$body" >/dev/null \
    && echo "✓ Posted PR comment" || echo "::warning::Could not comment on the PR. Does the job have pull-requests: write?"
fi
