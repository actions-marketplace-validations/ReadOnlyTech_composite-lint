#!/usr/bin/env bash
#
# Detects which languages are present, installs pinned linters for them, and runs them.
#
# Usage: lint [command] [options] [path...]
#
# Commands:
#   run       lint (without a command: run --install; give it explicitly to lint a path named
#             like a command, or to lint without installing)
#   detect    print the languages to lint, as JSON
#   install   install the linters the languages need
#   versions  print each tool's version (and the runtimes' settings, for the action)
#
# Options:
#   -c, --config-file FILE   settings file (default: .composite-lint.yml in the repo root, if
#                            present)
#   -i, --install            with run: install first
#   -l, --languages a,b      languages to lint, instead of detecting them
#   -q, --quiet              with run: show only the languages that fail (the quiet setting)
#   -x, --exclude PATHSPEC   exclude files (repeatable, or comma-separated)
#   -h, --help
#
# Paths default to the config's `paths`, or `.`. When both are given, only paths within the config's
# are linted (e.g. for pre-commit, which passes every changed file). Go is linted per module, so a
# .go file brings in its whole module, even if the paths or excludes leave out its go.mod. One in no
# module is linted with the other .go files in its directory.
#
# Files are those git tracks or would track. With the include-ignored setting true, the files it
# ignores are too, but only non-hidden ones unless include-hidden is true. Excludes default to
# `.git **/node_modules`, which setting any replaces (though -x adds to them); in a pattern, `*`
# matches within a directory and `**` across them, and anything matched excludes everything under
# it.
#
# Settings come from, in order of precedence: options; environment variables (as the action passes
# its inputs); the config file; and finally what's bundled in versions/ and configs/. The config
# file takes the action's input names as flat `key: value` lines, e.g. `shellcheck-version: 0.10.0`,
# with paths relative to the repo root; the matching environment variable is LINT_ plus the name in
# capitals with underscores, e.g. LINT_SHELLCHECK_VERSION.
#
# A linter's config, if not set that way, is the repo's own (e.g. .yamllint), found in its root the
# way the linter itself would; only failing that is the bundled one used.
#
# All inputs are validated before anything is installed or run. After that, a language whose tools
# can't be installed or found fails on its own and the other languages still run.
#
# Exit codes: 0 clean, 1 lint failures, 2 invalid usage/inputs or a language couldn't be set up.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LANGUAGES='actions docker go kotlin pre-commit python shell terraform woke yaml'
# for when no excludes are set; mostly relevant to linting files git ignores (include-ignored)
DEFAULT_EXCLUDES='.git **/node_modules'
PIP_TOOLS=' flake8 pre-commit yamllint zizmor '
CACHE="${LINT_CACHE:-${RUNNER_TOOL_CACHE:-${XDG_CACHE_HOME:-${HOME}/.cache}}/composite-lint}"
readonly ROOT LANGUAGES DEFAULT_EXCLUDES PIP_TOOLS CACHE

# setup-python's builds load libpython from their own lib dir, which setup-python only adds to the
# loader's path when it updates the environment, which the action has it not do. GitHub-hosted
# runners have it configured anyway; other runners don't, so without this the Python (and the venvs
# made from it) can't even start.
if [[ -n ${LINT_PYTHON:-} ]]; then
  LD_LIBRARY_PATH="$(dirname "$(dirname "${LINT_PYTHON}")")/lib${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
  readonly LD_LIBRARY_PATH
  export LD_LIBRARY_PATH
fi

die() {
  local -r message="${*}"
  echo "lint: ${message}" >&2
  exit 2
}

warn() {
  local -r message="${*}"
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    echo "::warning::${message}"
  else
    echo "lint: warning: ${message}" >&2
  fi
}

# Like die, but leaves it to the caller to carry on
error() {
  local -r message="${*}"
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    echo "::error::${message}"
  else
    echo "lint: error: ${message}" >&2
  fi
}


# Splits on whitespace and commas without globbing, e.g. `split ARR "${value}"`
split() {
  local -r array="${1}" text="${2}"
  IFS=$' \t\n,' read -r -d '' -a "${array}" <<<"${text}" || true
}

trim() {
  local text="${1}"
  text="${text#"${text%%[![:space:]]*}"}"
  echo "${text%"${text##*[![:space:]]}"}"
}

abspath() {
  local -r path="${1}"
  echo "$(cd "$(dirname "${path}")" && pwd)/$(basename "${path}")"
}

# --- versions and configs ---

env_key() {
  local -r name="${1}"
  echo "LINT_$(echo "${name}" | tr '[:lower:]-' '[:upper:]_')"
}

# First non-blank, non-comment line
read_version_file() {
  local -r file="${1}"
  local line
  while IFS= read -r line || [[ -n ${line} ]]; do
    line="$(trim "${line%%#*}")"
    if [[ -n ${line} ]]; then
      echo "${line}"
      return
    fi
  done <"${file}"
}

# The repo's own version file for a tool, if it has one in its root: .<tool>-version, like pyenv's
# .python-version and tfenv's .terraform-version (and the bundled versions/)
repo_version_file() {
  local -r tool="${1}"
  if [[ -f ${TOP}/.${tool}-version ]]; then
    echo "${TOP}/.${tool}-version"
  fi
}

version() {
  local -r tool="${1}"
  local key raw file repo_file v
  key="$(env_key "${tool}")"
  raw="${key}_VERSION"
  raw="${!raw:-}"
  file="${key}_VERSION_FILE"
  file="${!file:-}"
  repo_file="$(repo_version_file "${tool}")"
  readonly key raw file repo_file

  if [[ -n ${raw} && -n ${file} ]]; then
    die "set only one of ${key}_VERSION and ${key}_VERSION_FILE"
  elif [[ -n ${raw} ]]; then
    v="${raw}"
  elif [[ -n ${file} ]]; then
    [[ -f ${file} ]] || die "${key}_VERSION_FILE: ${file} not found"
    v="$(read_version_file "${file}")"
  elif [[ -n ${repo_file} ]]; then
    v="$(read_version_file "${repo_file}")"
  elif [[ -f ${ROOT}/versions/.${tool}-version ]]; then
    v="$(read_version_file "${ROOT}/versions/.${tool}-version")"
  else
    v="$(sed -n "s/^${tool}==//p" "${ROOT}/versions/pip/requirements.txt")"
  fi
  readonly v

  [[ -n ${v} ]] || die "no version found for ${tool}"

  # Inputs may come with or without a `v`. Release downloads are tagged with one; pip and Terraform
  # aren't.
  if is_pip "${tool}" || [[ ${tool} == terraform ]]; then
    echo "${v#v}"
  else
    echo "v${v#v}"
  fi
}

bundled_config() {
  local -r tool="${1}"
  case ${tool} in
    actionlint) echo actionlint.yml ;;
    flake8) echo flake8.ini ;;
    hadolint) echo hadolint.yml ;;
    ktfmt) echo ktfmt ;;
    pre-commit) echo pre-commit.yaml ;;
    shellcheck) echo shellcheckrc ;;
    tflint) echo tflint.hcl ;;
    yamllint) echo yamllint.yml ;;
    zizmor) echo zizmor.yml ;;
  esac
}

