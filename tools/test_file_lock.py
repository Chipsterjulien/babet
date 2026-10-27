#!/usr/bin/env python3
"""Independent processes, native flock and Babet workers; no GTK required."""
import argparse
import contextlib
import fcntl
import os
from pathlib import Path
import select
import shlex
import stat
import subprocess
import sys
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]
FIXTURE = ROOT / 'tests/fs/lock_file_contract.lua'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('binary', type=Path)
    parser.add_argument('--standalone', action='store_true', help='isolated binding runner, no workers')
    args = parser.parse_args()
    binary = args.binary.resolve()
    passed = 0

    def check(name):
        nonlocal passed
        passed += 1
        print('[PASS] file lock: ' + name, flush=True)

    def command(mode, path, *extra):
        return [str(binary), str(FIXTURE), mode, str(path), *map(str, extra)]

    def run(mode, path, expected, *extra):
        result = subprocess.run(command(mode, path, *extra), capture_output=True, text=True, timeout=20)
        assert result.returncode == 0 and result.stdout.strip() == expected, (
            mode, result.returncode, result.stdout, result.stderr)

    def line(child):
        assert select.select([child.stdout], [], [], 15)[0], 'child readiness timeout'
        text = child.stdout.readline().strip()
        if not text:
            raise AssertionError(('early exit', child.poll(), child.stderr.read()))
        return text

    @contextlib.contextmanager
    def process(mode, path):
        child = subprocess.Popen(command(mode, path), stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            yield child
        finally:
            if child.poll() is None:
                child.kill()
            child.communicate(timeout=10)

    def release(child):
        output, error = child.communicate('close\n', timeout=15)
        assert child.returncode == 0, (child.returncode, output, error)

    def native_available(path, available):
        with open(path, 'r+b') as stream:
            try:
                fcntl.flock(stream, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                assert not available, 'unexpected native contention'
            else:
                assert available, 'native flock bypassed Babet lock'

    def wait_for(path):
        deadline = time.monotonic() + 15
        while not path.exists():
            assert time.monotonic() < deadline, f'timeout waiting for {path.name}'
            time.sleep(0.02)

    with tempfile.TemporaryDirectory(prefix="babet-lock é space's-") as temp:
        root = Path(temp)
        lock = root / '.basket.lock'
        run('contract', lock, 'CONTRACT_OK')
        assert stat.S_IMODE(lock.stat().st_mode) & ~0o600 == 0
        check('arity, binary writes, unrelated close, explicit close, scope and GC')

        before = lock.stat()
        with process('hold', lock) as holder:
            assert line(holder) == 'HELD'
            run('try', lock, 'LOCKED'); native_available(lock, False)
            assert lock.read_bytes() == b'separate PID'
            run('try', root / 'another.lock', 'FREE')
            release(holder)
        native_available(lock, True)
        assert lock.stat().st_ino == before.st_ino
        check('independent processes and native flock, independent folders/files, unchanged inode/content')

        with open(lock, 'r+b') as native:
            fcntl.flock(native, fcntl.LOCK_EX | fcntl.LOCK_NB)
            run('try', lock, 'LOCKED')
        check('Babet respects a lock taken outside Babet')

        symlink = root / 'alias.lock'; symlink.symlink_to(lock)
        hardlink = root / 'hard.lock'; os.link(lock, hardlink)
        directory = root / 'alias-dir'; directory.symlink_to(root, target_is_directory=True)
        with process('hold', lock) as holder:
            assert line(holder) == 'HELD'
            for alias in (symlink, hardlink, directory / lock.name):
                run('try', alias, 'LOCKED')
            release(holder)
        run('write', symlink, 'WRITTEN', 'alias')
        assert lock.stat().st_ino == before.st_ino and lock.read_bytes() == b'alias'
        check('symlinks, directory aliases and hard links share the same lock')

        # Repeat simultaneous acquisition; the winner stays alive until observed.
        for _ in range(8):
            with process('race', lock) as a, process('race', lock) as b:
                assert line(a) == line(b) == 'READY'
                for child in (a, b):
                    child.stdin.write('go\n'); child.stdin.flush()
                result = [line(a), line(b)]
                assert sorted(result) == ['HELD', 'LOCKED'], result
                winner, loser = (a, b) if result[0] == 'HELD' else (b, a)
                loser.communicate(timeout=15); assert loser.returncode == 0
                release(winner)
        check('eight simultaneous acquisition races have exactly one winner')

        with process('hold', lock) as holder:
            assert line(holder) == 'HELD'
            holder.kill(); holder.communicate(timeout=15)
            assert holder.returncode == -9
        assert lock.exists(); run('try', lock, 'FREE')
        check('SIGKILL releases the lock and preserves the file')

        fifo = root / 'fifo'; os.mkfifo(fifo)
        for target in (fifo, Path('/dev/null'), root, root / 'absent' / 'lock'):
            run('reject', target, 'REJECTED')
        dangling = root / 'dangling'; dangling.symlink_to(root / 'no-target')
        run('reject', dangling, 'REJECTED'); assert not (root / 'no-target').exists()
        check('FIFO, device, directory, missing parent and dangling symlink rejected')

        helper = root / 'child.py'
        ready, stop, done = (root / name for name in ('ready', 'stop', 'done'))
        helper.write_text('''from pathlib import Path
import sys, time
ready, stop, done = map(Path, sys.argv[1:])
ready.touch()
deadline = time.monotonic() + 20
while not stop.exists() and time.monotonic() < deadline: time.sleep(0.02)
done.touch()
''')
        shell = shlex.join([sys.executable, str(helper), str(ready), str(stop), str(done)])
        try:
            run('launch', lock, 'LAUNCHED', shell + ' </dev/null >/dev/null 2>&1 &')
            wait_for(ready); assert not done.exists()
            run('try', lock, 'FREE'); native_available(lock, True)
        finally:
            stop.touch()
            if ready.exists(): wait_for(done)
        check('external program remains alive after launcher exit without retaining its lock')

        if not args.standalone:
            run('workers', lock, 'WORKERS_OK')
            check('worker Lua VM registration, contention and shutdown cleanup')
        else:
            print('[SKIP] worker integration requires the full Babet runtime')
    print(f'File lock integration: {passed} PASS / 0 FAIL')


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f'[FAIL] file lock: {error}', file=sys.stderr)
        sys.exit(1)
