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
EVIDENCE_TOKEN_RE = re.compile(r"^(?:(?:outbound|inbound):[0-9A-Fa-f ]+\*?|event:.+)$")
MANIFEST_SCHEMA_VERSION = 2
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

# Schema 2 is the complete preinstall mapping: every executable test names one or
# more required runs and each run carries explicit evidence expectations.
RUN2_KEYS = {
    "prefix",
    "scenario",
    "reset",
    "expect",
    "artifacts",
    "evidence",
    "sharedPrefixGroup",
    "sharedMatchToken",
    "expectedRuns",
}
EXPECT2_KEYS = {"files", "snapshot", "peripheral", "journal", "defaults", "transcript", "lifecycle"}
FILES_KEYS = {"require", "forbid"}
SNAPSHOT2_KEYS = {"state", "lastMode", "eq", "modes", "focusAncStrength", "focusWindBlock", "literal", "firmware"}
PERIPHERAL2_KEYS = {
    "connected",
    "mode",
    "eq",
    "multipoint",
    "firmware",
    "activeAudio",
    "preferences",
}
JOURNAL2_KEYS = {"state", "literal", "fields", "peripheralNotSynthetic"}
DEFAULTS_KEYS = {"preset"}
PRESET_KEYS = {"name", "values"}
TRANSCRIPT2_KEYS = {
    "scenarios",
    "order",
    "required",
    "forbidden",
    "noOutboundScenarios",
    "forbiddenMessages",
    "counts",
    "noOutboundBetween",
    "requireEvents",
    "forbidEvents",
    "segmentHeaders",
    "segmentHeadersAfter",
}
COUNT_KEYS = {"token", "equals", "atLeast", "atMost", "after"}
BETWEEN_KEYS = {"start", "end", "prefix"}
LIFECYCLE_KEYS = {"rxPrefix", "beforeEvent", "afterEvent", "expectedBefore", "expectedAfter", "expectedTotal"}
ATTACHMENT_KEYS = {"audits", "geometry", "invalidConfiguration", "journeyRunIDs"}
AUDIT_KEYS = {"contexts", "screenshots"}

SNAPSHOT_FILE_KEYS = {
    "version",
    "peripheralID",
    "manufacturer",
    "model",
    "firmware",
    "modes",
    "eq",
    "lastMode",
    "lastSeen",
    "battery",
    "multipoint",
    "devices",
    "controllerAddress",
}
PERIPHERAL_FILE_KEYS = {
    "scenario",
    "runID",
    "connected",
    "mode",
    "eq",
    "multipoint",
    "devices",
    "updatedAt",
    "firmware",
    "activeAudio",
    "preferences",
}
CONFIG_FILE_KEYS = {"scenario", "runID", "reset", "peripheral", "defaultsSuite"}


def _check_keys(mapping, allowed, where: str) -> None:
    require(isinstance(mapping, dict), f"{where}: expected an object")
    unknown = set(mapping) - allowed
    require(not unknown, f"{where}: unsupported keys {sorted(unknown)}")


def _require_bool(value, where: str) -> None:
    require(isinstance(value, bool), f"{where} must be a boolean")


def _require_int(value, where: str) -> None:
    require(isinstance(value, int) and not isinstance(value, bool), f"{where} must be an integer")


def _require_string(value, where: str, *, nonempty: bool = True) -> None:
    require(isinstance(value, str) and (bool(value) or not nonempty), f"{where} must be a string")


def _require_int_triplet(value, where: str) -> None:
    require(
        isinstance(value, list)
        and len(value) == 3
        and all(isinstance(item, int) and not isinstance(item, bool) for item in value),
        f"{where} must be exactly three integers",
    )


def validate_manifest(manifest) -> None:
    _check_keys(
        manifest,
        {"schemaVersion", "description", "synthetic", "simulator", "session", "journeys"},
        "manifest",
    )
    version = manifest.get("schemaVersion")
    require(
        version in (1, MANIFEST_SCHEMA_VERSION),
        f"manifest: unsupported schemaVersion {version!r}; expected 1 or {MANIFEST_SCHEMA_VERSION}",
    )

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
        if version == 1:
            _validate_entry(entry, f"manifest.session.tests[{index}]", seen_ids)
            require("label" in entry, f"{entry['id']}: session entries need a label")
        else:
            _validate_entry_v2(entry, f"manifest.session.tests[{index}]", seen_ids, "session")
        require(entry["id"].startswith(session["target"] + "/"), f"{entry['id']}: not in target {session['target']}")

    journeys = manifest.get("journeys")
    require(isinstance(journeys, list) and journeys, "manifest journeys required")
    names: set[str] = set()
    for index, entry in enumerate(journeys):
        if version == 1:
            _validate_entry(entry, f"manifest.journeys[{index}]", seen_ids)
        else:
            _validate_entry_v2(entry, f"manifest.journeys[{index}]", seen_ids, "ui")
        require(isinstance(entry.get("name"), str) and entry["name"], "journey name required")
        require(entry["name"] not in names, f"duplicate journey name {entry['name']!r}")
        names.add(entry["name"])

    if version == MANIFEST_SCHEMA_VERSION:
        _validate_prefix_groups(manifest["session"]["tests"], "session")
        _validate_prefix_groups(manifest["journeys"], "ui")


def _validate_prefix_groups(entries: list[dict], lane: str) -> None:
    """Reject ambiguous or reused prefixes except an explicit shared group."""
    seen: dict[str, dict] = {}
    for entry in entries:
        for run in entry["runs"]:
            if run.get("artifacts") is False or run.get("evidence") == "invalid-configuration":
                continue
            prefix = run["prefix"]
            group = run.get("sharedPrefixGroup")
            if group:
                continue
            require(
                prefix not in seen,
                f"{lane}: prefix {prefix!r} is used by more than one test; use sharedPrefixGroup only when the test source makes the runs indistinguishable",
            )
            seen[prefix] = entry
    groups: dict[str, list[dict]] = {}
    for entry in entries:
        for run in entry["runs"]:
            group = run.get("sharedPrefixGroup")
            if not group:
                continue
            require(
                isinstance(group, str) and group,
                f"{entry['id']}: sharedPrefixGroup must be a nonempty string",
            )
            groups.setdefault(group, []).append(run)
    for group, runs in groups.items():
        require(len(runs) >= 2, f"{lane}: sharedPrefixGroup {group!r} must cover at least two tests")
        prefix = runs[0]["prefix"]
        require(all(run["prefix"] == prefix for run in runs), f"{lane}: sharedPrefixGroup {group!r} mixes prefixes")
        require(
            all(run.get("expectedRuns", 1) == 1 for run in runs),
            f"{lane}: sharedPrefixGroup {group!r} must expect one run per test",
        )
        tokens = [run.get("sharedMatchToken") for run in runs]
        require(
            all(isinstance(token, str) and PACKET_TOKEN_RE.fullmatch(token) for token in tokens),
            f"{lane}: sharedPrefixGroup {group!r} needs one unique packet token per test",
        )
        require(len(set(tokens)) == len(tokens), f"{lane}: sharedPrefixGroup {group!r} reuses a match token")
        shapes = {json.dumps({"scenario": run["scenario"], "reset": run["reset"]}, sort_keys=True) for run in runs}
        require(len(shapes) == 1, f"{lane}: sharedPrefixGroup {group!r} has divergent scenario or reset")


def _validate_entry_v2(entry, where: str, seen_ids: set[str], lane: str) -> None:
    _check_keys(entry, {"id", "label", "name", "runs", "attachments"}, where)
    identifier = entry.get("id")
    require(isinstance(identifier, str) and identifier, f"{where}: test id required")
    require(TEST_ID_RE.fullmatch(identifier), f"{where}: invalid test id {identifier!r}")
    require(identifier not in seen_ids, f"{where}: duplicate test id {identifier!r}")
    seen_ids.add(identifier)
    require(isinstance(entry.get("label"), str) and entry["label"], f"{where}: label required")
    runs = entry.get("runs")
    require(isinstance(runs, list) and runs, f"{where}.runs must be a nonempty list")
    for index, run in enumerate(runs):
        _validate_run_v2(identifier, run, f"{where}.runs[{index}]", lane)
    if "attachments" in entry:
        _validate_attachments(entry["attachments"], f"{where}.attachments")


