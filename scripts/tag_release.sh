#!/usr/bin/env bash
#
# Tags HEAD as the next release. The script suggests the next version from the conventional commits
# since the newest vX.Y.Z tag that HEAD contains, then tags HEAD and pushes the tags in order:
# latest, vX, vX.Y, and vX.Y.Z. If that moved latest, it then commits a README update on HEAD that
# points the examples at the release, and pushes it. Last, it drafts the GitHub release, marked
# Latest only if it moved latest, with notes listing the commits that aren't ci or docs, to publish
# to the Marketplace from the web UI. HEAD must be clean, with no untracked files, and in sync with
# its upstream branch. gh must be logged in.
#
# Usage: scripts/tag_release.sh
#
# The suggestion is major if a commit's subject starts with `<type>!` (like `feat!:` or
# `fix(ci)!:`), minor if one starts with `feat`, and patch otherwise. Press Enter to accept it, or
# enter another version as vX.Y.Z or X.Y.Z. The version must be newer than the release that HEAD
# contains, and must not exist yet.
#
# HEAD is usually on the default branch. To patch an older release line, branch off its floating tag
# (like `git switch -c fix-1.2 v1.2`), then commit and push the fix. Each floating tag moves only
# when the new version is the newest release in its series: a v1.2.4 patch moves v1.2, but not v1 or
# latest if v1.3.0 exists.

set -euo pipefail

die() {
  local -r message="${*}"
  echo "tag_release: ${message}" >&2
  exit 1
}

