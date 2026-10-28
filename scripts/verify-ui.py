#!/usr/bin/env python3
"""Strict, disposable native verification runner for QuietControl.

Implements the Wave 2 runner contract from docs/testing/PLAN.md:

    ./scripts/verify.sh core|session|ui|preinstall [--only <journey> ...]

The runner is deliberately conservative. It never reuses a booted simulator,
never retries a failed test to green, and never treats process exit alone as
success. Every selected test must be discovered, executed, passed and not
skipped; selected journeys must also leave independently inspectable JSON
transcripts/snapshots under the app container.

Only the Python standard library is used.
"""

from __future__ import annotations

import argparse
import datetime
import hashlib
import json
import os
import re
import shlex
import shutil
import signal
import subprocess
import sys
import time
import traceback
import uuid
from dataclasses import dataclass, field
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
MANIFEST_PATH = ROOT / "docs" / "testing" / "journeys.json"
RUN_ROOT = ROOT / "build" / "Verification"
DEFAULT_XCODE_DEVELOPER_DIR = "/Applications/Xcode.app/Contents/Developer"
BUNDLE_ID = "uk.co.mzbali.quietcontrol"
MIN_FREE_DISK_BYTES = 15 * 1024 * 1024 * 1024

BUILD_TIMEOUT = 2400
TEST_TIMEOUT = 1200
RELEASE_TIMEOUT = 2400
SHORT_TIMEOUT = 180

UUID_RE = re.compile(
    r"^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$"
)
TEST_ID_RE = re.compile(r"^[A-Za-z0-9_.]+/[A-Za-z0-9_.]+/test[A-Za-z0-9_]+\(\)$")
PACKET_TOKEN_RE = re.compile(r"^(outbound|inbound):[0-9A-Fa-f ]+$")
EXIT_PASS = 0
EXIT_FAIL = 1
EXIT_USAGE = 2
EXIT_BLOCKED = 3
EXIT_INTERRUPTED = 130

# These two app-hosted tests use in-memory pending transports and remove their
# temporary storage in teardown. Every other test must export independent evidence.
NO_ARTIFACT_TESTS = frozenset({
    "QuietControlTests/QuietControlSessionTests/testRadioLossCancelsPendingSetupAndAllowsAnotherConnectionAttempt()",
    "QuietControlTests/QuietControlSessionTests/testQuietWaitingClearsBusyWithoutReplacingPendingConnection()",
})


class VerifyError(Exception):
    """A verification rule or artifact was not satisfied."""


class UsageError(Exception):
    """Bad command line; fail before doing expensive work."""


class BlockedError(Exception):
    """Required local environment (toolchain, runtime, device, disk) is missing."""


class RunnerInterrupted(Exception):
    def __init__(self, signum: int):
        super().__init__(f"interrupted by signal {signum}")
        self.signum = signum


# ---------------------------------------------------------------------------
# Strict JSON / small helpers
# ---------------------------------------------------------------------------


def _reject_duplicate_keys(pairs):
    result = {}
    for key, value in pairs:
        if key in result:
            raise ValueError(f"duplicate JSON key {key!r}")
        result[key] = value
    return result


def _reject_constant(value):
    raise ValueError(f"non-finite JSON constant {value!r} is not allowed")


def load_json_file(path: Path):
    try:
        text = Path(path).read_text(encoding="utf-8")
    except OSError as error:
        raise VerifyError(f"cannot read {path}: {error}") from error
    try:
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except ValueError as error:
        raise VerifyError(f"malformed JSON in {path}: {error}") from error


def parse_json_text(text: str, source: str):
    try:
        return json.loads(
            text,
            object_pairs_hook=_reject_duplicate_keys,
            parse_constant=_reject_constant,
        )
    except ValueError as error:
        raise VerifyError(f"malformed JSON from {source}: {error}") from error


def iso8601(value, source: str) -> datetime.datetime:
    if not isinstance(value, str) or not value:
        raise VerifyError(f"{source}: expected an ISO-8601 timestamp string")
    try:
        return datetime.datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError as error:
        raise VerifyError(f"{source}: invalid ISO-8601 timestamp {value!r}") from error


def normalize_packet(value: str) -> str:
    if not isinstance(value, str):
        raise VerifyError(f"packet must be a hex string, got {type(value).__name__}")
    return value.replace(" ", "").lower()


def validate_hex_packet(value: str, source: str) -> str:
    token = normalize_packet(value)
    if not token or len(token) % 2 or not re.fullmatch(r"[0-9a-f]+", token):
        raise VerifyError(f"{source}: invalid hex packet {value!r}")
    return token


def require(condition: bool, message: str) -> None:
    if not condition:
        raise VerifyError(message)


def utc_now() -> datetime.datetime:
    return datetime.datetime.now(datetime.timezone.utc)


def utc_stamp(value: datetime.datetime) -> str:
    return value.strftime("%Y-%m-%dT%H:%M:%SZ")


def make_run_id() -> str:
    return time.strftime("%Y%m%dT%H%M%SZ", time.gmtime()) + "-" + uuid.uuid4().hex[:8]


# ---------------------------------------------------------------------------
# Command execution with signal-safe cleanup
# ---------------------------------------------------------------------------


@dataclass
class CommandResult:
    command: list
    returncode: int
    log_path: Path
    stdout: str = ""
    timed_out: bool = False
    elapsed: float = 0.0


class CommandRunner:
    def __init__(self, log_dir: Path):
        self.log_dir = log_dir
        self.log_dir.mkdir(parents=True, exist_ok=True)
        self.records: list[dict] = []
        self._sequence = 0
        self.environment = dict(os.environ)
        self.developer_dir = str(Path(self.environment.get("DEVELOPER_DIR", DEFAULT_XCODE_DEVELOPER_DIR)).expanduser().resolve())
        self.environment["DEVELOPER_DIR"] = self.developer_dir
        self.environment["PATH"] = (
            f"{self.developer_dir}/usr/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:"
            + self.environment.get("PATH", "")
        )

    def run(
        self,
        command: list,
        label: str,
        timeout: int,
        *,
        capture: bool = False,
    ) -> CommandResult:
        self._sequence += 1
        safe_label = re.sub(r"[^A-Za-z0-9_.-]+", "-", label)[:120]
        log_path = self.log_dir / f"{self._sequence:02d}-{safe_label}.log"
        command_text = shlex.join(str(part) for part in command)
        started = time.monotonic()
        timed_out = False
        stdout = ""
        with open(log_path, "wb") as log:
            log.write(f"$ {command_text}\n\n".encode())
            log.flush()
            if capture:
                process = subprocess.Popen(
                    [str(part) for part in command],
                    cwd=ROOT,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    env=self.environment,
                    start_new_session=True,
                )
            else:
                process = subprocess.Popen(
                    [str(part) for part in command],
                    cwd=ROOT,
                    stdout=log,
                    stderr=subprocess.STDOUT,
                    env=self.environment,
                    start_new_session=True,
                )
            try:
                if capture:
                    data, _ = process.communicate(timeout=timeout)
                    stdout = data.decode("utf-8", errors="replace")
                    log.write(data)
                else:
                    process.wait(timeout=timeout)
            except subprocess.TimeoutExpired:
                timed_out = True
                stdout = self._terminate(process)
                log.write(b"\n[runner] timed out; process group terminated\n")
            except BaseException:
                self._terminate(process)
                raise
            finally:
                if capture and process.stdout is not None:
                    process.stdout.close()
        elapsed = time.monotonic() - started
        result = CommandResult(
            command=[str(part) for part in command],
            returncode=process.returncode if process.returncode is not None else -1,
            log_path=log_path,
            stdout=stdout,
            timed_out=timed_out,
            elapsed=elapsed,
        )
        self.records.append(
            {
                "command": command_text,
                "returncode": result.returncode,
                "timedOut": timed_out,
                "elapsedSeconds": round(elapsed, 2),
                "log": str(log_path),
            }
        )
        return result

    @staticmethod
    def _terminate(process: subprocess.Popen) -> str:
        if process.poll() is not None:
            return ""
        try:
            os.killpg(os.getpgid(process.pid), signal.SIGTERM)
        except (ProcessLookupError, PermissionError):
            return ""
        try:
            output, _ = process.communicate(timeout=10)
            return output.decode("utf-8", errors="replace") if output else ""
        except subprocess.TimeoutExpired:
            try:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
            except (ProcessLookupError, PermissionError):
                pass
            output, _ = process.communicate()
            return output.decode("utf-8", errors="replace") if output else ""

    def json_command(self, command: list, label: str, timeout: int = SHORT_TIMEOUT):
        result = self.run(command, label, timeout, capture=True)
        if result.timed_out:
            raise VerifyError(f"{label}: command timed out")
        if result.returncode != 0:
            raise VerifyError(f"{label}: command failed ({result.returncode}); see {result.log_path}")
        return parse_json_text(result.stdout, label), result

    @staticmethod
    def commands_log(records: list[dict]) -> str:
        lines = []
        for index, record in enumerate(records, 1):
            lines.append(f"# {index} rc={record['returncode']} elapsed={record['elapsedSeconds']}s")
            lines.append(record["command"])
            lines.append("")
        return "\n".join(lines)