def _validate_run_v2(identifier: str, run, where: str, lane: str) -> None:
    _check_keys(run, RUN2_KEYS, where)
    require(isinstance(run.get("prefix"), str) and run["prefix"], f"{where}: prefix required")
    require(re.fullmatch(r"[A-Za-z0-9-]+", run["prefix"]) is not None, f"{where}: invalid prefix {run['prefix']!r}")
    if run.get("artifacts") is False:
        require(identifier in NO_ARTIFACT_TESTS, f"{where}: no-artifact exemption is not allowed for {identifier}")
        require(set(run) == {"prefix", "artifacts"}, f"{where}: no-artifact runs cannot carry other fields")
        return
    if run.get("evidence") == "invalid-configuration":
        require(
            identifier
            == "QuietControlUITests/QuietControlUITests/testInvalidTestConfigurationFailsWithoutRadioFallback()"
            and lane == "ui"
            and run["prefix"] == "invalid-",
            f"{where}: invalid-configuration evidence is narrowly reserved for the invalid-config UI test",
        )
        require(run.get("expectedRuns", 1) == 0, f"{where}: invalid-configuration expects no harness run directory")
        require(set(run) <= {"prefix", "evidence", "expectedRuns"}, f"{where}: invalid-configuration fields")
        return
    require("scenario" in run and isinstance(run["scenario"], str) and run["scenario"], f"{where}: scenario required")
    _require_bool(run.get("reset"), f"{where}.reset")
    expect = run.get("expect")
    require(isinstance(expect, dict), f"{where}: expect required")
    _check_keys(expect, EXPECT2_KEYS, f"{where}.expect")
    if "files" in expect:
        _check_keys(expect["files"], FILES_KEYS, f"{where}.expect.files")
        for key in ("require", "forbid"):
            values = expect["files"].get(key, [])
            require(isinstance(values, list), f"{where}.expect.files.{key} must be a list")
            for name in values:
                require(
                    isinstance(name, str) and re.fullmatch(r"[A-Za-z0-9_.-]+", name),
                    f"{where}: invalid file name {name!r}",
                )
    if "snapshot" in expect:
        snapshot = expect["snapshot"]
        _check_keys(snapshot, SNAPSHOT2_KEYS, f"{where}.expect.snapshot")
        state = snapshot.get("state")
        require(state in {"present", "absent", "corrupt"}, f"{where}: snapshot.state invalid")
        if state == "present":
            require(set(snapshot) <= {"state", "lastMode", "eq", "modes", "focusAncStrength", "focusWindBlock", "firmware"},
                    f"{where}: unexpected present-snapshot fields")
            _require_int(snapshot.get("lastMode"), f"{where}.expect.snapshot.lastMode")
            _require_int_triplet(snapshot.get("eq"), f"{where}.expect.snapshot.eq")
            if "modes" in snapshot:
                modes = snapshot["modes"]
                require(
                    isinstance(modes, list) and modes and all(isinstance(m, int) and not isinstance(m, bool) for m in modes),
                    f"{where}.expect.snapshot.modes must be a list of integers",
                )
            if "focusAncStrength" in snapshot:
                _require_int(snapshot["focusAncStrength"], f"{where}.expect.snapshot.focusAncStrength")
            if "focusWindBlock" in snapshot:
                _require_bool(snapshot["focusWindBlock"], f"{where}.expect.snapshot.focusWindBlock")
            if "firmware" in snapshot:
                _require_string(snapshot["firmware"], f"{where}.expect.snapshot.firmware")
        elif state == "corrupt":
            require(set(snapshot) == {"state", "literal"}, f"{where}: corrupt snapshot needs only state and literal")
            _require_string(snapshot.get("literal"), f"{where}.expect.snapshot.literal", nonempty=False)
        else:
            require(set(snapshot) == {"state"}, f"{where}: absent snapshot takes no other fields")
    if "peripheral" in expect:
        peripheral = expect["peripheral"]
        _check_keys(peripheral, PERIPHERAL2_KEYS, f"{where}.expect.peripheral")
        require(bool(peripheral), f"{where}: peripheral expectation must not be empty")
        if "connected" in peripheral:
            _require_bool(peripheral["connected"], f"{where}.expect.peripheral.connected")
        if "mode" in peripheral:
            _require_int(peripheral["mode"], f"{where}.expect.peripheral.mode")
        if "eq" in peripheral:
            _require_int_triplet(peripheral["eq"], f"{where}.expect.peripheral.eq")
        if "multipoint" in peripheral:
            _require_bool(peripheral["multipoint"], f"{where}.expect.peripheral.multipoint")
        for key in ("firmware", "activeAudio"):
            if key in peripheral:
                _require_string(peripheral[key], f"{where}.expect.peripheral.{key}")
        if "preferences" in peripheral:
            preferences = peripheral["preferences"]
            require(isinstance(preferences, dict) and preferences, f"{where}: preferences must be a nonempty object")
            for key, value in preferences.items():
                _require_string(key, f"{where}: preference name")
                require(
                    isinstance(value, str) and re.fullmatch(r"[0-9a-fA-F ]+", value),
                    f"{where}: preference {key} must be a hex payload string",
                )
    if "journal" in expect:
        journal = expect["journal"]
        _check_keys(journal, JOURNAL2_KEYS, f"{where}.expect.journal")
        require(journal.get("state") in {"present", "absent"}, f"{where}: journal.state invalid")
        if journal["state"] == "present":
            allowed = {"state", "literal", "fields", "peripheralNotSynthetic"}
            require(set(journal) <= allowed, f"{where}: unsupported retained-journal fields")
            require(
                "literal" in journal or "fields" in journal,
                f"{where}: retained journal needs exact literal bytes or exact fields",
            )
            if "literal" in journal:
                _require_string(journal["literal"], f"{where}.expect.journal.literal", nonempty=False)
                parsed = parse_json_text(journal["literal"], f"{where}.expect.journal.literal")
                _check_keys(parsed, {"peripheral", "firmware", "name", "payload"}, f"{where}.expect.journal.literal")
            if "fields" in journal:
                _check_keys(
                    journal["fields"],
                    {"peripheral", "firmware", "name", "payload"},
                    f"{where}.expect.journal.fields",
                )
                for key, value in journal["fields"].items():
                    _require_string(value, f"{where}.expect.journal.fields.{key}")
            if "peripheralNotSynthetic" in journal:
                _require_bool(journal["peripheralNotSynthetic"], f"{where}.expect.journal.peripheralNotSynthetic")
                require(journal["peripheralNotSynthetic"], f"{where}: peripheralNotSynthetic cannot be false")
        else:
            require(set(journal) == {"state"}, f"{where}: absent journal takes no other fields")
    if "defaults" in expect:
        _check_keys(expect["defaults"], DEFAULTS_KEYS, f"{where}.expect.defaults")
        preset = expect["defaults"].get("preset")
        _check_keys(preset, PRESET_KEYS, f"{where}.expect.defaults.preset")
        _require_string(preset.get("name"), f"{where}.expect.defaults.preset.name")
        _require_int_triplet(preset.get("values"), f"{where}.expect.defaults.preset.values")
    if "transcript" in expect:
        _validate_transcript_v2(expect["transcript"], f"{where}.expect.transcript")
    if "lifecycle" in expect:
        lifecycle = expect["lifecycle"]
        _check_keys(lifecycle, LIFECYCLE_KEYS, f"{where}.expect.lifecycle")
        _require_string(lifecycle.get("rxPrefix"), f"{where}.expect.lifecycle.rxPrefix")
        if "expectedTotal" in lifecycle:
            _require_int(lifecycle["expectedTotal"], f"{where}.expect.lifecycle.expectedTotal")
            require(set(lifecycle) == {"rxPrefix", "expectedTotal"}, f"{where}: expectedTotal stands alone")
        else:
            _require_string(lifecycle.get("beforeEvent"), f"{where}.expect.lifecycle.beforeEvent")
            _require_string(lifecycle.get("afterEvent"), f"{where}.expect.lifecycle.afterEvent")
            _require_int(lifecycle.get("expectedBefore"), f"{where}.expect.lifecycle.expectedBefore")
            _require_int(lifecycle.get("expectedAfter"), f"{where}.expect.lifecycle.expectedAfter")
            require(
                lifecycle["expectedAfter"] > lifecycle["expectedBefore"],
                f"{where}: lifecycle RX must increase after the release",
            )


