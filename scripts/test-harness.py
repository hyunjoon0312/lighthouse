#!/usr/bin/env python3
"""Regression tests for Lighthouse's local Codex harness configuration and ledger."""

from __future__ import annotations

import json
from pathlib import Path
import subprocess
import sys
import tempfile
import tomllib
import unittest


ROOT = Path(__file__).resolve().parents[1]
HARNESS_SCRIPTS = ROOT / ".agents" / "skills" / "harness" / "scripts"
RUN = HARNESS_SCRIPTS / "run.py"
VALIDATE = HARNESS_SCRIPTS / "validate.py"
COMMUNICATION = HARNESS_SCRIPTS / "communication.py"


class CliCase(unittest.TestCase):
    maxDiff = None

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory(prefix="lighthouse-harness-test-")
        self.project = Path(self.temporary.name).resolve()
        (self.project / ".codex").mkdir()
        (self.project / ".codex" / "config.toml").write_text(
            "[agents]\nenabled = true\nmax_concurrent_threads_per_session = 3\n",
            encoding="utf-8",
        )
        for relative, content in {
            "contracts/a.txt": "A contract v1\n",
            "contracts/b.txt": "B contract v1\n",
            "contracts/consumer.txt": "consumer contract v1\n",
            "skills/workflow.md": "fixture workflow\n",
        }.items():
            path = self.project / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(content, encoding="utf-8")

    def tearDown(self) -> None:
        self.temporary.cleanup()

    def cli(self, script: Path, *arguments: str, ok: bool = True) -> subprocess.CompletedProcess[str]:
        completed = subprocess.run(
            [sys.executable, str(script), "--project", str(self.project), *arguments],
            cwd=self.project,
            text=True,
            capture_output=True,
            check=False,
        )
        detail = f"stdout:\n{completed.stdout}\nstderr:\n{completed.stderr}"
        if ok:
            self.assertEqual(completed.returncode, 0, detail)
        else:
            self.assertNotEqual(completed.returncode, 0, detail)
        return completed

    def run_cli(self, *arguments: str, ok: bool = True) -> subprocess.CompletedProcess[str]:
        return self.cli(RUN, *arguments, ok=ok)

    def write_json(self, relative: str, value: object) -> Path:
        path = self.project / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")
        return path

    def plan(self, *, overlap: bool = False, missing_input: bool = False) -> Path:
        a_owned = "outputs/shared/a.txt" if overlap else "outputs/a.txt"
        b_owned = "outputs/shared" if overlap else "outputs/b.txt"
        return self.write_json(
            "fixture-plan.json",
            {
                "objective": "Exercise the harness ledger with isolated fixture files",
                "tasks": [
                    {
                        "id": "A",
                        "role": "harness_worker",
                        "dependencies": [],
                        "ownership": [a_owned],
                        "inputs": ["contracts/missing.txt" if missing_input else "contracts/a.txt"],
                        "context": {
                            "decisions": ["A writes only its fixture output"],
                            "skill_paths": ["skills/workflow.md"],
                        },
                        "acceptance": ["A output exists"],
                        "required": True,
                    },
                    {
                        "id": "B",
                        "role": "harness_worker",
                        "dependencies": [],
                        "ownership": [b_owned],
                        "inputs": ["contracts/b.txt"],
                        "context": {
                            "decisions": ["B writes only its fixture output"],
                            "skill_paths": ["skills/workflow.md"],
                        },
                        "acceptance": ["B output exists"],
                        "required": True,
                    },
                    {
                        "id": "consumer",
                        "role": "harness_qa",
                        "dependencies": ["A"],
                        "ownership": ["outputs/consumer.txt"],
                        "inputs": ["contracts/consumer.txt"],
                        "context": {
                            "decisions": ["Consumer reads only accepted A output"],
                            "skill_paths": ["skills/workflow.md"],
                        },
                        "acceptance": ["Consumer output exists"],
                        "required": True,
                    },
                ],
            },
        )

    def init(self, run_id: str = "fixture-run", **plan_options: bool) -> dict:
        plan = self.plan(**plan_options)
        result = self.run_cli("init", "--plan-file", str(plan), "--run-id", run_id)
        return json.loads(result.stdout)

    def result_payload(
        self,
        run_id: str,
        task_id: str,
        status: str,
        artifacts: list[str] | None,
        *,
        check_status: str = "passed",
        evidence: str = "fixture output and state inspected",
        include_artifacts: bool = True,
    ) -> Path:
        value = {
            "run_id": run_id,
            "task_id": task_id,
            "status": status,
            "summary": f"Fixture task {task_id} ended as {status}",
            "checks": [
                {
                    "name": "fixture state check",
                    "status": check_status,
                    "required": True,
                    "command": f"fixture:{task_id}",
                    "evidence": evidence,
                }
            ],
            "issues": [] if status == "completed" else ["intentional fixture failure"],
        }
        if include_artifacts:
            value["artifacts"] = artifacts or []
        return self.write_json(f"submissions/{run_id}-{task_id}-{check_status}.json", value)

    def finish(
        self,
        run_id: str,
        task_id: str,
        agent_id: str,
        artifact: str,
        content: str,
    ) -> None:
        self.run_cli("start", "--run", run_id, "--task", task_id, "--agent-id", agent_id)
        output = self.project / artifact
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(content, encoding="utf-8")
        result = self.result_payload(run_id, task_id, "completed", [artifact])
        self.run_cli("result", "--run", run_id, "--task", task_id, "--result-file", str(result))
        self.run_cli(
            "agent",
            "--run",
            run_id,
            "--agent-id",
            agent_id,
            "--state",
            "idle",
            "--evidence",
            "test fixture observed the simulated native worker return",
        )

    def complete_run(self, run_id: str = "fixture-run") -> None:
        self.init(run_id)
        self.finish(run_id, "A", "test-fixture-agent-a", "outputs/a.txt", "A output\n")
        self.finish(run_id, "B", "test-fixture-agent-b", "outputs/b.txt", "B output\n")
        self.finish(
            run_id,
            "consumer",
            "test-fixture-agent-a",
            "outputs/consumer.txt",
            "consumer output\n",
        )


