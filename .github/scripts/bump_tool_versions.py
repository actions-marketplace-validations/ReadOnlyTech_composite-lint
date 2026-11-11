#!/usr/bin/env python3
"""Bump the tool versions bundled with this action to their newest release.

Adapted from RentTheRunway/application-workflows' script of the same name. Only
minor and patch updates are applied, never a new major version. Versions come
from each tool's GitHub tags; prereleases are ignored, as are versions released
less than COOLDOWN ago, matching Dependabot's cooldown. Each pin keeps its
precision, e.g. a pinned 3.15 becomes 3.16 rather than 3.16.0. The pip-installed
tools (versions/pip/requirements.txt, including pre-commit itself) are left to
Dependabot. Requires an authenticated `gh` CLI.

Usage:
  .github/scripts/bump_tool_versions.py [TOOL ...]
      Update the given tools (case-insensitive, e.g. `tflint terraform`), or
      all of them by default; --help lists them
"""
import argparse
import datetime
import functools
import json
import pathlib
import re
import subprocess
import sys
import urllib.request

REPO_ROOT = pathlib.Path(__file__).resolve().parents[2]
# Keep in sync with the cooldown in .github/dependabot.yml
COOLDOWN = datetime.timedelta(days=7)
VERSION = re.compile(r"^v?\d+(\.\d+)*$")
# A versions/.<tool>-version file: the version, with a `v` if the tool's tags have one
VERSION_FILE = r"^(v?)(?P<version>[\d.]+)$"
# A pre-commit rev frozen by `pre-commit autoupdate --freeze`, for repos without immutable releases
FROZEN_REV = (r"^\s*rev:\s*(?P<sha>[0-9a-f]{40})\s*#\s*frozen:\s*v"
              r"(?P<version>[\d.]+)$")


def setup_python_version(version, match):
    """Whether actions/setup-python can install a version on Linux runners.

    A pin like 3.16 counts as installable once any stable 3.16.x is.
    """
    url = ("https://raw.githubusercontent.com/actions/python-versions/main/"
           "versions-manifest.json")
    with urllib.request.urlopen(url) as response:
        manifest = json.load(response)
    return any(
        release["stable"]
        and (release["version"] == version
             or release["version"].startswith(f"{version}."))
        and any(file["platform"] == "linux" for file in release["files"])
        for release in manifest
    )


def version_file(name, repo, file, usable=None):
    return (name, repo, "v", f"versions/.{file}-version", VERSION_FILE, usable)


# Each item is (name, GitHub repo, tag prefix, file, pattern with a `version`
# group and optionally a `sha` group for the tag's commit, optional check that
# the new version is usable)
TOOLS = (
    version_file("actionlint", "rhysd/actionlint", "actionlint"),
    version_file("golangci-lint", "golangci/golangci-lint", "golangci-lint"),
    version_file("hadolint", "hadolint/hadolint", "hadolint"),
    (
        "pre-commit-hooks", "pre-commit/pre-commit-hooks", "v",
        "configs/pre-commit.yaml", FROZEN_REV, None,
    ),
    # The Python that runs the pip-installed linters
    version_file("Python", "python/cpython", "python", setup_python_version),
    version_file("ShellCheck", "koalaman/shellcheck", "shellcheck"),
    version_file("Terraform", "hashicorp/terraform", "terraform"),
    version_file("TFLint", "terraform-linters/tflint", "tflint"),
    (
        "TFLint ruleset", "terraform-linters/tflint-ruleset-terraform", "v",
        "configs/tflint.hcl", r"^(\s*version\s*=\s*\")(?P<version>[\d.]+)\"",
        None,
    ),
    version_file("woke", "get-woke/woke", "woke"),
)


def gh_list(path):
    result = subprocess.run(
        ["gh", "api", "--paginate", "--slurp", path],
        check=True, capture_output=True, text=True,
    )
    return [item for page in json.loads(result.stdout) for item in page]


def numbers(tag):
    """Version parts of a tag like v1, 1.2, or v1.2.3; empty for anything else
    (branches, prereleases, ...)."""
    if not VERSION.match(tag):
        return ()
    return tuple(int(part) for part in tag.lstrip("v").split("."))


