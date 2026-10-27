# composite-lint

All-in-one opinionated selection of linters &amp; config.

(Tested with Linux runners only, both GitHub-hosted and self-hosted.)

## Usage

See [`action.yml`](action.yml) for all inputs.

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

Only the tools needed for the selected `languages` (defaulting to
auto-detection) are installed. Every language / tool version can be overridden
with `<tool>-version` or `<tool>-version-file`, and its config with
`<tool>-config`; anything unset uses what's bundled in [`versions/`](versions)
and [`configs/`](configs). As a general rule, these default versions are
"latest stable" and the default configs are "very strict".

Without a `<tool>-config`, a linter uses the repo's own config if it has one in
its root, found the way that linter would: `.github/actionlint.y[a]ml`,
`.flake8` (or `setup.cfg`/`tox.ini` with a `[flake8]` section),
`.golangci.{yml,yaml,toml,json}`, `.hadolint.y[a]ml`, `.pre-commit-config.yaml`,
`.shellcheckrc`, `.tflint.hcl`, `.woke.y[a]ml`, `.yamllint[.yaml|.yml]`, or
`[.github/]zizmor.y[a]ml`. Only failing that is the bundled config used.

The linters, Go's module/build caches, golangci-lint's analysis cache, and
Terraform providers are kept in the Actions cache, and count toward your repo's
cache quota. Set `cache: false` to turn that off.

### Config File

Settings can instead live in `.composite-lint.yml` at the repo root, where the
action, local runs, and pre-commit all read them. It takes the action's input
names (except `cache`, `config-file`, and `github-token`) as flat `key: value`
lines, with paths relative to the repo root. The custom example above becomes:

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

Inputs (or, locally, options and `LINT_*` environment variables) take
precedence over the file. Use the `config-file` input or `-c` option for a file
elsewhere.

The `yaml-language-server` comment points editors at
[`composite-lint.schema.json`](composite-lint.schema.json), for completion and
validation of the keys.

## Supported Languages / Ecosystems

### Docker

Using `hadolint`.

### GitHub Actions

Using `actionlint`, `yamllint -s`, and `zizmor --persona auditor` (online when
`GH_TOKEN` / `gh auth token` is available).

### Go

Using `golangci-lint` and `go mod tidy`.

### Python

Using `flake8`.

### Shell

Using `shellcheck` (with the default config equivalent to `-x`).

### Terraform

Using `terraform validate`, `terraform fmt -check -diff`, and `tflint` (with
the default config using the `all` preset), run on each directory in parallel.

### YAML

Using `yamllint -s`.

## Other Checks

On by default, unless left out of a custom `languages` list:

- `pre-commit`: runs the hooks in [`configs/pre-commit.yaml`](configs/pre-commit.yaml)
  (`detect-private-key` and `check-symlinks`), or in your own config via
  `pre-commit-config`
- `woke`

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

Settings come from the config file, or the same `LINT_*` environment variables
the action uses; see `bin/lint.sh --help` for the details and every command and
option.

### With pre-commit

```yaml
repos:
  - repo: https://github.com/ReadOnlyTech/composite-lint
    rev: vX.Y.Z  # an exact release; pre-commit warns about floating tags like v0
    hooks:
      - id: composite-lint
```

The hook installs the pinned tools as needed and lints the files pre-commit
passes in, the same way the action does, including the config file's settings.

## Development

```sh
# lint this repo with itself (.composite-lint.yml excludes tests/fail)
bin/lint.sh run

# check tests/pass lints clean and each tests/fail case fails as expected
tests/run.sh
```

Each `tests/fail/<language>/<case>/` holds the files to lint, plus an `expect`
file containing a regex that must appear in the output.