# ---------------------------------------------------------------------------
# Manifest validation
# ---------------------------------------------------------------------------

EXPECT_KEYS = {"snapshot", "peripheral", "transcript"}
RUN_KEYS = {"prefix", "scenario", "reset", "artifacts"}
SNAPSHOT_KEYS = {"lastMode", "eq"}
PERIPHERAL_KEYS = {"connected", "mode", "eq", "multipoint"}
TRANSCRIPT_KEYS = {
    "scenarios",
    "order",
    "required",
    "forbidden",
    "noOutboundScenarios",
    "forbiddenMessages",
}


def _check_keys(mapping, allowed, where: str) -> None:
    require(isinstance(mapping, dict), f"{where}: expected an object")
    unknown = set(mapping) - allowed
    require(not unknown, f"{where}: unsupported keys {sorted(unknown)}")


def validate_manifest(manifest) -> None:
    _check_keys(
        manifest,
        {"schemaVersion", "description", "synthetic", "simulator", "session", "journeys"},
        "manifest",
    )
    require(manifest.get("schemaVersion") == 1, "manifest: schemaVersion must be 1")

    synthetic = manifest.get("synthetic")
    _check_keys(
        synthetic,
        {
            "peripheralUUID",
            "manufacturer",
            "model",
            "firmware",
            "defaultsSuitePrefix",
            "devices",
        },
        "manifest.synthetic",
    )
    require(
        isinstance(synthetic["peripheralUUID"], str) and UUID_RE.fullmatch(synthetic["peripheralUUID"]),
        "manifest.synthetic: peripheralUUID must be a UUID",
    )
    for key in ("manufacturer", "model", "firmware", "defaultsSuitePrefix"):
        require(isinstance(synthetic[key], str) and synthetic[key], f"manifest.synthetic: {key} is required")
    require(isinstance(synthetic["devices"], list) and synthetic["devices"], "manifest.synthetic: devices are required")
    for index, device in enumerate(synthetic["devices"]):
        _check_keys(device, {"address", "name", "connected"}, f"manifest.synthetic.devices[{index}]")
        require(isinstance(device["address"], str) and device["address"], "device address is required")
        require(isinstance(device["name"], str) and device["name"], "device name is required")
        require(isinstance(device["connected"], bool), "device connected must be a boolean")

    simulator = manifest.get("simulator")
    _check_keys(
        simulator,
        {"deviceTypes", "runtime", "minimumRuntimeMajor", "compactDeviceTypes"},
        "manifest.simulator",
    )
    require(isinstance(simulator["deviceTypes"], list) and simulator["deviceTypes"], "simulator deviceTypes required")
    require(isinstance(simulator["runtime"], str) and simulator["runtime"], "simulator runtime required")
    require(isinstance(simulator["minimumRuntimeMajor"], int), "simulator minimumRuntimeMajor required")
    require(isinstance(simulator["compactDeviceTypes"], list), "simulator compactDeviceTypes required")

    session = manifest.get("session")
    _check_keys(session, {"target", "tests"}, "manifest.session")
    require(isinstance(session.get("target"), str) and session["target"], "session target required")
    require(isinstance(session.get("tests"), list) and session["tests"], "session tests required")

    seen_ids: set[str] = set()
    for index, entry in enumerate(session["tests"]):
        _validate_entry(entry, f"manifest.session.tests[{index}]", seen_ids)
        require(entry["id"].startswith(session["target"] + "/"), f"{entry['id']}: not in target {session['target']}")
        require("label" in entry, f"{entry['id']}: session entries need a label")

    journeys = manifest.get("journeys")
    require(isinstance(journeys, list) and journeys, "manifest journeys required")
    names: set[str] = set()
    for index, entry in enumerate(journeys):
        _validate_entry(entry, f"manifest.journeys[{index}]", seen_ids)
        require(isinstance(entry.get("name"), str) and entry["name"], "journey name required")
        require(entry["name"] not in names, f"duplicate journey name {entry['name']!r}")
        names.add(entry["name"])


def _validate_entry(entry, where: str, seen_ids: set[str]) -> None:
    _check_keys(entry, {"id", "label", "name", "test", "run", "expect"}, where)
    identifier = entry.get("id", entry.get("test"))
    require(isinstance(identifier, str) and identifier, f"{where}: test id required")
    require(TEST_ID_RE.fullmatch(identifier), f"{where}: invalid test id {identifier!r}")
    require(identifier not in seen_ids, f"{where}: duplicate test id {identifier!r}")
    seen_ids.add(identifier)
    if "test" in entry and "id" not in entry:
        entry["id"] = entry.pop("test")

    run = entry.get("run")
    _check_keys(run, RUN_KEYS, f"{where}.run")
    require(isinstance(run.get("prefix"), str) and run["prefix"], f"{where}.run: prefix required")
    artifacts = run.get("artifacts", True)
    require(isinstance(artifacts, bool), f"{where}.run: artifacts must be a boolean")
    require(artifacts or identifier in NO_ARTIFACT_TESTS,
            f"{where}: no-artifact exemption is not allowed for {identifier}")
    if artifacts:
        require(isinstance(run.get("scenario"), str) and run["scenario"], f"{where}.run: scenario required")
        require(isinstance(run.get("reset"), bool), f"{where}.run: reset must be a boolean")
        expect = entry.get("expect")
        require(isinstance(expect, dict), f"{where}: expect required when artifacts are enabled")
        _check_keys(expect, EXPECT_KEYS, f"{where}.expect")
        if "snapshot" in expect:
            _check_keys(expect["snapshot"], SNAPSHOT_KEYS, f"{where}.expect.snapshot")
            require(isinstance(expect["snapshot"].get("lastMode"), int), f"{where}: snapshot.lastMode required")
            eq = expect["snapshot"].get("eq")
            require(isinstance(eq, list) and len(eq) == 3, f"{where}: snapshot.eq must have 3 values")
            require(all(isinstance(value, int) for value in eq), f"{where}: snapshot.eq values must be integers")
        if "peripheral" in expect:
            _check_keys(expect["peripheral"], PERIPHERAL_KEYS, f"{where}.expect.peripheral")
            require(isinstance(expect["peripheral"].get("connected"), bool), f"{where}: peripheral.connected required")
            require(isinstance(expect["peripheral"].get("mode"), int), f"{where}: peripheral.mode required")
            eq = expect["peripheral"].get("eq")
            require(isinstance(eq, list) and len(eq) == 3, f"{where}: peripheral.eq must have 3 values")
            require(isinstance(expect["peripheral"].get("multipoint"), bool), f"{where}: peripheral.multipoint required")
        if "transcript" in expect:
            _check_keys(expect["transcript"], TRANSCRIPT_KEYS, f"{where}.expect.transcript")
            scenarios = expect["transcript"].get("scenarios")
            require(isinstance(scenarios, list) and scenarios, f"{where}: transcript.scenarios required")
            require(all(isinstance(value, str) and value for value in scenarios), f"{where}: invalid scenario")
            for key in ("order", "required", "forbidden"):
                tokens = expect["transcript"].get(key, [])
                require(isinstance(tokens, list), f"{where}: transcript.{key} must be a list")
                for token in tokens:
                    require(
                        isinstance(token, str) and PACKET_TOKEN_RE.fullmatch(token),
                        f"{where}: invalid transcript {key} token {token!r}",
                    )
            no_outbound = expect["transcript"].get("noOutboundScenarios", [])
            require(isinstance(no_outbound, list), f"{where}: noOutboundScenarios must be a list")
            messages = expect["transcript"].get("forbiddenMessages", [])
            require(isinstance(messages, list), f"{where}: forbiddenMessages must be a list")


def load_manifest(path: Path = MANIFEST_PATH):
    manifest = load_json_file(path)
    validate_manifest(manifest)
    return manifest


def entry_identifier(entry: dict) -> str:
    return entry.get("id") or entry.get("test") or "unknown-test"