def _validate_transcript_v2(transcript, where: str) -> None:
    _check_keys(transcript, TRANSCRIPT2_KEYS, where)
    scenarios = transcript.get("scenarios")
    require(isinstance(scenarios, list) and scenarios, f"{where}.scenarios required")
    require(all(isinstance(value, str) and value for value in scenarios), f"{where}: invalid scenario")
    for key in ("order", "required", "forbidden"):
        tokens = transcript.get(key, [])
        require(isinstance(tokens, list), f"{where}.{key} must be a list")
        for token in tokens:
            require(
                isinstance(token, str) and EVIDENCE_TOKEN_RE.fullmatch(token),
                f"{where}: invalid {key} token {token!r}",
            )
    no_outbound = transcript.get("noOutboundScenarios", [])
    require(isinstance(no_outbound, list), f"{where}.noOutboundScenarios must be a list")
    messages = transcript.get("forbiddenMessages", [])
    require(isinstance(messages, list) and all(isinstance(m, str) for m in messages), f"{where}: forbiddenMessages")
    counts = transcript.get("counts", [])
    require(isinstance(counts, list), f"{where}.counts must be a list")
    for index, count in enumerate(counts):
        _check_keys(count, COUNT_KEYS, f"{where}.counts[{index}]")
        require(
            isinstance(count.get("token"), str) and EVIDENCE_TOKEN_RE.fullmatch(count["token"]),
            f"{where}.counts[{index}]: invalid token",
        )
        bounds = [key for key in ("equals", "atLeast", "atMost") if key in count]
        require(bool(bounds), f"{where}.counts[{index}]: need equals/atLeast/atMost")
        for key in bounds:
            _require_int(count[key], f"{where}.counts[{index}].{key}")
            require(count[key] >= 0, f"{where}.counts[{index}].{key} must be nonnegative")
        if "equals" in count:
            require(bounds == ["equals"], f"{where}.counts[{index}]: equals cannot be combined with bounds")
        if "after" in count:
            require(
                isinstance(count["after"], str) and EVIDENCE_TOKEN_RE.fullmatch(count["after"]),
                f"{where}.counts[{index}].after: invalid anchor",
            )
    between = transcript.get("noOutboundBetween", [])
    require(isinstance(between, list), f"{where}.noOutboundBetween must be a list")
    for index, rule in enumerate(between):
        _check_keys(rule, BETWEEN_KEYS, f"{where}.noOutboundBetween[{index}]")
        for key in ("start", "end"):
            require(
                isinstance(rule.get(key), str) and EVIDENCE_TOKEN_RE.fullmatch(rule[key]),
                f"{where}.noOutboundBetween[{index}].{key}: invalid token",
            )
        if "prefix" in rule:
            require(
                isinstance(rule["prefix"], str) and re.fullmatch(r"[0-9a-fA-F]+", rule["prefix"]),
                f"{where}.noOutboundBetween[{index}].prefix must be hex",
            )
    for key in ("requireEvents", "forbidEvents"):
        events = transcript.get(key, [])
        require(
            isinstance(events, list) and all(isinstance(value, str) and value for value in events),
            f"{where}.{key} must be a list of strings",
        )
    headers = transcript.get("segmentHeaders", [])
    require(isinstance(headers, list), f"{where}.segmentHeaders must be a list")
    for header in headers:
        require(
            isinstance(header, str) and re.fullmatch(r"[0-9a-fA-F]{2}", header),
            f"{where}: invalid segment header {header!r}",
        )
    if "segmentHeadersAfter" in transcript:
        _require_string(transcript["segmentHeadersAfter"], f"{where}.segmentHeadersAfter")


def _validate_attachments(attachments, where: str) -> None:
    _check_keys(attachments, ATTACHMENT_KEYS, where)
    require(bool(attachments), f"{where}: empty attachment expectations")
    if "audits" in attachments:
        audits = attachments["audits"]
        _check_keys(audits, AUDIT_KEYS, f"{where}.audits")
        for key in ("contexts", "screenshots"):
            values = audits.get(key)
            require(
                isinstance(values, list) and values and all(isinstance(v, str) and v for v in values),
                f"{where}.audits.{key} must be a nonempty string list",
            )
        require(
            len(set(audits["contexts"])) == len(audits["contexts"]),
            f"{where}.audits.contexts must be unique",
        )
        require(
            len(set(audits["screenshots"])) == len(audits["screenshots"]),
            f"{where}.audits.screenshots must be unique",
        )
        require(
            len(audits["contexts"]) == 12,
            f"{where}.audits.contexts must name exactly the twelve audited contexts",
        )
    if "geometry" in attachments:
        _require_bool(attachments["geometry"], f"{where}.geometry")
        require(attachments["geometry"], f"{where}.geometry cannot be disabled")
    if "invalidConfiguration" in attachments:
        _require_bool(attachments["invalidConfiguration"], f"{where}.invalidConfiguration")
        require(attachments["invalidConfiguration"], f"{where}.invalidConfiguration cannot be disabled")
    if "journeyRunIDs" in attachments:
        _require_int(attachments["journeyRunIDs"], f"{where}.journeyRunIDs")
        require(attachments["journeyRunIDs"] >= 0, f"{where}.journeyRunIDs must be nonnegative")


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


def _read_exact_bytes(path: Path, source: str) -> bytes:
    try:
        return path.read_bytes()
    except OSError as error:
        raise VerifyError(f"{source}: cannot read {path}: {error}") from error


def _check_snapshot_v2(path: Path, expected: dict, synthetic: dict) -> list[str]:
    state = expected["state"]
    if state == "absent":
        return [f"{path.name}: intentionally absent snapshot is present"] if path.exists() else []
    if state == "corrupt":
        if not path.is_file():
            return [f"{path.name}: required corrupt snapshot is missing"]
        try:
            actual = _read_exact_bytes(path, path.name)
        except VerifyError as error:
            return [str(error)]
        if actual != expected["literal"].encode("utf-8"):
            return [f"{path.name}: corrupt evidence bytes do not match the exact seeded literal"]
        try:
            load_json_file(path)
        except VerifyError:
            return []
        return [f"{path.name}: corrupt evidence unexpectedly parses as a valid snapshot"]

    if not path.is_file():
        return [f"{path.name}: missing confirmed snapshot"]
    identity = dict(synthetic)
    if "firmware" in expected:
        identity["firmware"] = expected["firmware"]
    errors = _check_snapshot(path, {"lastMode": expected["lastMode"], "eq": expected["eq"]}, identity)
    try:
        snapshot = load_json_file(path)
    except VerifyError:
        return errors
    if not isinstance(snapshot, dict):
        return errors
    unknown = set(snapshot) - SNAPSHOT_FILE_KEYS
    if unknown:
        errors.append(f"{path.name}: unsupported snapshot fields {sorted(unknown)}")
    if "modes" in expected:
        actual = snapshot.get("modes")
        indexes = None
        if isinstance(actual, list):
            indexes = [mode.get("index") for mode in actual if isinstance(mode, dict)]
        if indexes != expected["modes"]:
            errors.append(f"{path.name}: modes {indexes!r} != expected {expected['modes']!r}")
    focus = None
    modes = snapshot.get("modes")
    if isinstance(modes, list):
        focus = next((mode for mode in modes if isinstance(mode, dict) and mode.get("index") == 2), None)
    if "focusAncStrength" in expected:
        # The confirmed mode stores the inverted CNC scale; user-facing strength
        # is 10 - rawCNC (7 strength is persisted as rawCNC 3).
        raw = focus.get("rawCNC") if isinstance(focus, dict) else None
        value = (10 - raw) if isinstance(raw, int) and not isinstance(raw, bool) else None
        if value != expected["focusAncStrength"]:
            errors.append(f"{path.name}: Focus strength {value!r} != expected {expected['focusAncStrength']!r}")
    if "focusWindBlock" in expected:
        value = focus.get("windBlock") if isinstance(focus, dict) else None
        if value != expected["focusWindBlock"]:
            errors.append(f"{path.name}: Focus windBlock {value!r} != expected {expected['focusWindBlock']!r}")
    return errors


