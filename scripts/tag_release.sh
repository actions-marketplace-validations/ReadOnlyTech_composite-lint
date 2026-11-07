#!/usr/bin/env bash
#
# Tags HEAD as the next release. The script suggests the next version from the conventional commits since the newest
# vX.Y.Z tag that HEAD contains, then tags HEAD and pushes the tags in order: latest, vX, vX.Y, and vX.Y.Z.
#
# Usage: scripts/tag_release.sh
#
# The suggestion is major if a commit's subject starts with `<type>!` (like `feat!:` or `fix(ci)!:`), minor if one
# starts with `feat`, and patch otherwise. Press Enter to accept it, or enter another version as vX.Y.Z or X.Y.Z. The
# version must be newer than the release that HEAD contains, and must not exist yet.
#
# HEAD is usually on the default branch. To patch an older release line, branch off its floating tag (like
# `git switch -c fix-1.2 v1.2`) and commit the fix. Each floating tag moves only when the new version is the newest
# release in its series: a v1.2.4 patch moves v1.2, but not v1 or latest if v1.3.0 exists.

set -euo pipefail

die() {
  local message="${*}"
  readonly message
  echo "tag_release: ${message}" >&2
  exit 1
}

# The newest vX.Y.Z tag in the given tag names
newest_release() {
  { grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true; } | sort -V | tail -n 1
}

# Whether the first version is newer than the second, which can be empty
is_newer() {
  local candidate="${1}" than="${2}"
  readonly candidate than
  [[ -z ${than} ]] || [[ ${candidate} != "${than}" && "$(printf '%s\n' "${than}" "${candidate}" | sort -V | tail -n 1)" == "${candidate}" ]]
}

# Tags and floating tags as they are on origin, which moves the local floating tags too
git fetch -q --force --tags origin
default_branch="$(git symbolic-ref -q --short refs/remotes/origin/HEAD)" ||
  die "origin's default branch is unknown; run: git remote set-head origin --auto"
readonly default_branch
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
subjects="$(git log --format=%s "${range}")"
readonly subjects
[[ -n ${subjects} ]] || die "no commits since ${last}"

echo "Commits since ${last:-the start}:"
git log --format='  %h %s' "${range}"

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
[[ ${answer:-${suggested}} =~ ^v?([0-9]+)\.([0-9]+)\.([0-9]+)$ ]] || die "'${answer}' isn't vX.Y.Z or X.Y.Z"
new_major="v${BASH_REMATCH[1]}"
new_minor="${new_major}.${BASH_REMATCH[2]}"
version="${new_minor}.${BASH_REMATCH[3]}"
readonly new_major new_minor version
is_newer "${version}" "${last}" || die "${version} isn't newer than ${last}"
! git rev-parse -q --verify "refs/tags/${version}" >/dev/null || die "${version} already exists"

# Each floating tag only moves forward: to this release, if it's the newest in the tag's series
for tag in latest "${new_major}" "${new_minor}"; do
  if [[ ${tag} == latest ]]; then
    prefix=v
  else
    prefix="${tag}."
  fi
  newest="$(git tag --list "${prefix}*" | newest_release)"
  if is_newer "${version}" "${newest}"; then
    git tag -f "${tag}"
    git push -q --force origin "refs/tags/${tag}"
    # Tags pushed in the same second look equally new, so `pre-commit autoupdate` can pick a floating one
    sleep "${TAG_RELEASE_PUSH_DELAY:-2}"
  else
    echo "Leaving ${tag} at ${newest}, which is newer"
  fi
done
git tag "${version}"
git push -q origin "refs/tags/${version}"
echo "Tagged and pushed ${version}"