def all_manifest_tests(manifest) -> list[str]:
    tests = [entry_identifier(entry) for entry in manifest["session"]["tests"]]
    tests.extend(entry_identifier(entry) for entry in manifest["journeys"])
    return tests


def select_journeys(manifest, only: list[str], lane: str) -> list[dict]:
    if only and lane != "ui":
        raise UsageError("--only is valid only for the ui lane")
    names = [entry["name"] for entry in manifest["journeys"]]
    if not only:
        return list(manifest["journeys"])
    selected = []
    for name in only:
        if not name or name not in names:
            raise UsageError(f"unknown UI journey {name!r}; choose from: {', '.join(names)}")
        entry = next(item for item in manifest["journeys"] if item["name"] == name)
        if entry not in selected:
            selected.append(entry)
    if not selected:
        raise UsageError("no UI journey selected")
    return selected


# ---------------------------------------------------------------------------
# Discovery / xcresult / artifact inspection
# ---------------------------------------------------------------------------


def parse_enumeration_document(document) -> tuple[list[str], list[str]]:
    require(isinstance(document, dict), "enumeration: expected an object")
    errors = document.get("errors", [])
    require(isinstance(errors, list), "enumeration: errors must be a list")
    require(not errors, f"enumeration reported errors: {errors}")
    values = document.get("values")
    require(isinstance(values, list) and values, "enumeration: no values")
    enabled: list[str] = []
    disabled: list[str] = []
    for value in values:
        require(isinstance(value, dict), "enumeration: value must be an object")
        for key, bucket in (("enabledTests", enabled), ("disabledTests", disabled)):
            entries = value.get(key, [])
            require(isinstance(entries, list), f"enumeration: {key} must be a list")
            for item in entries:
                require(isinstance(item, dict) and isinstance(item.get("identifier"), str), "enumeration: bad test entry")
                bucket.append(item["identifier"])
    return enabled, disabled


def normalize_test_id(identifier: str) -> str:
    return identifier[:-2] if identifier.endswith("()") else identifier


def check_discovered(manifest, enabled: list[str], disabled: list[str]) -> list[str]:
    errors: list[str] = []
    enabled_normalized = [normalize_test_id(item) for item in enabled]
    duplicates = sorted({item for item in enabled_normalized if enabled_normalized.count(item) > 1})
    if duplicates:
        errors.append(f"enumeration returned duplicate tests: {duplicates}")
    expected = {normalize_test_id(item) for item in all_manifest_tests(manifest)}
    discovered = set(enabled_normalized)
    missing = sorted(expected - discovered)
    unknown = sorted(discovered - expected)
    if missing:
        errors.append(f"manifest tests not discovered (stale manifest): {missing}")
    if unknown:
        errors.append(f"discovered tests missing from manifest (add them): {unknown}")
    disabled_tests = sorted({normalize_test_id(item) for item in disabled})
    if disabled_tests:
        errors.append(f"tests are disabled in the test plan: {disabled_tests}")
    return errors


def leaf_records_from_tests_json(document) -> list[dict]:
    require(isinstance(document, dict), "xcresult tests: expected an object")
    nodes = document.get("testNodes")
    require(isinstance(nodes, list), "xcresult tests: testNodes missing")
    records: list[dict] = []

    def walk(node):
        require(isinstance(node, dict), "xcresult tests: node must be an object")
        if node.get("nodeType") == "Test Case":
            url = node.get("nodeIdentifierURL")
            identifier = None
            if isinstance(url, str) and "://" in url:
                parts = url.split("://", 1)[1].split("/")
                if len(parts) >= 4:
                    identifier = "/".join(parts[-3:])
            if identifier is None:
                raw = node.get("nodeIdentifier")
                require(isinstance(raw, str) and "/" in raw, "xcresult tests: test case lacks an identifier")
                identifier = raw
            records.append(
                {
                    "id": identifier,
                    "name": node.get("name", ""),
                    "result": node.get("result", "Unknown"),
                }
            )
        for child in node.get("children") or []:
            walk(child)

    for node in nodes:
        walk(node)
    return records


def result_summary_errors(summary, leaves: list[dict], expected_ids: list[str], udid: str) -> tuple[list[str], dict]:
    errors: list[str] = []
    require(isinstance(summary, dict), "xcresult summary: expected an object")
    expected = {normalize_test_id(item) for item in expected_ids}
    actual = [normalize_test_id(record["id"]) for record in leaves]
    actual_set = set(actual)
    counts = {
        "expected": len(expected),
        "total": summary.get("totalTestCount"),
        "passed": summary.get("passedTests"),
        "failed": summary.get("failedTests"),
        "skipped": summary.get("skippedTests"),
        "expectedFailures": summary.get("expectedFailures"),
    }
    if summary.get("result") != "Passed":
        errors.append(f"xcresult result is {summary.get('result')!r}, not 'Passed'")
    if counts["total"] != len(expected):
        errors.append(f"xcresult totalTestCount {counts['total']!r} != selected {len(expected)}")
    if counts["passed"] != len(expected):
        errors.append(f"xcresult passedTests {counts['passed']!r} != selected {len(expected)}")
    if counts["failed"] != 0:
        errors.append(f"xcresult failedTests {counts['failed']!r} != 0")
    if counts["skipped"] != 0:
        errors.append(f"xcresult skippedTests {counts['skipped']!r} != 0")
    if counts["expectedFailures"] != 0:
        errors.append(f"xcresult expectedFailures {counts['expectedFailures']!r} != 0")
    failures = summary.get("testFailures", [])
    if failures:
        errors.append(f"xcresult reports test failures: {[item.get('testName') for item in failures if isinstance(item, dict)]}")
    duplicates = sorted({item for item in actual if actual.count(item) > 1})
    if duplicates:
        errors.append(f"xcresult contains duplicate tests: {duplicates}")
    missing = sorted(expected - actual_set)
    unknown = sorted(actual_set - expected)
    if missing:
        errors.append(f"selected tests did not execute: {missing}")
    if unknown:
        errors.append(f"unexpected tests executed: {unknown}")
    for record in leaves:
        if record["result"] != "Passed":
            errors.append(f"{record['id']}: xcresult leaf result is {record['result']!r}")
    configurations = summary.get("devicesAndConfigurations")
    if not isinstance(configurations, list) or not configurations:
        errors.append("xcresult has no device configuration")
    else:
        for configuration in configurations:
            device = (configuration or {}).get("device") or {}
            if device.get("deviceId") != udid:
                errors.append(f"xcresult destination {device.get('deviceId')!r} != owned simulator {udid}")
    return errors, counts


def _transcript_rows(path: Path) -> list[dict]:
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        raise VerifyError(f"cannot read transcript {path}: {error}") from error
    rows: list[dict] = []
    lines = text.splitlines()
    if not lines:
        raise VerifyError(f"{path}: transcript is empty")
    for index, line in enumerate(lines, 1):
        if not line.strip():
            raise VerifyError(f"{path}:{index}: blank transcript line")
        try:
            row = json.loads(
                line,
                object_pairs_hook=_reject_duplicate_keys,
                parse_constant=_reject_constant,
            )
        except ValueError as error:
            raise VerifyError(f"{path}:{index}: malformed transcript JSON: {error}") from error
        require(isinstance(row, dict), f"{path}:{index}: transcript record must be an object")
        rows.append(row)
    return rows