# Where each tool looks for a config by default, in its own order of precedence. Only the repo root
# is checked, rather than per directory, and not the user's home directory.
repo_configs() {
  local -r tool="${1}"
  case ${tool} in
    actionlint) echo .github/actionlint.yaml .github/actionlint.yml ;;
    flake8) echo setup.cfg tox.ini .flake8 ;;
    golangci-lint) echo .golangci.yml .golangci.yaml .golangci.toml .golangci.json ;;
    hadolint) echo .hadolint.yaml .hadolint.yml ;;
    # ktfmt itself has no config file, only flags; this one has them, one per line (see ktfmt_flags)
    ktfmt) echo .ktfmt ;;
    pre-commit) echo .pre-commit-config.yaml ;;
    shellcheck) echo .shellcheckrc shellcheckrc ;;
    tflint) echo .tflint.hcl ;;
    woke) echo .woke.yaml .woke.yml ;;
    yamllint) echo .yamllint .yamllint.yaml .yamllint.yml ;;
    zizmor) echo .github/zizmor.yml .github/zizmor.yaml zizmor.yml zizmor.yaml ;;
  esac
}

# The repo's own config for a tool, if it has one
repo_config() {
  local -r tool="${1}"
  local file
  for file in $(repo_configs "${tool}"); do
    if [[ ! -f ${TOP}/${file} ]]; then
      continue
    fi
    # flake8 skips files without its section, e.g. a setup.cfg only for setuptools
    if [[ ${tool} == flake8 ]] && ! grep -Eq '^\[flake8(:local-plugins)?\]' "${TOP}/${file}"; then
      continue
    fi
    echo "${TOP}/${file}"
    return
  done
}

# Absolute path to the config to use: the input, else the repo's own, else the bundled one, else
# nothing
config() {
  local -r tool="${1}"
  local var path repo bundled
  var="$(env_key "${tool}")_CONFIG"
  path="${!var:-}"
  repo="$(repo_config "${tool}")"
  bundled="$(bundled_config "${tool}")"
  readonly var path repo bundled

  if [[ -n ${path} ]]; then
    [[ -f ${path} ]] || die "${var}: ${path} not found"
    abspath "${path}"
  elif [[ -n ${repo} ]]; then
    echo "${repo}"
  elif [[ -n ${bundled} ]]; then
    echo "${ROOT}/configs/${bundled}"
  fi
}

# Every key the config file accepts: the action's inputs, minus the ones only it uses (cache,
# config-file, github-token)
config_keys() {
  local tool
  echo languages paths exclude include-hidden include-ignored quiet
  for tool in go java python terraform; do
    echo "${tool}-version ${tool}-version-file"
  done
  for tool in actionlint flake8 golangci-lint hadolint ktfmt pre-commit shellcheck tflint woke yamllint zizmor; do
    echo "${tool}-config ${tool}-version ${tool}-version-file"
  done
}