def _check_peripheral_v2(path: Path, expected: dict, synthetic: dict, run_id: str) -> list[str]:
    if not path.is_file():
        return [f"{path.name}: missing peripheral state"]
    try:
        state = load_json_file(path)
    except VerifyError as error:
        return [str(error)]
    if not isinstance(state, dict):
        return [f"{path.name}: expected an object"]
    errors: list[str] = []
    unknown = set(state) - PERIPHERAL_FILE_KEYS
    if unknown:
        errors.append(f"{path.name}: unsupported fields {sorted(unknown)}")
    missing = {"scenario", "runID", "connected", "mode", "eq", "devices", "updatedAt"} - set(state)
    if missing:
        return [f"{path.name}: missing fields {sorted(missing)}"]
    if state["runID"] != run_id:
        errors.append(f"{path.name}: runID {state['runID']!r} != {run_id!r}")
    if state["scenario"] != expected.get("_scenario", state["scenario"]):
        errors.append(f"{path.name}: scenario {state['scenario']!r} != expected {expected.get('_scenario')!r}")
    for key in ("connected", "mode", "eq", "multipoint", "firmware", "activeAudio"):
        if key in expected and state.get(key) != expected[key]:
            errors.append(f"{path.name}: {key} {state.get(key)!r} != expected {expected[key]!r}")
    if "devices" in state:
        if not isinstance(state["devices"], list):
            errors.append(f"{path.name}: devices must be a list")
        else:
            actual = [
                {
                    "address": normalize_packet(device.get("address", "")),
                    "name": device.get("name"),
                    "connected": device.get("connected"),
                }
                for device in state["devices"]
                if isinstance(device, dict)
            ]
            if actual != [
                {"address": normalize_packet(d["address"]), "name": d["name"], "connected": d["connected"]}
                for d in synthetic["devices"]
            ]:
                errors.append(f"{path.name}: paired devices {actual!r} do not match the synthetic devices")
    if "preferences" in expected:
        preferences = state.get("preferences")
        if not isinstance(preferences, dict):
            errors.append(f"{path.name}: preferences must be an object")
        else:
            for key, value in expected["preferences"].items():
                if preferences.get(key) != value:
                    errors.append(f"{path.name}: preference {key} {preferences.get(key)!r} != {value!r}")
    try:
        iso8601(state["updatedAt"], f"{path.name}.updatedAt")
    except VerifyError as error:
        errors.append(str(error))
    return errors


def _check_journal(path: Path, expected: dict, synthetic: dict) -> list[str]:
    state = expected["state"]
    if state == "absent":
        return [] if not path.exists() else [f"{path.name}: recovery journal unexpectedly retained"]
    if not path.is_file():
        return [f"{path.name}: required retained recovery journal is missing"]
    try:
        actual = _read_exact_bytes(path, path.name)
    except VerifyError as error:
        return [str(error)]
    if "literal" in expected:
        if actual != expected["literal"].encode("utf-8"):
            return [f"{path.name}: retained journal bytes differ from the exact seeded checkpoint"]
        return []
    try:
        parsed = parse_json_text(actual.decode("utf-8"), path.name)
    except (UnicodeDecodeError, VerifyError) as error:
        return [f"{path.name}: invalid retained journal: {error}"]
    if not isinstance(parsed, dict):
        return [f"{path.name}: retained journal must be an object"]
    errors = []
    for key, value in expected.get("fields", {}).items():
        if parsed.get(key) != value:
            errors.append(f"{path.name}: journal {key} {parsed.get(key)!r} != {value!r}")
    if expected.get("peripheralNotSynthetic"):
        if parsed.get("peripheral") == synthetic["peripheralUUID"]:
            errors.append(f"{path.name}: mismatch journal must name a different synthetic peripheral")
    return errors


def _load_plist(path: Path):
    import plistlib

    try:
        with open(path, "rb") as handle:
            return plistlib.load(handle)
    except (OSError, ValueError, plistlib.InvalidFileException) as error:
        raise VerifyError(f"cannot read defaults plist {path}: {error}") from error


def _check_defaults(export_root: Path, suite: str, expected: dict) -> list[str]:
    name = suite + ".plist"
    candidates = [export_root / "Preferences" / name, export_root / "Library" / "Preferences" / name]
    path = next((candidate for candidate in candidates if candidate.is_file()), None)
    if path is None:
        return [f"missing isolated defaults plist {name}"]
    try:
        defaults = _load_plist(path)
    except VerifyError as error:
        return [str(error)]
    if not isinstance(defaults, dict):
        return [f"{name}: expected a dictionary"]
    raw = defaults.get("quietcontrol.eqPresets")
    if not isinstance(raw, bytes):
        return [f"{name}: quietcontrol.eqPresets is not encoded preset data"]
    try:
        preset_text = raw.decode("utf-8")
        presets = parse_json_text(preset_text, f"{name}:quietcontrol.eqPresets")
    except (UnicodeDecodeError, VerifyError) as error:
        return [f"{name}: invalid preset payload: {error}"]
    expected_preset = expected["preset"]
    if not isinstance(presets, list):
        return [f"{name}: presets must be an encoded list"]
    for preset in presets:
        if not isinstance(preset, dict):
            continue
        if preset.get("name") == expected_preset["name"]:
            if preset.get("values") != expected_preset["values"]:
                return [
                    f"{name}: preset {expected_preset['name']!r} values {preset.get('values')!r} "
                    f"!= {expected_preset['values']!r}"
                ]
            return []
    return [f"{name}: preset {expected_preset['name']!r} is not persisted"]


def _check_lifecycle(path: Path, expected: dict) -> list[str]:
    if not path.is_file():
        return [f"{path.name}: missing lifecycle diagnostics"]
    try:
        text = path.read_text(encoding="utf-8")
    except OSError as error:
        return [f"{path.name}: cannot read: {error}"]
    messages: list[str] = []
    for index, line in enumerate(text.splitlines(), 1):
        if not line.strip():
            return [f"{path.name}:{index}: blank lifecycle line"]
        try:
            record = parse_json_text(line, f"{path.name}:{index}")
        except VerifyError as error:
            return [str(error)]
        if not isinstance(record, dict) or not isinstance(record.get("message"), str):
            return [f"{path.name}:{index}: lifecycle record needs a message"]
        messages.append(record["message"])
    prefix = normalize_packet(expected["rxPrefix"]).lower()
    def rx_count(items: list[str]) -> int:
        total = 0
        for message in items:
            if not message.startswith("RX "):
                continue
            if normalize_packet(message[3:]).lower().startswith(prefix):
                total += 1
        return total
    if "expectedTotal" in expected:
        total = rx_count(messages)
        if total != expected["expectedTotal"]:
            return [f"{path.name}: production RX {prefix} occurs {total} times, expected {expected['expectedTotal']}"]
        return []
    before_index = next((i for i, m in enumerate(messages) if expected["beforeEvent"] in m), None)
    after_index = next((i for i, m in enumerate(messages) if expected["afterEvent"] in m), None)
    if before_index is None:
        return [f"{path.name}: lifecycle event {expected['beforeEvent']!r} is missing"]
    if after_index is None:
        return [f"{path.name}: lifecycle event {expected['afterEvent']!r} is missing"]
    before = rx_count(messages[: before_index + 1])
    after = rx_count(messages[: after_index + 1])
    errors = []
    if before != expected["expectedBefore"]:
        errors.append(f"{path.name}: production RX {prefix} before release is {before}, expected {expected['expectedBefore']}")
    if after != expected["expectedAfter"]:
        errors.append(f"{path.name}: production RX {prefix} after release is {after}, expected {expected['expectedAfter']}")
    return errors