def _check_transcript(path: Path, expect: dict, synthetic: dict) -> list[str]:
    errors: list[str] = []
    try:
        rows = _transcript_rows(path)
    except VerifyError as error:
        return [str(error)]

    expected_sequence = 1
    seen_scenarios: list[str] = []
    for index, row in enumerate(rows, 1):
        where = f"{path.name}:{index}"
        required = {"sequence", "timestamp", "direction", "kind", "bytes", "scenario", "peripheral", "connection"}
        missing = sorted(required - set(row))
        if missing:
            errors.append(f"{where}: missing fields {missing}")
            continue
        if not isinstance(row["sequence"], int) or row["sequence"] != expected_sequence:
            errors.append(f"{where}: sequence {row['sequence']!r} != expected {expected_sequence}")
        expected_sequence = (row["sequence"] if isinstance(row["sequence"], int) else expected_sequence) + 1
        try:
            iso8601(row["timestamp"], where)
        except VerifyError as error:
            errors.append(str(error))
        if row["direction"] not in {"outbound", "inbound", "event"}:
            errors.append(f"{where}: invalid direction {row['direction']!r}")
        if row["kind"] not in {"segment", "bmap", "event"}:
            errors.append(f"{where}: invalid kind {row['kind']!r}")
        if row["peripheral"] != synthetic["peripheralUUID"]:
            errors.append(f"{where}: peripheral {row['peripheral']!r} is not the synthetic identity")
        if row["connection"] != "simulated":
            errors.append(f"{where}: connection {row['connection']!r} is not simulated")
        if row["scenario"] not in seen_scenarios:
            seen_scenarios.append(row["scenario"])
        if row["kind"] == "event":
            if row["bytes"] != "":
                errors.append(f"{where}: event records must not carry bytes")
        else:
            try:
                validate_hex_packet(row["bytes"], where)
            except VerifyError as error:
                errors.append(str(error))
        message = row.get("message")
        if message is not None and not isinstance(message, str):
            errors.append(f"{where}: message must be a string")

    expected_scenarios = expect.get("scenarios", [])
    if seen_scenarios != expected_scenarios:
        errors.append(f"{path.name}: scenario order {seen_scenarios} != expected {expected_scenarios}")

    def matches(row, token: str) -> bool:
        direction, packet = token.split(":", 1)
        return (
            row.get("direction") == direction
            and row.get("kind") == "bmap"
            and normalize_packet(row.get("bytes", "")) == normalize_packet(packet)
        )

    position = 0
    for token in expect.get("order", []):
        found = None
        for index in range(position, len(rows)):
            if matches(rows[index], token):
                found = index
                break
        if found is None:
            errors.append(f"{path.name}: ordered packet {token!r} missing after record {position}")
            break
        position = found + 1

    for token in expect.get("required", []):
        if not any(matches(row, token) for row in rows):
            errors.append(f"{path.name}: required packet {token!r} missing")

    for token in expect.get("forbidden", []):
        if any(matches(row, token) for row in rows):
            errors.append(f"{path.name}: forbidden packet {token!r} present")

    forbidden_scenarios = set(expect.get("noOutboundScenarios", []))
    for index, row in enumerate(rows, 1):
        if (
            row.get("scenario") in forbidden_scenarios
            and row.get("direction") == "outbound"
            and row.get("kind") in {"segment", "bmap"}
        ):
            errors.append(f"{path.name}:{index}: outbound bytes in scenario {row['scenario']!r}")

    for message in expect.get("forbiddenMessages", []):
        if any(message in (row.get("message") or "") for row in rows):
            errors.append(f"{path.name}: forbidden transcript message {message!r} present")
    return errors


def _check_snapshot(path: Path, expected: dict, synthetic: dict) -> list[str]:
    errors: list[str] = []
    try:
        snapshot = load_json_file(path)
    except VerifyError as error:
        return [str(error)]
    if not isinstance(snapshot, dict):
        return [f"{path.name}: expected an object"]
    required = {
        "version",
        "peripheralID",
        "manufacturer",
        "model",
        "firmware",
        "modes",
        "eq",
        "lastMode",
        "lastSeen",
    }
    missing = sorted(required - set(snapshot))
    if missing:
        return [f"{path.name}: missing fields {missing}"]
    if snapshot["version"] != 1:
        errors.append(f"{path.name}: version {snapshot['version']!r} != 1")
    if snapshot["peripheralID"] != synthetic["peripheralUUID"]:
        errors.append(f"{path.name}: peripheralID is not the synthetic identity")
    if snapshot["manufacturer"] != synthetic["manufacturer"]:
        errors.append(f"{path.name}: manufacturer {snapshot['manufacturer']!r} is not synthetic")
    if snapshot["model"] != synthetic["model"]:
        errors.append(f"{path.name}: model {snapshot['model']!r} is not synthetic")
    if snapshot["firmware"] != synthetic["firmware"]:
        errors.append(f"{path.name}: firmware {snapshot['firmware']!r} is not synthetic")
    if snapshot["lastMode"] != expected["lastMode"]:
        errors.append(f"{path.name}: lastMode {snapshot['lastMode']!r} != expected {expected['lastMode']!r}")
    modes = snapshot["modes"]
    if not isinstance(modes, list) or not any(
        isinstance(mode, dict) and mode.get("index") == snapshot["lastMode"] for mode in modes
    ):
        errors.append(f"{path.name}: lastMode is not present in confirmed modes")
    eq = snapshot["eq"]
    try:
        values = [item["value"] for item in sorted(eq, key=lambda item: item["band"])]
    except (TypeError, KeyError):
        values = None
    if values != expected["eq"]:
        errors.append(f"{path.name}: snapshot EQ {values!r} != expected {expected['eq']!r}")
    try:
        iso8601(snapshot["lastSeen"], f"{path.name}.lastSeen")
    except VerifyError as error:
        errors.append(str(error))
    return errors


def _check_peripheral(path: Path, expected: dict, synthetic: dict, run_id: str) -> list[str]:
    errors: list[str] = []
    try:
        state = load_json_file(path)
    except VerifyError as error:
        return [str(error)]
    if not isinstance(state, dict):
        return [f"{path.name}: expected an object"]
    required = {"scenario", "runID", "connected", "mode", "eq", "multipoint", "devices", "updatedAt"}
    missing = sorted(required - set(state))
    if missing:
        return [f"{path.name}: missing fields {missing}"]
    if state["runID"] != run_id:
        errors.append(f"{path.name}: runID {state['runID']!r} != {run_id!r}")
    if state["connected"] != expected["connected"]:
        errors.append(f"{path.name}: connected {state['connected']!r} != {expected['connected']!r}")
    if state["mode"] != expected["mode"]:
        errors.append(f"{path.name}: mode {state['mode']!r} != {expected['mode']!r}")
    if state["eq"] != expected["eq"]:
        errors.append(f"{path.name}: EQ {state['eq']!r} != {expected['eq']!r}")
    if state["multipoint"] != expected["multipoint"]:
        errors.append(f"{path.name}: multipoint {state['multipoint']!r} != {expected['multipoint']!r}")
    devices = state["devices"]
    expected_devices = [
        {
            "address": normalize_packet(device["address"]),
            "name": device["name"],
            "connected": device["connected"],
        }
        for device in synthetic["devices"]
    ]
    if not isinstance(devices, list):
        errors.append(f"{path.name}: devices must be a list")
    else:
        actual_devices = [
            {
                "address": normalize_packet(device.get("address", "")),
                "name": device.get("name"),
                "connected": device.get("connected"),
            }
            for device in devices
            if isinstance(device, dict)
        ]
        if actual_devices != expected_devices:
            errors.append(f"{path.name}: paired devices {actual_devices!r} != synthetic {expected_devices!r}")
    try:
        iso8601(state["updatedAt"], f"{path.name}.updatedAt")
    except VerifyError as error:
        errors.append(str(error))
    return errors


def exported_run_names(export_root: Path) -> set[str]:
    base = export_root / "ApplicationSupport" / "QuietControlUITests"
    if not base.is_dir():
        return set()
    return {path.name for path in base.iterdir() if path.is_dir()}


def find_run_dir(export_root: Path, prefix: str, allowed: set[str] | None = None) -> Path:
    base = export_root / "ApplicationSupport" / "QuietControlUITests"
    require(base.is_dir(), f"missing exported test data at {base}")
    matches = sorted(
        path
        for path in base.iterdir()
        if path.is_dir() and path.name.startswith(prefix) and (allowed is None or path.name in allowed)
    )
    if len(matches) != 1:
        names = [path.name for path in matches]
        raise VerifyError(f"expected exactly one run directory with prefix {prefix!r}, found {names}")
    return matches[0]


