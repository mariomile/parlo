#!/usr/bin/env python3
"""Dependency-free native seam regressions; no app, models, input devices, or real clipboard.

Builds a snapshot of ParloCore and selected production App code under /tmp. AppKit/engine seams
are replaced by in-memory fakes; extracted methods retain their production bodies. The native
SystemIO/RecordingSession implementations also receive a real-SDK typecheck without execution.
"""
import argparse
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
FIXTURES = Path(__file__).with_name("NativeAuditFixtures.swift")
REGRESSIONS = Path(__file__).with_name("NativeAuditRegressions.swift")


def method(source, name):
    match = re.search(r"^    (?:private )?func " + re.escape(name) + r"\(", source, re.M)
    if not match:
        raise AssertionError(f"Missing production method {name}")
    start = match.start()
    brace = source.index("{", match.end())
    depth = 1
    cursor = brace + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[start:cursor].replace("    private func ", "    func ", 1)


def run(args, log):
    result = subprocess.run(args, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout)
    print(f"{log.name}: exit {result.returncode}", flush=True)
    if result.returncode:
        print(result.stdout[-24000:])
        raise SystemExit(result.returncode)
    return result.stdout


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    out = args.output or Path(tempfile.mkdtemp(prefix="parlo-native-audit-"))
    out.mkdir(parents=True, exist_ok=True)
    core = out / "Core"
    if core.exists():
        shutil.rmtree(core)
    shutil.copytree(ROOT / "ParloKit/Sources/ParloCore", core)
    compiler = ["xcrun", "swiftc", "-parse-as-library", "-swift-version", "6",
                "-module-cache-path", str(out / "module-cache")]
    run(compiler + ["-emit-library", "-emit-module", "-enable-testing", "-module-name", "ParloCore",
                    "-emit-module-path", str(out / "ParloCore.swiftmodule"),
                    "-o", str(out / "libParloCore.dylib")] + [str(p) for p in sorted(core.glob("*.swift"))],
        out / "core-compile.log")
    isolation = ["-default-isolation", "MainActor", "-enable-upcoming-feature", "NonisolatedNonsendingByDefault"]
    run(compiler + isolation + ["-typecheck", "-I", str(out)] +
        [str(ROOT / "App" / p) for p in ("SystemIO.swift", "NativeReliability.swift", "RecordingSession.swift", "AudioRecorder.swift")],
        out / "native-typecheck.log")

    system = (ROOT / "App/SystemIO.swift").read_text()
    # Real ClipboardTurn, TextInserter, selection types and SelectionReader. Only the OS adapters are fake.
    system = system[system.index("struct PasteboardSnapshot"):system.index("/// The element with keyboard focus")]
    recording = (ROOT / "App/RecordingSession.swift").read_text().replace("import ParloCore", "@testable import ParloCore")
    meeting = (ROOT / "App/MeetingController.swift").read_text().replace("import AppKit", "import Foundation\nimport Observation")
    meeting = meeting.replace("import ParloEngines", "").replace("import ParloCore", "@testable import ParloCore")
    controller = (ROOT / "App/AppController.swift").read_text()
    names = ["save", "persistSelection", "retry", "transcribeFile", "queueFile", "runFile", "job", "enqueue",
             "beginWork", "revokeWork", "isCurrent", "finishWork", "present", "failed", "delete", "deliver",
             "prepareForTermination", "terminationSaveSucceeded", "retryHistoryStorage"]
    settings = (ROOT / "App/SettingsView.swift").read_text()
    native = (ROOT / "App/NativeReliability.swift").read_text()
    source = FIXTURES.read_text()
    source = source.replace("// PRODUCTION_CONTROLLER_METHODS", "\n\n".join(method(controller, name) for name in names))
    source = source.replace("// PRODUCTION_SETTINGS_METHODS", "\n\n".join(method(settings, name) for name in ("resetKeyDraft", "saveKey", "test")))
    source = source.replace("// PRODUCTION_STORAGE_DELETE", method(settings, "delete"))
    combined = out / "NativeAuditCombined.swift"
    combined.write_text(source + "\n" + native + "\n" + system + "\n" + recording + "\n" + meeting + "\n" + REGRESSIONS.read_text())
    executable = out / "native-audit-tests"
    run(compiler + isolation + ["-I", str(out), "-L", str(out), "-lParloCore", "-Xlinker", "-rpath", "-Xlinker", str(out),
                               str(combined), "-o", str(executable)], out / "seam-compile.log")
    print(run([str(executable)], out / "results.txt"), end="")
    print(f"Evidence: {out}")


if __name__ == "__main__":
    main()