# The newest vX.Y.Z tag in the given tag names
newest_release() {
  { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -n 1
}

# Whether the first version is newer than the second, which can be empty
is_newer() {
  local -r candidate="${1}" than="${2}"
  if [[ -z ${than} ]]; then
    return 0
  fi
  if [[ ${candidate} == "${than}" ]]; then
    return 1
  fi

  local newer
  newer="$(printf '%s\n' "${than}" "${candidate}" | sort -V | tail -n 1)"
  readonly newer

  [[ ${newer} == "${candidate}" ]]
}

[[ -z "$(git status --porcelain)" ]] || die "There are uncommitted changes or untracked files!"

# Branches, tags, and floating tags as they are on origin, which moves the local floating tags too
git fetch -q --force --tags origin
upstream="$(git rev-parse -q --abbrev-ref '@{upstream}' 2>/dev/null)" ||
  die "HEAD isn't on a branch with an upstream!"
readonly upstream
if [[ "$(git rev-parse HEAD)" != "$(git rev-parse "${upstream}")" ]]; then
  die "HEAD isn't in sync with ${upstream}!"
fi

default_branch="$(git symbolic-ref -q --short refs/remotes/origin/HEAD)" ||
  die "origin's default branch is unknown; run: git remote set-head origin --auto"
readonly default_branch
# also checks that gh can reach the repo before anything is tagged
repo_url="$(gh repo view --json url --jq .url)"
readonly repo_url
if ! git merge-base --is-ancestor HEAD "${default_branch}"; then
  echo "Note: HEAD isn't on ${default_branch}, so this tags a release line or an unmerged branch."
fi

last="$(git tag --list --merged HEAD 'v*' | newest_release)"
readonly last
if [[ -n ${last} ]]; then
  range="${last}..HEAD"
else
  range=HEAD
fi
readonly range
# Skips this script's own README updates, which aren't changes to release
readonly log_filter=(-E --invert-grep
  --grep='^docs: use composite-lint v[0-9.]+ / pre-commit [^ ]+ in the README examples$')

subjects="$(git log --format=%s "${log_filter[@]}" "${range}")"
readonly subjects
[[ -n ${subjects} ]] || die "no commits since ${last}"
echo "Commits since ${last:-the start}:"
git log --format='  %h %s' "${log_filter[@]}" "${range}"
# CI and docs changes alone don't change the action, though breaking ones (`ci!:`) still release
grep -Eqv '^(ci|docs)(\([^)]*\))?:' <<<"${subjects}" || die "only ci and docs commits since ${last}"
changes="$(grep -Ev '^(ci|docs)(\([^)]*\))?:' <<<"${subjects}" | sed 's/^/* /')"
readonly changes

IFS=. read -r major minor patch <<<"${last:-v0.0.0}"
major="${major#v}"
if grep -Eq '^[[:alnum:]_-]+(\([^)]*\))?!:' <<<"${subjects}"; then
  suggested="v$((major + 1)).0.0"
elif grep -Eq '^feat[(:]' <<<"${subjects}"; then
  suggested="v${major}.$((minor + 1)).0"
else
  suggested="v${major}.${minor}.$((patch + 1))"
fi
readonly major minor patch suggested

read -r -p "Version [${suggested}]: " answer
readonly answer
chosen="${answer:-${suggested}}"
readonly chosen
version_pattern='^v?([0-9]+)\.([0-9]+)\.([0-9]+)$'
readonly version_pattern
if [[ ! ${chosen} =~ ${version_pattern} ]]; then
  die "'${chosen}' isn't vX.Y.Z or X.Y.Z"
fi

new_major="v${BASH_REMATCH[1]}"
new_minor="${new_major}.${BASH_REMATCH[2]}"
version="${new_minor}.${BASH_REMATCH[3]}"
readonly new_major new_minor version
is_newer "${version}" "${last}" || die "${version} isn't newer than ${last}"
! git rev-parse -q --verify "refs/tags/${version}" >/dev/null || die "${version} already exists"

# Each floating tag only moves forward: to this release, if it's the newest in the tag's series
moved_latest=false
for tag in latest "${new_major}" "${new_minor}"; do
  if [[ ${tag} == latest ]]; then
    prefix=v
  else
    prefix="${tag}."
  fi

  newest="$(git tag --list "${prefix}*" | newest_release)"
  if is_newer "${version}" "${newest}"; then
    if [[ ${tag} == latest ]]; then
      moved_latest=true
    fi

    git tag -f "${tag}"
    git push -q --force origin "refs/tags/${tag}"
    # Tags pushed in the same second look equally new, so `pre-commit autoupdate` can pick a
    # floating one
    sleep "${TAG_RELEASE_PUSH_DELAY:-2}"
  else
    echo "Leaving ${tag} at ${newest}, which is newer"
  fi
done
readonly moved_latest

git tag "${version}"
git push -q origin "refs/tags/${version}"
echo "Tagged and pushed ${version}"

# Points the README examples at the newest release
update_readme() {
  local hooks_rev hooks_version
  hooks_rev="$(sed -nE 's/^[[:space:]]*rev:[[:space:]]*(.+)$/\1/p' configs/pre-commit.yaml)"
  # the vX.Y.Z from its `# frozen: vX.Y.Z` comment
  hooks_version="${hooks_rev##*frozen: }"
  readonly hooks_rev hooks_version

  sed -E \
    -e "s|(uses: ReadOnlyTech/composite-lint@).*|\1${version}|" \
    -e "\|repo: https://github.com/ReadOnlyTech/composite-lint\$|{n;s|(rev: ).*|\1${version}|;}" \
    -e "\|repo: https://github.com/pre-commit/pre-commit-hooks\$|{n;s|(rev: ).*|\1${hooks_rev}|;}" \
    README.md >README.md.new
  mv README.md.new README.md
  if git diff --quiet HEAD -- README.md; then
    echo "The README already uses composite-lint ${version} / pre-commit ${hooks_version}"
    return
  fi

  git commit -q -m "docs: use composite-lint ${version} / pre-commit ${hooks_version} in the README examples" -- README.md
  git push
  echo "Pushed the README update"
}

if [[ ${moved_latest} == true ]]; then
  update_readme
fi

if [[ -n ${last} ]]; then
  changelog="${repo_url}/compare/${last}...${version}"
else
  changelog="${repo_url}/commits/${version}"
fi
readonly changelog
# A draft, since only the web UI can publish to the Marketplace (it needs a 2FA confirmation)
gh release create "${version}" --draft --verify-tag --title "${version}" --latest="${moved_latest}" \
  --notes "## What's Changed
${changes}


**Full Changelog**: ${changelog}"
echo "Drafted the ${version} release; publish it to the Marketplace from its page above"