def inspect_entry_artifacts(
    entry: dict, export_root: Path, synthetic: dict, allowed_runs: set[str] | None = None
) -> list[str]:
    """Validate one manifest entry's exported app-container evidence."""
    identifier = entry_identifier(entry)
    run = entry["run"]
    prefix = run["prefix"]
    if not run.get("artifacts", True):
        if identifier not in NO_ARTIFACT_TESTS:
            return [f"{identifier}: no-artifact exemption is not allowed"]
        base = export_root / "ApplicationSupport" / "QuietControlUITests"
        if base.is_dir():
            unexpected = [path.name for path in base.iterdir() if path.is_dir() and path.name.startswith(prefix)]
            if unexpected:
                return [f"{identifier}: unexpected app-container artifacts {unexpected} for a no-artifact test"]
        return []

    try:
        run_dir = find_run_dir(export_root, prefix, allowed_runs)
    except VerifyError as error:
        return [f"{identifier}: {error}"]
    run_id = run_dir.name
    errors: list[str] = []

    config_path = run_dir / "test-config.json"
    try:
        config = load_json_file(config_path)
    except VerifyError as error:
        return [f"{identifier}: {error}"]
    required = {"scenario", "runID", "reset", "peripheral", "defaultsSuite"}
    missing = sorted(required - set(config)) if isinstance(config, dict) else sorted(required)
    if missing:
        return [f"{identifier}: test-config.json missing fields {missing}"]
    if config["runID"] != run_id:
        errors.append(f"{identifier}: test-config runID {config['runID']!r} != directory {run_id!r}")
    if config["scenario"] != run["scenario"]:
        errors.append(
            f"{identifier}: test-config scenario {config['scenario']!r} != manifest {run['scenario']!r}"
        )
    if config["reset"] != run["reset"]:
        errors.append(f"{identifier}: test-config reset {config['reset']!r} != manifest {run['reset']!r}")
    if config["peripheral"] != synthetic["peripheralUUID"]:
        errors.append(f"{identifier}: test-config peripheral is not the synthetic identity")
    expected_suite = synthetic["defaultsSuitePrefix"] + run_id
    if config["defaultsSuite"] != expected_suite:
        errors.append(f"{identifier}: defaults suite {config['defaultsSuite']!r} != {expected_suite!r}")

    expect = entry["expect"]
    transcript_path = run_dir / "transport.jsonl"
    if not transcript_path.is_file():
        errors.append(f"{identifier}: missing transport.jsonl")
    else:
        errors.extend(_check_transcript(transcript_path, expect.get("transcript", {}), synthetic))

    if "snapshot" in expect:
        snapshot_path = run_dir / "LastConfirmedState.json"
        if not snapshot_path.is_file():
            errors.append(f"{identifier}: missing LastConfirmedState.json")
        else:
            errors.extend(_check_snapshot(snapshot_path, expect["snapshot"], synthetic))

    if "peripheral" in expect:
        state_path = run_dir / "peripheral-state.json"
        if not state_path.is_file():
            errors.append(f"{identifier}: missing peripheral-state.json")
        else:
            errors.extend(_check_peripheral(state_path, expect["peripheral"], synthetic, run_id))
    return errors


# ---------------------------------------------------------------------------
# Simulator lifecycle
# ---------------------------------------------------------------------------


def _version_tuple(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", value))


def choose_simulator(manifest, runtimes_doc) -> tuple[dict, dict, list[dict]]:
    runtimes = runtimes_doc.get("runtimes", [])
    available = [
        runtime
        for runtime in runtimes
        if runtime.get("platform") == "iOS" and runtime.get("isAvailable", False)
    ]
    require(bool(available), "no available iOS simulator runtime is installed")
    simulator = manifest["simulator"]
    preferred_name = simulator["runtime"]
    preferred = next((runtime for runtime in available if runtime.get("name") == preferred_name), None)
    if preferred is None:
        minimum = simulator["minimumRuntimeMajor"]
        compatible = [runtime for runtime in available if _version_tuple(runtime["version"])[0] >= minimum]
        require(bool(compatible), f"no iOS {minimum}+ simulator runtime is installed")
        preferred = max(compatible, key=lambda runtime: _version_tuple(runtime["version"]))

    supported = {
        item["name"]: item for item in preferred.get("supportedDeviceTypes", []) if item.get("name")
    }
    device_type = None
    for name in simulator["deviceTypes"]:
        if name in supported:
            device_type = supported[name]
            break
    require(device_type is not None, f"runtime {preferred['name']} supports none of {simulator['deviceTypes']}")

    coverage = []
    minimum = simulator["minimumRuntimeMajor"]
    minimum_runtimes = [
        runtime for runtime in available if _version_tuple(runtime["version"])[0] == minimum
    ]
    if not minimum_runtimes:
        coverage.append(
            {
                "lane": "minimum-ios-runtime",
                "status": "BLOCKED",
                "countedAsTested": False,
                "detail": f"iOS {minimum} simulator runtime is not installed; minimum-OS coverage is absent.",
            }
        )
    compact_names = set(simulator["compactDeviceTypes"])
    compact_available = any(
        compact_names & {item.get("name") for item in runtime.get("supportedDeviceTypes", [])}
        for runtime in available
    )
    if not compact_available:
        coverage.append(
            {
                "lane": "compact-device",
                "status": "BLOCKED",
                "countedAsTested": False,
                "detail": f"none of {sorted(compact_names)} is supported by an installed runtime; compact-device coverage is absent.",
            }
        )
    return preferred, device_type, coverage


def create_simulator(runner: CommandRunner, runtime: dict, device_type: dict, run_id: str):
    name = f"QuietControl Verify {run_id}"
    command = [
        "xcrun",
        "simctl",
        "create",
        name,
        device_type["identifier"],
        runtime["identifier"],
    ]
    result = runner.run(command, "simulator-create", SHORT_TIMEOUT, capture=True)
    if result.returncode != 0:
        raise BlockedError(f"simulator create failed; see {result.log_path}")
    udid = result.stdout.strip()
    if not UUID_RE.fullmatch(udid):
        raise BlockedError(f"simulator create returned an invalid UDID {udid!r}")
    return {"udid": udid, "name": name, "deviceType": device_type["name"], "runtime": runtime["name"]}


def boot_simulator(runner: CommandRunner, simulator: dict) -> None:
    udid = simulator["udid"]
    boot = runner.run(["xcrun", "simctl", "boot", udid], "simulator-boot", SHORT_TIMEOUT, capture=True)
    if boot.returncode != 0:
        raise BlockedError(f"simulator boot failed; see {boot.log_path}")
    status = runner.run(
        ["xcrun", "simctl", "bootstatus", udid, "-b"], "simulator-bootstatus", SHORT_TIMEOUT, capture=True
    )
    if status.returncode != 0:
        raise BlockedError(f"simulator did not finish booting; see {status.log_path}")


def owned_device_for_cleanup(inventory, simulator: dict | None) -> tuple[dict | None, list[str]]:
    """Return the inventory entry for this run's recorded UUID, never another device."""
    if not simulator:
        return None, []
    udid = simulator.get("udid")
    if not udid or not UUID_RE.fullmatch(udid):
        return None, [f"refusing to clean up invalid simulator UDID {udid!r}"]
    matches = [
        device
        for devices in inventory.get("devices", {}).values()
        for device in devices or []
        if device.get("udid") == udid
    ]
    if not matches:
        return None, []
    owned = matches[0]
    if owned.get("name") != simulator.get("name"):
        return None, [
            f"refusing to delete {udid}: device name {owned.get('name')!r} is not task-owned {simulator.get('name')!r}"
        ]
    return owned, []


def cleanup_simulator(runner: CommandRunner, simulator: dict | None) -> list[str]:
    """Remove only the simulator this run created, identified by its recorded UDID."""
    errors: list[str] = []
    if not simulator:
        return errors
    udid = simulator.get("udid")
    if not udid or not UUID_RE.fullmatch(udid):
        return [f"refusing to clean up invalid simulator UDID {udid!r}"]
    try:
        inventory, _ = runner.json_command(
            ["xcrun", "simctl", "list", "devices", "--json"], "simulator-cleanup-inventory"
        )
    except VerifyError as error:
        return [f"cannot verify simulator ownership before cleanup: {error}"]
    owned, ownership_errors = owned_device_for_cleanup(inventory, simulator)
    if ownership_errors:
        return ownership_errors
    if owned is not None:
        runner.run(["xcrun", "simctl", "shutdown", udid], "simulator-cleanup-shutdown", SHORT_TIMEOUT)
        deleted = runner.run(["xcrun", "simctl", "delete", udid], "simulator-cleanup-delete", SHORT_TIMEOUT)
        if deleted.returncode != 0:
            errors.append(f"failed to delete task-owned simulator {udid}; see {deleted.log_path}")
    try:
        inventory, _ = runner.json_command(
            ["xcrun", "simctl", "list", "devices", "--json"], "simulator-cleanup-verify"
        )
        remaining = [
            device.get("udid")
            for devices in inventory.get("devices", {}).values()
            for device in devices or []
            if device.get("udid") == udid
        ]
        if remaining:
            errors.append(f"task-owned simulator {udid} still exists after cleanup")
    except VerifyError as error:
        errors.append(f"cannot verify simulator cleanup: {error}")
    return errors


# ---------------------------------------------------------------------------
# Source fingerprint and environment preflight
# ---------------------------------------------------------------------------


def content_fingerprint(paths: list[str], root: Path = ROOT) -> str:
    """Hash working-tree contents without depending on Git's index or HEAD SHA.

    The same file contents therefore keep the same fingerprint before and after a
    commit, while any later edit invalidates it.
    """
    digest = hashlib.sha256()
    for relative in sorted(set(paths)):
        digest.update(relative.encode("utf-8", errors="replace"))
        digest.update(b"\0")
        path = root / relative
        if path.is_file():
            digest.update(hashlib.sha256(path.read_bytes()).digest())
        else:
            digest.update(b"<missing>")
    return digest.hexdigest()


def fingerprint_source(runner: CommandRunner) -> dict:
    sha_result = runner.run(["git", "rev-parse", "HEAD"], "source-sha", SHORT_TIMEOUT, capture=True)
    require(sha_result.returncode == 0, "git rev-parse HEAD failed")
    status_result = runner.run(["git", "status", "--porcelain"], "source-status", SHORT_TIMEOUT, capture=True)
    require(status_result.returncode == 0, "git status failed")
    tracked_result = runner.run(["git", "ls-files", "-z"], "source-tracked", SHORT_TIMEOUT, capture=True)
    require(tracked_result.returncode == 0, "git ls-files failed")
    untracked_result = runner.run(
        ["git", "ls-files", "--others", "--exclude-standard", "-z"],
        "source-untracked",
        SHORT_TIMEOUT,
        capture=True,
    )
    require(untracked_result.returncode == 0, "git ls-files failed")

    sha = sha_result.stdout.strip()
    status = status_result.stdout
    tracked = [path for path in tracked_result.stdout.split("\0") if path]
    untracked = [path for path in untracked_result.stdout.split("\0") if path]
    digest = content_fingerprint(tracked + untracked)

    dirty_files = []
    for line in status.splitlines():
        if len(line) > 3:
            dirty_files.append(line[3:].split(" -> ")[-1])
    return {
        "sha": sha,
        "dirty": bool(status.strip()),
        "dirtyFiles": dirty_files,
        "contentFingerprint": digest,
        "fingerprint": f"tree:{digest}",
    }


def preflight(runner: CommandRunner, manifest) -> dict:
    developer_dir = Path(runner.developer_dir)
    xcodebuild = developer_dir / "usr" / "bin" / "xcodebuild"
    if not xcodebuild.is_file() or not os.access(xcodebuild, os.X_OK):
        raise BlockedError(f"full Xcode is not installed at {developer_dir}")
    for tool in ("git", "nm", "strings", "xcrun"):
        if shutil.which(tool) is None:
            raise BlockedError(f"required tool {tool!r} is not installed")
    for tool in ("xcodebuild", "simctl", "xcresulttool", "swift"):
        found = runner.run(["xcrun", "--find", tool], f"preflight-{tool}", SHORT_TIMEOUT, capture=True)
        if found.returncode != 0 or not found.stdout.strip():
            raise BlockedError(f"required Xcode tool {tool!r} is unavailable")

    version = runner.run(["xcodebuild", "-version"], "preflight-xcode-version", SHORT_TIMEOUT, capture=True)
    if version.returncode != 0:
        raise BlockedError("xcodebuild -version failed")
    version_lines = version.stdout.splitlines()
    xcode_version = version_lines[0] if version_lines else "unknown"
    xcode_build = version_lines[1] if len(version_lines) > 1 else "unknown"

    disk = shutil.disk_usage(ROOT)
    if disk.free < MIN_FREE_DISK_BYTES:
        raise BlockedError(
            f"only {disk.free / 1024 ** 3:.1f} GiB free; need at least {MIN_FREE_DISK_BYTES / 1024 ** 3:.0f} GiB"
        )

    runtimes_doc, _ = runner.json_command(["xcrun", "simctl", "list", "runtimes", "--json"], "preflight-runtimes")
    runtime, device_type, coverage = choose_simulator(manifest, runtimes_doc)
    return {
        "xcodeVersion": xcode_version,
        "xcodeBuild": xcode_build,
        "macOS": os.uname().release,
        "runtime": runtime,
        "deviceType": device_type,
        "coverage": coverage,
    }


# ---------------------------------------------------------------------------
# Lanes
# ---------------------------------------------------------------------------


def _build_for_testing(runner: CommandRunner, run_dir: Path, simulator: dict) -> Path:
    derived_data = run_dir / "DerivedData"
    command = [
        "xcodebuild",
        "build-for-testing",
        "-project",
        "QuietControl.xcodeproj",
        "-scheme",
        "QuietControl",
        "-testPlan",
        "QuietControl",
        "-destination",
        f"platform=iOS Simulator,id={simulator['udid']}",
        "-derivedDataPath",
        str(derived_data),
        "CODE_SIGNING_ALLOWED=NO",
    ]
    result = runner.run(command, "build-for-testing", BUILD_TIMEOUT)
    require(result.returncode == 0, f"build-for-testing failed; see {result.log_path}")
    candidates = sorted((derived_data / "Build" / "Products").glob("*.xctestrun"))
    require(len(candidates) == 1, f"expected one .xctestrun, found {[str(path) for path in candidates]}")
    return candidates[0]


def _enumerate_tests(runner: CommandRunner, run_dir: Path, simulator: dict, xctestrun: Path):
    enumeration_path = run_dir / "artifacts" / "enumeration.json"
    enumeration_path.parent.mkdir(parents=True, exist_ok=True)
    result_path = run_dir / "results" / "enumeration.xcresult"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "xcodebuild",
        "test-without-building",
        "-xctestrun",
        str(xctestrun),
        "-destination",
        f"platform=iOS Simulator,id={simulator['udid']}",
        "-enumerate-tests",
        "-test-enumeration-style",
        "flat",
        "-test-enumeration-format",
        "json",
        "-test-enumeration-output-path",
        str(enumeration_path),
        "-resultBundlePath",
        str(result_path),
        "CODE_SIGNING_ALLOWED=NO",
    ]
    result = runner.run(command, "enumerate-tests", TEST_TIMEOUT)
    require(result.returncode == 0, f"test enumeration failed; see {result.log_path}")
    document = load_json_file(enumeration_path)
    enabled, disabled = parse_enumeration_document(document)
    return enabled, disabled, enumeration_path, result_path


