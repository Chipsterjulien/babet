#!/usr/bin/env python3
"""Real worker/process regressions, including main-thread SIGINT delivery."""
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import tempfile
import time

HELPER = r'''
#include <signal.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--mask") == 0) {
        sigset_t mask; sigprocmask(SIG_SETMASK, NULL, &mask);
        const int sigs[] = {SIGINT,SIGTERM,SIGHUP,SIGUSR1,SIGUSR2,SIGPIPE};
        for (unsigned i=0;i<sizeof(sigs)/sizeof(sigs[0]);++i)
            if (sigismember(&mask,sigs[i])) return 23;
        puts("MASK_OK"); return 0;
    }
    if (argc == 3 && strcmp(argv[1], "--hold") == 0) {
        FILE *f=fopen(argv[2],"w"); if(!f) return 2;
        fprintf(f,"%ld\n",(long)getpid()); if(fclose(f)) return 3;
        for (;;) pause();
    }
    return 4;
}
'''

LUA = r'''
local W=babet.workers
local function q(s) return "'"..s:gsub("'", "'\\''").."'" end
if arg[1]=='basic' then
    local original_execute, original_popen=os.execute,io.popen
    local code=[==[
        local count=0
        local function check(fn) fn();count=count+1 end
        local function q(s) return "'"..s:gsub("'", "'\\''").."'" end
        local function mask()
            local f=assert(io.open('/proc/thread-self/status'))
            local s=f:read('*a');f:close();return assert(s:match('SigBlk:%s*(%x+)'))
        end
        local before=mask()
        local command='exec '..q(worker.args.helper)..' --mask'
        check(function() assert(select('#',os.execute())==1 and os.execute()) end)
        check(function()
            local a,b,c=os.execute(command..' >/dev/null')
            assert(a and b=='exit' and c==0)
        end)
        check(function()
            local a,b,c=os.execute('exit 17');assert(a==nil and b=='exit' and c==17)
        end)
        check(function()
            local a,b,c=os.execute('kill -TERM $$');assert(a==nil and b=='signal' and c==15)
        end)
        check(function()
            local f=assert(io.popen(command));assert(io.type(f)=='file')
            assert(f:read('*a')=='MASK_OK\n');assert(f:close());assert(io.type(f)=='closed file')
        end)
        check(function()
            local f=assert(io.popen('cat > '..q(worker.args.output),'w'))
            assert(f:write('WORKER_PIPE_DATA'));assert(f:close())
            f=assert(io.open(worker.args.output));assert(f:read('*a')=='WORKER_PIPE_DATA');f:close()
        end)
        check(function()
            local f=assert(io.popen('printf "one\ntwo\n"'))
            local lines={};for line in f:lines() do lines[#lines+1]=line end
            assert(lines[1]=='one' and lines[2]=='two' and #lines==2);assert(f:close())
        end)
        check(function()
            local retained
            do local f <close> = assert(io.popen('printf done'));retained=f;assert(f:read('*a')=='done') end
            assert(io.type(retained)=='closed file' and not pcall(retained.close,retained))
        end)
        check(function()
            local retained
            local co=coroutine.create(function()
                local f <close> = assert(io.popen('printf abc'));retained=f;coroutine.yield()
            end)
            assert(coroutine.resume(co));assert(coroutine.close(co));assert(io.type(retained)=='closed file')
        end)
        check(function()
            local f=assert(io.popen('exit 19'));local a,b,c=f:close()
            assert(a==nil and b=='exit' and c==19)
        end)
        check(function()
            local f=assert(io.popen('kill -TERM $$'));local a,b,c=f:close()
            assert(a==nil and b=='signal' and c==15)
        end)
        check(function()
            for _,mode in ipairs({'','x','rw','rb'}) do assert(not pcall(io.popen,'true',mode)) end
            assert(not pcall(os.execute,{}));assert(not pcall(io.popen,{}))
        end)
        check(function()
            local execute=require('os').execute;local popen=require('io').popen
            assert(coroutine.wrap(function()
                assert(execute('exit 0'));local p=assert(popen('printf alias'))
                local s=p:read('*a');assert(p:close());return s
            end)()=='alias')
        end)
        check(function()
            -- Reaping through __gc, followed by ordinary continued execution.
            do local p=assert(io.popen('printf gc'));assert(p:read('*a')=='gc') end
            collectgarbage('collect');assert(os.execute('exit 0'))
        end)
        check(function() assert(mask()==before) end)
        return count
    ]==]
    local jobs={}
    for i=1,4 do jobs[i]=assert(W.spawn(code,{helper=arg[2],output=arg[3]..i})) end
    for _,job in ipairs(jobs) do local ok,n=job:join(15);assert(ok and n==15,tostring(n)) end
    local nested=assert(W.spawn([[
        local job=assert(babet.workers.spawn(worker.args.code,worker.args.args))
        local ok,n=job:join(15);assert(ok,tostring(n));return n
    ]],{code=code,args={helper=arg[2],output=arg[3]..'nested'}}))
    local ok,n=nested:join(15);assert(ok and n==15,tostring(n))
    assert(os.execute==original_execute and io.popen==original_popen)
    print('Worker standard process: 76 PASS')
else
    local delivered=false
    babet.signal.handle('INT',function()
        delivered=true
        local f=assert(io.open(arg[5],'w'));assert(f:write('HANDLED'));f:close()
    end)
    local job=assert(W.spawn([[
        local function q(s) return "'"..s:gsub("'", "'\\''").."'" end
        local command='exec '..q(worker.args.helper)..' --hold '..q(worker.args.ready)
        local a,b,c
        if worker.args.kind=='execute' then a,b,c=os.execute(command)
        else
            local p=assert(io.popen(command));assert(p:read('*a')=='');a,b,c=p:close()
        end
        return {ok=a==true,kind=b,code=c}
    ]],{helper=arg[2],ready=arg[3],kind=arg[1]}))
    local deadline=babet.monotonic()+20
    while job:status()=='running' do assert(babet.monotonic()<deadline,'worker timed out') end
    local ok,result=job:join(3);assert(ok,tostring(result))
    assert(delivered and result.ok==false and result.kind=='signal' and result.code==15)
    print('WORKER_SIGNAL_OK')
end
'''


