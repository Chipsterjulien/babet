#!/usr/bin/env python3
"""Inspect versioned ELF imports without executing the program."""
import argparse,os,re,subprocess
from pathlib import Path

def report(binary):
    def readelf(*args):
        return subprocess.run(['readelf',*args,str(binary)],check=True,text=True,capture_output=True,env=dict(os.environ,LC_ALL='C')).stdout
    requirements={name:{} for name in ('GLIBC','GLIBCXX','CXXABI')}
    for line in readelf('--dyn-syms','--wide').splitlines():
        if not re.search(r'\bUND\b',line):continue
        match=re.search(r'\b(\w+)@+(GLIBCXX|GLIBC|CXXABI)_(\d+(?:\.\d+)+)\b',line)
        if match:
            name,family,version=match.groups();requirements[family].setdefault(version,set()).add(name)
    lines=[f'Runtime ABI report: {Path(binary).name}','Versioned imports from this ELF only (not dlopen GTK/plugins, SDK, CPU ISA or kernel).']
    for family,versions in requirements.items():
        if versions:
            version=max(versions,key=lambda s:tuple(map(int,s.split('.'))));lines.append(f'{family} minimum: {version}; required by: '+', '.join(sorted(versions[version])))
        else:lines.append(f'{family} minimum: no versioned import found')
    needed=re.findall(r'\(NEEDED\).*?\[(.*?)\]',readelf('--dynamic','--wide'))
    lines.append('Direct shared libraries: '+(', '.join(needed)or 'none'))
    lines.append('Build all native dependencies on the oldest target distribution; test the resulting binary there.')
    return '\n'.join(lines)+'\n'

def main():
    p=argparse.ArgumentParser();p.add_argument('binary',type=Path);p.add_argument('--output',type=Path);a=p.parse_args();text=report(a.binary)
    if a.output:a.output.write_text(text)
    else:print(text,end='')
if __name__=='__main__':main()
