#!/usr/bin/env bash
#
# Runs bin/lint.sh against the fixtures:
#   tests/pass/            everything is detected and lints clean
#   tests/fail/<lang>/<case>/  linting <lang> fails, with output matching the regex in <case>/expect
#
# Expects the tools to be installed already (bin/lint.sh install).

set -o pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 2
lint=bin/lint.sh
readonly lint
failures=0

# plain output so expectations don't depend on CI annotation formats
unset GITHUB_ACTIONS
# this repo's .composite-lint.yml excludes tests/fail, which is exactly what these lint
export LINT_CONFIG_FILE=/dev/null
# and its .pre-commit-config.yaml would be found instead of the bundled config being tested
export LINT_PRE_COMMIT_CONFIG=configs/pre-commit.yaml

# Created here rather than committed: the runner can't download an action whose repo contains a broken symlink. It's
# still linted, being untracked but not ignored.
broken_symlink=tests/fail/pre-commit/broken-symlink/link
# A separate repo, for its own linter configs
here=${PWD}
repo=$(mktemp -d)
readonly broken_symlink here repo
ln -sf missing.txt "${broken_symlink}"
trap 'rm -f "${broken_symlink}"; rm -rf "${repo}"' EXIT

fail() {
  local message=${*}
  readonly message
  echo "FAIL: ${message}"
  failures=$((failures + 1))
}

# Checks `lint detect`'s output for the given arguments
detects() {
  local description=${1} expected=${2} args=("${@:3}") actual
  actual=$("${lint}" detect "${args[@]}" 2>&1)
  readonly description expected args actual
  if [[ ${actual} != "${expected}" ]]; then
    fail "${description}: expected ${expected}, got ${actual}"
  else
    echo "ok: ${description}"
  fi
}

detects 'detect tests/pass' '["actions","docker","go","pre-commit","python","shell","terraform","woke","yaml"]' tests/pass

if ! output=$("${lint}" run tests/pass 2>&1); then
  echo "${output}"
  fail "tests/pass"
else
  echo 'ok: tests/pass'
fi

output=$(LINT_YAMLLINT_CONFIG=missing.yml "${lint}" run --languages python,yaml tests/pass 2>&1)
status=${?}
if [[ ${status} -ne 2 || ${output} == *'== python =='* ]]; then
  echo "${output}"
  fail "invalid input: expected exit 2 before anything ran, got ${status}"
else
  echo 'ok: invalid input stops everything up front'
fi

# This golangci-lint version is never installed, and the system dirs won't have one to fall back on (unlike, e.g.,
# Homebrew's), so only the go checks should be skipped. Uses this Bash, since PATH no longer finds a modern one.
output=$(PATH=/usr/bin:/bin LINT_GOLANGCI_LINT_VERSION=0.0.1 "${BASH}" "${lint}" run --languages go,python tests/pass 2>&1)
status=${?}
if [[ ${status} -ne 2 || ${output} != *'skipping go'* || ${output} != *'== python =='* ]]; then
  echo "${output}"
  fail "setup isolation: expected exit 2 with go skipped and python run, got ${status}"
else
  echo 'ok: a language that fails setup is skipped without stopping the others'
fi

# Without the guards, this config's hooks would run the linter again, which would run them again, and never finish
output=$(LINT_PRE_COMMIT_CONFIG=tests/pre-commit-nested.yaml "${lint}" run --languages pre-commit tests/pass/pre-commit 2>&1)
status=${?}
if ((status)); then
  echo "${output}"
  fail "nested pre-commit: expected the hooks running composite-lint to be skipped, got ${status}"
else
  echo "ok: a pre-commit config that runs composite-lint doesn't recurse"
fi

# The config file, given as process substitutions
detects 'config languages' '["python","shell"]' -c <(echo 'languages: python, shell') tests/pass
detects 'options override the config' '["yaml"]' -c <(echo 'languages: python') -l yaml tests/pass
LINT_LANGUAGES=yaml detects 'the environment overrides the config' '["yaml"]' -c <(echo 'languages: python') tests/pass
detects 'config and option excludes add up' '["pre-commit","woke","yaml"]' \
  -c <(echo 'exclude: tests/pass/python') -x tests/pass/shell tests/pass/python tests/pass/shell tests/pass/yaml
detects 'given paths only count within the config paths' '["pre-commit","python","woke"]' \
  -c <(echo 'paths: tests/pass/python') tests/pass

# The schema has to list exactly the keys the config file accepts
schema_keys=$(python3 -I -c 'import json, sys; print("\n".join(sorted(json.load(open(sys.argv[1]))["properties"])))' \
  composite-lint.schema.json)
# shellcheck disable=SC1090  # config_keys, from the script
config_keys=$(source <(sed -n '/^config_keys()/,/^}/p' "${lint}") && config_keys | tr ' ' '\n' | LC_ALL=C sort)
if [[ ${schema_keys} != "${config_keys}" ]]; then
  diff <(echo "${config_keys}") <(echo "${schema_keys}")
  fail 'the schema and the config keys differ (< script, > schema)'
else
  echo 'ok: the schema matches the config keys'
fi

output=$("${lint}" detect -c <(echo 'nope: 1') tests/pass 2>&1)
status=${?}
if [[ ${status} -ne 2 || ${output} != *"unknown key 'nope'"* ]]; then
  echo "${output}"
  fail "unknown config key: expected exit 2, got ${status}"
else
  echo 'ok: an unknown config key is an error'
fi

# Runs the linter in the separate repo, and checks its exit status
in_repo() {
  local description=${1} expected=${2} args=("${@:3}") actual
  output=$(cd "${repo}" && "${here}/${lint}" run "${args[@]}" 2>&1)
  actual=${?}
  readonly description expected args actual
  if ((actual != expected)); then
    echo "${output}"
    fail "${description}: expected exit ${expected}, got ${actual}"
  else
    echo "ok: ${description}"
  fi
}

git -C "${repo}" init -q
echo 'key: value' >"${repo}/no-document-start.yml"
printf 'x = "%0150d"\n' 0 >"${repo}/long_line.py"
in_repo 'the bundled config, without a repo one' 1 -l yaml
printf 'extends: default\nrules:\n  document-start: disable\n' >"${repo}/.yamllint"
in_repo "the repo's own config" 0 -l yaml
LINT_YAMLLINT_CONFIG=${here}/configs/yamllint.yml in_repo "an input over the repo's config" 1 -l yaml
printf '[metadata]\nname = example\n' >"${repo}/setup.cfg"
printf '[flake8]\nmax-line-length = 200\n' >"${repo}/.flake8"
in_repo "the repo's config, skipping one without the tool's section" 0 -l python

for case in tests/fail/*/*/; do
  case=${case%/}
  lang=${case#tests/fail/}
  lang=${lang%%/*}
  expect=$(<"${case}/expect")

  if output=$("${lint}" run --languages "${lang}" "${case}" 2>&1); then
    echo "${output}"
    fail "${case}: passed"
  # case dirs are often named after the rule, so don't let the paths in the output satisfy the expectation
  elif ! grep -Eq -- "${expect}" <<<"${output//"${case}"/}"; then
    echo "${output}"
    fail "${case}: output didn't match /${expect}/"
  else
    echo "ok: ${case}"
  fi
done
readonly failures

if ((failures)); then
  echo "${failures} failure(s)"
  exit 1
fi
echo 'All passed'
