"""Check the answer of `agentiscaled task send -json`: exits non-zero unless
the task completed and its result carries the nonce.

Usage: check_answer.py TASK_JSON NONCE
"""

import json
import sys


def main():
    if len(sys.argv) != 3:
        sys.exit(__doc__)
    path, nonce = sys.argv[1:]
    try:
        with open(path) as f:
            task = json.load(f)
    except (OSError, ValueError) as e:
        sys.exit(f"no task answer in {path}: {e}")
    if not isinstance(task, dict):
        sys.exit(f"no task answer in {path}: {task!r}")
    ended = task.get("terminal") or task.get("state")
    print(f"task {task.get('task_id')} ended {ended}: {task.get('result') or task.get('message')}", flush=True)
    if task.get("terminal") != "completed" or nonce not in (task.get("result") or ""):
        sys.exit(f"want a completed task answering {nonce}, got {task}")


if __name__ == "__main__":
    main()
