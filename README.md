# composite-lint

One action that runs an opinionated set of linters, with strict linter configs.

We test the action only on Linux runners, both GitHub-hosted and self-hosted.

## Usage

[`action.yml`](action.yml) lists all of the inputs.

```yaml
- name: Check out repo
  uses: actions/checkout@v7
  with:
    persist-credentials: false

- name: Run linting (strict, autodetect)
  uses: ReadOnlyTech/composite-lint@v0

- name: Run linting (custom)
  uses: ReadOnlyTech/composite-lint@v0
  with:
    cache: false
    paths: src
    exclude: 'src/build/*.py,src/scripts/*.sh'
    github-token: ${{ secrets.MY_GH_TOKEN }}
    languages: python,shell
    python-version-file: src/main/python/.python-version
    shellcheck-config: .shellcheckrc
    shellcheck-version: 0.9.0
```

The action installs only the tools that the selected `languages` need. If you
do not set `languages`, the action finds them from the files in the repo.

### Versions

Each tool gets its version from the first of these that exists:

1. The `<tool>-version` or `<tool>-version-file` input.
2. A `.<tool>-version` file in the repo root, with the same name as in
   [`versions/`](versions). Examples are `.python-version` and
   `.terraform-version`. For Go, the `go.mod` file in the repo root comes first.
3. The bundled file in [`versions/`](versions). The bundled versions are
   usually the latest stable releases.

### Linter Configs

Each linter gets its linter config from the first of these that exists:

1. The `<tool>-config` input.
2. The linter config of the repo, in the repo root. The action looks for the
   same files as the linter, in the same order. The table that follows lists
   them.
3. The bundled file in [`configs/`](configs). The bundled linter configs are
   very strict.

| Linter | Files in the repo root |
|---|---|
| actionlint | `.github/actionlint.yaml`, `.github/actionlint.yml` |
| flake8 | `setup.cfg`, `tox.ini`, `.flake8` (only with a `[flake8]` section) |
| golangci-lint | `.golangci.yml`, `.golangci.yaml`, `.golangci.toml`, `.golangci.json` |
| hadolint | `.hadolint.yaml`, `.hadolint.yml` |
| pre-commit | `.pre-commit-config.yaml` |
| ShellCheck | `.shellcheckrc`, `shellcheckrc` |
| TFLint | `.tflint.hcl` |
| woke | `.woke.yaml`, `.woke.yml` |
| yamllint | `.yamllint`, `.yamllint.yaml`, `.yamllint.yml` |
| zizmor | `.github/zizmor.yml`, `.github/zizmor.yaml`, `zizmor.yml`, `zizmor.yaml` |

### Cache

The action keeps these items in the Actions cache:

- The linters.
- The module and build caches of Go.
- The analysis cache of golangci-lint.
- The Terraform providers.

These items count toward the cache quota of your repo. To disable the cache,
set `cache: false`.

### Which Files

By default, the action lints the files that git tracks. It also lints the
untracked files that git does not ignore. Two inputs add more files:

- `include-ignored: true` adds the files that git ignores, like `ls`.
- `include-hidden: true` also adds the hidden files that git ignores, like
  `ls -a`.

The action always lints the hidden files that git does not ignore, such as
`.github/`. Thus, `include-hidden` without `include-ignored` is an error.

These two inputs work best before a build or an install adds artifacts. After
that, you must `exclude` all of the artifacts.

`exclude` takes paths and glob patterns. In a pattern, `*` matches in one
directory, and `**` matches across directories. A path or pattern also excludes
all of the files under each match. The default is `.git **/node_modules`. If
you set `exclude`, your value replaces the default.

### Config File

You can put settings in a `.composite-lint.yml` file in the repo root. The
action, local runs, and pre-commit all read this config file. It uses the
input names as flat `key: value` lines. It accepts all of the inputs except
`cache`, `config-file`, and `github-token`. Paths in it are relative to the
repo root.

This config file gives the same settings as the custom example in
[Usage](#usage):

```yaml
---

# yamllint disable-line rule:line-length
# yaml-language-server: $schema=https://raw.githubusercontent.com/ReadOnlyTech/composite-lint/main/composite-lint.schema.json
paths: src
exclude: src/build/*.py, src/scripts/*.sh
languages: python, shell
python-version-file: src/main/python/.python-version
shellcheck-config: .shellcheckrc
shellcheck-version: 0.9.0
```

Inputs have priority over the config file. In local runs, options and `LINT_*`
environment variables have priority over it. To use a config file in a
different location, set the `config-file` input or the `-c` option.

The `yaml-language-server` comment tells editors to use
[`composite-lint.schema.json`](composite-lint.schema.json). The editor can
then complete and validate the keys.

## Supported Languages / Ecosystems

### Docker

Tools: `hadolint`.

### GitHub Actions

Tools: `actionlint`, `yamllint -s`, and `zizmor --persona auditor`. zizmor
also does its online audits when `GH_TOKEN` or `gh auth token` gives a token.

### Go

Tools: `golangci-lint` and `go mod tidy`.

### Python

Tools: `flake8`.

### Shell

Tools: `shellcheck`. The bundled linter config has the same effect as `-x`.

### Terraform

Tools: `terraform validate`, `terraform fmt -check -diff`, and `tflint`. The
bundled TFLint config uses the `all` preset. The action lints each Terraform
directory in parallel.

### YAML

Tools: `yamllint -s`.

## Other Checks

These checks are on by default. A custom `languages` list turns off each check
that it does not include:

- `pre-commit`: Runs the hooks in the file that `pre-commit-config` gives. If
  you do not set that input, it runs the hooks in the `.pre-commit-config.yaml` of the repo.
  If neither exists, it runs the hooks in
  [`configs/pre-commit.yaml`](configs/pre-commit.yaml), which are
  `detect-private-key` and `check-symlinks`.
- `woke`.

## Running Locally

```sh
# installs pinned tools into the cache
bin/lint.sh install

# lints the repo (or the config file's `paths`)
bin/lint.sh run

# does both the above
bin/lint.sh run --install

# lints one language in a dir, excluding a subdir (short forms: r, -l, -x)
bin/lint.sh r -l shell -x path/to/dir/vendor path/to/dir
```

Local runs read their settings from the config file. They also read the same
`LINT_*` environment variables that the action uses. For all of the commands,
options, and details, run `bin/lint.sh --help`.

### With pre-commit

```yaml
repos:
  - repo: https://github.com/ReadOnlyTech/composite-lint
    rev: vX.Y.Z  # an exact release; pre-commit warns about floating tags like v0
    hooks:
      - id: composite-lint
```

The hook installs the pinned tools when they are necessary. It lints the files
that pre-commit gives it, in the same way as the action. It also reads the
config file.

## Development

```sh
# lint this repo with itself (.composite-lint.yml excludes tests/fail)
bin/lint.sh run

# check tests/pass lints clean and each tests/fail case fails as expected
tests/run.sh
```

Each `tests/fail/<language>/<case>/` directory contains the files to lint and
an `expect` file. The `expect` file contains a regex that must match the
output.
