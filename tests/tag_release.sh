#!/usr/bin/env bash
#
# Runs scripts/tag_release.sh against a throwaway origin, answering its version prompt on stdin, and checks
# its output and where it leaves the tags on origin. Needs only git.

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
  local message="${*}"
  readonly message
  echo "FAIL: ${message}"
  failures="$((failures + 1))"
}

commit() {
  local message="${1}"
  readonly message
  git -C "${work}" commit -q --allow-empty -m "${message}"
}

push_main() {
  git -C "${work}" push -q origin main
}

# Runs the script with the given answer to its prompt, and checks its exit status and that its output contains the text
release() {
  local description="${1}" answer="${2}" expected="${3}" text="${4}" output actual
  output="$(cd "${work}" && "${script}" <<<"${answer}" 2>&1)"
  actual="${?}"
  readonly description answer expected text output actual
  if ((actual != expected)) || [[ ${output} != *"${text}"* ]]; then
    echo "${output}"
    fail "${description}: expected exit ${expected} and '${text}', got ${actual}"
  else
    echo "ok: ${description}"
  fi
}

# Checks that each of the tags points at the revision on origin
tags_at() {
  local description="${1}" rev="${2}" tags=("${@:3}") expected tag actual
  expected="$(git -C "${work}" rev-parse "${rev}^{commit}")"
  readonly description rev tags expected
  for tag in "${tags[@]}"; do
    actual="$(git -C "${work}" ls-remote origin "refs/tags/${tag}" | cut -f1)"
    if [[ ${actual} != "${expected}" ]]; then
      fail "${description}: expected ${tag} on origin at ${rev}, got '${actual}'"
      return
    fi
  done
  echo "ok: ${description}"
}

git init -q --bare -b main "${root}/origin.git"
git init -q -b main "${work}"
git -C "${work}" remote add origin "${root}/origin.git"
commit 'feat: initial'
push_main
git -C "${work}" remote set-head origin main

# The main line
release 'the first release starts from 0.0.0' '' 0 'Tagged and pushed v0.1.0'
tags_at 'the first release adds every tag' main latest v0 v0.1 v0.1.0
release 'no commits since the last release' '' 1 'no commits since v0.1.0'

commit 'fix: a bug'
commit 'docs: words'
push_main
release 'fix and docs suggest a patch' '' 0 'Tagged and pushed v0.1.1'
tags_at 'a patch moves the floating tags' main latest v0 v0.1 v0.1.1
tags_at 'a patch leaves the older release' main~2 v0.1.0

commit 'feat(ci): thing'
push_main
release 'an invalid version' 'banana' 1 "'banana' isn't vX.Y.Z or X.Y.Z"
release 'an older version' '0.0.1' 1 "v0.0.1 isn't newer than v0.1.1"
release 'the same version' 'v0.1.1' 1 "v0.1.1 isn't newer than v0.1.1"
release 'a scoped feat suggests a minor' '' 0 'Tagged and pushed v0.2.0'
tags_at 'a minor adds its vX.Y' main latest v0 v0.2 v0.2.0
tags_at 'a minor leaves the older vX.Y' main~1 v0.1

commit 'fix: other'
push_main
release 'a version without the v' '0.4.0' 0 'Tagged and pushed v0.4.0'
tags_at 'the version without the v' main latest v0 v0.4 v0.4.0

commit 'refactor(lint)!: drop thing'
push_main
release 'a scoped breaking change suggests a major' '' 0 'Tagged and pushed v1.0.0'
tags_at 'a major adds its vX and vX.Y' main latest v1 v1.0 v1.0.0
tags_at 'a major leaves the older vX' main~1 v0

commit 'fix: x'
commit 'feat: new'
push_main
release 'a feat after a fix suggests a minor' '' 0 'Tagged and pushed v1.1.0'

# A release line: patch 1.0 while 1.1.0 is the newest, without pushing the branch
git -C "${work}" switch -q -c fix-1.0 v1.0
commit 'fix: backport'
release 'a branch off a floating tag is noted' '' 0 "HEAD isn't on origin/main"
tags_at 'a patch on an older line moves only its vX.Y' fix-1.0 v1.0 v1.0.1
tags_at 'a patch on an older line leaves the newer release' v1.1.0 latest v1 v1.1
commit 'feat: backported feature'
release 'a version that exists on another line' '' 1 'v1.1.0 already exists'
release 'the next patch on an older line' '1.0.2' 0 'Leaving v1 at v1.1.0, which is newer'
tags_at 'the next patch moves its vX.Y again' fix-1.0 v1.0 v1.0.2
readonly failures

if ((failures)); then
  echo "${failures} failure(s)"
  exit 1
fi
echo 'All passed'