def _check_transcript_v2(path: Path, expect: dict, synthetic: dict) -> list[str]:
    if not path.is_file():
        return [f"{path.name}: missing transport transcript"]
    errors = _check_transcript(path, {"scenarios": expect["scenarios"]}, synthetic)
    try:
        rows = _transcript_rows(path)
    except VerifyError:
        return errors
    for index, row in enumerate(rows, 1):
        unknown = set(row) - {
            "sequence",
            "timestamp",
            "direction",
            "kind",
            "bytes",
            "scenario",
            "peripheral",
            "connection",
            "message",
        }
        if unknown:
            errors.append(f"{path.name}:{index}: unsupported transcript fields {sorted(unknown)}")

    def matches(row, token: str) -> bool:
        if token.startswith("event:"):
            return row.get("kind") == "event" and token[6:] in (row.get("message") or "")
        direction, packet = token.split(":", 1)
        actual = normalize_packet(row.get("bytes", ""))
        if packet.endswith("*"):
            matched = actual.startswith(normalize_packet(packet[:-1]))
        else:
            matched = actual == normalize_packet(packet)
        return row.get("direction") == direction and row.get("kind") in {"bmap", "segment"} and matched

    position = 0
    for token in expect.get("order", []):
        found = next((i for i in range(position, len(rows)) if matches(rows[i], token)), None)
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
    for rule in expect.get("counts", []):
        scope = rows
        if "after" in rule:
            anchor = next((i for i, row in enumerate(rows) if matches(row, rule["after"])), None)
            if anchor is None:
                errors.append(f"{path.name}: count anchor {rule['after']!r} is missing")
                continue
            scope = rows[anchor + 1 :]
        actual = sum(1 for row in scope if matches(row, rule["token"]))
        if "equals" in rule and actual != rule["equals"]:
            errors.append(f"{path.name}: {rule['token']!r} occurs {actual} times, expected exactly {rule['equals']}")
        if actual < rule.get("atLeast", 0):
            errors.append(f"{path.name}: {rule['token']!r} occurs {actual} times, expected at least {rule['atLeast']}")
        if "atMost" in rule and actual > rule["atMost"]:
            errors.append(f"{path.name}: {rule['token']!r} occurs {actual} times, expected at most {rule['atMost']}")
    for rule in expect.get("noOutboundBetween", []):
        start = next((i for i, row in enumerate(rows) if matches(row, rule["start"])), None)
        end = next((i for i, row in enumerate(rows) if matches(row, rule["end"])), None)
        if start is None or end is None or end <= start:
            errors.append(f"{path.name}: noOutboundBetween anchors are missing or out of order")
            continue
        allowed_prefix = rule.get("prefix")
        offenders = [
            row.get("bytes")
            for row in rows[start + 1 : end]
            if row.get("direction") == "outbound"
            and row.get("kind") in {"segment", "bmap"}
            and (
                allowed_prefix is None
                or normalize_packet(row.get("bytes", "")).startswith(normalize_packet(allowed_prefix))
            )
        ]
        if offenders:
            errors.append(f"{path.name}: unexpected outbound traffic between {rule['start']!r} and {rule['end']!r}")
    if "segmentHeaders" in expect and "segmentHeadersAfter" not in expect:
        actual = [
            normalize_packet(row.get("bytes", ""))[:2]
            for row in rows
            if row.get("direction") == "inbound" and row.get("kind") == "segment"
        ]
        expected = [header.lower() for header in expect["segmentHeaders"]]
        if actual != expected:
            errors.append(f"{path.name}: inbound segment headers {actual} != expected {expected}")
    if "segmentHeadersAfter" in expect:
        anchor_text = expect["segmentHeadersAfter"]
        anchor = next((i for i, row in enumerate(rows) if anchor_text in (row.get("message") or "")), None)
        if anchor is None:
            errors.append(f"{path.name}: segment header anchor {anchor_text!r} is missing")
        else:
            actual = [
                normalize_packet(row.get("bytes", ""))[:2]
                for row in rows[anchor + 1 :]
                if row.get("direction") == "inbound" and row.get("kind") == "segment"
            ]
            expected = [header.lower() for header in expect.get("segmentHeaders", [])]
            if actual != expected:
                errors.append(f"{path.name}: post-release segment headers {actual} != expected {expected}")
    messages = [row.get("message") or "" for row in rows]
    for text in expect.get("requireEvents", []):
        if not any(text in message for message in messages):
            errors.append(f"{path.name}: required event {text!r} is missing")
    for text in expect.get("forbidEvents", []):
        if any(text in message for message in messages):
            errors.append(f"{path.name}: forbidden event {text!r} is present")
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


def inspect_run_evidence(
    spec: dict,
    run_dir: Path,
    export_root: Path,
    synthetic: dict,
    run_id: str,
    scenario: str,
) -> list[str]:
    identifier = spec.get("_identifier", "test")
    errors: list[str] = []
    config_path = run_dir / "test-config.json"
    if not config_path.is_file():
        return [f"{identifier}: missing test-config.json"]
    try:
        config = load_json_file(config_path)
    except VerifyError as error:
        return [f"{identifier}: {error}"]
    if not isinstance(config, dict):
        return [f"{identifier}: test-config.json must be an object"]
    unknown = set(config) - CONFIG_FILE_KEYS
    if unknown:
        errors.append(f"{identifier}: test-config.json has unsupported fields {sorted(unknown)}")
    missing = CONFIG_FILE_KEYS - set(config)
    if missing:
        return [f"{identifier}: test-config.json missing fields {sorted(missing)}"]
    if config["runID"] != run_id:
        errors.append(f"{identifier}: test-config runID {config['runID']!r} != directory {run_id!r}")
    if config["scenario"] != scenario:
        errors.append(f"{identifier}: test-config scenario {config['scenario']!r} != manifest {scenario!r}")
    if config["reset"] is not spec["reset"]:
        errors.append(f"{identifier}: test-config reset {config['reset']!r} != manifest {spec['reset']!r}")
    if config["peripheral"] != synthetic["peripheralUUID"]:
        errors.append(f"{identifier}: test-config peripheral is not the synthetic identity")
    expected_suite = synthetic["defaultsSuitePrefix"] + run_id
    if config["defaultsSuite"] != expected_suite:
        errors.append(f"{identifier}: defaults suite {config['defaultsSuite']!r} != {expected_suite!r}")

    expect = spec["expect"]
    files = expect.get("files", {})
    for name in files.get("require", []):
        if not (run_dir / name).is_file():
            errors.append(f"{identifier}: required evidence file {name} is missing")
    for name in files.get("forbid", []):
        if (run_dir / name).exists():
            errors.append(f"{identifier}: forbidden evidence file {name} is present")
    if "snapshot" in expect:
        errors.extend(_check_snapshot_v2(run_dir / "LastConfirmedState.json", expect["snapshot"], synthetic))
    if "peripheral" in expect:
        peripheral = dict(expect["peripheral"])
        peripheral["_scenario"] = scenario
        errors.extend(_check_peripheral_v2(run_dir / "peripheral-state.json", peripheral, synthetic, run_id))
    if "journal" in expect:
        errors.extend(_check_journal(run_dir / "PreferenceRecovery.json", expect["journal"], synthetic))
    if "defaults" in expect:
        errors.extend(_check_defaults(export_root, expected_suite, expect["defaults"]))
    if "transcript" in expect:
        errors.extend(_check_transcript_v2(run_dir / "transport.jsonl", expect["transcript"], synthetic))
    if "lifecycle" in expect:
        errors.extend(_check_lifecycle(run_dir / "LifecycleDiagnostics.jsonl", expect["lifecycle"]))
    return errors


