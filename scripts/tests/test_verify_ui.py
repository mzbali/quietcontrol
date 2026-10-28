#!/usr/bin/env python3
"""Acceptance-rule tests for scripts/verify-ui.py.

These exercise the runner's decision rules with small saved enumeration,
xcresult and app-container samples. They deliberately do not mirror internal
implementation details: each case is a false-green or cleanup scenario that
must fail (or a valid sample that must pass).
"""

from __future__ import annotations

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.dont_write_bytecode = True

SCRIPTS = Path(__file__).resolve().parents[1]
ROOT = SCRIPTS.parent
SPEC = importlib.util.spec_from_file_location("verify_ui", SCRIPTS / "verify-ui.py")
verify = importlib.util.module_from_spec(SPEC)
sys.modules["verify_ui"] = verify
SPEC.loader.exec_module(verify)


SYNTHETIC = {
    "peripheralUUID": "11111111-2222-4333-8444-555555555555",
    "manufacturer": "Bose Corporation",
    "model": "884367-0100",
    "firmware": "1.0.6-80+f5f219b",
    "defaultsSuitePrefix": "uk.co.mzbali.quietcontrol.ui-tests.",
    "devices": [
        {"address": "a1 b2 c3 d4 e5 01", "name": "iPhone", "connected": True},
        {"address": "a1 b2 c3 d4 e5 02", "name": "MacBook Pro", "connected": True},
        {"address": "a1 b2 c3 d4 e5 03", "name": "Work laptop", "connected": False},
    ],
}

DEVICES = [
    "QuietControlTests/QuietControlSessionTests/testOne()",
    "QuietControlTests/QuietControlSessionTests/testQuietWaitingClearsBusyWithoutReplacingPendingConnection()",
    "QuietControlUITests/QuietControlUITests/testJourney()",
]


def manifest_fixture() -> dict:
    return {
        "schemaVersion": 1,
        "synthetic": copy.deepcopy(SYNTHETIC),
        "simulator": {
            "deviceTypes": ["iPhone Duo"],
            "runtime": "iOS 27.1",
            "minimumRuntimeMajor": 17,
            "compactDeviceTypes": ["iPhone SE (3rd generation)"],
        },
        "session": {
            "target": "QuietControlTests",
            "tests": [
                {
                    "id": DEVICES[0],
                    "label": "one",
                    "run": {"prefix": "unit-", "scenario": "connected", "reset": True},
                    "expect": {
                        "snapshot": {"lastMode": 1, "eq": [-1, 4, 2]},
                        "peripheral": {"connected": True, "mode": 1, "eq": [-1, 4, 2], "multipoint": True},
                        "transcript": {
                            "scenarios": ["connected"],
                            "order": ["outbound:1f0305020100", "inbound:1f03030101"],
                        },
                    },
                },
                {
                    "id": DEVICES[1],
                    "label": "two",
                    "run": {"prefix": "pending-", "artifacts": False},
                },
            ],
        },
        "journeys": [
            {
                "name": "modes",
                "test": DEVICES[2],
                "run": {"prefix": "aware-", "scenario": "connected", "reset": True},
                "expect": {
                    "snapshot": {"lastMode": 1, "eq": [-1, 4, 2]},
                    "peripheral": {"connected": True, "mode": 1, "eq": [-1, 4, 2], "multipoint": True},
                    "transcript": {
                        "scenarios": ["connected"],
                        "order": [
                            "outbound:1f0305020100",
                            "inbound:1f03030101",
                            "outbound:1f030100",
                            "inbound:1f03030101",
                        ],
                    },
                },
            }
        ],
    }


def transcript_row(sequence, direction, kind, packet="", scenario="connected", message=None):
    row = {
        "sequence": sequence,
        "timestamp": "2026-10-28T02:00:00Z",
        "direction": direction,
        "kind": kind,
        "bytes": packet,
        "scenario": scenario,
        "peripheral": SYNTHETIC["peripheralUUID"],
        "connection": "simulated",
    }
    if message is not None:
        row["message"] = message
    return row


def snapshot_fixture(last_mode=1):
    return {
        "version": 1,
        "peripheralID": SYNTHETIC["peripheralUUID"],
        "manufacturer": SYNTHETIC["manufacturer"],
        "model": SYNTHETIC["model"],
        "firmware": SYNTHETIC["firmware"],
        "modes": [{"index": 0, "name": "Quiet"}, {"index": 1, "name": "Aware"}],
        "eq": [
            {"band": 0, "value": -1},
            {"band": 1, "value": 4},
            {"band": 2, "value": 2},
        ],
        "lastMode": last_mode,
        "lastSeen": "2026-10-28T02:00:00Z",
        "battery": 90,
    }


def peripheral_fixture(scenario="connected", connected=True, mode=1):
    return {
        "scenario": scenario,
        "runID": "aware-1234ABCD",
        "connected": connected,
        "mode": mode,
        "eq": [-1, 4, 2],
        "multipoint": True,
        "devices": [
            {"address": device["address"], "name": device["name"], "connected": device["connected"]}
            for device in SYNTHETIC["devices"]
        ],
        "updatedAt": "2026-10-28T02:00:00Z",
    }


def make_export(tmp: Path, run_id: str, rows, config=None, snapshot=None, state=None, omit=()):
    run_dir = tmp / "ApplicationSupport" / "QuietControlUITests" / run_id
    run_dir.mkdir(parents=True)
    config = config if config is not None else {
        "scenario": "connected",
        "runID": run_id,
        "reset": True,
        "peripheral": SYNTHETIC["peripheralUUID"],
        "defaultsSuite": SYNTHETIC["defaultsSuitePrefix"] + run_id,
    }
    files = {
        "test-config.json": json.dumps(config, indent=2),
        "transport.jsonl": "\n".join(json.dumps(row) for row in rows) + "\n",
        "LastConfirmedState.json": json.dumps(snapshot if snapshot is not None else snapshot_fixture()),
        "peripheral-state.json": json.dumps(state if state is not None else peripheral_fixture()),
    }
    for name, content in files.items():
        if name not in omit:
            (run_dir / name).write_text(content, encoding="utf-8")
    return run_dir


def valid_rows():
    return [
        transcript_row(1, "event", "event", scenario="connected", message="Configured connected."),
        transcript_row(2, "event", "event", scenario="connected", message="Simulated QC connected."),
        transcript_row(3, "outbound", "bmap", "1f 03 05 02 01 00"),
        transcript_row(4, "inbound", "bmap", "1f 03 03 01 01"),
        transcript_row(5, "outbound", "bmap", "1f 03 01 00"),
        transcript_row(6, "inbound", "bmap", "1f 03 03 01 01"),
    ]


