# SPDX-License-Identifier: GPL-3.0-or-later
"""Tests for bin/wave.

Run from the repo root: make test-wave
or: python3 -m unittest discover -s test -p 'test_*.py'

wave runs `bd` from PATH.  These tests put a stub `bd` first on PATH that
keeps the kv store in a JSON file in a temporary directory, so no real
beads database is read or written.  The working directory is a temporary
directory outside any git repository.
"""

import json
import os
import subprocess
import sys
import tempfile
import textwrap
import unittest

WAVE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bin", "wave")

# Handles the bd calls wave makes for kv: list --json, set, clear.  Every
# call is appended to calls.log.
FAKE_BD = textwrap.dedent("""\
    #!{python}
    import json, os, sys
    state = os.environ["WAVE_FAKE_BD"]
    kv_path = os.path.join(state, "kv.json")
    with open(os.path.join(state, "calls.log"), "a") as f:
        f.write(json.dumps(sys.argv[1:]) + "\\n")
    kv = json.load(open(kv_path)) if os.path.exists(kv_path) else {{}}
    args = sys.argv[1:]
    if args[:2] == ["kv", "list"]:
        print(json.dumps(dict(kv, schema_version=1)))
    elif args[:2] == ["kv", "set"]:
        kv[args[2]] = args[3]
    elif args[:2] == ["kv", "clear"]:
        kv.pop(args[2], None)
    elif args[0] == "list":
        print(open(os.path.join(state, "members.json")).read())
    elif args[:2] == ["label", "remove"]:
        pass
    else:
        sys.exit("fake bd: unhandled " + " ".join(args))
    json.dump(kv, open(kv_path, "w"))
    """)


class WaveTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = self.tmp.name
        bindir = os.path.join(self.dir, "bin")
        os.mkdir(bindir)
        bd = os.path.join(bindir, "bd")
        with open(bd, "w") as f:
            f.write(FAKE_BD.format(python=sys.executable))
        os.chmod(bd, 0o755)
        self.env = dict(os.environ,
                        PATH=bindir + os.pathsep + os.environ["PATH"],
                        WAVE_FAKE_BD=self.dir,
                        GIT_CEILING_DIRECTORIES=self.dir)
        self.work = os.path.join(self.dir, "work")
        os.mkdir(self.work)

    def tearDown(self):
        self.tmp.cleanup()

    def wave(self, *args, ok=True):
        r = subprocess.run([sys.executable, WAVE, *args], cwd=self.work,
                           env=self.env, capture_output=True, text=True)
        if ok:
            self.assertEqual(r.returncode, 0, r.stderr)
        else:
            self.assertNotEqual(r.returncode, 0, r.stdout)
        return r

    def kv(self):
        path = os.path.join(self.dir, "kv.json")
        return json.load(open(path)) if os.path.exists(path) else {}

    def members(self, *issues):
        with open(os.path.join(self.dir, "members.json"), "w") as f:
            json.dump([{"id": i, "status": st, "title": i} for i, st in issues], f)

    def test_dispatch_refuses_an_existing_wave(self):
        self.wave("dispatch", "12", "--at", "2026-10-18T08:00:00Z")
        r = self.wave("dispatch", "12", ok=False)
        self.assertIn("already has dispatched", r.stderr)
        self.assertEqual(self.kv()["wave.12.dispatched"], "2026-10-18T08:00:00Z")
        self.wave("dispatch", "12", "--force", "--at", "2026-10-19T08:00:00Z")
        self.assertEqual(self.kv()["wave.12.dispatched"], "2026-10-19T08:00:00Z")

    def test_check_flags_open_members(self):
        self.members(("a-1", "closed"), ("a-2", "in_progress"))
        r = self.wave("check", "9", ok=False)
        self.assertIn("a-2", r.stdout)
        self.members(("a-1", "closed"))
        self.assertIn("all members closed", self.wave("check", "9").stdout)

    def test_drop_clears_keys_and_unlabels(self):
        self.members(("a-1", "closed"))
        self.wave("dispatch", "78-test", "--at", "2026-10-18T08:00:00Z")
        self.wave("model", "78-test", "a-1", "m")
        self.wave("dispatch", "7", "--at", "2026-10-18T08:00:00Z")
        self.wave("drop", "78-test")
        self.assertEqual(list(self.kv()), ["wave.7.dispatched"])
        calls = open(os.path.join(self.dir, "calls.log")).read()
        self.assertIn('["label", "remove", "a-1", "wave-78-test"]', calls)

    def test_review_start_and_done_with_counts(self):
        self.wave("review", "start", "12", "--at", "2026-10-18T10:00:00+02:00")
        self.wave("review", "done", "wave-12", "--findings", "3", "--fixed", "2",
                  "--at", "2026-10-18T08:40:00Z")
        self.assertEqual(self.kv(), {
            "wave.12.review.started": "2026-10-18T08:00:00Z",
            "wave.12.review.finished": "2026-10-18T08:40:00Z findings=3 fixed=2",
        })

    def test_review_done_without_counts_is_just_the_time(self):
        self.wave("review", "start", "12", "--at", "2026-10-18T08:00:00Z")
        self.wave("review", "done", "12", "--at", "2026-10-18T08:40:00Z")
        self.assertEqual(self.kv()["wave.12.review.finished"], "2026-10-18T08:40:00Z")
        self.wave("review", "done", "12", "--fixed", "0", "--at", "2026-10-18T08:41:00Z")
        self.assertEqual(self.kv()["wave.12.review.finished"],
                         "2026-10-18T08:41:00Z fixed=0")

    def test_review_done_needs_review_start(self):
        r = self.wave("review", "done", "12", "--findings", "1", ok=False)
        self.assertIn("no review.started", r.stderr)
        self.assertIn("wave review start 12", r.stderr)
        self.assertEqual(self.kv(), {})

    def test_negative_counts_are_refused(self):
        self.wave("review", "start", "12")
        r = self.wave("review", "done", "12", "--findings", "-1", ok=False)
        self.assertIn("must be 0 or more", r.stderr)
        self.assertNotIn("wave.12.review.finished", self.kv())

    def test_merge_done_needs_merge_start(self):
        self.wave("review", "start", "12")
        self.wave("review", "done", "12")
        r = self.wave("merge", "done", "12", "--sha", "abc1234", ok=False)
        self.assertIn("no merge.started", r.stderr)
        self.assertNotIn("wave.12.merge.completed", self.kv())

    def test_merge_without_review_or_dispatch(self):
        self.wave("merge", "start", "12", "--at", "2026-10-18T09:00:00Z")
        r = self.wave("merge", "done", "12", "--sha", "abc1234",
                      "--at", "2026-10-18T09:05:00Z")
        self.assertEqual(r.stderr, "")
        self.assertEqual(self.kv(), {
            "wave.12.merge.started": "2026-10-18T09:00:00Z",
            "wave.12.merge.completed": "2026-10-18T09:05:00Z abc1234",
        })

    def test_merge_done_outside_git_records_no_sha(self):
        self.wave("merge", "start", "12", "--at", "2026-10-18T09:00:00Z")
        self.wave("merge", "done", "12", "--at", "2026-10-18T09:05:00Z")
        self.assertEqual(self.kv()["wave.12.merge.completed"], "2026-10-18T09:05:00Z")

    def test_merge_start_warns_when_review_unfinished(self):
        self.wave("review", "start", "12")
        r = self.wave("merge", "start", "12")
        self.assertIn("review started but not finished", r.stderr)
        self.assertIn("wave.12.merge.started", self.kv())

    def test_restarting_a_phase_warns_and_clears_its_end(self):
        self.wave("review", "start", "12", "--at", "2026-10-18T08:00:00Z")
        self.wave("review", "done", "12", "--findings", "2", "--fixed", "2",
                  "--at", "2026-10-18T08:30:00Z")
        r = self.wave("review", "start", "12", "--at", "2026-10-18T09:00:00Z")
        self.assertIn("already started 2026-10-18T08:00:00Z; overwriting", r.stderr)
        self.assertIn("clearing review.finished", r.stderr)
        self.assertEqual(self.kv(), {"wave.12.review.started": "2026-10-18T09:00:00Z"})

    def test_first_start_is_silent(self):
        r = self.wave("merge", "start", "12")
        self.assertEqual(r.stderr, "")

    def test_end_before_start_warns(self):
        self.wave("merge", "start", "12", "--at", "2026-10-18T09:00:00Z")
        r = self.wave("merge", "done", "12", "--sha", "abc1234",
                      "--at", "2026-10-18T08:00:00Z")
        self.assertIn("is before merge.started", r.stderr)

    def test_show_prints_phases(self):
        self.wave("dispatch", "12", "--title", "Twelve", "--at", "2026-10-18T07:00:00Z")
        self.wave("review", "start", "12", "--at", "2026-10-18T08:00:00Z")
        self.wave("review", "done", "12", "--findings", "1", "--fixed", "1",
                  "--at", "2026-10-18T08:30:00Z")
        self.wave("merge", "start", "12", "--at", "2026-10-18T08:45:00Z")
        self.wave("merge", "start", "13", "--at", "2026-10-18T09:00:00Z")
        out = self.wave("show").stdout.splitlines()
        self.assertEqual(out, [
            "wave-12\t2026-10-18T07:00:00Z\t-\tTwelve",
            "  review\t2026-10-18T08:00:00Z\t2026-10-18T08:30:00Z findings=1 fixed=1",
            "  merge\t2026-10-18T08:45:00Z\t-",
            "wave-13\t-\t-\t",
            "  merge\t2026-10-18T09:00:00Z\t-",
        ])
        self.assertEqual(self.wave("show", "13").stdout.splitlines(), out[3:])

    def test_tokens_set_then_add(self):
        self.wave("tokens", "12", "demo-a", "67000")
        self.assertEqual(self.kv(), {"wave.12.tokens.demo-a": "67000"})
        self.wave("tokens", "wave-12", "demo-a", "1500", "--add")
        self.assertEqual(self.kv()["wave.12.tokens.demo-a"], "68500")
        self.wave("tokens", "12", "demo-a", "100")
        self.assertEqual(self.kv()["wave.12.tokens.demo-a"], "100")

    def test_tokens_add_with_nothing_recorded_starts_at_zero(self):
        self.wave("tokens", "12", "demo-b", "42", "--add")
        self.assertEqual(self.kv(), {"wave.12.tokens.demo-b": "42"})

    def test_tokens_refuses_negative_and_garbage(self):
        r = self.wave("tokens", "12", "demo-a", "-5", ok=False)
        self.assertIn("must be 0 or more", r.stderr)
        self.wave("tokens", "12", "demo-a", "12k", ok=False)
        self.assertEqual(self.kv(), {})

    def test_usage_sets_fields_and_mirrors_tokens(self):
        self.wave("usage", "12", "demo-a", "--input", "1000", "--output", "200",
                  "--cache-read", "500", "--cost", "0.045", "--turns", "3")
        self.assertEqual(self.kv(), {
            "wave.12.usage.demo-a.input": "1000",
            "wave.12.usage.demo-a.output": "200",
            "wave.12.usage.demo-a.cache_read": "500",
            "wave.12.usage.demo-a.cost": "0.045",
            "wave.12.usage.demo-a.turns": "3",
            "wave.12.tokens.demo-a": "1200",
        })

    def test_usage_add_sums_only_given_fields(self):
        self.wave("usage", "12", "demo-a", "--input", "1000", "--output", "200",
                  "--cache-read", "500", "--cost", "0.045", "--turns", "3")
        self.wave("usage", "wave-12", "demo-a", "--input", "300", "--output", "50",
                  "--add")
        kv = self.kv()
        self.assertEqual(kv["wave.12.usage.demo-a.input"], "1300")
        self.assertEqual(kv["wave.12.usage.demo-a.output"], "250")
        # untouched fields are unaffected by a partial --add
        self.assertEqual(kv["wave.12.usage.demo-a.cache_read"], "500")
        self.assertEqual(kv["wave.12.usage.demo-a.cost"], "0.045")
        self.assertEqual(kv["wave.12.usage.demo-a.turns"], "3")
        # tokens mirrors the current input+output, not a separately summed value
        self.assertEqual(kv["wave.12.tokens.demo-a"], "1550")

    def test_usage_needs_at_least_one_field(self):
        r = self.wave("usage", "12", "demo-a", ok=False)
        self.assertIn("needs at least one of", r.stderr)
        self.assertEqual(self.kv(), {})

    def test_usage_cost_only_does_not_touch_tokens(self):
        self.wave("usage", "12", "demo-a", "--cost", "0.5")
        self.assertEqual(self.kv(), {
            "wave.12.usage.demo-a.cost": "0.5",
            "wave.12.tokens.demo-a": "0",
        })

    def test_usage_refuses_negative(self):
        r = self.wave("usage", "12", "demo-a", "--input", "-5", ok=False)
        self.assertIn("must be 0 or more", r.stderr)
        self.assertEqual(self.kv(), {})

    def test_phases_write_only_kv(self):
        self.wave("review", "start", "12")
        self.wave("review", "done", "12")
        self.wave("merge", "start", "12")
        self.wave("merge", "done", "12", "--sha", "abc1234")
        with open(os.path.join(self.dir, "calls.log")) as f:
            calls = [json.loads(line) for line in f]
        self.assertTrue(all(c[0] == "kv" for c in calls), calls)


if __name__ == "__main__":
    unittest.main()