def _entry_runs(entry: dict) -> list[dict]:
    return entry.get("runs") or [entry.get("run")]


def _run_directory_matches_token(run_dir: Path, token: str) -> bool:
    try:
        rows = _transcript_rows(run_dir / "transport.jsonl")
    except VerifyError:
        return False
    direction, packet = token.split(":", 1)
    return any(
        row.get("direction") == direction
        and row.get("kind") in {"bmap", "segment"}
        and normalize_packet(row.get("bytes", "")) == normalize_packet(packet)
        for row in rows
    )


def map_and_inspect_lane(
    entries: list[dict],
    export_root: Path,
    new_runs: set[str],
    synthetic: dict,
    lane: str,
) -> tuple[list[str], list[dict]]:
    """Map the lane's newly created run directories to the manifest exactly once."""
    errors: list[str] = []
    claimed: dict[str, dict] = {}
    details: list[dict] = []
    deferred: dict[str, list[tuple[dict, dict]]] = {}

    prefix_owners: list[tuple[str, dict]] = []
    for entry in entries:
        for spec in _entry_runs(entry):
            if spec.get("artifacts") is False or spec.get("evidence") == "invalid-configuration":
                continue
            prefix_owners.append((spec["prefix"], spec))

    def longest_owner(name: str) -> dict | None:
        matches = [(len(prefix), spec) for prefix, spec in prefix_owners if name.startswith(prefix)]
        if not matches:
            return None
        longest = max(length for length, _ in matches)
        owners = {id(spec): spec for length, spec in matches if length == longest}
        return next(iter(owners.values())) if len(owners) == 1 else None

    for entry in entries:
        for spec in _entry_runs(entry):
            if spec.get("artifacts") is False:
                leaked = sorted(name for name in new_runs if name.startswith(spec["prefix"]))
                if leaked:
                    errors.append(f"{entry['id']}: unexpected app-container artifacts {leaked} for a no-artifact test")
                continue
            if spec.get("evidence") == "invalid-configuration":
                leaked = sorted(name for name in new_runs if name.startswith(spec["prefix"]))
                if leaked:
                    errors.append(f"{entry['id']}: invalid configuration created harness run directories {leaked}")
                continue
            group = spec.get("sharedPrefixGroup")
            if group:
                deferred.setdefault(group, []).append((entry, spec))
                continue
            matching = sorted(
                name
                for name in new_runs
                if name.startswith(spec["prefix"]) and longest_owner(name) is spec
            )
            expected = spec.get("expectedRuns", 1)
            if len(matching) != expected:
                errors.append(
                    f"{entry['id']}: expected exactly {expected} run director{'y' if expected == 1 else 'ies'} "
                    f"with prefix {spec['prefix']!r}, found {matching}"
                )
                continue
            for name in matching:
                if name in claimed:
                    errors.append(f"{entry['id']}: run directory {name!r} is reused by another test")
                    continue
                claimed[name] = spec
                details.append({"id": entry["id"], "runID": name, "prefix": spec["prefix"]})

    for group, members in deferred.items():
        prefix = members[0][1]["prefix"]
        matching = sorted(name for name in new_runs if name.startswith(prefix) and name not in claimed)
        expected = sum(spec.get("expectedRuns", 1) for _, spec in members)
        if len(matching) != expected:
            errors.append(
                f"sharedPrefixGroup {group!r}: expected {expected} run directories with prefix {prefix!r}, found {matching}"
            )
            continue
        assigned: dict[str, str] = {}
        for name in matching:
            hits = [
                (entry, spec)
                for entry, spec in members
                if _run_directory_matches_token(
                    export_root / "ApplicationSupport" / "QuietControlUITests" / name,
                    spec["sharedMatchToken"],
                )
            ]
            if len(hits) != 1:
                errors.append(
                    f"sharedPrefixGroup {group!r}: run {name!r} matches {len(hits)} tests; evidence is ambiguous"
                )
                continue
            entry, spec = hits[0]
            if id(spec) in assigned:
                errors.append(f"sharedPrefixGroup {group!r}: run {name!r} duplicates evidence for {entry['id']}")
                continue
            assigned[id(spec)] = name
            claimed[name] = spec
            details.append({"id": entry["id"], "runID": name, "prefix": spec["prefix"], "shared": group})
        for entry, spec in members:
            if id(spec) not in assigned:
                errors.append(f"sharedPrefixGroup {group!r}: no run directory proves {entry['id']}")

    extras = sorted(new_runs - set(claimed))
    for name in extras:
        errors.append(f"{lane}: exported run directory {name!r} is not claimed by the manifest")

    for entry in entries:
        for spec in _entry_runs(entry):
            if spec.get("artifacts") is False or spec.get("evidence") == "invalid-configuration":
                continue
            assigned = [name for name, owner in claimed.items() if owner is spec]
            if not assigned:
                continue
            for name in assigned:
                tagged = dict(spec)
                tagged["_identifier"] = entry["id"]
                errors.extend(
                    inspect_run_evidence(
                        tagged,
                        export_root / "ApplicationSupport" / "QuietControlUITests" / name,
                        export_root,
                        synthetic,
                        name,
                        spec["scenario"],
                    )
                )
    return errors, details


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


def _export_container(
    runner: CommandRunner, run_dir: Path, simulator: dict, label: str, *, allow_empty: bool = False
) -> Path:
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
    if not source.is_dir() and not allow_empty:
        require(False, f"{label}: no QuietControlUITests evidence in the app container")
    destination = run_dir / "artifacts" / label
    destination.mkdir(parents=True, exist_ok=True)
    target = destination / "ApplicationSupport" / "QuietControlUITests"
    if target.exists():
        shutil.rmtree(target)
    if source.is_dir():
        shutil.copytree(source, target)
    else:
        target.mkdir(parents=True, exist_ok=True)
    preferences = container / "Library" / "Preferences"
    preferences_target = destination / "Preferences"
    if preferences.is_dir():
        if preferences_target.exists():
            shutil.rmtree(preferences_target)
        shutil.copytree(preferences, preferences_target)
    return destination


def _normalize_attachment_name(name: str) -> str:
    match = re.match(r"^(.*)_\d+_[0-9A-Fa-f-]+(\.\w+)$", name)
    if match:
        name = match.group(1) + match.group(2)
    return re.sub(r"\.(?:txt|png|jpe?g|heic)$", "", name, flags=re.IGNORECASE)


def _export_attachments(runner: CommandRunner, result_bundle: Path, run_dir: Path, label: str) -> dict:
    """Export the xcresult attachment manifest and files associated with this lane."""
    output = run_dir / "attachments" / label
    if output.exists():
        shutil.rmtree(output)
    output.mkdir(parents=True, exist_ok=True)
    result = runner.run(
        [
            "xcrun",
            "xcresulttool",
            "export",
            "attachments",
            "--path",
            str(result_bundle),
            "--output-path",
            str(output),
        ],
        f"{label}-attachments",
        SHORT_TIMEOUT,
        capture=True,
    )
    if result.returncode != 0:
        raise VerifyError(f"{label}: cannot export xcresult attachments; see {result.log_path}")
    manifest_path = output / "manifest.json"
    if not manifest_path.is_file():
        raise VerifyError(f"{label}: xcresult attachment manifest is missing")
    document = load_json_file(manifest_path)
    require(isinstance(document, list), f"{label}: attachment manifest must be a list")
    by_test: dict[str, dict[str, Path]] = {}
    errors: list[str] = []
    for group in document:
        require(isinstance(group, dict), f"{label}: attachment group must be an object")
        _check_keys(group, {"attachments", "testIdentifier", "testIdentifierURL"}, f"{label}.attachments")
        identifier = group.get("testIdentifier")
        require(isinstance(identifier, str) and identifier, f"{label}: attachment group needs a test identifier")
        records = group.get("attachments")
        require(isinstance(records, list), f"{label}: attachments must be a list")
        names: dict[str, Path] = {}
        for record in records:
            require(isinstance(record, dict), f"{label}: attachment record must be an object")
            _check_keys(
                record,
                {
                    "configurationName",
                    "deviceId",
                    "deviceName",
                    "exportedFileName",
                    "isAssociatedWithFailure",
                    "suggestedHumanReadableName",
                    "timestamp",
                },
                f"{label}.attachment",
            )
            exported = record.get("exportedFileName")
            suggested = record.get("suggestedHumanReadableName")
            require(isinstance(exported, str) and exported, f"{label}: attachment filename is missing")
            require(isinstance(suggested, str) and suggested, f"{label}: attachment suggested name is missing")
            path = output / exported
            if not path.is_file():
                errors.append(f"{label}: exported attachment {exported!r} is missing")
                continue
            name = _normalize_attachment_name(suggested)
            if name in names:
                errors.append(f"{label}: duplicate attachment name {name!r} for {identifier}")
                continue
            names[name] = path
        by_test[identifier] = names
    if errors:
        raise VerifyError("; ".join(errors))
    return {"root": output, "tests": by_test}