class ManifestTests(unittest.TestCase):
    def test_evidence_cannot_be_disabled_for_arbitrary_tests(self):
        for bucket in ("session", "ui"):
            with self.subTest(bucket=bucket):
                manifest = manifest_fixture()
                entry = manifest["session"]["tests"][0] if bucket == "session" else manifest["journeys"][0]
                entry["run"]["artifacts"] = False
                with self.assertRaisesRegex(verify.VerifyError, "no-artifact exemption"):
                    verify.validate_manifest(manifest)

    def test_allowlisted_pending_test_needs_no_container_evidence(self):
        manifest = manifest_fixture()
        verify.validate_manifest(manifest)
        entry = manifest["session"]["tests"][1]
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(verify.inspect_entry_artifacts(entry, Path(tmp), SYNTHETIC), [])

    def test_current_manifest_is_valid_and_selectable(self):
        manifest = verify.load_manifest()
        names = {journey["name"] for journey in manifest["journeys"]}
        self.assertTrue({"modes", "mode-rejected", "mode-unconfirmed", "offline"} <= names)
        self.assertEqual(
            len(verify.all_manifest_tests(manifest)),
            len(set(verify.all_manifest_tests(manifest))),
        )
        selected = verify.select_journeys(manifest, [], "ui")
        self.assertEqual(selected, manifest["journeys"])

    def test_duplicate_test_and_unknown_key_are_rejected(self):
        manifest = manifest_fixture()
        duplicate = copy.deepcopy(manifest["journeys"][0])
        duplicate["name"] = "other"
        manifest["journeys"].append(duplicate)
        with self.assertRaises(verify.VerifyError):
            verify.validate_manifest(manifest)

        manifest = manifest_fixture()
        manifest["journeys"][0]["expect"]["peripheral"]["battery"] = 90
        with self.assertRaises(verify.VerifyError):
            verify.validate_manifest(manifest)

    def test_selection_rejects_unknown_empty_and_partial_preinstall(self):
        manifest = manifest_fixture()
        with self.assertRaises(verify.UsageError):
            verify.select_journeys(manifest, ["missing"], "ui")
        with self.assertRaises(verify.UsageError):
            verify.select_journeys(manifest, [""], "ui")
        with self.assertRaises(verify.UsageError):
            verify.select_journeys(manifest, ["modes"], "preinstall")
        with self.assertRaises(verify.UsageError):
            verify.select_journeys(manifest, ["modes"], "session")

    def test_strict_json_rejects_duplicate_keys(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "state.json"
            path.write_text('{"mode": 1, "mode": 0}', encoding="utf-8")
            with self.assertRaises(verify.VerifyError):
                verify.load_json_file(path)

    def test_acceptance_fingerprint_tracks_content_not_git_state(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "a").write_text("one", encoding="utf-8")
            (root / "b").write_text("two", encoding="utf-8")
            first = verify.content_fingerprint(["a", "b"], root)
            (root / "a").write_text("one", encoding="utf-8")
            self.assertEqual(first, verify.content_fingerprint(["a", "b"], root))
            (root / "b").write_text("changed", encoding="utf-8")
            self.assertNotEqual(first, verify.content_fingerprint(["a", "b"], root))


class DiscoveryAndResultTests(unittest.TestCase):
    def test_disabled_unmanifested_test_cannot_hide_from_coverage(self):
        errors = verify.check_discovered(manifest_fixture(), DEVICES,
            ["QuietControlUITests/QuietControlUITests/testNewDisabled()"])
        self.assertTrue(any("disabled" in error and "testNewDisabled" in error for error in errors), errors)

    def enumeration(self, enabled):
        return {"errors": [], "values": [{"enabledTests": [{"identifier": item} for item in enabled], "disabledTests": []}]}

    def test_missing_duplicate_and_unknown_tests_fail(self):
        manifest = manifest_fixture()

        enabled = [DEVICES[0], DEVICES[1], DEVICES[2]]
        self.assertEqual(verify.check_discovered(manifest, enabled, []), [])

        errors = verify.check_discovered(manifest, [DEVICES[0], DEVICES[2]], [])
        self.assertTrue(any("not discovered" in error for error in errors), errors)

        errors = verify.check_discovered(manifest, enabled + [DEVICES[2]], [])
        self.assertTrue(any("duplicate" in error for error in errors), errors)

        errors = verify.check_discovered(manifest, enabled + ["QuietControlUITests/QuietControlUITests/testNew()"], [])
        self.assertTrue(any("missing from manifest" in error for error in errors), errors)

        errors = verify.check_discovered(manifest, enabled, [DEVICES[2]])
        self.assertTrue(any("disabled" in error for error in errors), errors)

    def test_enumeration_document_errors_fail(self):
        document = {"errors": ["Could not enumerate"], "values": []}
        with self.assertRaises(verify.VerifyError):
            verify.parse_enumeration_document(document)

    def test_xcresult_leaf_identifiers_use_target_class_method(self):
        document = {
            "testNodes": [
                {
                    "name": "QuietControl",
                    "nodeType": "Test Plan",
                    "children": [
                        {
                            "name": "QuietControlUITests",
                            "nodeType": "UI test bundle",
                            "children": [
                                {
                                    "name": "QuietControlUITests",
                                    "nodeType": "Test Suite",
                                    "children": [
                                        {
                                            "name": "testJourney()",
                                            "nodeType": "Test Case",
                                            "result": "Passed",
                                            "nodeIdentifier": "QuietControlUITests/testJourney()",
                                            "nodeIdentifierURL": "test://com.apple.xcode/QuietControl/QuietControlUITests/QuietControlUITests/testJourney",
                                        }
                                    ],
                                }
                            ],
                        }
                    ],
                }
            ]
        }
        records = verify.leaf_records_from_tests_json(document)
        self.assertEqual(
            records,
            [{"id": "QuietControlUITests/QuietControlUITests/testJourney", "name": "testJourney()", "result": "Passed"}],
        )

    def summary(self, expected=1):
        return {
            "result": "Passed",
            "totalTestCount": expected,
            "passedTests": expected,
            "failedTests": 0,
            "skippedTests": 0,
            "expectedFailures": 0,
            "testFailures": [],
            "devicesAndConfigurations": [{"device": {"deviceId": "UDID"}}],
        }

    def leaves(self, identifier=DEVICES[2], result="Passed"):
        return [{"id": identifier, "name": "test", "result": result}]

    def test_passing_summary_matches(self):
        errors, counts = verify.result_summary_errors(
            self.summary(), self.leaves(), [DEVICES[2]], "UDID"
        )
        self.assertEqual(errors, [])
        self.assertEqual(counts["passed"], 1)

    def test_skipped_failed_count_and_destination_mismatch_fail(self):
        summary = self.summary()
        summary["skippedTests"] = 1
        errors, _ = verify.result_summary_errors(summary, self.leaves(result="Skipped"), [DEVICES[2]], "UDID")
        self.assertTrue(any("skippedTests" in error for error in errors), errors)
        self.assertTrue(any("Skipped" in error for error in errors), errors)

        summary = self.summary()
        summary["failedTests"] = 1
        summary["passedTests"] = 0
        summary["result"] = "Failed"
        errors, _ = verify.result_summary_errors(summary, self.leaves(result="Failed"), [DEVICES[2]], "UDID")
        self.assertTrue(any("failedTests" in error for error in errors), errors)
        self.assertTrue(any("not 'Passed'" in error for error in errors), errors)

        errors, _ = verify.result_summary_errors(self.summary(expected=2), self.leaves(), [DEVICES[2]], "UDID")
        self.assertTrue(any("totalTestCount" in error for error in errors), errors)

        errors, _ = verify.result_summary_errors(self.summary(), self.leaves(), [DEVICES[2]], "OTHER-UDID")
        self.assertTrue(any("destination" in error for error in errors), errors)

    def test_selected_test_that_did_not_execute_fails(self):
        errors, _ = verify.result_summary_errors(
            self.summary(), self.leaves(identifier=DEVICES[0]), [DEVICES[2]], "UDID"
        )
        self.assertTrue(any("did not execute" in error for error in errors), errors)
        self.assertTrue(any("unexpected tests" in error for error in errors), errors)


class TranscriptTests(unittest.TestCase):
    def entry(self, transcript):
        entry = copy.deepcopy(manifest_fixture()["journeys"][0])
        entry["expect"]["transcript"] = transcript
        return entry

    def test_valid_artifacts_pass(self):
        entry = copy.deepcopy(manifest_fixture()["journeys"][0])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "aware-1234ABCD", valid_rows())
            self.assertEqual(verify.inspect_entry_artifacts(entry, root, SYNTHETIC), [])

    def test_wrong_packet_order_fails(self):
        entry = copy.deepcopy(manifest_fixture()["journeys"][0])
        rows = valid_rows()
        # The independent GET is removed: the write acknowledgement must not count as it.
        rows = [row for row in rows if row["bytes"] != "1f 03 01 00"]
        rows[3]["sequence"] = 4
        rows[4]["sequence"] = 5
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "aware-1234ABCD", rows)
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("ordered packet" in error for error in errors), errors)

    def test_wrong_mode_packet_and_forbidden_success_fail(self):
        entry = self.entry(
            {
                "scenarios": ["connected"],
                "order": ["outbound:1f0305020100", "inbound:1f03040104"],
                "forbidden": ["inbound:1f03030101"],
            }
        )
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "aware-1234ABCD", valid_rows())
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("required" in error or "ordered packet" in error for error in errors), errors)
        self.assertTrue(any("forbidden packet" in error for error in errors), errors)

    def test_sequence_gap_and_duplicate_fail(self):
        entry = copy.deepcopy(manifest_fixture()["journeys"][0])
        rows = valid_rows()
        rows[2]["sequence"] = 4
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "aware-1234ABCD", rows)
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("sequence" in error for error in errors), errors)

    def test_malformed_missing_and_blank_transcript_fail(self):
        entry = copy.deepcopy(manifest_fixture()["journeys"][0])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run_dir = make_export(root, "aware-1234ABCD", valid_rows())
            (run_dir / "transport.jsonl").write_text("{not json}\n", encoding="utf-8")
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("malformed transcript JSON" in error for error in errors), errors)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "aware-1234ABCD", valid_rows(), omit=("transport.jsonl",))
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("missing transport.jsonl" in error for error in errors), errors)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run_dir = make_export(root, "aware-1234ABCD", valid_rows())
            (run_dir / "transport.jsonl").write_text("\n".join(json.dumps(row) for row in valid_rows()[:2]) + "\n\n", encoding="utf-8")
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("blank transcript line" in error for error in errors), errors)

    def test_wrong_snapshot_and_peripheral_fail(self):
        entry = copy.deepcopy(manifest_fixture()["journeys"][0])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "aware-1234ABCD", valid_rows(), snapshot=snapshot_fixture(last_mode=0))
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("lastMode" in error for error in errors), errors)

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            state = peripheral_fixture(mode=0)
            state["devices"][0]["address"] = "REAL-MAC"
            make_export(root, "aware-1234ABCD", valid_rows(), state=state)
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("peripheral-state.json: mode" in error for error in errors), errors)
        self.assertTrue(any("paired devices" in error for error in errors), errors)

    def test_offline_outbound_after_relaunch_fails(self):
        entry = copy.deepcopy(manifest_fixture()["journeys"][0])
        entry["run"]["scenario"] = "offline-cached"
        entry["run"]["reset"] = False
        entry["expect"]["transcript"] = {
            "scenarios": ["connected", "offline-cached"],
            "order": ["outbound:1f0305020100", "inbound:1f03030101"],
            "noOutboundScenarios": ["offline-cached"],
        }
        rows = valid_rows() + [
            transcript_row(7, "event", "event", scenario="offline-cached", message="Configured offline-cached."),
            transcript_row(8, "outbound", "bmap", "1f 03 05 02 00 00", scenario="offline-cached"),
        ]
        config = {
            "scenario": "offline-cached",
            "runID": "aware-1234ABCD",
            "reset": False,
            "peripheral": SYNTHETIC["peripheralUUID"],
            "defaultsSuite": SYNTHETIC["defaultsSuitePrefix"] + "aware-1234ABCD",
        }
        state = peripheral_fixture(scenario="offline-cached", connected=False, mode=0)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "aware-1234ABCD", rows, config=config, state=state)
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("outbound bytes in scenario" in error for error in errors), errors)

    def test_missing_second_offline_scenario_fails(self):
        entry = copy.deepcopy(manifest_fixture()["journeys"][0])
        entry["run"]["scenario"] = "offline-cached"
        entry["run"]["reset"] = False
        entry["expect"]["transcript"] = {
            "scenarios": ["connected", "offline-cached"],
            "noOutboundScenarios": ["offline-cached"],
        }
        config = {
            "scenario": "offline-cached",
            "runID": "aware-1234ABCD",
            "reset": False,
            "peripheral": SYNTHETIC["peripheralUUID"],
            "defaultsSuite": SYNTHETIC["defaultsSuitePrefix"] + "aware-1234ABCD",
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "aware-1234ABCD", valid_rows(), config=config)
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("scenario order" in error for error in errors), errors)

    def test_wrong_identity_and_reset_fail(self):
        entry = copy.deepcopy(manifest_fixture()["journeys"][0])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            config = {
                "scenario": "connected",
                "runID": "aware-1234ABCD",
                "reset": False,
                "peripheral": "aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",
                "defaultsSuite": "wrong.suite",
            }
            make_export(root, "aware-1234ABCD", valid_rows(), config=config)
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        text = "\n".join(errors)
        self.assertIn("reset", text)
        self.assertIn("synthetic identity", text)
        self.assertIn("defaults suite", text)

    def test_ambiguous_prefix_is_resolved_only_by_the_new_run(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "reject-SESSION", valid_rows())
            make_export(root, "reject-UI", valid_rows())
            with self.assertRaises(verify.VerifyError):
                verify.find_run_dir(root, "reject-")
            self.assertEqual(verify.find_run_dir(root, "reject-", {"reject-UI"}).name, "reject-UI")

    def test_no_artifact_entry_rejects_leaked_app_container_data(self):
        entry = copy.deepcopy(manifest_fixture()["session"]["tests"][1])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            make_export(root, "pending-1234", [])
            errors = verify.inspect_entry_artifacts(entry, root, SYNTHETIC)
        self.assertTrue(any("unexpected app-container artifacts" in error for error in errors), errors)


