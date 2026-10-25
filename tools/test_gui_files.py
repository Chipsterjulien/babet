#!/usr/bin/env python3
"""Pictures and cancellable file dialogs against deterministic fake GTK."""
import os
from pathlib import Path
import shlex
import struct
import sys
import tempfile
import zlib
from test_gui_widgets import run, ROOT

def png_bytes():
    def chunk(kind,data):
        return struct.pack('>I',len(data))+kind+data+struct.pack('>I',zlib.crc32(kind+data))
    return b'\x89PNG\r\n\x1a\n'+chunk(b'IHDR',struct.pack('>IIBBBBB',80,40,8,2,0,0,0))+chunk(b'IDAT',zlib.compress((b'\0'+b'\xff\0\0'*80)*40))+chunk(b'IEND',b'')

def main():
    binary=str(Path(sys.argv[1]).resolve()); passed=0
    flags={'OFF':[], 'UBSAN':['-fsanitize=undefined'], 'ASAN_UBSAN':['-fsanitize=address,undefined','-fno-omit-frame-pointer']}[os.getenv('BABET_TEST_GUI_SANITIZERS','OFF')]
    with tempfile.TemporaryDirectory(prefix='babet-gui-files-') as tmp:
        tmp=Path(tmp); picture=tmp/'image.png';picture.write_bytes(png_bytes())
        bad=tmp/'bad.png';bad.write_text('invalid')
        libraries={}
        for variant,defines in [('full',[]),('no-fit',['BABET_FAKE_GTK_NO_CONTENT_FIT']),('no-texture',['BABET_FAKE_GTK_NO_TEXTURE_FILE','BABET_FAKE_GTK_NO_CONTENT_FIT']),('unavailable',['BABET_FAKE_GTK_NO_FILE_DIALOG'])]:
            folder=tmp/variant;folder.mkdir();libraries[variant]=folder
            run([*shlex.split(os.getenv('CC','cc')),'-std=c99','-Wall','-Wextra','-Werror','-fPIC','-shared',*flags,*['-D'+d for d in defines],str(ROOT/'tests/gui/fake_gtk4_runtime.c'),'-o',str(folder/'libgtk-4.so.1')])
        for mode in ['full','no-fit','no-texture']:
            env=dict(os.environ,LD_LIBRARY_PATH=str(libraries[mode]))
            result=run([binary,str(ROOT/'tests/gui/picture_contract.lua'),str(picture),mode,str(bad)],env)
            assert 'PICTURE_OK' in result.stdout;print('[PASS] picture '+mode);passed+=1
        modes=['open','save','multiple','cancel','error','remote','mixed','reentrant','callback-error','yield','close-parent','gc-parent','quit','close-state','coroutine','unavailable']
        modes += ['allocation-'+str(i) for i in [42,43,44,45,46]]
        for mode in modes:
            log=tmp/'gtk.log';log.unlink(missing_ok=True)
            env={k:v for k,v in os.environ.items() if not k.startswith('BABET_FAKE_GTK_')}
            env.update(LD_LIBRARY_PATH=str(libraries['unavailable' if mode=='unavailable' else 'full']),BABET_FAKE_GTK_LOG=str(log))
            env['BABET_FAKE_GTK_FILE_RESULT']=mode
            if mode in ['close-parent','gc-parent','quit','close-state']:env['BABET_FAKE_GTK_FILE_HOLD']='1'
            case=mode
            if mode.startswith('allocation-'):env['BABET_FAKE_GTK_FILE_FAIL']=mode.split('-')[1];case='allocation'
            result=run([binary,str(ROOT/'tests/gui/file_dialog_contract.lua'),case],env)
            assert 'FILE_OK:'+case in result.stdout, result.stdout
            assert 'CALLBACK_AFTER_CANCEL' not in result.stderr
            if mode=='callback-error':assert 'FILE_CALLBACK_SENTINEL' in result.stderr
            if mode=='yield':assert 'yield' in result.stderr
            if mode=='open':
                text=log.read_text()
                for expected in ['file-title:Choose image','file-modal:true','file-folder:/tmp','filter-name:Images','filter-pattern:*.png','filter-pattern:*.jpg','filter-mime:image/*']:assert expected in text,expected
            print('[PASS] file dialog '+mode);passed+=1
    print(f'GUI images/files: {passed} PASS / 0 FAIL')
if __name__=='__main__':
    try:main()
    except Exception as e:print('[FAIL] GUI files:',e,file=sys.stderr);sys.exit(1)
