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
    "QuietControlTests/QuietControlSessionTests/testTwo()",
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