# Sets each setting in the config file that isn't already set in the environment. Its paths are
# relative to the repo root, so they're made absolute (and paths/exclude become git pathspecs from
# the root).
load_config() {
  local -r file="${1}"
  local keys line key value var items item pathspecs
  keys=" $(config_keys | tr '\n' ' ') "
  readonly keys

  while IFS= read -r line || [[ -n ${line} ]]; do
    line="$(trim "${line%%#*}")"
    if [[ -z ${line} || ${line} == --- ]]; then
      continue
    fi
    [[ ${line} =~ ^([a-z0-9-]+):[[:space:]]*(.*)$ ]] || die "${file}: expected flat 'key: value' lines, not '${line}'"
    key="${BASH_REMATCH[1]}"
    value="${BASH_REMATCH[2]}"
    [[ ${keys} == *" ${key} "* ]] || die "${file}: unknown key '${key}'"
    if [[ ${value} =~ ^\"(.*)\"$ || ${value} =~ ^\'(.*)\'$ ]]; then
      value="${BASH_REMATCH[1]}"
    fi

    var="$(env_key "${key}")"
    if [[ -n ${!var:-} ]]; then
      continue
    fi
    case ${key} in
      paths | exclude)
        split items "${value}"
        pathspecs=()
        for item in "${items[@]}"; do
          pathspecs+=(":(top)${item}")
        done
        value="${pathspecs[*]}"
        ;;
      *-config | *-version-file)
        if [[ ${value} != /* ]]; then
          value="${TOP}/${value}"
        fi
        ;;
    esac
    printf -v "${var}" '%s' "${value}"
  done <"${file}"
}

# --- tool installation ---

tools_for() {
  local -r lang="${1}"
  case ${lang} in
    actions) echo actionlint shellcheck zizmor ;;
    docker) echo hadolint ;;
    go) echo golangci-lint ;;
    kotlin) echo ktfmt ;;
    pre-commit) echo pre-commit ;;
    python) echo flake8 ;;
    shell) echo shellcheck ;;
    terraform) echo tflint ;;
    woke) echo woke ;;
    yaml) echo yamllint ;;
  esac
}

is_pip() {
  local -r tool="${1}"
  [[ ${PIP_TOOLS} == *" ${tool} "* ]]
}

tool_dir() {
  local -r tool="${1}"
  local v
  v="$(version "${tool}")"
  readonly v
  if is_pip "${tool}"; then
    echo "${CACHE}/venv/${tool}-${v}/bin"
  else
    echo "${CACHE}/tools/${tool}/${v}"
  fi
}

platform() {
  OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
  case $(uname -m) in
    x86_64 | amd64) ARCH=amd64 ;;
    aarch64 | arm64) ARCH=arm64 ;;
    *) die "unsupported architecture: $(uname -m)" ;;
  esac
  readonly OS ARCH
}

# Takes the release tag; some asset names use the version without its `v`
binary_url() {
  local -r tool="${1}" tag="${2}"
  local -r v="${tag#v}" gh=https://github.com
  case ${tool} in
    actionlint)
      echo "${gh}/rhysd/actionlint/releases/download/${tag}/actionlint_${v}_${OS}_${ARCH}.tar.gz" ;;
    golangci-lint)
      echo "${gh}/golangci/golangci-lint/releases/download/${tag}/golangci-lint-${v}-${OS}-${ARCH}.tar.gz" ;;
    hadolint)
      local os="${OS}" arch=x86_64
      [[ ${OS} == darwin ]] && os=macos
      [[ ${ARCH} == arm64 ]] && arch=arm64
      readonly os arch
      echo "${gh}/hadolint/hadolint/releases/download/${tag}/hadolint-${os}-${arch}" ;;
    # the jar rather than the native builds, which are only for some platforms
    ktfmt)
      echo "${gh}/Kotlin/ktfmt/releases/download/${tag}/ktfmt-${v}-with-dependencies.jar" ;;
    shellcheck)
      local arch=x86_64
      [[ ${ARCH} == arm64 ]] && arch=aarch64
      readonly arch
      echo "${gh}/koalaman/shellcheck/releases/download/${tag}/shellcheck-${tag}.${OS}.${arch}.tar.gz" ;;
    tflint)
      echo "${gh}/terraform-linters/tflint/releases/download/${tag}/tflint_${OS}_${ARCH}.zip" ;;
    woke)
      echo "${gh}/get-woke/woke/releases/download/${tag}/woke-${v}-${OS}-${ARCH}.tar.gz" ;;
    *)
      die "don't know how to install ${tool}" ;;
  esac
}

# The installers run in a context where `set -e` is ignored, so every step checks its own result.

# no checksum verification; a checksum fetched from the same release only catches corruption.
# Pin hashes per version in versions/ if supply-chain verification is needed.
install_binary() {
  local -r tool="${1}" tag="${2}"
  local -r dest="${CACHE}/tools/${tool}/${tag}"
  [[ -x ${dest}/${tool} ]] && return

  local url tmp
  tmp="$(mktemp -d)" || return 1
  url="$(binary_url "${tool}" "${tag}")"
  readonly tmp url
  echo "Installing ${tool} ${tag} from ${url}"

  if ! curl -fsSL "${url}" -o "${tmp}/download"; then
    rm -rf "${tmp}"
    return 1
  fi
  case ${url} in
    *.tar.gz) tar -xzf "${tmp}/download" -C "${tmp}" ;;
    *.zip) unzip -q "${tmp}/download" -d "${tmp}" ;;
    # run by a wrapper, with the java on the PATH
    *.jar)
      # $0 and $@ are for the wrapper to expand
      # shellcheck disable=SC2016
      mv "${tmp}/download" "${tmp}/${tool}.jar" &&
        printf '#!/bin/sh\nexec java -jar "$(dirname "$0")/%s.jar" "$@"\n' "${tool}" >"${tmp}/${tool}" ;;
    *) mv "${tmp}/download" "${tmp}/${tool}" ;;
  esac &&
    mkdir -p "${dest}" &&
    find "${tmp}" -type f \( -name "${tool}" -o -name "${tool}.jar" \) -exec mv {} "${dest}/" \;
  rm -rf "${tmp}"
  [[ -f ${dest}/${tool} ]] && chmod +x "${dest}/${tool}"
}

install_pip() {
  local -r tool="${1}" tool_version="${2}"
  local -r venv="${CACHE}/venv/${tool}-${tool_version}"
  # A venv breaks if the Python it was made from has gone (e.g. after an upgrade) or it's lost
  # files, so check the tool actually runs
  if [[ -x ${venv}/bin/${tool} ]] && "${venv}/bin/${tool}" --version >/dev/null 2>&1; then
    return
  fi
  echo "Installing ${tool} ${tool_version} with pip"

  rm -rf "${venv}"
  if ! "${LINT_PYTHON:-python3}" -m venv "${venv}"; then
    error "couldn't create a venv; install your distro's venv package (e.g. python3-venv) or set LINT_PYTHON"
    rm -rf "${venv}"
    return 1
  fi
  if ! "${venv}/bin/python" -m pip install -q --disable-pip-version-check "${tool}==${tool_version}"; then
    rm -rf "${venv}"
    return 1
  fi
}

# The tools needed by the selected languages, without duplicates
selected_tools() {
  local lang tool seen=' '
  for lang in "${SELECTED[@]}"; do
    for tool in $(tools_for "${lang}"); do
      if [[ ${seen} != *" ${tool} "* ]]; then
        seen+="${tool} "
        echo "${tool}"
      fi
    done
  done
}

install_path() {
  local -r tool="${1}" tool_version="${2}"
  if is_pip "${tool}"; then
    echo "${CACHE}/venv/${tool}-${tool_version}"
  else
    echo "${CACHE}/tools/${tool}/${tool_version}"
  fi
}

# Installs everything it can; a tool that fails doesn't stop the others. With LINT_PRUNE=true, also
# deletes any other installed versions (for caches that would otherwise only grow).
install_tools() {
  local tool v path keep=' ' status=0
  platform
  for tool in $(selected_tools); do
    v="$(version "${tool}")"
    keep+="$(install_path "${tool}" "${v}") "
    if is_pip "${tool}"; then
      install_pip "${tool}" "${v}"
    else
      install_binary "${tool}" "${v}"
    fi || {
      error "failed to install ${tool} ${v}"
      status=2
    }
  done
  readonly keep status

  if [[ ${LINT_PRUNE:-} == true ]]; then
    for path in "${CACHE}"/tools/*/* "${CACHE}"/venv/*; do
      if [[ -e ${path} && ${keep} != *" ${path} "* ]]; then
        echo "Pruning ${path}"
        rm -rf "${path}"
      fi
    done
  fi
  return ${status}
}

runtimes_for() {
  local -r lang="${1}"
  case ${lang} in
    go) echo go ;;
    kotlin) echo java ;;
    terraform) echo terraform ;;
  esac
}

need() {
  local -r program="${1}"
  command -v "${program}" >/dev/null && return
  error "${program} not found; run 'bin/lint.sh install' or put it on the PATH"
  return 1
}

# Puts the installed version of each of a language's tools first on the PATH, falling back to
# whatever's already there. Fails if anything the language needs is missing.
setup_language() {
  local -r lang="${1}"
  local tool dir status=0
  for tool in $(tools_for "${lang}"); do
    dir="$(tool_dir "${tool}")"
    if [[ -d ${dir} ]]; then
      PATH="${dir}:${PATH}"
    fi
    need "${tool}" || status=1
  done
  for tool in $(runtimes_for "${lang}"); do
    need "${tool}" || status=1
  done
  readonly status
  return ${status}
}

# Dies on any invalid version or config input for the selected languages, before anything else
# happens
validate_inputs() {
  local tool
  for tool in $(selected_tools); do
    version "${tool}" >/dev/null
    config "${tool}" >/dev/null
  done
  runtime_setting go '' >/dev/null
  runtime_setting java '' >/dev/null
  runtime_setting python '' >/dev/null
  if is_selected kotlin; then
    ktfmt_flags >/dev/null
  fi
  if is_selected terraform; then
    version terraform >/dev/null
  fi
}

is_selected() {
  local -r lang="${1}"
  [[ " ${SELECTED[*]} " == *" ${lang} "* ]]
}

# A runtime's version setting, for the action's setup-<runtime> step: its version or its version
# file
runtime_setting() {
  local -r runtime="${1}" default_file="${2}"
  local key raw file
  key="$(env_key "${runtime}")"
  raw="${key}_VERSION"
  raw="${!raw:-}"
  file="${key}_VERSION_FILE"
  file="${!file:-}"
  readonly key raw file
  if [[ -n ${raw} && -n ${file} ]]; then
    die "set only one of ${key}_VERSION and ${key}_VERSION_FILE"
  elif [[ -n ${raw} ]]; then
    echo "${runtime}-version ${raw}"
  else
    echo "${runtime}-version-file ${file:-${default_file}}"
  fi
}

print_versions() {
  local tool python=false python_file go_file java_file
  for tool in $(selected_tools); do
    echo "${tool} $(version "${tool}")"
    # these configs pin the versions of what the tools install (TFLint's ruleset, pre-commit's
    # hooks)
    case ${tool} in
      pre-commit | tflint) echo "${tool}-config $(cksum <"$(config "${tool}")")" ;;
    esac
    if is_pip "${tool}"; then
      python=true
    fi
  done
  readonly python

  if [[ ${python} == true ]]; then
    python_file="$(repo_version_file python)"
    readonly python_file
    runtime_setting python "${python_file:-${ROOT}/versions/.python-version}"
  fi
  if is_selected go; then
    # go.mod is Go's own, so it wins; with neither, e.g. for modules only in subdirs, the bundled
    # version
    go_file="$(repo_version_file go)"
    if [[ -f ${TOP}/go.mod ]]; then
      go_file=go.mod
    elif [[ -z ${go_file} ]]; then
      go_file="${ROOT}/versions/.go-version"
    fi
    readonly go_file
    runtime_setting go "${go_file}"
  fi
  if is_selected kotlin; then
    java_file="$(repo_version_file java)"
    readonly java_file
    runtime_setting java "${java_file:-${ROOT}/versions/.java-version}"
  fi
  if is_selected terraform; then
    echo "terraform-version $(version terraform)"
  fi
}

# --- file discovery and language detection ---

# The git pathspecs for an exclude. A plain path excludes everything under it. A pattern is a glob,
# where `*` matches within a directory and `**` across them, and also excludes everything under what
# it matches (so e.g. **/node_modules covers node_modules/ at any depth).
exclude_pathspecs() {
  local -r exclude="${1}"
  local magic=exclude path="${exclude}"
  # combined with any magic it already has, e.g. the config's :(top)
  if [[ ${exclude} == ':('* ]]; then
    magic+=",${exclude#:(}"
    magic="${magic%%)*}"
    path="${exclude#*)}"
  fi
  readonly path

  # git never lists anything in .git anyway, and before 2.56, excluding a path shorter than the
  # paths being listed could read out of bounds and list nothing at all
  if [[ ${path} == .git || ${path} == .git/* ]]; then
    return
  fi
  if [[ ${path} == *[*?[]* ]]; then
    echo ":(${magic},glob)${path}"
    echo ":(${magic},glob)${path}/**"
  else
    echo ":(${magic})${path}"
  fi
}

# Files within the given pathspecs: everything git tracks or would track, plus what it ignores if
# INCLUDE_IGNORED, but then only hidden ones (any part of the path starting with `.`) if
# INCLUDE_HIDDEN
list_files() {
  local -r pathspecs=("${@}")
  local ignored
  git ls-files -co --exclude-standard -- "${pathspecs[@]}" || return 1
  if [[ ${INCLUDE_IGNORED} == false ]]; then
    return
  fi
  ignored="$(git ls-files -oi --exclude-standard -- "${pathspecs[@]}")" || return 1
  if [[ ${INCLUDE_HIDDEN} == false ]]; then
    ignored="$(grep -Ev '(^|/)\.[^./]' <<<"${ignored}")" || true
  fi
  readonly ignored
  if [[ -n ${ignored} ]]; then
    echo "${ignored}"
  fi
}

# What Go lints, once each: the go.mod of each module that the given .go and go.mod files are in,
# and the directory of each .go file in no module. Go is linted per module, so e.g. pre-commit's
# changed .go files bring in their modules, even where the paths or excludes leave out the go.mod.
go_targets() {
  local path dir up
  for path in "${@}"; do
    if [[ ${path} == *.go || ${path##*/} == go.mod ]]; then
      if [[ ${path} == */* ]]; then
        echo "${path%/*}"
      else
        echo .
      fi
    fi
  done | sort -u | while IFS= read -r dir; do
    # physical, as git reports TOP
    dir="$(cd "${dir}" && pwd -P)" || continue
    up="${dir}"
    while [[ ${up} == "${TOP}" || ${up} == "${TOP}"/* ]]; do
      if [[ -f ${up}/go.mod ]]; then
        echo "${up}/go.mod"
        continue 2
      fi
      up="${up%/*}"
    done
    echo "${dir}"
  done | sort -u
}

collect_files() {
  local excludes=() p f list
  for p in "${EXCLUDES[@]}"; do
    while IFS= read -r f; do
      excludes+=("${f}")
    done < <(exclude_pathspecs "${p}")
  done
  readonly excludes

  list="$(list_files "${PATHS[@]}" "${excludes[@]}")" || die "couldn't list files"
  # given paths only count within the configured ones
  if ((${#SCOPE[@]})); then
    list="$(comm -12 <(sort <<<"${list}") <(list_files "${SCOPE[@]}" | sort))"
  fi
  readonly list
  FILES=()
  while IFS= read -r f; do
    # broken symlinks are kept for pre-commit (check-symlinks by default)
    if [[ -f ${f} || -L ${f} ]]; then
      FILES+=("${f}")
    fi
  done <<<"${list}"
  readonly FILES
}

is_shell_script() {
  local -r file="${1}"
  local line
  IFS= read -r line <"${file}" || true
  readonly line
  [[ ${line} =~ ^#!.*[/[:space:]](ba|da|k)?sh([[:space:]]|$) ]]
}

matches() {
  local -r lang="${1}" file="${2}"
  local -r base="${file##*/}"
  case ${lang} in
    actions)
      case ${file} in
        .github/workflows/*.yml | .github/workflows/*.yaml | */.github/workflows/*.yml | */.github/workflows/*.yaml) return 0 ;;
        .github/dependabot.yml | .github/dependabot.yaml | */.github/dependabot.yml | */.github/dependabot.yaml) return 0 ;;
      esac
      [[ ${base} == action.yml || ${base} == action.yaml ]] ;;
    docker) [[ ${base} == *Dockerfile* || ${base} == *.dockerfile || ${base} == Containerfile* ]] ;;
    kotlin) [[ ${base} == *.kt || ${base} == *.kts ]] ;;
    pre-commit) true ;;
    python) [[ ${base} == *.py ]] ;;
    shell) [[ ${base} == *.sh || ${base} == *.bash ]] || { [[ ${base} != *.* ]] && is_shell_script "${file}"; } ;;
    terraform) [[ ${base} == *.tf ]] ;;
    woke) true ;;
    yaml) [[ ${base} == *.yml || ${base} == *.yaml ]] ;;
  esac
}

