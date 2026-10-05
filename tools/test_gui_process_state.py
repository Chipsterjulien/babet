#!/usr/bin/env python3
"""Process-global mutation guards before/after real GTK loader paths."""
from pathlib import Path
import os
import shlex
import subprocess
import sys
import tempfile


LUA = r'''
local gui=babet.gui
local count=0
local function check(fn) fn();count=count+1 end
local original_dir=assert(babet.currentDir())
local original_locale=assert(os.setlocale())
local function mutable()
    assert(babet.setenv('BABET_GUI_STATE_TEST','before'))
    assert(os.setlocale(original_locale))
    assert(babet.chdir(original_dir))
end
check(mutable)
check(function() assert(not pcall(gui.available,true));mutable() end)
check(function() assert(not pcall(gui.init,true));mutable() end)
local function thread_count()
    local f=assert(io.open('/proc/self/status'))
    local text=f:read('*a');f:close()
    return assert(tonumber(text:match('Threads:%s*(%d+)')))
end
local threads_before=thread_count()
local a,e
if arg[1]=='available' then a,e=gui.available()
elseif arg[1]=='coroutine' then a,e=coroutine.wrap(function()return gui.available()end)()
elseif arg[1]=='missing' then a,e=gui.available();assert(a==nil and type(e)=='string')
else a,e=gui.init() end
if arg[1]=='init-fail' then assert(a==nil and type(e)=='string')
elseif arg[1]~='missing' then assert(a,e) end
check(function()
    if arg[1]=='available' or arg[1]=='coroutine' or arg[1]=='init' then
        assert(thread_count()>threads_before,'native fixture thread missing')
    end
end)
check(function()
    local ok,err=babet.setenv('BABET_GUI_STATE_TEST','after')
    assert(ok==nil and tostring(err):find('GTK',1,true),'setenv remained allowed after GTK load')
    assert(babet.env('BABET_GUI_STATE_TEST')=='before')
end)
check(function()
    local ok,err=babet.chdir(arg[2])
    assert(ok==nil and tostring(err):find('GTK',1,true),'chdir remained allowed after GTK load')
    assert(babet.currentDir()==original_dir)
end)
check(function()
    for _,locale in ipairs({original_locale,'','C'}) do
        local ok,err=pcall(os.setlocale,locale)
        assert(not ok and tostring(err):find('GTK',1,true),'locale remained mutable after GTK load')
    end
    assert(os.setlocale()==original_locale and os.setlocale(nil,'numeric'))
end)
check(function()
    assert(coroutine.wrap(function()
        assert(babet.setenv('BABET_GUI_STATE_TEST','again')==nil)
        assert(not pcall(require('os').setlocale,original_locale))
        return os.setlocale()==original_locale
    end)())
end)
check(function()
    -- Repeated success/failure never thaws state.
    gui.available();gui.init();assert(babet.setenv('BABET_GUI_STATE_TEST','retry')==nil)
end)
check(function()
    local job=assert(babet.workers.spawn([[
        assert(babet.setenv('BABET_GUI_STATE_TEST','worker')==nil)
        assert(not pcall(os.setlocale,'C'))
        assert(not pcall(babet.gui.available))
        return babet.env('BABET_GUI_STATE_TEST')
    ]]))
    local ok,result=job:join(5);assert(ok and result=='before',tostring(result))
    assert(babet.setenv('BABET_GUI_STATE_TEST','joined')==nil)
end)
assert(count==10)
print('GUI process state: 10 PASS')
'''


def run(args, **kwargs):
    result=subprocess.run([str(x) for x in args],capture_output=True,text=True,timeout=40,**kwargs)
    if result.returncode:
        raise AssertionError(f'{args}: exit={result.returncode}\n{result.stdout}{result.stderr}')
    return result.stdout


def main():
    if len(sys.argv)!=2:
        raise SystemExit('Usage: test_gui_process_state.py /path/to/babet')
    binary=Path(sys.argv[1]).resolve();source=Path(__file__).resolve().parents[1]
    with tempfile.TemporaryDirectory(prefix='babet-gui-state-') as temp:
        root=Path(temp);project=root/'project';project.mkdir()
        (project/'main.lua').write_text(LUA)
        other=root/'other';other.mkdir()
        for name,fixture in [('native','fake_gtk4_process_state.c'),('init-fail','fake_gtk4_init_fail.c'),('missing','fake_gtk4_missing_symbol.c')]:
            folder=root/name;folder.mkdir()
            run([*shlex.split(os.environ.get('CC','cc')),'-std=c11','-Wall','-Wextra','-Werror','-fPIC','-shared','-pthread',
                 '-Wl,-soname,libgtk-4.so.1',source/'tests/gui'/fixture,'-ldl','-o',folder/'libgtk-4.so.1'])
        app=root/'application';run([binary,'--create-exe',project,app])
        for mode,command in [('file',[binary,project/'main.lua']),('folder',[binary,project]),('embedded',[app])]:
            for scenario in ('available','coroutine','init','init-fail','missing'):
                library=root/(scenario if scenario in ('init-fail','missing') else 'native')
                output=run([*command,scenario,other],cwd=root,env=dict(os.environ,LD_LIBRARY_PATH=str(library)))
                if 'GUI process state: 10 PASS' not in output:
                    raise AssertionError(f'{mode}/{scenario}: missing completion marker\n{output}')
                print(f'[PASS] {mode}/{scenario}: 10 process-state guards',flush=True)
    print('GUI process state runtime: 150 PASS / 0 FAIL',flush=True)


if __name__=='__main__':
    try:
        main()
    except (AssertionError,OSError,subprocess.SubprocessError) as error:
        print(f'[FAIL] GUI process state: {error}',file=sys.stderr)
        raise SystemExit(1)
