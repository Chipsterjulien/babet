#!/usr/bin/env python3
"""Native TextView tag contracts and external file drops, including old GTK."""
import os
from pathlib import Path
import shlex
import sys
import tempfile
from test_gui_widgets import run, ROOT

def main():
    binary=str(Path(sys.argv[1]).resolve());passed=0
    flags={'OFF':[], 'UBSAN':['-fsanitize=undefined'], 'ASAN_UBSAN':['-fsanitize=address,undefined','-fno-omit-frame-pointer']}[os.getenv('BABET_TEST_GUI_SANITIZERS','OFF')]
    with tempfile.TemporaryDirectory(prefix='babet-gui-rich-') as directory:
        folder=Path(directory);libraries={}
        for name,defines in [('full',[]),('no-tags',['BABET_FAKE_GTK_NO_TEXT_TAGS']),('no-files',['BABET_FAKE_GTK_NO_FILE_DROP'])]:
            lib=folder/name;lib.mkdir();libraries[name]=lib
            run([*shlex.split(os.getenv('CC','cc')),'-std=c99','-Wall','-Wextra','-Werror','-fPIC','-shared',*flags,*['-D'+d for d in defines],str(ROOT/'tests/gui/fake_gtk4_runtime.c'),'-o',str(lib/'libgtk-4.so.1')])
        for mode in ['full','unavailable','allocation','table-failure']:
            log=folder/'native.log';log.unlink(missing_ok=True)
            env={k:v for k,v in os.environ.items() if not k.startswith('BABET_FAKE_GTK_')}
            env.update(LD_LIBRARY_PATH=str(libraries['no-tags' if mode=='unavailable' else 'full']),BABET_FAKE_GTK_LOG=str(log))
            if mode=='allocation':env['BABET_FAKE_GTK_TAG_FAIL']='1'
            if mode=='table-failure':env['BABET_FAKE_GTK_TAG_ADD_FAIL']='1'
            result=run([binary,str(ROOT/'tests/gui/text_tags_contract.lua'),'allocation' if mode=='table-failure' else mode],env)
            assert 'TEXT_TAGS_OK' in result.stdout,result.stdout
            if mode=='full':
                for prop in ['foreground=#123abc','background=#abcdef','underline=1','strikethrough=1','weight=700','style=2','scale=1.25']:assert 'tag-property:'+prop in log.read_text(),prop
            print('[PASS] TextView tags '+mode);passed+=1
        for mode in ['files','mixed','delayed','mixed-delayed','mixed-remote','source-copy','hover-copy','nested','nested-move-only','nested-enter','remote','default','configure-late','reject','hover-reject','callback-error','close','disable','reconfigure','unavailable']:
            log=folder/'native.log';log.unlink(missing_ok=True)
            env={k:v for k,v in os.environ.items() if not k.startswith('BABET_FAKE_GTK_')}
            env.update(LD_LIBRARY_PATH=str(libraries['no-files' if mode=='unavailable' else 'full']),BABET_FAKE_GTK_LOG=str(log),BABET_FAKE_GTK_DROP_FILES='1')
            if mode in ['remote','mixed-remote']:env['BABET_FAKE_GTK_REMOTE_FILES']='1'
            if mode=='source-copy':env['BABET_FAKE_GTK_DROP_SOURCE_ACTIONS']='1'
            if mode.startswith('nested'):env['BABET_FAKE_GTK_DROP_NESTED']='1'
            if mode=='nested-enter':env['BABET_FAKE_GTK_DROP_ENTER_ONLY']='1'
            if 'delayed' in mode:env['BABET_FAKE_GTK_DELAY_FILES']='1'
            result=run([binary,str(ROOT/'tests/gui/file_drop_contract.lua'),mode],env)
            assert 'FILE_DROP_OK' in result.stdout,result.stdout
            if mode=='callback-error':assert 'FILE_DROP_SENTINEL' in result.stderr,result.stderr
            if mode!='unavailable':
                expected='filtered' if mode=='default' else 'refused' if mode in ['remote','reject','hover-reject','callback-error','disable','reconfigure','nested-move-only'] else 'accepted'
                assert 'files:'+expected in log.read_text(),log.read_text()
                if mode.startswith('nested'):assert 'files:negotiated:'+('move' if mode=='nested-enter' else 'copy') in log.read_text(),log.read_text()
            print('[PASS] file drop '+mode);passed+=1
    print(f'GUI rich text/files: {passed} PASS / 0 FAIL')
if __name__=='__main__':
    try:main()
    except Exception as e:print('[FAIL] GUI rich text/files:',e,file=sys.stderr);sys.exit(1)