files_for() {
  local -r lang="${1}"
  local f
  LANG_FILES=()
  if [[ ${lang} == go ]]; then
    while IFS= read -r f; do
      LANG_FILES+=("${f}")
    done < <(go_targets "${FILES[@]}")
    return
  fi
  for f in "${FILES[@]}"; do
    # only pre-commit gets broken symlinks, so check-symlinks can report them rather than every
    # linter failing on them
    if [[ ${lang} != pre-commit && ! -e ${f} ]]; then
      continue
    fi
    if matches "${lang}" "${f}"; then
      LANG_FILES+=("${f}")
    fi
  done
}

select_languages() {
  local lang kept=()
  SELECTED=()
  if ((${#LANGS[@]})); then
    for lang in "${LANGS[@]}"; do
      [[ " ${LANGUAGES} " == *" ${lang} "* ]] || die "unknown language '${lang}' (supported: ${LANGUAGES})"
      SELECTED+=("${lang}")
    done
  else
    for lang in ${LANGUAGES}; do
      files_for "${lang}"
      if ((${#LANG_FILES[@]})); then
        SELECTED+=("${lang}")
      fi
    done
  fi
  if [[ ${HOOKED_BY_PRE_COMMIT} == true ]] && is_selected pre-commit; then
    echo "lint: skipping the pre-commit check; pre-commit is already running the other hooks in its config" >&2
    for lang in "${SELECTED[@]}"; do
      if [[ ${lang} != pre-commit ]]; then
        kept+=("${lang}")
      fi
    done
    SELECTED=("${kept[@]}")
  fi
  readonly SELECTED
}

print_json() {
  local -r items=("${@}")
  local sep='' item
  printf '['
  for item in "${items[@]}"; do
    printf '%s"%s"' "${sep}" "${item}"
    sep=,
  done
  printf ']\n'
}

# --- linters ---
# Each runs every check for its language against LANG_FILES and returns 1 if any failed.
# zizmor and woke respect .gitignore, so they're left to find files themselves when that's
# equivalent (see self_discovery). The rest always get LANG_FILES: yamllint and flake8 would lint
# gitignored dirs like .venv, and neither hadolint nor shellcheck searches directories.

# Whether tools can be given the paths to search themselves: only when they're all directories
# (e.g., pre-commit passes every file, which zizmor rejects unless it's YAML), and they'd find the
# same files. They follow .gitignore, so not when linting ignored files, nor with custom excludes
# or a configured scope, which they wouldn't know about. (The default excludes are things git
# ignores anyway.)
self_discovery() {
  local p
  if [[ ${INCLUDE_IGNORED} == true || ${CUSTOM_EXCLUDES} == true ]] || ((${#SCOPE[@]})); then
    return 1
  fi
  for p in "${PATHS[@]}"; do
    [[ -d ${p} ]] || return 1
  done
}

each() {
  local -r command=("${@}")
  printf '%s\0' "${LANG_FILES[@]}" | xargs -0 "${command[@]}"
}

# For tools with no option to stay silent when they succeed: only shows their output if they fail
quiet() {
  local -r command=("${@}")
  local output rc=0
  output="$("${command[@]}" 2>&1)" || rc="${?}"
  readonly output rc
  if ((rc)); then
    echo "${output}"
    return 1
  fi
}

lint_actions() {
  local rc=0 f cfg workflows=() zizmor_opts=(-q --persona auditor -c "$(config zizmor)")
  for f in "${LANG_FILES[@]}"; do
    case ${f} in
      .github/workflows/* | */.github/workflows/*) workflows+=("${f}") ;;
    esac
  done
  readonly workflows

  if ((${#workflows[@]})); then
    cfg="$(config actionlint)"
    readonly cfg
    # actionlint passes scripts to shellcheck via stdin, so the rcfile's disables have to be passed
    # as options
    SHELLCHECK_OPTS="$(sed -n 's/^[[:space:]]*disable=/-e /p' "$(config shellcheck)" | tr '\n' ' ')" \
      actionlint ${cfg:+-config-file "${cfg}"} "${workflows[@]}" || rc=1
  fi

  if [[ -z ${GH_TOKEN:-} ]] && type -p gh >/dev/null; then
    GH_TOKEN="$(gh auth token 2>/dev/null)" && export GH_TOKEN
  fi

  if [[ -z ${GH_TOKEN:-} ]]; then
    zizmor_opts+=(-o)
  fi
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    zizmor_opts+=(--format github)
  fi
  readonly zizmor_opts
  if ! self_discovery; then
    quiet zizmor "${zizmor_opts[@]}" "${LANG_FILES[@]}" || rc=1
  else
    quiet zizmor "${zizmor_opts[@]}" "${PATHS[@]}" || rc=1
  fi
  readonly rc
  return ${rc}
}

lint_docker() {
  each hadolint -c "$(config hadolint)"
}

lint_go() {
  local rc=0 mod opts=(--show-stats=false --no-config) cfg
  cfg="$(config golangci-lint)"
  readonly cfg
  if [[ -n ${cfg} ]]; then
    opts=(--show-stats=false -c "${cfg}")
  fi
  readonly opts

  for mod in "${LANG_FILES[@]}"; do
    # a directory in no module, where ./... finds nothing; its files are linted together, as one
    # package
    # assumes one package per directory, so an external _test package there fails to typecheck
    if [[ ${mod} != */go.mod ]]; then
      (cd "${mod}" && golangci-lint run "${opts[@]}" ./*.go) || rc=1
      continue
    fi
    (
      cd "$(dirname "${mod}")"
      go mod tidy -diff
    ) || rc=1
    (
      cd "$(dirname "${mod}")"
      golangci-lint run "${opts[@]}" ./...
    ) || rc=1
  done
  readonly rc
  return ${rc}
}

# The flags in ktfmt's config, one per line; blank lines and `#` comments are skipped. Dies on any
# that would stop the check from working. ktfmt itself merges the rest with any .editorconfig.
ktfmt_flags() {
  local file line flags=()
  file="$(config ktfmt)"
  readonly file
  while IFS= read -r line || [[ -n ${line} ]]; do
    line="$(trim "${line}")"
    if [[ -z ${line} || ${line} == '#'* ]]; then
      continue
    fi
    case ${line} in
      # what would have ktfmt print help, read stdin, or format only part of a file
      -h | --help | -v | --version | --stdin-name* | --line* | --offset* | --length*)
        die "${file}: '${line}' stops ktfmt from checking the files" ;;
      # ktfmt takes anything else, even `-x`, as a file to format
      -n | --*) ;;
      *) die "${file}: '${line}' is not a ktfmt option; composite-lint gives the files" ;;
    esac
    flags+=("${line}")
  done <"${file}"
  readonly flags
  if ((${#flags[@]})); then
    printf '%s\n' "${flags[@]}"
  fi
}

lint_kotlin() {
  local flags=() flag
  while IFS= read -r flag; do
    flags+=("${flag}")
  done < <(ktfmt_flags)
  readonly flags
  each ktfmt "${flags[@]}" --dry-run --set-exit-if-changed
}

# Runs the hooks in the pre-commit config (by default, detect-private-key and check-symlinks) on
# the files
lint_pre_commit() {
  export PRE_COMMIT_HOME="${PRE_COMMIT_HOME:-${CACHE}/pre-commit}"
  readonly PRE_COMMIT_HOME
  # A config that includes this linter's own hook would run it again, which would run pre-commit
  # again, forever. This run already covers everything, so skip the hook, and mark the nested run
  # (see main) in case it has another id.
  # pre-commit lists every hook even when it passes, hence quiet
  quiet each env LINT_NESTED=true "SKIP=composite-lint${SKIP:+,${SKIP}}" \
    pre-commit run -c "$(config pre-commit)" --files
}

lint_python() {
  each flake8 --config "$(config flake8)"
}

lint_shell() {
  each shellcheck --rcfile "$(config shellcheck)"
}

# Inits without a backend, keeping .terraform out of the checkout and leaving any lock file as it
# was found
terraform_validate() {
  local -r dir="${1}"
  local -r lock="${dir}/.terraform.lock.hcl"
  local rc=0 data output lockfile_opts=()
  if [[ -f ${lock} ]]; then
    lockfile_opts=(-lockfile=readonly)
  fi
  data="$(mktemp -d "${TF_DATA_ROOT}/XXXXXX")"
  readonly data lockfile_opts

  # only the step that failed is shown, so a successful init's chatter doesn't bury validate's
  # errors
  if ! output="$(TF_DATA_DIR="${data}" terraform -chdir="${dir}" init -backend=false -input=false "${lockfile_opts[@]}" 2>&1)" ||
    ! output="$(TF_DATA_DIR="${data}" terraform -chdir="${dir}" validate 2>&1)"; then
    echo "${output}"
    rc=1
  fi
  readonly output rc

  if ! ((${#lockfile_opts[@]})); then
    rm -f "${lock}"
  fi
  return ${rc}
}

# Every check for one directory, saving the output so parallel runs can be printed in order
# afterwards
terraform_dir() {
  local -r dir="${1}"
  local -r out="${TF_DATA_ROOT}/out/dir${dir//\//%}"
  local rc=0
  {
    terraform fmt -check -diff "${dir}" || rc=1
    terraform_validate "${dir}" || rc=1
    tflint --chdir="${dir}" -c "${TFLINT_CONFIG}" || rc=1
  } >"${out}" 2>&1
  readonly rc
  return ${rc}
}

lint_terraform() {
  local rc=0 dir f dirs=()
  TFLINT_CONFIG="$(config tflint)"
  TF_DATA_ROOT="$(mktemp -d)"
  export TF_PLUGIN_CACHE_DIR="${TF_PLUGIN_CACHE_DIR:-${CACHE}/terraform-plugins}"
  export TFLINT_PLUGIN_DIR="${TFLINT_PLUGIN_DIR:-${CACHE}/tflint-plugins}"
  readonly TFLINT_CONFIG TF_DATA_ROOT TF_PLUGIN_CACHE_DIR TFLINT_PLUGIN_DIR
  # for the parallel runs
  export TFLINT_CONFIG TF_DATA_ROOT
  export -f terraform_dir terraform_validate
  mkdir -p "${TF_PLUGIN_CACHE_DIR}" "${TFLINT_PLUGIN_DIR}" "${TF_DATA_ROOT}/out"

  quiet tflint --init -c "${TFLINT_CONFIG}" || rc=1
  while IFS= read -r dir; do
    dirs+=("${dir}")
  done < <(for f in "${LANG_FILES[@]}"; do dirname "${f}"; done | sort -u)
  readonly dirs

  # The first directory runs alone so its init fills the plugin cache; the rest then read from it,
  # rather than racing to write the same providers (which the cache doesn't support)
  terraform_dir "${dirs[0]}" || rc=1
  if ((${#dirs[@]} > 1)); then
    # ${1} is the child bash's argument, so it mustn't expand here
    # shellcheck disable=SC2016
    printf '%s\0' "${dirs[@]:1}" |
      xargs -0 -n 1 -P "$(getconf _NPROCESSORS_ONLN)" bash -c 'terraform_dir "${1}"' _ || rc=1
  fi
  readonly rc

  for dir in "${dirs[@]}"; do
    f="${TF_DATA_ROOT}/out/dir${dir//\//%}"
    if [[ -s ${f} ]]; then
      echo "-- ${dir}"
      cat "${f}"
    fi
  done
  rm -rf "${TF_DATA_ROOT}"
  return ${rc}
}

lint_woke() {
  local cfg opts=(--exit-1-on-failure)
  cfg="$(config woke)"
  readonly cfg
  if [[ -n ${cfg} ]]; then
    opts+=(-c "${cfg}")
  fi
  if [[ -n ${GITHUB_ACTIONS:-} ]]; then
    opts+=(-o github-actions)
  fi
  readonly opts
  if ! self_discovery; then
    quiet each woke "${opts[@]}"
  else
    quiet woke "${opts[@]}" "${PATHS[@]}"
  fi
}

lint_yaml() {
  each yamllint -s -c "$(config yamllint)"
}

# Sets up and lints one language, returning 2 if it couldn't be set up and 1 if linting failed
lint_language() {
  local -r lang="${1}"
  if ! setup_language "${lang}"; then
    error "skipping ${lang} checks; it couldn't be set up"
    return 2
  fi
  "lint_${lang//-/_}" || return 1
}

# `Linting <lang>` and dots up to 36 characters, so the results after it (PASS or FAIL) line up and
# end the line at 40
lint_label() {
  local -r text="Linting ${1}"
  local dots
  dots="$(printf '%*s' "$((36 - ${#text}))" '')"
  readonly dots
  printf '%s%s' "${text}" "${dots// /.}"
}

# Runs every language even if others fail, printing `Linting <lang>...PASS` or `...FAIL` and then
# its output. A setup failure (status 2) outranks lint failures (status 1). The output is held back
# until the language is done, so it comes after the result; in GitHub Actions it's grouped under
# that line. With QUIET, languages that pass aren't shown at all.
run_linters() {
  local -r gha="${GITHUB_ACTIONS:-}"
  local lang rc result status=0 out
  out="$(mktemp)"
  readonly out
  for lang in "${SELECTED[@]}"; do
    files_for "${lang}"
    if ! ((${#LANG_FILES[@]})); then
      warn "no ${lang} files found"
      continue
    fi

    # locally, the start of the line shows what's running; a group's title has to be a whole line
    if [[ ${QUIET} == false && -z ${gha} ]]; then
      lint_label "${lang}"
    fi
    rc=0
    # braces rather than a subshell, so setup_language's PATH changes carry on to the next ones
    { lint_language "${lang}"; } >"${out}" 2>&1 || rc="${?}"
    result=PASS
    if ((rc)); then
      result=FAIL
    fi
    if ((rc > status)); then
      status="${rc}"
    fi

    if [[ ${QUIET} == true && ${result} == PASS ]]; then
      continue
    elif [[ -n ${gha} && -s ${out} ]]; then
      echo "::group::$(lint_label "${lang}")${result}"
      cat "${out}"
      echo '::endgroup::'
    else
      if [[ ${QUIET} == true || -n ${gha} ]]; then
        lint_label "${lang}"
      fi
      echo "${result}"
      cat "${out}"
    fi
  done
  rm -f "${out}"
  readonly status
  return ${status}
}

# --- main ---

usage() {
  local -r status="${1:-0}"
  sed -n '3,/^$/s/^# \{0,1\}//p' "${BASH_SOURCE[0]}"
  exit "${status}"
}

if [[ ${LINT_NESTED:-} == true ]]; then
  echo "lint: skipping; already running inside composite-lint's pre-commit check, which covers these files" >&2
  exit 0
fi

# Only the first argument can be the command. Without one, the default is `run --install`, and the
# arguments (if any) are its options and paths, so e.g. `-l yaml run` lints a path named run.
cmd=run
# whether run installs first
also_install=false
case ${1:-} in
  run) shift ;;
  detect | install | versions) cmd="${1}" && shift ;;
  *) also_install=true ;;
esac
readonly cmd

cli_quiet=''
config_file="${LINT_CONFIG_FILE:-}"
cli_languages=''
cli_excludes=()
cli_paths=()
while ((${#})); do
  # an option, path, or option value, and the next argument (the value, for options that take one)
  arg="${1}"
  value="${2:-}"
  case ${arg} in
    -c | --config-file)
      [[ -n ${value} ]] || die "${arg} needs a value"
      config_file="${value}"
      shift 2
      ;;
    -i | --install)
      also_install=true
      shift
      ;;
    -l | --languages)
      [[ -n ${value} ]] || die "${arg} needs a value"
      cli_languages="${value}"
      shift 2
      ;;
    -q | --quiet)
      cli_quiet=true
      shift
      ;;
    -x | --exclude)
      [[ -n ${value} ]] || die "${arg} needs a value"
      cli_excludes+=("${value}")
      shift 2
      ;;
    -h | --help) usage ;;
    -*) die "unknown option ${arg}" ;;
    *)
      cli_paths+=("${arg}")
      shift
      ;;
  esac
done
if [[ ${also_install} == true && ${cmd} != run ]]; then
  die "--install only applies to run"
fi
if [[ -n ${cli_quiet} && ${cmd} != run ]]; then
  die "--quiet only applies to run"
fi

git rev-parse --is-inside-work-tree >/dev/null 2>&1 || die "not inside a git repository"
TOP="$(git rev-parse --show-toplevel)"
readonly TOP
if [[ -z ${config_file} && -f ${TOP}/.composite-lint.yml ]]; then
  config_file="${TOP}/.composite-lint.yml"
fi
if [[ -n ${config_file} ]]; then
  # -r rather than -f, so e.g. /dev/null can stand in for "no config"
  [[ -r ${config_file} ]] || die "config file ${config_file} not found"
  load_config "${config_file}"
fi
readonly also_install cli_quiet config_file cli_languages cli_excludes cli_paths

# options win over the environment and the config; LINT_LANGUAGES also accepts detect's JSON output
if [[ -n ${cli_languages} ]]; then
  split LANGS "${cli_languages}"
else
  LINT_LANGUAGES="${LINT_LANGUAGES:-}"
  split LANGS "${LINT_LANGUAGES//[\[\]\"]/}"
fi
# Excludes set in the environment or config replace the defaults; options add to whichever apply
CUSTOM_EXCLUDES=false
if [[ -n ${LINT_EXCLUDE:-} ]] || ((${#cli_excludes[@]})); then
  CUSTOM_EXCLUDES=true
fi
readonly CUSTOM_EXCLUDES
split EXCLUDES "${LINT_EXCLUDE:-${DEFAULT_EXCLUDES}}"
more=()
for exclude in "${cli_excludes[@]}"; do
  split more "${exclude}"
  EXCLUDES+=("${more[@]}")
done
# given paths are linted only within the configured ones (see collect_files)
split SCOPE "${LINT_PATHS:-}"
if ((${#cli_paths[@]})); then
  PATHS=("${cli_paths[@]}")
else
  PATHS=("${SCOPE[@]}")
  SCOPE=()
fi
if ! ((${#PATHS[@]})); then
  PATHS=(.)
fi
readonly LANGS EXCLUDES SCOPE PATHS

INCLUDE_IGNORED="${LINT_INCLUDE_IGNORED:-false}"
INCLUDE_HIDDEN="${LINT_INCLUDE_HIDDEN:-false}"
readonly INCLUDE_IGNORED INCLUDE_HIDDEN
[[ ${INCLUDE_IGNORED} == true || ${INCLUDE_IGNORED} == false ]] ||
  die "include-ignored must be true or false, not '${INCLUDE_IGNORED}'"
[[ ${INCLUDE_HIDDEN} == true || ${INCLUDE_HIDDEN} == false ]] ||
  die "include-hidden must be true or false, not '${INCLUDE_HIDDEN}'"
# hidden files git doesn't ignore are always linted, so alone it would do nothing
[[ ${INCLUDE_HIDDEN} == false || ${INCLUDE_IGNORED} == true ]] || die 'include-hidden requires include-ignored'
QUIET="${cli_quiet:-${LINT_QUIET:-false}}"
readonly QUIET
[[ ${QUIET} == true || ${QUIET} == false ]] || die "quiet must be true or false, not '${QUIET}'"

# Whether pre-commit is running this script as a hook, with the same config that the pre-commit
# check would use. If so, pre-commit runs the other hooks in that config itself, so the check would
# only run them again.
HOOKED_BY_PRE_COMMIT=false
if [[ ${PRE_COMMIT:-} == 1 && $(config pre-commit) == "${TOP}/.pre-commit-config.yaml" ]]; then
  HOOKED_BY_PRE_COMMIT=true
fi
readonly HOOKED_BY_PRE_COMMIT

collect_files
select_languages

if [[ ${cmd} != detect ]]; then
  validate_inputs
fi

case ${cmd} in
  detect) print_json "${SELECTED[@]}" ;;
  install) install_tools ;;
  run)
    # a tool that fails to install only fails the languages that need it
    if [[ ${also_install} == true ]]; then
      install_tools || true
    fi
    run_linters
    ;;
  versions) print_versions ;;
esac
