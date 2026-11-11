#!/usr/bin/env python3
"""Exercise production scheduler/process callbacks against deterministic GTK."""
import os,re,shlex,sys,tempfile
from pathlib import Path
from test_gui_widgets import ROOT,run

def main():
    binary=str(Path(sys.argv[1]).resolve())
    flags={'OFF':[],'UBSAN':['-fsanitize=undefined'],'ASAN_UBSAN':['-fsanitize=address,undefined','-fno-omit-frame-pointer']}[os.getenv('BABET_TEST_GUI_SANITIZERS','OFF')]
    with tempfile.TemporaryDirectory(prefix='babet-events-') as tmp:
        run([*shlex.split(os.getenv('CC','cc')),'-std=c99','-Wall','-Wextra','-Werror','-shared','-fPIC',*flags,str(ROOT/'tests/gui/fake_gtk4_runtime.c'),'-o',tmp+'/libgtk-4.so.1'])
        env={k:v for k,v in os.environ.items() if not k.startswith('BABET_FAKE_GTK_')};env['LD_LIBRARY_PATH']=tmp
        for mode,token in [('contract','EVENT_LOOP_OK'),('cancel','EVENT_CANCEL_OK'),('draw','EVENT_DRAW_OK'),('errors','EVENT_ERRORS_OK')]:
            p=run([binary,str(ROOT/f'tests/gui/event_loop_{mode}.lua')],env);assert token in p.stdout,p.stdout
            if mode=='errors':
                for s in ['DEFAULT_TRACE_SENTINEL','SIGNAL_TRACE_SENTINEL','HANDLER_TRACE_SENTINEL','ORIGINAL_TRACE_SENTINEL','stack traceback']:assert s in p.stderr,p.stderr
                # The stderr prefixes are documented: one per module.
                for pattern in [r'^babet\.gui callback error: .*DEFAULT_TRACE_SENTINEL',r'^babet\.signal callback error: .*SIGNAL_TRACE_SENTINEL']:assert re.search(pattern,p.stderr,re.M),p.stderr
                assert 'babet callback error' not in p.stderr,p.stderr
            else:assert 'callback error' not in p.stderr,p.stderr
            print('[PASS] GUI event loop '+mode)
    print('GUI event loop: 4 PASS / 0 FAIL')
if __name__=='__main__':
    try:main()
    except Exception as e:print('[FAIL] GUI event loop:',e,file=sys.stderr);sys.exit(1)
