#!/usr/bin/env python3
from pathlib import Path
import os,shlex,subprocess,tempfile
from runtime_abi import report

def main():
    with tempfile.TemporaryDirectory(prefix='babet-abi-')as temp:
        r=Path(temp);cc=shlex.split(os.getenv('CC','cc'))
        (r/'a.c').write_text('#include <stdio.h>\nint main(void){return puts("GLIBC_99.0")<0;}\n')
        subprocess.run([*cc,str(r/'a.c'),'-o',str(r/'app')],check=True)
        text=report(r/'app');assert 'GLIBC minimum:' in text and 'GLIBC minimum: no' not in text and '99.0' not in text,text
        (r/'bad').write_text('GLIBC_99.0')
        try:report(r/'bad')
        except subprocess.CalledProcessError:pass
        else:raise AssertionError('non-ELF accepted')
        (r/'lib.c').write_text('void not_imported(void){}\n');(r/'versions').write_text('GLIBC_99.0 { global: not_imported; };\n')
        subprocess.run([*cc,'-shared','-fPIC',str(r/'lib.c'),'-Wl,--version-script='+str(r/'versions'),'-o',str(r/'lib.so')],check=True)
        assert '99.0' not in report(r/'lib.so')
    print('[PASS] runtime ABI: imported versions only, strings/definitions ignored, invalid ELF rejected')
if __name__=='__main__':main()