class ProjectPolicyTests(unittest.TestCase):
    def test_project_agent_and_config_policy(self) -> None:
        expected = {
            "lighthouse_app": ("gpt-5.6-sol", "medium", "workspace-write"),
            "lighthouse_imaging": ("gpt-5.6-sol", "medium", "workspace-write"),
            "lighthouse_catalog": ("gpt-5.6-sol", "medium", "workspace-write"),
            "lighthouse_reviewer": ("gpt-6-astra", "high", "read-only"),
            "lighthouse_qa": ("gpt-6-astra", "high", "workspace-write"),
        }
        agent_dir = ROOT / ".codex" / "agents"
        self.assertEqual({path.stem for path in agent_dir.glob("*.toml")}, set(expected))
        for name, values in expected.items():
            data = tomllib.loads((agent_dir / f"{name}.toml").read_text(encoding="utf-8"))
            self.assertEqual(data.get("name"), name)
            self.assertEqual(
                (data.get("model"), data.get("model_reasoning_effort"), data.get("sandbox_mode")),
                values,
            )

        config = tomllib.loads((ROOT / ".codex" / "config.toml").read_text(encoding="utf-8"))
        self.assertEqual(config.get("agents", {}).get("enabled"), True)
        self.assertEqual(config.get("agents", {}).get("max_concurrent_threads_per_session"), 3)
        for forbidden in ("model", "model_provider", "sandbox_mode", "approval_policy"):
            self.assertNotIn(forbidden, config)

        for skill in ("lighthouse-development", "astra-sol-workflow", "harness"):
            self.assertTrue((ROOT / ".agents" / "skills" / skill / "SKILL.md").is_file())


