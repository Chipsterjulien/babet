#!/usr/bin/env python3
"""Exercise CLI exits in fresh processes, with real PTYs and native callbacks."""
import errno
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import termios
import time


LUA = r'''
local scenario, output = arg[1], arg[2]
if scenario:sub(1, 4) == 'pty-' then
    io.write('PRE_CURSES_READY\n'); io.flush()
    assert(io.read('*l') == 'go')
    assert(babet.curses.start())
    assert(babet.curses.write('EXIT_CURSES_ACTIVE'))
    assert(babet.curses.refresh())
    scenario = scenario:sub(5)
end

-- Keep both objects reachable until explicit state closure. os.exit without
-- close must flush the file but must not run the Lua finalizer.
buffered = assert(io.open(output, 'wb'))
buffered:setvbuf('full')
assert(buffered:write('BUFFERED_EXIT_OUTPUT'))
local recursive = scenario == 'recursive' or scenario == 'return-recursive'
    or scenario == 'error-recursive' or scenario == 'gc-recursive'
exit_probe = setmetatable({}, {__gc=function()
    io.write('LUA_FINALIZER\n')
    if recursive then os.exit(31, true) end
end})

local actions = {
    default = function() os.exit() end,
    yes = function() os.exit(true) end,
    no = function() os.exit(false) end,
    code = function() os.exit(23) end,
    string = function() os.exit('23') end,
    nilcode = function() os.exit(nil) end,
    negative = function() os.exit(-1) end,
    large = function() os.exit(511) end,
    close = function() os.exit(23, true) end,
    truthy = function() os.exit(23, 0) end,
    extra = function() os.exit(23, false, {}) end,
    alias = function() local exit=require('os').exit; exit(23) end,
    caught = function() pcall(os.exit, 23) end,
    coroutine = function() coroutine.wrap(function() os.exit(23) end)() end,
    ['coroutine-close'] = function()
        coroutine.wrap(function() os.exit(23, true) end)()
    end,
    recursive = function() os.exit(23, true) end,
    ['return-recursive'] = function() end,
    ['error-recursive'] = function() error('top-level close sentinel') end,
    ['gc-recursive'] = function()
        exit_probe=nil; collectgarbage('collect')
    end,
    invalid = function()
        for _, value in ipairs({'invalid', {}, function() end, 1.5}) do
            assert(not pcall(os.exit, value, true))
        end
        if babet.curses then
            -- PTY cases must still have a usable curses session here.
            if arg[1]:sub(1, 4) == 'pty-' then
                assert(babet.curses.write('INVALID_EXIT_RECOVERED'))
                assert(babet.curses.refresh())
            end
        end
        io.write('INVALID_EXIT_RECOVERED\n')
        os.exit(23)
    end,
    worker = function()
        active_job = assert(babet.workers.spawn([[
            assert(worker.send('ready', 5))
            -- Blocks outside the Lua cancellation hook. The default exit
            -- must not add an implicit worker join.
            local f=assert(io.open(worker.args.fifo, 'r'))
            f:close()
        ]], {fifo=arg[3]}))
        local ok, value=active_job:recv(10)
        assert(ok and value=='ready', tostring(value))
        io.write('WORKER_READY\n')
        os.exit(23)
    end,
    ['worker-close'] = function()
        active_job=assert(babet.workers.spawn([[
            assert(worker.send('ready', 5)); worker.recv()
        ]]))
        local ok, value=active_job:recv(10)
        assert(ok and value=='ready', tostring(value))
        os.exit(23, true)
    end,
}
assert(actions[scenario], scenario)()
if scenario ~= 'return-recursive' then error('os.exit unexpectedly returned') end
'''


def run(command, *, cwd, status=0, timeout=20):
    result = subprocess.run([str(x) for x in command], cwd=cwd,
                            capture_output=True, timeout=timeout)
    if result.returncode != status:
        raise AssertionError(f'{command}: status={result.returncode}, expected={status}\n'
                             + (result.stdout + result.stderr).decode('utf-8', 'replace'))
    return result.stdout + result.stderr