def _run_xcode_tests(
    runner: CommandRunner,
    run_dir: Path,
    simulator: dict,
    xctestrun: Path,
    label: str,
    test_ids: list[str],
):
    result_path = run_dir / "results" / f"{label}.xcresult"
    result_path.parent.mkdir(parents=True, exist_ok=True)
    command = [
        "xcodebuild",
        "test-without-building",
        "-xctestrun",
        str(xctestrun),
        "-destination",
        f"platform=iOS Simulator,id={simulator['udid']}",
        "-parallel-testing-enabled",
        "NO",
        "-resultBundlePath",
        str(result_path),
    ]
    command.extend(f"-only-testing:{identifier}" for identifier in test_ids)
    command.append("CODE_SIGNING_ALLOWED=NO")
    result = runner.run(command, label, TEST_TIMEOUT)
    command_errors = []
    if result.timed_out:
        command_errors.append(f"{label}: xcodebuild timed out; see {result.log_path}")
    if result.returncode != 0:
        command_errors.append(f"{label}: xcodebuild failed with exit {result.returncode}; see {result.log_path}")
    if not result_path.is_dir():
        return {
            "label": label,
            "command": shlex.join(command),
            "returncode": result.returncode,
            "timedOut": result.timed_out,
            "log": str(result.log_path),
            "resultBundle": str(result_path),
            "counts": {},
            "tests": [],
            "errors": command_errors + [f"{label}: no xcresult produced (exit {result.returncode}); see {result.log_path}"],
        }
    try:
        summary, summary_result = runner.json_command(
            ["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result_path), "--compact"],
            f"{label}-summary",
        )
        tests_document, tests_result = runner.json_command(
            ["xcrun", "xcresulttool", "get", "test-results", "tests", "--path", str(result_path), "--compact"],
            f"{label}-tests",
        )
        leaves = leaf_records_from_tests_json(tests_document)
        errors, counts = result_summary_errors(summary, leaves, test_ids, simulator["udid"])
    except VerifyError as error:
        return {
            "label": label,
            "command": shlex.join(command),
            "returncode": result.returncode,
            "timedOut": result.timed_out,
            "log": str(result.log_path),
            "resultBundle": str(result_path),
            "counts": {},
            "tests": [],
            "errors": command_errors + [f"{label}: cannot parse xcresult: {error}"],
        }
    return {
        "label": label,
        "command": shlex.join(command),
        "returncode": result.returncode,
        "timedOut": result.timed_out,
        "log": str(result.log_path),
        "summaryLog": str(summary_result.log_path),
        "testsLog": str(tests_result.log_path),
        "resultBundle": str(result_path),
        "counts": counts,
        "tests": leaves,
        "errors": command_errors + errors,
    }


def _export_container(runner: CommandRunner, run_dir: Path, simulator: dict, label: str) -> Path:
    result = runner.run(
        ["xcrun", "simctl", "get_app_container", simulator["udid"], BUNDLE_ID, "data"],
        f"{label}-container",
        SHORT_TIMEOUT,
        capture=True,
    )
    require(result.returncode == 0, f"{label}: cannot locate app data container; see {result.log_path}")
    container = Path(result.stdout.strip())
    require(container.is_dir(), f"{label}: app data container {container} is missing")
    source = container / "Library" / "Application Support" / "QuietControlUITests"
    require(source.is_dir(), f"{label}: no QuietControlUITests evidence in the app container")
    destination = run_dir / "artifacts" / label
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / "ApplicationSupport" / "QuietControlUITests"
    if target.exists():
        shutil.rmtree(target)
    shutil.copytree(source, target)
    return destination


def container_run_names(runner: CommandRunner, simulator: dict, label: str) -> set[str]:
    result = runner.run(
        ["xcrun", "simctl", "get_app_container", simulator["udid"], BUNDLE_ID, "data"],
        f"{label}-container-before",
        SHORT_TIMEOUT,
        capture=True,
    )
    if result.returncode != 0:
        return set()
    base = Path(result.stdout.strip()) / "Library" / "Application Support" / "QuietControlUITests"
    if not base.is_dir():
        return set()
    return {path.name for path in base.iterdir() if path.is_dir()}


def run_core_lane(runner: CommandRunner, run_dir: Path) -> dict:
    result = runner.run([str(ROOT / "scripts" / "test.sh")], "core-tests", BUILD_TIMEOUT)
    text = result.log_path.read_text(encoding="utf-8", errors="replace")
    executed = [int(value) for value in re.findall(r"Executed (\d+) tests?, with", text)]
    failures = [int(value) for value in re.findall(r"Executed \d+ tests?, with (\d+) failures?", text)]
    skipped = re.findall(r"\b(\d+) skipped\b|\bTest Case .* skipped\b", text)
    errors: list[str] = []
    if result.returncode != 0:
        errors.append(f"core tests failed with exit {result.returncode}; see {result.log_path}")
    if not executed:
        errors.append("core test output contained no 'Executed N tests' summary")
    elif max(executed) == 0:
        errors.append("core test output reported zero executed tests")
    if failures and any(value != 0 for value in failures):
        errors.append(f"core test output reported failures {failures}")
    if skipped:
        errors.append("core test output reported skipped tests")
    executed_count = max(executed) if executed else 0
    failed_count = max(failures) if failures else 0
    return {
        "label": "core",
        "command": shlex.join(result.command),
        "returncode": result.returncode,
        "log": str(result.log_path),
        "counts": {
            "expected": executed_count,
            "total": executed_count,
            "passed": executed_count if failed_count == 0 else executed_count - failed_count,
            "failed": failed_count,
            "skipped": 0 if not skipped else None,
        },
        "tests": [],
        "errors": errors,
    }


def run_session_lane(
    runner: CommandRunner,
    run_dir: Path,
    simulator: dict,
    xctestrun: Path,
    manifest,
) -> list[dict]:
    entries = manifest["session"]["tests"]
    test_ids = [entry["id"] for entry in entries]
    before = container_run_names(runner, simulator, "session")
    lane = _run_xcode_tests(runner, run_dir, simulator, xctestrun, "session", test_ids)
    try:
        export = _export_container(runner, run_dir, simulator, "session")
    except VerifyError as error:
        lane["errors"].append(str(error))
        return [lane]
    new_runs = exported_run_names(export) - before
    lane["artifacts"] = str(export)
    lane["runDirectories"] = sorted(new_runs)
    for entry in entries:
        lane["errors"].extend(inspect_entry_artifacts(entry, export, manifest["synthetic"], new_runs))
    return [lane]


def run_ui_lane(
    runner: CommandRunner,
    run_dir: Path,
    simulator: dict,
    xctestrun: Path,
    manifest,
    journeys: list[dict],
) -> list[dict]:
    lanes = []
    for journey in journeys:
        label = f"ui-{journey['name']}"
        before = container_run_names(runner, simulator, label)
        lane = _run_xcode_tests(runner, run_dir, simulator, xctestrun, label, [journey["id"]])
        try:
            export = _export_container(runner, run_dir, simulator, label)
        except VerifyError as error:
            lane["errors"].append(str(error))
        else:
            new_runs = exported_run_names(export) - before
            lane["artifacts"] = str(export)
            lane["runDirectories"] = sorted(new_runs)
            lane["errors"].extend(
                inspect_entry_artifacts(journey, export, manifest["synthetic"], new_runs)
            )
        lanes.append(lane)
    return lanes


def run_release_check(runner: CommandRunner, run_dir: Path) -> dict:
    derived_data = run_dir / "ReleaseDerivedData"
    command = [
        "xcodebuild",
        "-project",
        "QuietControl.xcodeproj",
        "-scheme",
        "QuietControl",
        "-configuration",
        "Release",
        "-sdk",
        "iphoneos",
        "-destination",
        "generic/platform=iOS",
        "-derivedDataPath",
        str(derived_data),
        "CODE_SIGNING_ALLOWED=NO",
        "build",
    ]
    result = runner.run(command, "release-device-build", RELEASE_TIMEOUT)
    app = derived_data / "Build" / "Products" / "Release-iphoneos" / "QuietControl.app"
    binary = app / "QuietControl"
    errors: list[str] = []
    checks: list[dict] = []
    if result.returncode != 0:
        errors.append(f"unsigned Release device build failed; see {result.log_path}")
    if not binary.is_file():
        errors.append(f"Release app binary missing at {binary}")
        return {
            "label": "release-device",
            "command": shlex.join(command),
            "returncode": result.returncode,
            "log": str(result.log_path),
            "errors": errors,
            "checks": checks,
        }

    banned = [
        "QCTestHarness",
        "QCSimulatorPeripheral",
        "QCTestEvidence",
        "QCTestScenario",
        "QCSimulatedPeripheralState",
        "--quietcontrol-ui-testing",
        "quietcontrol.ui-tests.",
    ]
    symbol_result = runner.run(["nm", "-a", str(binary)], "release-symbols", SHORT_TIMEOUT, capture=True)
    strings_result = runner.run(["strings", "-a", str(binary)], "release-strings", SHORT_TIMEOUT, capture=True)
    if symbol_result.returncode != 0:
        errors.append(f"cannot inspect Release symbols; see {symbol_result.log_path}")
    if strings_result.returncode != 0:
        errors.append(f"cannot inspect Release strings; see {strings_result.log_path}")
    haystack = (symbol_result.stdout or "") + "\n" + (strings_result.stdout or "")
    leaked = [name for name in banned if name in haystack]
    if leaked:
        errors.append(f"Release/device binary contains simulator test fixtures: {leaked}")
    checks.append(
        {
            "name": "release-test-fixture-exclusion",
            "status": "PASS" if not leaked else "FAIL",
            "detail": "no simulator fixture symbols or strings in the unsigned Release device binary"
            if not leaked
            else f"leaked {leaked}",
        }
    )

    plugins = app / "PlugIns"
    test_bundles = sorted(str(path) for path in app.rglob("*.xctest")) if app.is_dir() else []
    if plugins.exists() or test_bundles:
        errors.append(f"Release app contains test bundles: {test_bundles or plugins}")
    checks.append(
        {
            "name": "release-no-test-bundles",
            "status": "PASS" if not (plugins.exists() or test_bundles) else "FAIL",
            "detail": "no .xctest bundles embedded in the Release app",
        }
    )
    return {
        "label": "release-device",
        "command": shlex.join(command),
        "returncode": result.returncode,
        "log": str(result.log_path),
        "app": str(app),
        "binary": str(binary),
        "errors": errors,
        "checks": checks,
    }


# ---------------------------------------------------------------------------
# Reporting
# ---------------------------------------------------------------------------


def write_summary(run_dir: Path, summary: dict) -> Path:
    summary_path = run_dir / "summary.json"
    summary_path.write_text(json.dumps(summary, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    return summary_path


def print_lane(lane: dict) -> None:
    counts = lane.get("counts") or {}
    detail = ""
    if counts:
        detail = (
            f" expected={counts.get('expected')} executed={counts.get('total')} "
            f"passed={counts.get('passed')} failed={counts.get('failed')} skipped={counts.get('skipped')}"
        )
    if lane["errors"]:
        print(f"FAIL {lane['label']}{detail}")
        for error in lane["errors"]:
            print(f"  - {error}")
    else:
        print(f"PASS {lane['label']}{detail}")


def decide_status(failures: list[str], blocked: list[str]) -> tuple[str, int]:
    if blocked:
        return "BLOCKED", EXIT_BLOCKED
    if failures:
        return "FAIL", EXIT_FAIL
    return "PASS", EXIT_PASS


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="verify.sh",
        description="Run QuietControl native simulator verification with disposable simulators.",
    )
    parser.add_argument("lane", choices=["core", "session", "ui", "preinstall"])
    parser.add_argument(
        "--only",
        action="append",
        default=[],
        metavar="JOURNEY",
        help="UI journey name (repeatable); valid only for the ui lane.",
    )
    return parser


def main(argv=None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)

    try:
        manifest = load_manifest()
        journeys = select_journeys(manifest, args.only, args.lane)
    except UsageError as error:
        print(f"USAGE: {error}", file=sys.stderr)
        return EXIT_USAGE
    except VerifyError as error:
        print(f"FAIL manifest: {error}", file=sys.stderr)
        return EXIT_FAIL

    run_id = make_run_id()
    run_dir = RUN_ROOT / run_id
    runner = CommandRunner(run_dir / "logs")
    started = utc_now()
    summary = {
        "runID": run_id,
        "lane": args.lane,
        "status": "FAIL",
        "startedAt": utc_stamp(started),
        "finishedAt": None,
        "elapsedSeconds": None,
        "runDirectory": str(run_dir),
        "commands": [],
        "source": None,
        "environment": None,
        "selection": {
            "only": args.only,
            "journeys": [journey["name"] for journey in journeys] if args.lane in {"ui", "preinstall"} else [],
            "sessionTests": [entry["id"] for entry in manifest["session"]["tests"]]
            if args.lane in {"session", "preinstall"}
            else [],
            "uiTests": [journey["id"] for journey in journeys] if args.lane in {"ui", "preinstall"} else [],
        },
        "lanes": [],
        "release": None,
        "checks": [],
        "coverage": [],
        "errors": [],
        "simulator": None,
    }
    simulator = None
    interruptions: list[str] = []
    exit_code = EXIT_FAIL

    def handle_signal(signum, _frame):
        raise RunnerInterrupted(signum)

    previous_handlers = {}
    for signum in (signal.SIGINT, signal.SIGTERM):
        previous_handlers[signum] = signal.signal(signum, handle_signal)

    try:
        summary["source"] = fingerprint_source(runner)
        environment = preflight(runner, manifest)
        summary["environment"] = {
            "developerDir": runner.developer_dir,
            "xcodeVersion": environment["xcodeVersion"],
            "xcodeBuild": environment["xcodeBuild"],
            "macOS": environment["macOS"],
            "runtime": environment["runtime"]["name"],
            "runtimeBuild": environment["runtime"].get("buildversion"),
            "deviceType": environment["deviceType"]["name"],
        }
        summary["coverage"] = environment["coverage"]
        for gap in environment["coverage"]:
            print(f"BLOCKED coverage {gap['lane']}: {gap['detail']}")

        simulator = create_simulator(
            runner, environment["runtime"], environment["deviceType"], run_id
        )
        summary["simulator"] = dict(simulator)
        boot_simulator(runner, simulator)

        lanes: list[dict] = []
        if args.lane in {"core", "preinstall"}:
            lanes.append(run_core_lane(runner, run_dir))
            summary["lanes"] = lanes

        if args.lane != "core":
            xctestrun = _build_for_testing(runner, run_dir, simulator)
            enabled, disabled, enumeration_path, enumeration_result = _enumerate_tests(
                runner, run_dir, simulator, xctestrun
            )
            discovery_errors = check_discovered(manifest, enabled, disabled)
            summary["checks"].append(
                {
                    "name": "test-discovery",
                    "status": "PASS" if not discovery_errors else "FAIL",
                    "detail": f"{len(enabled)} executable tests discovered",
                    "enumeration": str(enumeration_path),
                    "resultBundle": str(enumeration_result),
                    "disabled": disabled,
                }
            )
            if discovery_errors:
                lanes.append(
                    {
                        "label": "discovery",
                        "command": "",
                        "counts": {},
                        "tests": [],
                        "errors": discovery_errors,
                    }
                )

            if args.lane in {"session", "preinstall"}:
                lanes.extend(run_session_lane(runner, run_dir, simulator, xctestrun, manifest))
                summary["lanes"] = lanes
            if args.lane in {"ui", "preinstall"}:
                lanes.extend(run_ui_lane(runner, run_dir, simulator, xctestrun, manifest, journeys))
                summary["lanes"] = lanes

            if args.lane == "preinstall":
                release = run_release_check(runner, run_dir)
                summary["release"] = release
                summary["checks"].extend(release.get("checks", []))
                lanes.append(
                    {
                        "label": release["label"],
                        "command": release["command"],
                        "counts": {},
                        "tests": [],
                        "errors": release["errors"],
                        "log": release["log"],
                    }
                )
                summary["lanes"] = lanes

        summary["lanes"] = lanes
        failures = [error for lane in lanes for error in (lane.get("errors") or [])]
        failures.extend(summary["errors"])

        final_source = fingerprint_source(runner)
        if final_source["fingerprint"] != summary["source"]["fingerprint"]:
            failures.append("source changed while verification was running; acceptance is invalid")

        status, exit_code = decide_status(failures, interruptions)
        summary["status"] = status
        summary["errors"] = failures

        for lane in lanes:
            print_lane(lane)
        for lane in summary["lanes"]:
            if lane.get("artifacts"):
                print(f"  evidence {lane['label']}: {lane['artifacts']}")
            if lane.get("resultBundle"):
                print(f"  xcresult {lane['label']}: {lane['resultBundle']}")
        if summary["release"]:
            print(
                f"release binary: {summary['release'].get('binary')}"
                if not summary["release"].get("errors")
                else "release check failed"
            )
    except UsageError as error:
        summary["errors"].append(str(error))
        print(f"USAGE: {error}", file=sys.stderr)
        exit_code = EXIT_USAGE
        summary["status"] = "FAIL"
    except BlockedError as error:
        summary["errors"].append(str(error))
        summary["status"] = "BLOCKED"
        exit_code = EXIT_BLOCKED
        print(f"BLOCKED: {error}", file=sys.stderr)
    except RunnerInterrupted as error:
        summary["errors"].append(str(error))
        summary["status"] = "BLOCKED"
        exit_code = EXIT_INTERRUPTED
        print(f"BLOCKED: {error}", file=sys.stderr)
    except VerifyError as error:
        summary["errors"].append(str(error))
        summary["status"] = "FAIL"
        exit_code = EXIT_FAIL
        print(f"FAIL: {error}", file=sys.stderr)
    except Exception as error:  # unexpected: retain evidence rather than hiding it
        summary["errors"].append(f"unexpected runner error: {error}")
        summary["traceback"] = traceback.format_exc()
        summary["status"] = "FAIL"
        exit_code = EXIT_FAIL
        print(f"FAIL: unexpected runner error: {error}", file=sys.stderr)
    finally:
        cleanup_errors = cleanup_simulator(runner, simulator)
        summary["cleanup"] = {
            "simulator": simulator,
            "errors": cleanup_errors,
        }
        summary["errors"].extend(cleanup_errors)
        if cleanup_errors:
            summary["status"] = "FAIL"
            exit_code = EXIT_FAIL
            for error in cleanup_errors:
                print(f"FAIL cleanup: {error}", file=sys.stderr)
        summary["finishedAt"] = utc_stamp(utc_now())
        summary["elapsedSeconds"] = round((utc_now() - started).total_seconds(), 2)
        summary["commands"] = runner.records
        run_dir.mkdir(parents=True, exist_ok=True)
        (run_dir / "commands.log").write_text(CommandRunner.commands_log(runner.records), encoding="utf-8")
        summary_path = write_summary(run_dir, summary)
        for signum, handler in previous_handlers.items():
            signal.signal(signum, handler)
        print(f"RESULT: {summary['status']}")
        print(f"Run directory: {run_dir}")
        print(f"Summary: {summary_path}")
        if summary["source"] and summary["source"]["dirty"]:
            print(f"Source: {summary['source']['sha']} (dirty; not an accepted clean revision)")
        elif summary["source"]:
            print(f"Source: {summary['source']['sha']}")

    return exit_code


if __name__ == "__main__":
    sys.exit(main())