def run(args, cwd):
    result = subprocess.run([str(x) for x in args], cwd=cwd, capture_output=True,
                            text=True, timeout=40)
    if result.returncode:
        raise AssertionError(f'{args}: status={result.returncode}\n{result.stdout}{result.stderr}')
    return result.stdout


def wait_for(path, process):
    deadline = time.monotonic() + 10
    while time.monotonic() < deadline:
        if path.exists() and path.stat().st_size:
            return
        if process.poll() is not None:
            raise AssertionError('worker launcher stopped before its readiness marker')
        time.sleep(0.01)
    raise AssertionError(f'timed out waiting for {path.name}')


def signals(command, kind, helper, work):
    ready, handled = work/'ready', work/'handled'
    ready.unlink(missing_ok=True); handled.unlink(missing_ok=True)
    args = [*command,kind,helper,ready,'unused',handled]
    process = subprocess.Popen([str(x) for x in args], cwd=work,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                               text=True, start_new_session=True)
    try:
        wait_for(ready, process)
        child = int(ready.read_text())
        assert child > 1
        os.kill(process.pid, signal.SIGINT)
        wait_for(handled, process)
        os.kill(child, signal.SIGTERM)
        stdout, stderr = process.communicate(timeout=10)
        if process.returncode != 0 or 'WORKER_SIGNAL_OK' not in stdout:
            raise AssertionError(f'{kind}: exit={process.returncode}\n{stdout}{stderr}')
    finally:
        # Covers timeout and blocked child masks without leaving a shell/helper.
        try:
            os.killpg(process.pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
        process.communicate()


def main():
    if len(sys.argv)!=2:
        raise SystemExit('Usage: test_worker_standard_process.py /path/to/babet')
    binary=Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory(prefix='babet-worker-standard-') as temp:
        work=Path(temp);project=work/'project';project.mkdir()
        source=project/'main.lua';source.write_text(LUA)
        helper_source=work/'helper.c';helper_source.write_text(HELPER)
        helper=work/'helper'
        run([*shlex.split(os.environ.get('CC','cc')),'-std=c11','-D_POSIX_C_SOURCE=200809L',
             '-Wall','-Wextra','-Werror',helper_source,'-o',helper],work)
        app=work/'application';run([binary,'--create-exe',project,app],work)
        for mode,command in [('file',[binary,source]),('folder',[binary,project]),('embedded',[app])]:
            output=run([*command,'basic',helper,work/'output'],work)
            assert 'Worker standard process: 76 PASS' in output,output
            print(f'[PASS] {mode}: 76 standard-process/worker contracts',flush=True)
            for kind in ('execute','popen'):
                signals(command,kind,helper,work)
                print(f'[PASS] {mode}/{kind}: main SIGINT delivered; child SIGTERM effective',flush=True)
    print('Worker standard process runtime: 234 PASS / 0 FAIL',flush=True)


if __name__=='__main__':
    try:
        main()
    except (AssertionError,OSError,subprocess.SubprocessError) as error:
        print(f'[FAIL] worker standard process: {error}',file=sys.stderr)
        raise SystemExit(1)
