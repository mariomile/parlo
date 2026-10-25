#!/usr/bin/env python3
"""Run exact copied monitor bodies with in-memory OS seams; never creates a live tap.

Also typechecks the unmodified monitor against the native SDK. All compilation is isolated
under --output, with only HotkeyStateMachine copied from ParloCore (no package/model builds).
--source can replay the regression against a saved pre-fix monitor.
"""
import argparse
import re
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]


def run(command, log):
    result = subprocess.run(command, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write_text(result.stdout)
    print(f"{log.name}: exit {result.returncode}", flush=True)
    if result.stdout:
        print(result.stdout, end="")
    if result.returncode:
        raise SystemExit(result.returncode)


def method(source, name):
    match = re.search(r"^    private func " + re.escape(name) + r"\(", source, re.M)
    if not match:
        raise AssertionError(f"Missing production controller method {name}")
    brace = source.index("{", match.end())
    depth, cursor = 1, brace + 1
    while depth:
        depth += (source[cursor] == "{") - (source[cursor] == "}")
        cursor += 1
    return source[match.start():cursor].replace("private func", "func", 1)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path)
    parser.add_argument('--source', type=Path, default=ROOT / 'App/HotkeyMonitor.swift')
    args = parser.parse_args()
    out = args.output or Path(tempfile.mkdtemp(prefix='parlo-hotkey-'))
    out.mkdir(parents=True, exist_ok=True)
    core = out / 'HotkeyStateMachine.swift'
    core.write_text((ROOT / 'ParloKit/Sources/ParloCore/HotkeyStateMachine.swift').read_text())
    compiler = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '6',
                '-module-cache-path', str(out / 'module-cache')]
    run(compiler + ['-emit-module', '-module-name', 'ParloCore', '-emit-module-path',
                    str(out / 'ParloCore.swiftmodule'), str(core)], out / 'core-module.log')
    isolation = ['-default-isolation', 'MainActor', '-enable-upcoming-feature', 'NonisolatedNonsendingByDefault']
    original = out / 'HotkeyMonitor.native.swift'
    original.write_text(args.source.read_text())
    run(compiler + isolation + ['-typecheck', '-I', str(out), str(original)], out / 'native-typecheck.log')
    source = args.source.read_text().replace('import ParloCore', '')
    # Only OS boundaries change; start/isRunning/handle/poll/disposal remain production code.
    for old, new in [
        ('CGEvent.tapCreate', 'FakeOS.create'), ('CGEvent.tapEnable', 'FakeOS.enable'),
        ('CGEvent.tapIsEnabled', 'FakeOS.isEnabled'),
        ('CFMachPortCreateRunLoopSource', 'FakeOS.createSource'),
        ('CFMachPortIsValid', 'FakeOS.isValid'), ('CFMachPortInvalidate', 'FakeOS.invalidateTap'),
        ('CFRunLoopAddSource', 'FakeOS.addSource'), ('CFRunLoopRemoveSource', 'FakeOS.removeSource'),
        ('CFRunLoopSourceInvalidate', 'FakeOS.invalidateSource'),
        ('CFRunLoopGetMain()', 'FakeOS.mainLoop'),
        ('CFRunLoopSource', 'FakeSource'), ('CFMachPort', 'FakeTap'),
        ('CGEventSource.flagsState(.combinedSessionState)', 'FakeOS.flags'),
        ('ProcessInfo.processInfo.systemUptime', 'FakeOS.now'),
    ]:
        source = source.replace(old, new)
    combined = out / 'HotkeyMonitorTests.swift'
    fixture = Path(__file__).with_name('HotkeyMonitorFixtures.swift').read_text()
    controller = (ROOT / 'App/AppController.swift').read_text()
    methods = '\n'.join(method(controller, name) for name in ('startHotkey', 'retryHotkey'))
    methods = re.sub(r'\bTimer\b', 'FakeTimer', methods)
    methods = re.sub(r'\bRunLoop\b', 'FakeRunLoop', methods)
    fixture = fixture.replace('// PRODUCTION_CONTROLLER_METHODS', methods)
    combined.write_text(core.read_text() + '\n' + source + '\n' + fixture)
    executable = out / 'hotkey-tests'
    run(compiler + isolation + [str(combined), '-o', str(executable)], out / 'seam-compile.log')
    run([str(executable)], out / 'results.txt')
    print(f'Evidence: {out}')


if __name__ == '__main__':
    main()
