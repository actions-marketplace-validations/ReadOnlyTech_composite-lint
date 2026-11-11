#!/usr/bin/env python3
"""Tests .github/scripts/bump_tool_versions.py's version choice and cooldown,
the latter against this repo's real tags. Requires an authenticated `gh` CLI."""
import datetime
import pathlib
import sys
import unittest

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1]
                       / ".github" / "scripts"))
import bump_tool_versions as bump  # noqa: E402

REPO = "ReadOnlyTech/composite-lint"
SECOND = datetime.timedelta(seconds=1)


def utc(text):
    return datetime.datetime.fromisoformat(text)


class Newest(unittest.TestCase):
    AVAILABLE = ["1.2.0", "1.3.0", "1.3.1", "2.0.0", "3.15.4", "3.16.0",
                 "3.16.1"]

    def newest(self, current, old_enough=lambda version: True):
        return bump.newest(self.AVAILABLE, current, old_enough)

    def test_newest_in_the_major_version(self):
        self.assertEqual(self.newest("1.2.0"), "1.3.1")

    def test_falls_back_past_versions_too_new(self):
        self.assertEqual(self.newest("1.2.0", lambda v: v != "1.3.1"), "1.3.0")

    def test_keeps_the_current_version_if_all_are_too_new(self):
        self.assertEqual(self.newest("1.2.0", lambda v: False), "1.2.0")

    def test_keeps_the_precision(self):
        self.assertEqual(self.newest("3.15", lambda v: v != "3.16.1"), "3.16")

    def test_keeps_the_current_version_if_newest(self):
        self.assertEqual(self.newest("3.16"), "3.16")


class Cooldown(unittest.TestCase):
    def test_release_uses_its_publish_date(self):
        # v0.0.7's release was published well after its commit
        released = utc("2026-11-03T03:38:50Z")
        self.assertEqual(bump.released(REPO, "v0.0.7"), released)
        self.assertLess(utc(bump.commit(REPO, "v0.0.7")["date"]), released)
        self.assertFalse(bump.old_enough(REPO, "v0.0.7",
                                         released + bump.COOLDOWN - SECOND))
        self.assertTrue(bump.old_enough(REPO, "v0.0.7",
                                        released + bump.COOLDOWN))

    def test_tag_without_release_uses_its_commit_date(self):
        # `latest` moves with each release, so its date isn't fixed
        committed = utc(bump.commit(REPO, "latest")["date"])
        self.assertEqual(bump.released(REPO, "latest"), committed)
        self.assertFalse(bump.old_enough(REPO, "latest",
                                         committed + bump.COOLDOWN - SECOND))
        self.assertTrue(bump.old_enough(REPO, "latest",
                                        committed + bump.COOLDOWN))


if __name__ == "__main__":
    unittest.main(verbosity=2)