def _test_method(identifier: str) -> str:
    value = identifier[:-2] if identifier.endswith("()") else identifier
    return value.split("/")[-1]


def _attachments_for(attachments: dict, identifier: str) -> tuple[dict[str, Path], list[str]]:
    method = _test_method(identifier)
    matches = {
        key: value
        for key, value in attachments["tests"].items()
        if _test_method(key) == method
    }
    if len(matches) != 1:
        return {}, [f"{identifier}: expected exactly one xcresult attachment group, found {sorted(matches)}"]
    return next(iter(matches.values())), []


def _check_audit_summary(path: Path, context: str) -> list[str]:
    errors: list[str] = []
    try:
        summary = load_json_file(path)
    except VerifyError as error:
        return [f"{path.name}: {error}"]
    if not isinstance(summary, dict):
        return [f"{path.name}: audit summary must be an object"]
    _check_keys(
        summary,
        {"screen", "auditTypes", "counts", "countsNote", "policy", "issues"},
        f"{path.name}",
    )
    if summary.get("screen") != context:
        errors.append(f"{path.name}: screen {summary.get('screen')!r} != required context {context!r}")
    counts = summary.get("counts")
    if not isinstance(counts, dict):
        return errors + [f"{path.name}: counts must be an object"]
    _check_keys(counts, {"reported", "ignored", "failed"}, f"{path.name}.counts")
    for key in ("reported", "ignored", "failed"):
        _require_int(counts.get(key), f"{path.name}.counts.{key}")
    issues = summary.get("issues")
    if not isinstance(issues, list):
        return errors + [f"{path.name}: issues must be a list"]
    if counts["reported"] != len(issues):
        errors.append(f"{path.name}: reported {counts['reported']} != {len(issues)} raw issues")
    if counts["reported"] != counts["ignored"] + counts["failed"]:
        errors.append(f"{path.name}: reported counts are inconsistent (reported != ignored + failed)")
    policy = summary.get("policy")
    if not isinstance(policy, dict):
        errors.append(f"{path.name}: policy must be an object")
    else:
        if policy.get("substringExemptions") is not False:
            errors.append(f"{path.name}: substring exemptions are not allowed")
        if policy.get("coordinateExemptions") is not False:
            errors.append(f"{path.name}: coordinate exemptions are not allowed")
        if policy.get("enabledIssueSuppression") != 0:
            errors.append(f"{path.name}: enabled issue suppression must be 0")
    ignored = 0
    failed = 0
    for index, issue in enumerate(issues):
        where = f"{path.name}.issues[{index}]"
        if not isinstance(issue, dict):
            errors.append(f"{where}: issue must be an object")
            failed += 1
            continue
        _check_keys(
            issue,
            {"auditType", "description", "identifier", "label", "enabled", "ignored", "exemption", "frame"},
            where,
        )
        is_ignored = issue.get("ignored")
        if not isinstance(is_ignored, bool):
            errors.append(f"{where}: ignored must be a boolean")
            failed += 1
            continue
        if is_ignored:
            ignored += 1
            if issue.get("auditType") != "contrast" or issue.get("enabled") is not False:
                errors.append(f"{where}: only a contrast issue on a disabled element may be ignored")
            if not isinstance(issue.get("exemption"), str) or "disabled" not in issue["exemption"]:
                errors.append(f"{where}: ignored issue needs the disabled-control exemption")
        else:
            failed += 1
        if "frame" in issue:
            frame = issue["frame"]
            if not isinstance(frame, dict):
                errors.append(f"{where}: frame must be an object")
            else:
                _check_keys(frame, {"x", "y", "width", "height"}, f"{where}.frame")
                for key in ("x", "y", "width", "height"):
                    value = frame.get(key)
                    if not isinstance(value, (int, float)) or isinstance(value, bool):
                        errors.append(f"{where}.frame.{key} must be a number")
                    elif not (value == value and abs(value) != float("inf")):
                        errors.append(f"{where}.frame.{key} must be finite")
                    elif key in {"width", "height"} and value <= 0:
                        errors.append(f"{where}.frame.{key} must be positive")
                if all(isinstance(frame.get(k), (int, float)) for k in ("x", "y", "width", "height")):
                    if frame["x"] + frame["width"] > 100000 or frame["y"] + frame["height"] > 100000:
                        errors.append(f"{where}: frame is outside any possible screen")
    if ignored != counts["ignored"]:
        errors.append(f"{path.name}: ignored count {counts['ignored']} != raw ignored {ignored}")
    if failed != counts["failed"]:
        errors.append(f"{path.name}: failed count {counts['failed']} != raw failed {failed}")
    if counts["failed"] != 0:
        errors.append(f"{path.name}: accessibility audit recorded {counts['failed']} enabled issue(s)")
    return errors


def _check_geometry(path: Path) -> list[str]:
    try:
        geometry = load_json_file(path)
    except VerifyError as error:
        return [f"{path.name}: {error}"]
    if not isinstance(geometry, dict):
        return [f"{path.name}: geometry must be an object"]
    _check_keys(
        geometry,
        {"screen", "elements", "stableSeconds", "before", "after", "heroClearAfter", "strength"},
        f"{path.name}",
    )
    errors: list[str] = []
    expected_elements = ["mode-summary", "mode-strength", "mode-cancel", "mode-save-toolbar", "mode-save-bottom"]
    if geometry.get("screen") != "editor-large-text":
        errors.append(f"{path.name}: screen must be editor-large-text")
    if geometry.get("elements") != expected_elements:
        errors.append(f"{path.name}: elements are not the five ordered editor frames")
    if geometry.get("strength") != "7 of 10":
        errors.append(f"{path.name}: audited strength must be 7 of 10")
    if geometry.get("heroClearAfter") is not True:
        errors.append(f"{path.name}: heroClearAfter must be true")
    if geometry.get("stableSeconds") != 0.5:
        errors.append(f"{path.name}: stableSeconds must be 0.5")
    frames = {}
    for key in ("before", "after"):
        values = geometry.get(key)
        if not isinstance(values, list) or len(values) != 5:
            errors.append(f"{path.name}: {key} must have five frames")
            continue
        parsed = []
        for index, frame in enumerate(values):
            where = f"{path.name}.{key}[{index}]"
            if not isinstance(frame, dict):
                errors.append(f"{where}: frame must be an object")
                parsed = None
                break
            _check_keys(frame, {"x", "y", "width", "height"}, where)
            numbers = {}
            for field in ("x", "y", "width", "height"):
                value = frame.get(field)
                if not isinstance(value, (int, float)) or isinstance(value, bool):
                    errors.append(f"{where}.{field} must be a number")
                    numbers = None
                    break
                if value != value or abs(value) == float("inf"):
                    errors.append(f"{where}.{field} must be finite")
                    numbers = None
                    break
                numbers[field] = value
            if numbers is None:
                parsed = None
                break
            if numbers["width"] <= 0 or numbers["height"] <= 0:
                errors.append(f"{where}: frame must have positive size")
            if numbers["x"] < 0 or numbers["y"] < 0:
                errors.append(f"{where}: frame cannot start outside the screen")
            if numbers["x"] + numbers["width"] > 100000 or numbers["y"] + numbers["height"] > 100000:
                errors.append(f"{where}: frame is outside any possible screen")
            parsed.append(numbers)
        frames[key] = parsed
    if isinstance(frames.get("before"), list) and isinstance(frames.get("after"), list):
        if frames["before"] != frames["after"]:
            errors.append(f"{path.name}: before and after audit frames differ")
        summary, strength, cancel, top_save, bottom_save = frames["before"]
        if summary["y"] < cancel["y"] + cancel["height"] + 8:
            errors.append(f"{path.name}: mode-summary overlaps the pinned Cancel row")
        if strength["y"] + strength["height"] > bottom_save["y"] - 16:
            errors.append(f"{path.name}: mode-strength overlaps the pinned bottom Save")
        if top_save["x"] <= cancel["x"] + cancel["width"]:
            errors.append(f"{path.name}: top Save is not beside Cancel in the pinned row")
        if top_save["y"] != cancel["y"]:
            errors.append(f"{path.name}: top Save is not in the same pinned row as Cancel")
        if bottom_save["y"] <= strength["y"]:
            errors.append(f"{path.name}: bottom Save is not below the editor hero")
    return errors