class ProcessOutcomeTests(unittest.TestCase):
    def run_with_passing_result(self, returncode, timed_out):
        class FakeRunner:
            def run(self, command, label, timeout):
                result = Path(command[command.index("-resultBundlePath") + 1])
                result.mkdir(parents=True)
                return verify.CommandResult(command, returncode, result.parent / "test.log", timed_out=timed_out)

            def json_command(self, command, label):
                if "summary" in command:
                    document = {
                        "result": "Passed", "totalTestCount": 1, "passedTests": 1,
                        "failedTests": 0, "skippedTests": 0, "expectedFailures": 0,
                        "testFailures": [], "devicesAndConfigurations": [{"device": {"deviceId": "UDID"}}],
                    }
                else:
                    document = {"testNodes": [{"nodeType": "Test Case", "name": "testJourney()",
                        "nodeIdentifier": DEVICES[2], "result": "Passed"}]}
                return document, verify.CommandResult(command, 0, Path("result.log"))

        with tempfile.TemporaryDirectory() as tmp:
            return verify._run_xcode_tests(FakeRunner(), Path(tmp), {"udid": "UDID"},
                Path("fixture.xctestrun"), "sample", [DEVICES[2]])

    def test_nonzero_exit_rejects_even_a_passing_xcresult(self):
        result = self.run_with_passing_result(65, False)
        self.assertEqual(result["counts"]["passed"], 1, "Passing evidence is still parsed and retained.")
        self.assertTrue(any("exit 65" in error for error in result["errors"]), result)

    def test_timeout_rejects_even_with_zero_exit_and_passing_xcresult(self):
        result = self.run_with_passing_result(0, True)
        self.assertEqual(result["counts"]["passed"], 1)
        self.assertTrue(any("timed out" in error for error in result["errors"]), result)

    def test_successful_process_and_passing_results_are_accepted(self):
        self.assertEqual(self.run_with_passing_result(0, False)["errors"], [])

    def test_requested_developer_directory_reaches_subprocesses(self):
        with tempfile.TemporaryDirectory() as tmp:
            requested = str((Path(tmp) / "Other Xcode.app/Contents/Developer").resolve())
            with patch.dict(verify.os.environ, {"DEVELOPER_DIR": requested}):
                runner = verify.CommandRunner(Path(tmp) / "logs")
            self.assertEqual(runner.developer_dir, requested)
            self.assertTrue(runner.environment["PATH"].startswith(requested + "/usr/bin:"))
            result = runner.run([sys.executable, "-c", "import os; print(os.environ['DEVELOPER_DIR'])"],
                                "environment", 10, capture=True)
            self.assertEqual(result.returncode, 0)
            self.assertEqual(result.stdout.strip(), requested)
            with self.assertRaises(verify.BlockedError) as blocked:
                verify.preflight(runner, manifest_fixture())
            self.assertIn(requested, str(blocked.exception))


