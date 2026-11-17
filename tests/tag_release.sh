#!/usr/bin/env bash
#
# Runs scripts/tag_release.sh against a throwaway origin, answering its version prompt on stdin, and
# checks its output and where it leaves the tags on origin. Needs only git.

set -o pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
script="${PWD}/scripts/tag_release.sh"
root="$(mktemp -d)"
work="${root}/work"
readonly script root work
trap 'rm -rf "${root}"' EXIT
failures=0

# Independent of the user's git config, like commit signing or hooks
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=test GIT_AUTHOR_EMAIL=test@example.com
export GIT_COMMITTER_NAME=test GIT_COMMITTER_EMAIL=test@example.com
# The script waits between tag pushes, which only matters for real releases
export TAG_RELEASE_PUSH_DELAY=0

fail() {
  local -r message="${*}"
  echo "FAIL: ${message}"
  failures="$((failures + 1))"
}

commit() {
  local -r message="${1}"
  git -C "${work}" commit -q --allow-empty -m "${message}"
}

push() {
  git -C "${work}" push -q -u origin HEAD
}

# Runs the script with the given answer to its prompt, and checks its exit status and that its
# output contains the text
release() {
  local -r description="${1}" answer="${2}" expected="${3}" text="${4}"
  local output
  output="$(cd "${work}" && "${script}" <<<"${answer}" 2>&1)"
  local -r actual="${?}"
  readonly output
  if ((actual != expected)) || [[ ${output} != *"${text}"* ]]; then
    echo "${output}"
    fail "${description}: expected exit ${expected} and '${text}', got ${actual}"
  else
    echo "ok: ${description}"
  fi
}

# Checks that each of the tags points at the revision on origin
tags_at() {
  local -r description="${1}" rev="${2}" tags=("${@:3}")
  local expected
  expected="$(git -C "${work}" rev-parse "${rev}^{commit}")"
  readonly expected
  local tag actual
  for tag in "${tags[@]}"; do
    actual="$(git -C "${work}" ls-remote origin "refs/tags/${tag}" | cut -f1)"
    if [[ ${actual} != "${expected}" ]]; then
      fail "${description}: expected ${tag} on origin at ${rev}, got '${actual}'"
      return
    fi
  done
  echo "ok: ${description}"
}