def run_pty(command, cwd, status):
    pid, master = pty.fork()
    if pid == 0:
        try:
            os.chdir(cwd)
            env = dict(os.environ, TERM='xterm-256color', LC_ALL='C.UTF-8')
            os.execve(str(command[0]), [str(x) for x in command], env)
        except BaseException:
            os._exit(125)
    output = bytearray()
    baseline = None
    result = None
    deadline = time.monotonic() + 20
    try:
        while time.monotonic() < deadline:
            ready, _, _ = select.select([master], [], [], 0.03)
            if ready:
                try:
                    output.extend(os.read(master, 65536))
                except OSError as error:
                    if error.errno != errno.EIO:
                        raise
            if baseline is None and b'PRE_CURSES_READY' in output:
                baseline = termios.tcgetattr(master)
                os.write(master, b'go\n')
            waited, result_status = os.waitpid(pid, os.WNOHANG)
            if waited:
                result = result_status
                break
        if result is None:
            raise AssertionError(f'PTY timeout: {command}')
        # Drain anything written just before waitpid observed termination.
        os.set_blocking(master, False)
        while True:
            try:
                chunk = os.read(master, 65536)
            except (BlockingIOError, OSError):
                break
            if not chunk:
                break
            output.extend(chunk)
        if os.waitstatus_to_exitcode(result) != status:
            raise AssertionError(f'PTY status {result}: {output!r}')
        if baseline is None or termios.tcgetattr(master) != baseline:
            raise AssertionError(f'PTY terminal attributes were not restored: {output!r}')
        if b'EXIT_CURSES_ACTIVE' not in output:
            raise AssertionError(f'PTY curses did not start: {output!r}')
        return bytes(output)
    finally:
        if result is None:
            try:
                os.kill(pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            os.waitpid(pid, 0)
        os.close(master)


def main():
    if len(sys.argv) != 2:
        raise SystemExit('Usage: test_cli_exit.py /path/to/babet')
    binary = Path(sys.argv[1]).resolve()
    root = Path(__file__).resolve().parents[1]
    count = 0
    with tempfile.TemporaryDirectory(prefix='babet-cli-exit-') as temp:
        work = Path(temp)
        project = work / 'project'; project.mkdir()
        source = project / 'main.lua'; source.write_text(LUA)
        app = work / 'application'
        run([binary, '--create-exe', project, app], cwd=work)
        fifo = work / 'worker-fifo'; os.mkfifo(fifo)
        witness = work / 'buffered-output'
        cases = [('default', 0), ('yes', 0), ('no', 1), ('code', 23),
                 ('string', 23), ('nilcode', 0), ('negative', 255), ('large', 255),
                 ('close', 23), ('truthy', 23), ('extra', 23), ('alias', 23),
                 ('caught', 23), ('coroutine', 23), ('coroutine-close', 23),
                 ('recursive', 31), ('return-recursive', 31),
                 ('error-recursive', 31), ('gc-recursive', 31),
                 ('invalid', 23), ('worker', 23), ('worker-close', 23)]
        closing = {'close', 'truthy', 'coroutine-close', 'recursive',
                   'return-recursive', 'error-recursive', 'gc-recursive', 'worker-close'}
        pty_cases = {'code', 'close', 'coroutine', 'coroutine-close', 'recursive',
                     'return-recursive', 'error-recursive', 'gc-recursive',
                     'invalid', 'worker', 'worker-close'}
        for mode, command in [('file', [binary, source]),
                              ('folder', [binary, project]), ('embedded', [app])]:
            for scenario, status in cases:
                for terminal in (False, True) if scenario in pty_cases else (False,):
                    witness.unlink(missing_ok=True)
                    name = ('pty-' if terminal else '') + scenario
                    args = [*command, name, witness, fifo]
                    output = (run_pty(args, work, status) if terminal
                              else run(args, cwd=work, status=status))
                    expected_gc = 1 if scenario in closing else 0
                    if output.count(b'LUA_FINALIZER') != expected_gc:
                        raise AssertionError(f'{mode}/{name}: unexpected finalizers: {output!r}')
                    if witness.read_bytes() != b'BUFFERED_EXIT_OUTPUT':
                        raise AssertionError(f'{mode}/{name}: buffered file was not flushed')
                    if scenario == 'invalid' and b'INVALID_EXIT_RECOVERED' not in output:
                        raise AssertionError(f'{mode}/{name}: invalid-argument recovery missing')
                    print(f'[PASS] CLI exit {mode}/{name}', flush=True)
                    count += 1

        # Use Babet's public plugin ABI, which also works with an ASan binary.
        plugin = work / 'exit-probe.so'
        run([*shlex.split(os.environ.get('CXX', 'c++')), '-std=c++23', '-shared',
             '-fPIC', '-pthread', '-Wall', '-Wextra', '-Wpedantic', '-Werror',
             '-I' + str(root / 'include'), root / 'tests/native_plugins/plugin_exit.cpp',
             '-o', plugin], cwd=work)
        native = work / 'native.lua'
        native.write_text('local p=assert(babet.plugin.load(arg[1])); '
                          'p.functions.start(); if arg[2] == "exit" then os.exit(23) '
                          'elseif arg[2] == "close" then os.exit(23,true) end')
        for mode in ('return', 'exit', 'close'):
            output = run([binary, native, plugin, mode], cwd=work,
                         status=0 if mode == 'return' else 23)
            assert b'NATIVE_THREAD_READY' in output, output
            for marker in (b'NATIVE_ATEXIT', b'NATIVE_DESTRUCTOR'):
                if (marker in output) != (mode == 'return'):
                    raise AssertionError(f'native {mode}: unexpected native teardown: {output!r}')
            print(f'[PASS] CLI native teardown/{mode}', flush=True)
            count += 1
    print(f'CLI exit: {count} PASS / 0 FAIL', flush=True)


if __name__ == '__main__':
    try:
        main()
    except (AssertionError, OSError, subprocess.SubprocessError) as error:
        print(f'[FAIL] CLI exit: {error}', file=sys.stderr)
        raise SystemExit(1)