class CleanupTests(unittest.TestCase):
    def inventory(self, *devices):
        return {"devices": {"runtime": [{"udid": udid, "name": name} for udid, name in devices]}}

    def test_only_the_recorded_task_owned_uuid_is_selected(self):
        owned = {"udid": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "name": "QuietControl Verify run"}
        inventory = self.inventory(
            ("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "QuietControl Verify run"),
            ("99999999-8888-4777-8666-555555555555", "Someone else's iPhone"),
        )
        device, errors = verify.owned_device_for_cleanup(inventory, owned)
        self.assertEqual(errors, [])
        self.assertEqual(device["udid"], owned["udid"])

    def test_another_device_with_same_uuid_but_foreign_name_is_refused(self):
        owned = {"udid": "AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "name": "QuietControl Verify run"}
        inventory = self.inventory(("AAAAAAAA-BBBB-4CCC-8DDD-EEEEEEEEEEEE", "Existing iPhone"))
        device, errors = verify.owned_device_for_cleanup(inventory, owned)
        self.assertIsNone(device)
        self.assertTrue(any("refusing to delete" in error for error in errors), errors)

    def test_invalid_or_missing_uuid_is_not_deleted(self):
        inventory = self.inventory(("99999999-8888-4777-8666-555555555555", "Unrelated"))
        device, errors = verify.owned_device_for_cleanup(inventory, {"udid": "not-a-uuid", "name": "x"})
        self.assertIsNone(device)
        self.assertTrue(errors)
        device, errors = verify.owned_device_for_cleanup(inventory, None)
        self.assertIsNone(device)
        self.assertEqual(errors, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)


# ---------------------------------------------------------------------------
# Schema 2: complete run sets and explicit evidence
# ---------------------------------------------------------------------------

V2_ID_1 = "QuietControlTests/QuietControlSessionTests/testOne()"
V2_ID_2 = "QuietControlTests/QuietControlSessionTests/testTwo()"


def v2_manifest():
    return {
        "schemaVersion": 2,
        "synthetic": copy.deepcopy(SYNTHETIC),
        "simulator": {
            "deviceTypes": ["iPhone Duo"],
            "runtime": "iOS 27.1",
            "minimumRuntimeMajor": 17,
            "compactDeviceTypes": ["iPhone SE (3rd generation)"],
        },
        "session": {
            "target": "QuietControlTests",
            "tests": [
                {
                    "id": V2_ID_1,
                    "label": "one",
                    "runs": [
                        {
                            "prefix": "unit-",
                            "scenario": "connected",
                            "reset": True,
                            "expect": {
                                "files": {"require": ["test-config.json", "transport.jsonl"]},
                                "snapshot": {"state": "present", "lastMode": 1, "eq": [-1, 4, 2]},
                                "peripheral": {"connected": True, "mode": 1},
                                "transcript": {
                                    "scenarios": ["connected"],
                                    "order": ["outbound:1f0305020100", "inbound:1f03030101"],
                                    "counts": [
                                        {"token": "outbound:1f030100", "equals": 1, "after": "outbound:1f0305020100"}
                                    ],
                                },
                            },
                        }
                    ],
                }
            ],
        },
        "journeys": [
            {
                "name": "fixture",
                "id": "QuietControlUITests/QuietControlUITests/testJourney()",
                "label": "ui-fixture",
                "runs": [
                    {
                        "prefix": "ui-",
                        "scenario": "connected",
                        "reset": True,
                        "expect": {"transcript": {"scenarios": ["connected"]}},
                    }
                ],
            }
        ],
    }


def v2_run(tmp: Path, run_id: str, rows, *, scenario="connected", reset=True, snapshot=None,
           state=None, config_extra=None, files=None):
    run_dir = tmp / "ApplicationSupport" / "QuietControlUITests" / run_id
    run_dir.mkdir(parents=True)
    config = {
        "scenario": scenario,
        "runID": run_id,
        "reset": reset,
        "peripheral": SYNTHETIC["peripheralUUID"],
        "defaultsSuite": SYNTHETIC["defaultsSuitePrefix"] + run_id,
    }
    if config_extra:
        config.update(config_extra)
    contents = {"test-config.json": json.dumps(config)}
    if rows is not None:
        contents["transport.jsonl"] = "\n".join(json.dumps(row) for row in rows) + "\n"
    if snapshot is not None:
        contents["LastConfirmedState.json"] = snapshot if isinstance(snapshot, str) else json.dumps(snapshot_fixture(snapshot))
    if state is not None:
        state = dict(state)
        state["runID"] = run_id
        state["scenario"] = scenario
        contents["peripheral-state.json"] = json.dumps(state)
    for name in files or []:
        contents[name] = ""
    for name, text in contents.items():
        (run_dir / name).write_text(text, encoding="utf-8")
    return run_dir


def v2_rows():
    return [
        transcript_row(1, "event", "event", message="Configured connected."),
        transcript_row(2, "outbound", "bmap", "1f 03 01 00"),
        transcript_row(3, "inbound", "bmap", "1f 03 03 01 00"),
        transcript_row(4, "outbound", "bmap", "1f 03 05 02 01 00"),
        transcript_row(5, "inbound", "bmap", "1f 03 03 01 01"),
        transcript_row(6, "outbound", "bmap", "1f 03 01 00"),
        transcript_row(7, "inbound", "bmap", "1f 03 03 01 01"),
    ]


class Schema2ManifestTests(unittest.TestCase):
    def test_strict_run_types_are_rejected(self):
        for mutation in (
            lambda m: m["session"]["tests"][0]["runs"][0].update(reset="yes"),
            lambda m: m["session"]["tests"][0]["runs"][0]["expect"]["snapshot"].update(lastMode="1"),
            lambda m: m["session"]["tests"][0]["runs"][0]["expect"]["transcript"]["counts"][0].update(equals=-1),
            lambda m: m["session"]["tests"][0]["runs"][0]["expect"]["transcript"].update(order=["not-a-token"]),
            lambda m: m["session"]["tests"][0]["runs"][0]["expect"].update(artifacts=False),
            lambda m: m["session"]["tests"][0]["runs"][0].update(scenario=""),
        ):
            manifest = v2_manifest()
            mutation(manifest)
            with self.assertRaises(verify.VerifyError):
                verify.validate_manifest(manifest)

    def test_shared_prefix_requires_unique_match_tokens(self):
        manifest = v2_manifest()
        first = manifest["session"]["tests"][0]
        second = copy.deepcopy(first)
        second["id"] = V2_ID_2
        for entry in (first, second):
            entry["runs"][0]["sharedPrefixGroup"] = "same"
            entry["runs"][0]["sharedMatchToken"] = "outbound:1f0305020100"
        manifest["session"]["tests"].append(second)
        with self.assertRaisesRegex(verify.VerifyError, "reuses a match token"):
            verify.validate_manifest(manifest)

    def test_incompatible_schema_version_fails_clearly(self):
        manifest = v2_manifest()
        manifest["schemaVersion"] = 3
        with self.assertRaisesRegex(verify.VerifyError, "unsupported schemaVersion"):
            verify.validate_manifest(manifest)

    def test_schema1_is_still_supported(self):
        verify.validate_manifest(manifest_fixture())


class Schema2EvidenceTests(unittest.TestCase):
    def inspect(self, tmp, run_id, entry, new_runs=None):
        return verify.map_and_inspect_lane(
            [entry], tmp, set(new_runs if new_runs is not None else [run_id]), SYNTHETIC, "session"
        )

    def test_missing_and_extra_runs_fail(self):
        entry = v2_manifest()["session"]["tests"][0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            v2_run(root, "unit-AAAA", v2_rows(), snapshot=1,
                   state=peripheral_fixture(mode=1))
            v2_run(root, "unit-BBBB", v2_rows(), snapshot=1,
                   state=peripheral_fixture(mode=1))
            errors, _ = self.inspect(root, "unit-AAAA", entry, ["unit-AAAA", "unit-BBBB"])
            self.assertTrue(any("expected exactly 1" in error for error in errors), errors)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            v2_run(root, "unit-AAAA", v2_rows(), snapshot=1,
                   state=peripheral_fixture(mode=1))
            errors, _ = self.inspect(root, "unit-AAAA", entry, [])
            self.assertTrue(any("expected exactly 1" in error for error in errors), errors)

    def test_unclaimed_run_directory_fails(self):
        entry = v2_manifest()["session"]["tests"][0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            v2_run(root, "unit-AAAA", v2_rows(), snapshot=1,
                   state=peripheral_fixture(mode=1))
            v2_run(root, "stray-AAAA", v2_rows(), snapshot=1,
                   state=peripheral_fixture(mode=1))
            errors, _ = self.inspect(root, "unit-AAAA", entry, ["unit-AAAA", "stray-AAAA"])
        self.assertTrue(any("not claimed by the manifest" in error for error in errors), errors)

    def test_shared_prefix_is_mapped_by_evidence_not_order(self):
        manifest = v2_manifest()
        first = manifest["session"]["tests"][0]
        second = copy.deepcopy(first)
        second["id"] = V2_ID_2
        first["runs"][0].update(prefix="eqfail-", sharedPrefixGroup="shared",
                                 sharedMatchToken="outbound:010702020701")
        second["runs"][0].update(prefix="eqfail-", sharedPrefixGroup="shared",
                                 sharedMatchToken="outbound:010702020401")
        second["runs"][0]["expect"]["transcript"] = {
            "scenarios": ["connected"],
            "required": ["outbound:010702020401"],
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            first_rows = v2_rows() + [transcript_row(8, "outbound", "bmap", "01 07 02 02 07 01")]
            second_rows = v2_rows() + [transcript_row(8, "outbound", "bmap", "01 07 02 02 04 01")]
            v2_run(root, "eqfail-AAAA", first_rows, snapshot=1, state=peripheral_fixture(mode=1))
            v2_run(root, "eqfail-BBBB", second_rows, snapshot=1, state=peripheral_fixture(mode=1))
            errors, details = verify.map_and_inspect_lane(
                [first, second], root, {"eqfail-AAAA", "eqfail-BBBB"}, SYNTHETIC, "session"
            )
        self.assertEqual(errors, [])
        self.assertEqual({item["runID"] for item in details}, {"eqfail-AAAA", "eqfail-BBBB"})

    def test_anchored_count_rejects_a_startup_get(self):
        entry = v2_manifest()["session"]["tests"][0]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            v2_run(root, "unit-AAAA", v2_rows(), snapshot=1, state=peripheral_fixture(mode=1))
            errors, _ = self.inspect(root, "unit-AAAA", entry)
        self.assertEqual(errors, [])
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            rows = [row for row in v2_rows() if row["sequence"] < 6]
            v2_run(root, "unit-AAAA", rows, snapshot=1, state=peripheral_fixture(mode=1))
            errors, _ = self.inspect(root, "unit-AAAA", entry)
        self.assertTrue(any("occurs 0 times" in error for error in errors), errors)

    def test_no_outbound_between_anchors_fails(self):
        entry = v2_manifest()["session"]["tests"][0]
        entry["runs"][0]["expect"]["transcript"] = {
            "scenarios": ["connected"],
            "noOutboundBetween": [
                {"start": "event:Configured connected", "end": "inbound:1f03030101"}
            ],
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            v2_run(root, "unit-AAAA", v2_rows(), snapshot=1, state=peripheral_fixture(mode=1))
            errors, _ = self.inspect(root, "unit-AAAA", entry)
        self.assertTrue(any("unexpected outbound traffic" in error for error in errors), errors)

    def test_corrupt_snapshot_requires_exact_bytes_and_absence_is_checked(self):
        entry = v2_manifest()["session"]["tests"][0]
        entry["runs"][0]["expect"]["snapshot"] = {"state": "corrupt", "literal": '{"version":1'}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            v2_run(root, "unit-AAAA", v2_rows(), snapshot='{"other":1}', state=peripheral_fixture(mode=1))
            errors, _ = self.inspect(root, "unit-AAAA", entry)
            self.assertTrue(any("do not match" in error for error in errors), errors)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            v2_run(root, "unit-AAAA", v2_rows(), snapshot='{"version":1', state=peripheral_fixture(mode=1))
            errors, _ = self.inspect(root, "unit-AAAA", entry)
            self.assertEqual(errors, [])
        entry["runs"][0]["expect"]["snapshot"] = {"state": "absent"}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            v2_run(root, "unit-AAAA", v2_rows(), snapshot=1, state=peripheral_fixture(mode=1))
            errors, _ = self.inspect(root, "unit-AAAA", entry)
        self.assertTrue(any("intentionally absent" in error for error in errors), errors)

    def test_retained_journal_bytes_and_removal_are_exact(self):
        entry = v2_manifest()["session"]["tests"][0]
        literal = '{"peripheral":"8A1B2C3D-4E5F-4061-8273-849506172839","firmware":"1.0.6-80+f5f219b","name":"rememberMode","payload":"AQ=="}'
        entry["runs"][0]["expect"]["journal"] = {"state": "present", "literal": literal}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run_dir = v2_run(root, "unit-AAAA", v2_rows(), snapshot=1, state=peripheral_fixture(mode=1))
            (run_dir / "PreferenceRecovery.json").write_text(literal, encoding="utf-8")
            errors, _ = self.inspect(root, "unit-AAAA", entry)
            self.assertEqual(errors, [])
            (run_dir / "PreferenceRecovery.json").write_text(literal + "\n", encoding="utf-8")
            errors, _ = self.inspect(root, "unit-AAAA", entry)
            self.assertTrue(any("differ from the exact seeded" in error for error in errors), errors)
        entry["runs"][0]["expect"]["journal"] = {"state": "absent"}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run_dir = v2_run(root, "unit-AAAA", v2_rows(), snapshot=1, state=peripheral_fixture(mode=1))
            (run_dir / "PreferenceRecovery.json").write_text(literal, encoding="utf-8")
            errors, _ = self.inspect(root, "unit-AAAA", entry)
        self.assertTrue(any("unexpectedly retained" in error for error in errors), errors)

    def test_preset_defaults_are_read_from_the_isolated_plist(self):
        import plistlib

        entry = v2_manifest()["session"]["tests"][0]
        entry["runs"][0]["expect"]["defaults"] = {"preset": {"name": "Mine", "values": [-1, 7, 2]}}
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run_dir = v2_run(root, "unit-AAAA", v2_rows(), snapshot=1, state=peripheral_fixture(mode=1))
            suite = SYNTHETIC["defaultsSuitePrefix"] + "unit-AAAA"
            prefs = root / "Preferences"
            prefs.mkdir()
            presets = [{"id": "x", "name": "Mine", "values": [-1, 7, 2]}]
            with open(prefs / (suite + ".plist"), "wb") as handle:
                plistlib.dump({"quietcontrol.eqPresets": json.dumps(presets).encode()}, handle)
            errors, _ = self.inspect(root, "unit-AAAA", entry)
            self.assertEqual(errors, [])
            presets[0]["values"] = [-1, 4, 2]
            with open(prefs / (suite + ".plist"), "wb") as handle:
                plistlib.dump({"quietcontrol.eqPresets": json.dumps(presets).encode()}, handle)
            errors, _ = self.inspect(root, "unit-AAAA", entry)
        self.assertTrue(any("values" in error for error in errors), errors)

    def test_fragmented_segment_headers_and_lifecycle_counts(self):
        entry = v2_manifest()["session"]["tests"][0]
        entry["runs"][0]["expect"]["transcript"] = {
            "scenarios": ["connected"],
            "segmentHeadersAfter": "Released held reply",
            "segmentHeaders": ["80", "81"],
        }
        entry["runs"][0]["expect"]["lifecycle"] = {
            "rxPrefix": "1f 06 03 2f", "beforeEvent": "partial", "afterEvent": "complete",
            "expectedBefore": 0, "expectedAfter": 2,
        }
        rows = v2_rows() + [
            transcript_row(8, "event", "event", message="Released held reply"),
            transcript_row(9, "inbound", "segment", "80 1f 06 03 2f"),
            transcript_row(10, "inbound", "segment", "81 00"),
        ]
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            run_dir = v2_run(root, "unit-AAAA", rows, snapshot=1, state=peripheral_fixture(mode=1))
            (run_dir / "LifecycleDiagnostics.jsonl").write_text(
                "\n".join(json.dumps({"message": message}) for message in [
                    "partial", "RX 1f 06 03 2f 00", "RX 1f 06 03 2f 01", "complete"
                ]) + "\n",
                encoding="utf-8",
            )
            errors, _ = self.inspect(root, "unit-AAAA", entry)
            self.assertEqual(errors, [])
            rows[8]["bytes"] = "82 1f 06 03 2f"
            rows[9]["bytes"] = "83 00"
            v2_run(root, "unit-BBBB", rows, snapshot=1, state=peripheral_fixture(mode=1))
            entry["runs"][0]["prefix"] = "unit-"
            errors, _ = verify.map_and_inspect_lane(
                [entry], root, {"unit-BBBB"}, SYNTHETIC, "session"
            )
        self.assertTrue(any("post-release segment headers" in error for error in errors), errors)


class AnchoredEvidenceTests(unittest.TestCase):
    def lifecycle(self, messages):
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "LifecycleDiagnostics.jsonl"
            path.write_text("\n".join(json.dumps({"message": m}) for m in messages) + "\n")
            return verify._check_lifecycle(path, {
                "rxPrefix": "1f06032f", "beforeEvent": "partial", "afterEvent": "complete",
                "expectedBefore": 3, "expectedAfter": 6,
            })

    def test_fragmented_rx_cannot_move_across_partial_or_completion_boundary(self):
        rx = [f"RX 1f 06 03 2f {i:02x}" for i in range(6)]
        self.assertEqual(self.lifecycle(rx[:3] + ["partial"] + rx[3:] + ["complete"]), [])
        for bad in (
            rx + ["partial", "complete"],
            rx[:3] + ["partial", "complete"] + rx[3:],
            rx[:3] + ["partial", "partial"] + rx[3:] + ["complete"],
            rx[:3] + ["complete"] + rx[3:] + ["partial"],
            rx[:3] + rx[3:4] + ["partial"] + rx[4:] + ["complete"],
        ):
            with self.subTest(messages=bad):
                self.assertTrue(self.lifecycle(bad), "Moving or duplicating records must fail despite the same total RX")

    def test_manifest_requires_distinct_orderable_lifecycle_boundaries(self):
        for lifecycle in (
            {"rxPrefix": "1f06", "expectedTotal": 6},
            {"rxPrefix": "1f06", "beforeEvent": "same", "afterEvent": "same", "expectedBefore": 3, "expectedAfter": 6},
            {"rxPrefix": "1f06", "beforeEvent": "partial", "afterEvent": "complete", "expectedBefore": -1, "expectedAfter": 6},
        ):
            manifest = v2_manifest()
            manifest["session"]["tests"][0]["runs"][0]["expect"]["lifecycle"] = lifecycle
            with self.subTest(lifecycle=lifecycle), self.assertRaises(verify.VerifyError):
                verify.validate_manifest(manifest)

    def test_manifest_rejects_invalid_ordered_count_windows(self):
        for count in (
            {"token": "outbound:1f030100", "equals": 1, "after": []},
            {"token": "outbound:1f030100", "equals": 1, "after": ["outbound:1f0602*", 4]},
            {"token": "outbound:1f030100", "equals": 1, "before": "outbound:*"},
            {"token": "outbound:1f030100", "equals": 1, "after": "outbound:1f0602*", "before": False},
        ):
            manifest = v2_manifest()
            manifest["session"]["tests"][0]["runs"][0]["expect"]["transcript"]["counts"] = [count]
            with self.subTest(count=count), self.assertRaises(verify.VerifyError):
                verify.validate_manifest(manifest)

    def check_journey(self, name, tokens):
        manifest = verify.load_manifest(Path(__file__).resolve().parents[2] / "docs/testing/journeys.json")
        entry = next(e for e in manifest["journeys"] if e["name"] == name)
        rows = []
        for i, token in enumerate(tokens, 1):
            direction, value = token.split(":", 1)
            rows.append(transcript_row(i, direction, "event" if direction == "event" else "bmap",
                                       "" if direction == "event" else value,
                                       message=value if direction == "event" else None))
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "transport.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in rows) + "\n", encoding="utf-8")
            return verify._check_transcript_v2(path, entry["runs"][0]["expect"]["transcript"], SYNTHETIC)

    def test_editor_setup_or_later_reads_cannot_replace_save_confirmation(self):
        focus = "inbound:1f06032f02000d010100466f637573000000000000000000000000000000000000000000000000000000000000000300000000"
        tokens = ["outbound:1f030100", "inbound:1f03030100", focus,
                  "outbound:1f06022702", focus, "outbound:1f030100", "inbound:1f03030100",
                  "outbound:1f010500", focus, "outbound:1f030100", focus]
        self.assertEqual(self.check_journey("editor", tokens), [])
        missing_get = tokens.copy()
        missing_get[5] = "outbound:04040100"
        self.assertTrue(self.check_journey("editor", missing_get), "Setup/later GET cannot replace action GET")
        missing_mode = tokens.copy()
        missing_mode[8] = "inbound:020203015a"
        self.assertTrue(self.check_journey("editor", missing_mode), "A later reopened editor cannot replace the write read-back")

    def test_preset_earlier_drag_cannot_replace_relaunch_confirmations(self):
        changed = "inbound:0107030cf60aff00f60a0701f60a0202"
        baseline = "inbound:0107030cf60aff00f60a0401f60a0202"
        tokens = ["outbound:010702020701", changed, "outbound:01070100", changed,
                  "event:eq presets loaded 1: Mine",
                  "outbound:01070202ff00", baseline, "outbound:01070100", baseline,
                  "outbound:010702020701", changed, "outbound:01070100", changed,
                  "outbound:010702020202", changed, "outbound:01070100", changed]
        self.assertEqual(self.check_journey("presets", tokens), [])
        for index in (12, 16):
            tokens[index] = "inbound:020203015a"
        self.assertTrue(self.check_journey("presets", tokens), "First-launch confirmation cannot prove a relaunch write")


class Schema2AttachmentTests(unittest.TestCase):
    CONTEXTS = [f"{screen}-{config}" for config in ("light", "dark", "large-text")
                for screen in ("home", "equalizer", "editor", "settings")]

    def entry(self):
        return {
            "name": "access",
            "id": "QuietControlUITests/QuietControlUITests/testAccessibilityAndLargeTextNavigation()",
            "label": "ui-access",
            "runs": [
                {"prefix": "access-light-", "scenario": "connected", "reset": True,
                 "expect": {"transcript": {"scenarios": ["connected"]}}}
            ],
            "attachments": {
                "audits": {
                    "contexts": self.CONTEXTS,
                    "screenshots": self.CONTEXTS + [
                        "editor-large-text-wind-clear", "editor-large-text-before-audit"
                    ],
                },
                "geometry": True,
                "journeyRunIDs": 1,
            },
        }

    def geometry(self):
        return {
            "screen": "editor-large-text",
            "elements": ["mode-summary", "mode-strength", "mode-cancel", "mode-save-toolbar", "mode-save-bottom"],
            "stableSeconds": 0.5,
            "before": [
                {"x": 44, "y": 296, "width": 302, "height": 86},
                {"x": 44, "y": 398, "width": 302, "height": 48},
                {"x": 28, "y": 82, "width": 128, "height": 68},
                {"x": 265, "y": 82, "width": 97, "height": 68},
                {"x": 28, "y": 558, "width": 334, "height": 78},
            ],
            "after": [
                {"x": 44, "y": 296, "width": 302, "height": 86},
                {"x": 44, "y": 398, "width": 302, "height": 48},
                {"x": 28, "y": 82, "width": 128, "height": 68},
                {"x": 265, "y": 82, "width": 97, "height": 68},
                {"x": 28, "y": 558, "width": 334, "height": 78},
            ],
            "heroClearAfter": True,
            "strength": "7 of 10",
        }

    def attachments(self, tmp: Path, *, mutate=None):
        files = {}
        for context in self.CONTEXTS:
            path = tmp / f"audit-summary-{context}.txt"
            summary = {
                "screen": context,
                "auditTypes": ["hitRegion", "sufficientElementDescription", "textClipped", "contrast"],
                "counts": {"reported": 0, "ignored": 0, "failed": 0},
                "countsNote": "reported = ignored + failed",
                "policy": {
                    "substringExemptions": False,
                    "coordinateExemptions": False,
                    "enabledIssueSuppression": 0,
                },
                "issues": [],
            }
            if mutate:
                mutate(context, summary)
            path.write_text(json.dumps(summary), encoding="utf-8")
            files[f"audit-summary-{context}"] = path
        for context in self.CONTEXTS + ["editor-large-text-wind-clear", "editor-large-text-before-audit"]:
            path = tmp / f"{context}.png"
            path.write_bytes(b"\x89PNG\r\n\x1a\nrest")
            files[context] = path
        geometry = tmp / "audit-geometry-editor-large-text.txt"
        geometry.write_text(json.dumps(self.geometry()), encoding="utf-8")
        files["audit-geometry-editor-large-text"] = geometry
        run_id = "access-light-AAAA"
        journey = tmp / "journey.txt"
        journey.write_text(f"runID: {run_id}\n", encoding="utf-8")
        files["journey-access"] = journey
        return {"root": tmp, "tests": {self.entry()["id"]: files}}

    def validate(self, attachments, details):
        return verify._validate_attachments_for_entry(self.entry(), attachments, details)

    def test_valid_attachments_pass(self):
        with tempfile.TemporaryDirectory() as tmp:
            attachments = self.attachments(Path(tmp))
            details = [{"id": self.entry()["id"], "runID": "access-light-AAAA"}]
            self.assertEqual(self.validate(attachments, details), [])

    def test_forged_counts_and_enabled_exemption_fail(self):
        def forged(context, summary):
            if context == "home-light":
                summary["counts"] = {"reported": 2, "ignored": 1, "failed": 0}
                summary["issues"] = [{
                    "auditType": "contrast", "description": "x", "identifier": "x", "label": "x",
                    "enabled": True, "ignored": True, "exemption": "disabled control",
                }]
        with tempfile.TemporaryDirectory() as tmp:
            attachments = self.attachments(Path(tmp), mutate=forged)
            errors = self.validate(attachments, [{"id": self.entry()["id"], "runID": "access-light-AAAA"}])
        text = "\n".join(errors)
        self.assertIn("may be ignored", text)
        self.assertIn("reported", text)

    def test_missing_context_is_not_silently_accepted(self):
        with tempfile.TemporaryDirectory() as tmp:
            attachments = self.attachments(Path(tmp))
            files = attachments["tests"][self.entry()["id"]]
            files.pop("audit-summary-settings-dark")
            errors = self.validate(attachments, [{"id": self.entry()["id"], "runID": "access-light-AAAA"}])
        self.assertTrue(any("settings-dark" in error for error in errors), errors)

    def test_geometry_mismatch_and_nonfinite_frames_fail(self):
        with tempfile.TemporaryDirectory() as tmp:
            attachments = self.attachments(Path(tmp))
            path = attachments["tests"][self.entry()["id"]]["audit-geometry-editor-large-text"]
            geometry = self.geometry()
            geometry["after"][0]["y"] = 240
            path.write_text(json.dumps(geometry), encoding="utf-8")
            errors = self.validate(attachments, [{"id": self.entry()["id"], "runID": "access-light-AAAA"}])
            self.assertTrue(any("frames differ" in error for error in errors), errors)
            geometry = self.geometry()
            geometry["before"][1]["height"] = float("inf")
            path.write_text(json.dumps(geometry, allow_nan=True), encoding="utf-8")
            errors = self.validate(attachments, [{"id": self.entry()["id"], "runID": "access-light-AAAA"}])
            self.assertTrue(any("finite" in error or "malformed" in error for error in errors), errors)

    def test_invalid_configuration_requires_messages_screenshots_and_no_runs(self):
        entry = {
            "name": "invalid",
            "id": "QuietControlUITests/QuietControlUITests/testInvalidTestConfigurationFailsWithoutRadioFallback()",
            "label": "ui-invalid",
            "runs": [{"prefix": "invalid-", "evidence": "invalid-configuration", "expectedRuns": 0}],
            "attachments": {"invalidConfiguration": True},
        }
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            files = {}
            for name, text in {
                "journey-invalid-run": "runID: invalid-AAAA run!\nQuietControl could not start\nQUIETCONTROL_TEST_RUN_ID must be 1-64 ASCII letters, digits or hyphens.",
                "journey-invalid-scenario": "runID: invalid-BBBB\nQuietControl could not start\nUnsupported QUIETCONTROL_TEST_SCENARIO: not-a-scenario.",
            }.items():
                path = root / name
                path.write_text(text, encoding="utf-8")
                files[name] = path
            for name in ("invalid-run-error", "invalid-scenario-error"):
                path = root / name
                path.write_bytes(b"\x89PNG\r\n\x1a\n")
                files[name] = path
            attachments = {"root": root, "tests": {entry["id"]: files}}
            details = []
            self.assertEqual(verify._validate_attachments_for_entry(entry, attachments, details), [])
            errors, _ = verify.map_and_inspect_lane(
                [entry], root, {"invalid-LEAK"}, SYNTHETIC, "ui-invalid"
            )
            self.assertTrue(any("created harness run directories" in error for error in errors), errors)
            files["journey-invalid-run"].write_text("runID: invalid-AAAA\nno message\n", encoding="utf-8")
            errors = verify._validate_attachments_for_entry(entry, attachments, details)
            self.assertTrue(any("run-ID error message" in error for error in errors), errors)