@functools.cache
def releases(repo, prefix):
    """Release versions (without the prefix) of repo's tags with prefix."""
    refs = gh_list(f"repos/{repo}/git/matching-refs/tags/{prefix}")
    names = (ref["ref"].removeprefix(f"refs/tags/{prefix}") for ref in refs)
    return [name for name in names if numbers(name)]


def newest(available, current, old_enough):
    """The newest old-enough version in current's major version, keeping its
    precision."""
    parts = len(numbers(current))
    same = [v for v in available if numbers(v)[:1] == numbers(current)[:1]]
    for version in sorted(same, key=numbers, reverse=True):
        # pad (e.g. a 3.16 tag for a 3.16.0 pin) or truncate to the same precision
        best = (numbers(version) + (0,) * parts)[:parts]
        if best <= numbers(current):
            break
        if old_enough(version):
            return ".".join(str(part) for part in best)
    return current


@functools.cache
def commit(repo, tag):
    """The hash and date of the commit that a tag points to, through any
    annotated tag."""
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/commits/{tag}",
         "--jq", "{sha, date: .commit.committer.date}"],
        check=True, capture_output=True, text=True,
    )
    return json.loads(result.stdout)


def released(repo, tag):
    """When the tag's GitHub release was published, or else the date of its
    commit, for repos that only tag (or where the release has no date)."""
    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/releases/tags/{tag}",
         "--jq", ".published_at"],
        capture_output=True, text=True,
    )
    if result.returncode and "HTTP 404" not in result.stderr:
        result.check_returncode()
    date = result.stdout.strip() if not result.returncode else ""
    if date in ("", "null"):
        date = commit(repo, tag)["date"]
    return datetime.datetime.fromisoformat(date)


def old_enough(repo, tag, now=None):
    """Whether the tag was released at least COOLDOWN before now (by default,
    the current time)."""
    now = now or datetime.datetime.now(datetime.UTC)
    return now - released(repo, tag) >= COOLDOWN


def bump(name, repo, prefix, file, pattern, usable):
    """Bump the tool's pin in file."""
    available = releases(repo, prefix)
    path = REPO_ROOT / file

    def cooled(version):
        if old_enough(repo, f"{prefix}{version}"):
            return True
        print(f"{name} {version} skipped: under {COOLDOWN.days} days old")
        return False

    def replace(match):
        current = match["version"]
        candidate = newest(available, current, cooled)
        if numbers(candidate) <= numbers(current):
            return match[0]
        if usable and not usable(candidate, match):
            print(f"{name} {current} -> {candidate} skipped: not yet usable")
            return match[0]
        print(f"{name} {current} -> {candidate}")
        values = {"version": candidate}
        if "sha" in match.re.groupindex:
            values["sha"] = commit(repo, f"{prefix}{candidate}")["sha"]
        # replace from the end, so the earlier groups' offsets stay valid
        text, start = match[0], match.start()
        for group in sorted(values, key=match.start, reverse=True):
            text = (text[:match.start(group) - start] + values[group]
                    + text[match.end(group) - start:])
        return text

    text = path.read_text()
    new = re.compile(pattern, re.MULTILINE).sub(replace, text)
    if new != text:
        path.write_text(new)


def key(name):
    """A tool's command-line name, e.g. "TFLint ruleset" -> "tflint-ruleset"."""
    return name.lower().replace(" ", "-")


def parse_args(argv):
    names = sorted(key(tool[0]) for tool in TOOLS)
    choices = ", ".join(names)
    parser = argparse.ArgumentParser(
        description="Bump the bundled tool versions (minor and patch only).")
    parser.add_argument(
        "tools", nargs="*", metavar="TOOL", type=key,
        help=f"tools to update, default all: {choices}")
    tools = parser.parse_args(argv).tools
    if unknown := sorted(set(tools) - set(names)):
        parser.error(f"unknown tools: {', '.join(unknown)}; "
                     f"choose from: {choices}")
    return tools


def main(selected):
    for tool in TOOLS:
        if not selected or key(tool[0]) in selected:
            bump(*tool)


if __name__ == "__main__":
    main(parse_args(sys.argv[1:]))
