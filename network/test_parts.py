"""Secret-free checks of the network check's own parts, for pull requests:
fake-codex answers the way agentiscaled's codex runtime reads it, and
check_answer.py passes only a completed task that carries the nonce, so the
stand-in agent and the check of its answer are exercised without the service
or a join code.

Run: python3 -I network/test_parts.py
"""

import json
import os
import subprocess
import sys
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
NONCE = "network-check-0123abcd"


def fake_codex_answer(prompt):
    """What fake-codex leaves as its last message, run as the codex runtime runs it."""
    with tempfile.TemporaryDirectory() as d:
        last = os.path.join(d, "last.json")
        subprocess.run([os.path.join(HERE, "fake-codex"), "exec", "--json", "--output-last-message", last, "-"],
                       input=prompt, text=True, check=True, stdout=subprocess.DEVNULL)
        with open(last) as f:
            return json.load(f)["text"]


class NetworkCheckParts(unittest.TestCase):
    def check(self, task):
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "task.json")
            with open(path, "w") as f:
                f.write(task if isinstance(task, str) else json.dumps(task))
            return subprocess.run([sys.executable, "-I", os.path.join(HERE, "check_answer.py"), path, NONCE],
                                  capture_output=True, text=True, timeout=30)

    def test_agent_answers_with_the_nonce(self):
        answer = fake_codex_answer(f"Reply with this nonce: {NONCE}")
        r = self.check({"task_id": "t1", "state": "completed", "terminal": "completed", "result": answer})
        self.assertEqual(r.returncode, 0, r.stdout + r.stderr)
        self.assertIn("task t1 ended completed", r.stdout)

    def test_wrong_answer_fails(self):
        r = self.check({"task_id": "t1", "state": "completed", "terminal": "completed", "result": "echo something else"})
        self.assertNotEqual(r.returncode, 0)
        self.assertIn(f"want a completed task answering {NONCE}", r.stderr)

    def test_failed_task_fails(self):
        r = self.check({"task_id": "t1", "state": "failed", "terminal": "failed", "result": f"echo {NONCE}"})
        self.assertNotEqual(r.returncode, 0)

    def test_no_answer_fails(self):
        r = self.check("")
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("no task answer", r.stderr)

    def test_fake_codex_version(self):
        r = subprocess.run([os.path.join(HERE, "fake-codex"), "--version"], capture_output=True, text=True, check=True)
        self.assertIn("network-check", r.stdout)


if __name__ == "__main__":
    unittest.main()