# Checks the README examples on origin's main, in a commit on top of the tag
readme_at() {
  local -r description="${1}" tag="${2}"
  local readme parent
  readme="$(git -C "${work}" show "origin/main:README.md" 2>&1)"
  parent="$(git -C "${work}" rev-parse origin/main~1)"
  readonly readme parent
  if [[ ${readme} != "uses: ReadOnlyTech/composite-lint@${tag}
  - repo: https://github.com/ReadOnlyTech/composite-lint
    rev: ${tag}
  - repo: https://github.com/pre-commit/pre-commit-hooks
    rev: abc123  # frozen: v6.0.0" ]]; then
    fail "${description}: expected the README examples at ${tag}, got: ${readme}"
  elif [[ ${parent} != "$(git -C "${work}" rev-parse "${tag}^{commit}")" ]]; then
    fail "${description}: expected the README update right after ${tag}"
  else
    echo "ok: ${description}"
  fi
}

# Checks the arguments of the last GitHub release created
github_release() {
  local -r description="${1}" expected="${2}"
  local actual
  actual="$(cat "${GH_LOG}")"
  readonly actual
  if [[ ${actual} != "${expected}" ]]; then
    fail "${description}: expected:
${expected}
got:
${actual}"
  else
    echo "ok: ${description}"
  fi
}

# A stand-in for gh, which gives the repo's URL and logs the arguments of a release
export GH_LOG="${root}/gh-release"
mkdir "${root}/bin"
cat >"${root}/bin/gh" <<'EOF'
#!/usr/bin/env bash
if [[ ${1} == repo ]]; then
  echo https://github.com/ReadOnlyTech/composite-lint
else
  printf '%s\n' "${@}" >"${GH_LOG}"
fi
EOF
chmod +x "${root}/bin/gh"
export PATH="${root}/bin:${PATH}"

git init -q --bare -b main "${root}/origin.git"
git init -q -b main "${work}"
git -C "${work}" remote add origin "${root}/origin.git"
mkdir "${work}/configs"
printf '  - repo: https://github.com/pre-commit/pre-commit-hooks\n    rev: abc123  # frozen: v6.0.0\n' \
  >"${work}/configs/pre-commit.yaml"
printf '%s\n' 'uses: ReadOnlyTech/composite-lint@v0.0.0' \
  '  - repo: https://github.com/ReadOnlyTech/composite-lint' '    rev: v0.0.0' \
  '  - repo: https://github.com/pre-commit/pre-commit-hooks' '    rev: old' >"${work}/README.md"
git -C "${work}" add .
commit 'feat: initial'
push
git -C "${work}" remote set-head origin main

# The main line, where each release that moves latest adds a README commit on top of its tag
release 'the first release starts from 0.0.0' '' 0 'Pushed the README update'
tags_at 'the first release adds every tag' main~1 latest v0 v0.1 v0.1.0
readme_at 'the first release updates the README' v0.1.0
github_release 'the first release links its commits' "release
create
v0.1.0
--draft
--verify-tag
--title
v0.1.0
--latest=true
--notes
## What's Changed
* feat: initial


**Full Changelog**: https://github.com/ReadOnlyTech/composite-lint/commits/v0.1.0"
release 'the README update is not a change to release' '' 1 'no commits since v0.1.0'

commit 'fix: a bug'
commit 'docs: words'
push
release 'fix and docs suggest a patch' '' 0 'Tagged and pushed v0.1.1'
tags_at 'a patch moves the floating tags' main~1 latest v0 v0.1 v0.1.1
tags_at 'a patch leaves the older release' main~4 v0.1.0
github_release 'the release notes leave out docs' "release
create
v0.1.1
--draft
--verify-tag
--title
v0.1.1
--latest=true
--notes
## What's Changed
* fix: a bug


**Full Changelog**: https://github.com/ReadOnlyTech/composite-lint/compare/v0.1.0...v0.1.1"

commit 'feat(ci): thing'
push
release 'an invalid version' 'banana' 1 "'banana' isn't vX.Y.Z or X.Y.Z"
release 'an older version' '0.0.1' 1 "v0.0.1 isn't newer than v0.1.1"
release 'the same version' 'v0.1.1' 1 "v0.1.1 isn't newer than v0.1.1"
release 'a scoped feat suggests a minor' '' 0 'Tagged and pushed v0.2.0'
tags_at 'a minor adds its vX.Y' main~1 latest v0 v0.2 v0.2.0
tags_at 'a minor leaves the older vX.Y' main~3 v0.1

commit 'fix: other'
push
release 'a version without the v' '0.4.0' 0 'Tagged and pushed v0.4.0'
tags_at 'the version without the v' main~1 latest v0 v0.4 v0.4.0

commit 'refactor(lint)!: drop thing'
push
release 'a scoped breaking change suggests a major' '' 0 'Tagged and pushed v1.0.0'
tags_at 'a major adds its vX and vX.Y' main~1 latest v1 v1.0 v1.0.0
tags_at 'a major leaves the older vX' main~3 v0

commit 'fix: x'
commit 'feat: new'
push
release 'a feat after a fix suggests a minor' '' 0 'Tagged and pushed v1.1.0'
readme_at 'a newer release updates the README again' v1.1.0

# A release line: patch 1.0 while 1.1.0 is the newest
git -C "${work}" switch -q -c fix-1.0 v1.0
commit 'fix: backport'
release 'a branch without an upstream' '' 1 "HEAD isn't on a branch with an upstream!"
push
release 'a branch off a floating tag is noted' '' 0 "HEAD isn't on origin/main"
tags_at 'a patch on an older line moves only its vX.Y' fix-1.0 v1.0 v1.0.1
tags_at 'a patch on an older line leaves the newer release' v1.1.0 latest v1 v1.1
github_release "a patch on an older line isn't the latest release" "release
create
v1.0.1
--draft
--verify-tag
--title
v1.0.1
--latest=false
--notes
## What's Changed
* fix: backport


**Full Changelog**: https://github.com/ReadOnlyTech/composite-lint/compare/v1.0.0...v1.0.1"
release 'no commits since the last release' '' 1 'no commits since v1.0.1'
commit 'feat: backported feature'
push
release 'a version that exists on another line' '' 1 'v1.1.0 already exists'
release 'the next patch on an older line' '1.0.2' 0 'Leaving v1 at v1.1.0, which is newer'
tags_at 'the next patch moves its vX.Y again' fix-1.0 v1.0 v1.0.2
readme_at 'a patch on an older line leaves the README' v1.1.0

# Only a clean HEAD, in sync with its upstream, is released
git -C "${work}" switch -q main
commit 'fix: unpushed'
release 'an unpushed commit' '' 1 "HEAD isn't in sync with origin/main!"
push
echo change >>"${work}/README.md"
release 'an uncommitted change' '' 1 'There are uncommitted changes or untracked files!'
git -C "${work}" restore README.md
touch "${work}/untracked"
release 'an untracked file' '' 1 'There are uncommitted changes or untracked files!'
rm "${work}/untracked"
release 'a clean, pushed HEAD' '' 0 'Pushed the README update'
readme_at 'a clean, pushed HEAD updates the README' v1.1.1

commit 'docs: words'
commit 'ci(updater): thing'
push
release 'only ci and docs commits' '' 1 'only ci and docs commits since v1.1.1'
readonly failures

if ((failures)); then
  echo "${failures} failure(s)"
  exit 1
fi
echo 'All passed'