def _validate_attachments_for_entry(
    entry: dict,
    attachments: dict,
    run_details: list[dict],
) -> list[str]:
    spec = entry.get("attachments")
    if not spec:
        return []
    names, errors = _attachments_for(attachments, entry["id"])
    if errors:
        return errors

    if spec.get("invalidConfiguration"):
        text_names = {"journey-invalid-run", "journey-invalid-scenario"}
        missing = sorted(text_names - set(names))
        if missing:
            errors.append(f"{entry['id']}: missing invalid-configuration attachments {missing}")
        for screenshot in ("invalid-run-error", "invalid-scenario-error"):
            if screenshot not in names:
                errors.append(f"{entry['id']}: missing invalid-configuration screenshot {screenshot!r}")
            else:
                try:
                    data = _read_exact_bytes(names[screenshot], screenshot)
                except VerifyError as error:
                    errors.append(str(error))
                    continue
                if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                    errors.append(f"{entry['id']}: {screenshot} is not a PNG screenshot")
        run_text = ""
        if "journey-invalid-run" in names:
            try:
                run_text = names["journey-invalid-run"].read_text(encoding="utf-8")
            except OSError as error:
                errors.append(f"{entry['id']}: cannot read journey-invalid-run: {error}")
            else:
                first = run_text.splitlines()[0] if run_text.splitlines() else ""
                if not first.startswith("runID: invalid-"):
                    errors.append(f"{entry['id']}: journey-invalid-run does not record the invalid run ID")
                if "QUIETCONTROL_TEST_RUN_ID" not in run_text:
                    errors.append(f"{entry['id']}: journey-invalid-run lacks the actual run-ID error message")
                if "run!" not in run_text:
                    errors.append(f"{entry['id']}: journey-invalid-run did not use a malformed run ID")
                if "outbound bmap" in run_text:
                    errors.append(f"{entry['id']}: invalid run ID emitted radio traffic")
        scenario_text = ""
        if "journey-invalid-scenario" in names:
            try:
                scenario_text = names["journey-invalid-scenario"].read_text(encoding="utf-8")
            except OSError as error:
                errors.append(f"{entry['id']}: cannot read journey-invalid-scenario: {error}")
            else:
                if "Unsupported QUIETCONTROL_TEST_SCENARIO" not in scenario_text:
                    errors.append(f"{entry['id']}: journey-invalid-scenario lacks the unsupported-scenario message")
                if "outbound bmap" in scenario_text:
                    errors.append(f"{entry['id']}: invalid scenario emitted radio traffic")
        if run_text and scenario_text:
            run_id = run_text.splitlines()[0].removeprefix("runID: ").strip()
            scenario_id = scenario_text.splitlines()[0].removeprefix("runID: ").strip()
            if run_id == scenario_id:
                errors.append(f"{entry['id']}: invalid run-ID and scenario cases must use distinct run IDs")
            if " " in scenario_id or "!" in scenario_id:
                errors.append(f"{entry['id']}: the unknown-scenario run ID must use the valid shape")

    if "audits" in spec:
        contexts = spec["audits"]["contexts"]
        screenshots = spec["audits"]["screenshots"]
        for context in contexts:
            name = f"audit-summary-{context}"
            if name not in names:
                errors.append(f"{entry['id']}: missing audit summary {name!r}")
                continue
            errors.extend(_check_audit_summary(names[name], context))
        for context in contexts:
            if context not in names:
                errors.append(f"{entry['id']}: missing required screenshot {context!r}")
                continue
            try:
                data = _read_exact_bytes(names[context], context)
            except VerifyError as error:
                errors.append(str(error))
                continue
            if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                errors.append(f"{entry['id']}: {context} is not a PNG screenshot")
        for screenshot in screenshots:
            if screenshot not in names:
                errors.append(f"{entry['id']}: missing required screenshot {screenshot!r}")
            else:
                try:
                    data = _read_exact_bytes(names[screenshot], screenshot)
                except VerifyError as error:
                    errors.append(str(error))
                    continue
                if not data.startswith(b"\x89PNG\r\n\x1a\n"):
                    errors.append(f"{entry['id']}: {screenshot} is not a PNG screenshot")
    if spec.get("geometry"):
        if "audit-geometry-editor-large-text" not in names:
            errors.append(f"{entry['id']}: missing large-editor audit geometry attachment")
        else:
            errors.extend(_check_geometry(names["audit-geometry-editor-large-text"]))
    if "journeyRunIDs" in spec:
        expected = spec["journeyRunIDs"]
        actual = len([detail for detail in run_details if detail["id"] == entry["id"]])
        if actual != expected:
            errors.append(f"{entry['id']}: mapped {actual} run directories, expected {expected}")
        journeys = sorted(name for name in names if name.startswith("journey-"))
        if len(journeys) != 1:
            errors.append(f"{entry['id']}: expected one journey transcript attachment, found {journeys}")
        else:
            try:
                text = names[journeys[0]].read_text(encoding="utf-8")
            except OSError as error:
                errors.append(f"{entry['id']}: cannot read journey attachment: {error}")
            else:
                for detail in (d for d in run_details if d["id"] == entry["id"]):
                    if detail["runID"] not in text:
                        errors.append(f"{entry['id']}: journey attachment does not name run {detail['runID']}")
    return errors


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
    if manifest.get("schemaVersion") == MANIFEST_SCHEMA_VERSION:
        errors, details = map_and_inspect_lane(
            entries, export, new_runs, manifest["synthetic"], "session"
        )
        lane["errors"].extend(errors)
        lane["evidenceRuns"] = details
    else:
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
        attachments = None
        result_bundle = Path(lane["resultBundle"])
        if result_bundle.is_dir():
            try:
                attachments = _export_attachments(runner, result_bundle, run_dir, label)
                lane["attachmentRoot"] = str(attachments["root"])
            except VerifyError as error:
                lane["errors"].append(str(error))
        invalid_only = bool(journey.get("runs")) and all(
            spec.get("evidence") == "invalid-configuration" for spec in journey["runs"]
        )
        try:
            export = _export_container(
                runner, run_dir, simulator, label, allow_empty=invalid_only
            )
        except VerifyError as error:
            lane["errors"].append(str(error))
        else:
            new_runs = exported_run_names(export) - before
            lane["artifacts"] = str(export)
            lane["runDirectories"] = sorted(new_runs)
            if manifest.get("schemaVersion") == MANIFEST_SCHEMA_VERSION:
                errors, details = map_and_inspect_lane(
                    [journey], export, new_runs, manifest["synthetic"], label
                )
                lane["errors"].extend(errors)
                lane["evidenceRuns"] = details
                if attachments is not None:
                    lane["errors"].extend(
                        _validate_attachments_for_entry(journey, attachments, details)
                    )
            else:
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