class LedgerRegressionTests(CliCase):
    def test_happy_path_packets_and_completion(self) -> None:
        run_id = "happy"
        self.init(run_id)
        ready = json.loads(self.run_cli("ready", "--run", run_id).stdout)
        self.assertEqual(ready["ready"], ["A", "B"])
        self.assertEqual(ready["blocked"]["consumer"], ["Dependency A is pending."])

        self.run_cli("start", "--run", run_id, "--task", "A", "--agent-id", "test-fixture-agent-a")
        packet = (self.project / ".harness" / "runs" / run_id / "task-A" / "input.md").read_text(encoding="utf-8")
        self.assertIn(f"Working root: {self.project}", packet)
        self.assertIn("A writes only its fixture output", packet)
        self.assertIn("skills/workflow.md", packet)
        self.assertIn('"contracts/a.txt": "sha256:', packet)
        output = self.project / "outputs" / "a.txt"
        output.parent.mkdir(parents=True)
        output.write_text("A output\n", encoding="utf-8")
        result = self.result_payload(run_id, "A", "completed", ["outputs/a.txt"])
        self.run_cli("result", "--run", run_id, "--task", "A", "--result-file", str(result))
        self.run_cli("agent", "--run", run_id, "--agent-id", "test-fixture-agent-a", "--state", "idle", "--evidence", "fixture return observed")

        self.finish(run_id, "B", "test-fixture-agent-b", "outputs/b.txt", "B output\n")
        ready = json.loads(self.run_cli("ready", "--run", run_id).stdout)
        self.assertEqual(ready["ready"], ["consumer"])
        self.finish(run_id, "consumer", "test-fixture-agent-a", "outputs/consumer.txt", "consumer output\n")
        completed = self.cli(VALIDATE, "--run", run_id, "--complete")
        self.assertIn("PASS: run happy", completed.stdout)

    def test_failure_dependency_evidence_and_missing_input(self) -> None:
        run_id = "failure"
        self.init(run_id)
        self.run_cli("start", "--run", run_id, "--task", "A", "--agent-id", "test-fixture-agent-a")
        failed = self.result_payload(run_id, "A", "failed", [], check_status="failed", evidence="intentional fixture failure")
        self.run_cli("result", "--run", run_id, "--task", "A", "--result-file", str(failed))
        self.run_cli("agent", "--run", run_id, "--agent-id", "test-fixture-agent-a", "--state", "idle", "--evidence", "fixture failure returned")
        refused = self.run_cli("start", "--run", run_id, "--task", "consumer", "--agent-id", "test-fixture-agent-c", ok=False)
        self.assertIn("Dependency A is failed", refused.stderr)
        self.assertNotEqual(self.cli(VALIDATE, "--run", run_id, "--complete", ok=False).returncode, 0)

        self.run_cli("start", "--run", run_id, "--task", "B", "--agent-id", "test-fixture-agent-b")
        output = self.project / "outputs" / "b.txt"
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text("B output\n", encoding="utf-8")
        no_artifacts = self.result_payload(run_id, "B", "completed", None, include_artifacts=False)
        self.assertIn("Result artifacts", self.run_cli("result", "--run", run_id, "--task", "B", "--result-file", str(no_artifacts), ok=False).stderr)
        no_evidence = self.result_payload(run_id, "B", "completed", ["outputs/b.txt"], evidence="")
        self.assertIn("non-empty evidence", self.run_cli("result", "--run", run_id, "--task", "B", "--result-file", str(no_evidence), ok=False).stderr)
        for status in ("failed", "not_run"):
            bad_check = self.result_payload(run_id, "B", "completed", ["outputs/b.txt"], check_status=status, evidence="fixture check did not pass")
            rejected = self.run_cli("result", "--run", run_id, "--task", "B", "--result-file", str(bad_check), ok=False)
            self.assertIn("required and has not passed", rejected.stderr)

        missing_plan = self.plan(missing_input=True)
        self.run_cli("init", "--plan-file", str(missing_plan), "--run-id", "missing-input")
        missing_status = json.loads(self.run_cli("status", "--run", "missing-input").stdout)
        missing_a = next(task for task in missing_status["plan"]["tasks"] if task["id"] == "A")
        self.assertEqual(missing_a["input_fingerprints"]["contracts/missing.txt"], "missing")

        # The ledger records a missing immutable input; this fixture does not
        # claim that a native worker should have been dispatched. Model the
        # already-started edge case and verify that its blocked result keeps
        # both the dependent task and run completion closed.
        self.run_cli(
            "start",
            "--run",
            "missing-input",
            "--task",
            "A",
            "--agent-id",
            "test-fixture-missing-input-agent",
        )
        blocked = self.result_payload(
            "missing-input",
            "A",
            "blocked",
            [],
            check_status="not_run",
            evidence="required immutable input was absent",
        )
        self.run_cli(
            "result",
            "--run",
            "missing-input",
            "--task",
            "A",
            "--result-file",
            str(blocked),
        )
        self.run_cli(
            "agent",
            "--run",
            "missing-input",
            "--agent-id",
            "test-fixture-missing-input-agent",
            "--state",
            "idle",
            "--evidence",
            "fixture blocked result returned without native execution evidence",
        )
        consumer = self.run_cli(
            "start",
            "--run",
            "missing-input",
            "--task",
            "consumer",
            "--agent-id",
            "test-fixture-consumer-agent",
            ok=False,
        )
        self.assertIn("Dependency A is blocked", consumer.stderr)
        incomplete = self.cli(VALIDATE, "--run", "missing-input", "--complete", ok=False)
        self.assertIn("Required task A is blocked", incomplete.stderr)

    def test_overlapping_running_ownership_is_rejected(self) -> None:
        run_id = "ownership"
        self.init(run_id, overlap=True)
        self.run_cli("start", "--run", run_id, "--task", "A", "--agent-id", "test-fixture-agent-a")
        rejected = self.run_cli("start", "--run", run_id, "--task", "B", "--agent-id", "test-fixture-agent-b", ok=False)
        self.assertIn("overlapping write ownership", rejected.stderr)

    def test_resume_invalidates_changed_input_and_consumer_only(self) -> None:
        old_id, new_id = "resume-old", "resume-new"
        self.complete_run(old_id)
        old_plan = self.project / ".harness" / "runs" / old_id / "plan.json"
        old_bytes = old_plan.read_bytes()
        (self.project / "contracts" / "a.txt").write_text("A contract v2\n", encoding="utf-8")

        resumed = json.loads(self.run_cli("resume", "--run", old_id, "--new-run", new_id).stdout)
        self.assertEqual(resumed["reused"], ["B"])
        self.assertEqual(set(resumed["pending"]), {"A", "consumer"})
        self.assertEqual(old_plan.read_bytes(), old_bytes)
        status = json.loads(self.run_cli("status", "--run", new_id).stdout)
        by_id = {task["id"]: task["status"] for task in status["plan"]["tasks"]}
        self.assertEqual(by_id, {"A": "pending", "B": "completed", "consumer": "pending"})

    def test_changed_accepted_artifact_breaks_completion(self) -> None:
        run_id = "artifact-drift"
        self.complete_run(run_id)
        (self.project / "outputs" / "a.txt").write_text("changed after acceptance\n", encoding="utf-8")
        failed = self.cli(VALIDATE, "--run", run_id, "--complete", ok=False)
        self.assertIn("accepted artifact snapshot is stale", failed.stderr)

    def test_communication_records_linked_fixture_events(self) -> None:
        run_id = "communication-fixture"
        recorded = self.cli(
            COMMUNICATION,
            "--run",
            run_id,
            "log",
            "--sender",
            "test-fixture-sender",
            "--recipient",
            "test-fixture-recipient",
            "--kind",
            "question",
            "--task",
            "A",
            "--delivery",
            "recorded",
            "--body",
            "fixture question; no native delivery occurred",
        )
        first = json.loads(recorded.stdout)
        sent = self.cli(
            COMMUNICATION,
            "--run",
            run_id,
            "log",
            "--sender",
            "test-fixture-sender",
            "--recipient",
            "test-fixture-recipient",
            "--kind",
            "question",
            "--task",
            "A",
            "--delivery",
            "sent",
            "--reply-to",
            first["message_id"],
            "--body",
            "fixture sent observation; this is not native-agent evidence",
        )
        second = json.loads(sent.stdout)
        self.assertEqual(second["reply_to"], first["message_id"])
        log = self.project / "_workspace" / "communications" / f"{run_id}.jsonl"
        events = [json.loads(line) for line in log.read_text(encoding="utf-8").splitlines()]
        self.assertEqual([event["delivery"] for event in events], ["recorded", "sent"])
        self.assertTrue(all(event["sender"].startswith("test-fixture-") for event in events))


if __name__ == "__main__":
    unittest.main(verbosity=2)
