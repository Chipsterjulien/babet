#!/usr/bin/env python3
"""Context, binary resources, strict globals and exists in all three launch modes."""
from pathlib import Path
import subprocess,sys,tempfile
SCRIPT=r'''
local b=babet;local info=assert(b.runtimeInfo());assert(info.mode==arg[1],info.mode)
assert(info.executablePath:sub(1,1)=='/');info.mode='changed';assert(b.runtimeInfo().mode==arg[1])
local dir=arg[2]
assert(b.exists(dir)and not b.fileExists(dir));assert(b.exists(dir..'/plain.txt'));assert(b.exists(dir..'/link'))
assert(not b.exists(dir..'/absent'));assert(not b.exists(dir..'/plain.txt/child'))
if arg[1]=='embedded' then
 assert(info.projectDir==nil and info.scriptPath=='main.lua')
 assert(b.embedded.read('binary.dat')=='\0\255\r\n\239\187\191#data')
 assert(b.embedded.read('empty')=='');assert(b.embedded.read('été.txt')=='unicode');assert(b.embedded.read('BINARY.dat')==nil)
 local names=assert(b.embedded.list());assert(#names==4);for i=2,#names do assert(names[i-1]<names[i])end
else
 assert(info.projectDir==dir..'/project');assert(info.scriptPath==dir..'/project/main.lua')
 assert(b.embedded.read('main.lua')==nil and b.embedded.list()==nil)
end
assert(not pcall(b.embedded.read,'a\0b'))
assert(b.strict());local strict_ok,strict_err=pcall(function()return NEVER_DEFINED_RUNTIME_TEST end)
assert(not strict_ok and strict_err:find('undefined global variable: NEVER_DEFINED_RUNTIME_TEST',1,true),strict_err);assert(rawget(_G,'NEVER_DEFINED_RUNTIME_TEST')==nil)
NEW_GLOBAL_RUNTIME_TEST=3;assert(NEW_GLOBAL_RUNTIME_TEST==3);assert(b.strict(false));assert(NEVER_DEFINED_RUNTIME_TEST==nil)
local foreign={__index=function()return 17 end};setmetatable(_G,foreign)
local ok,err=b.strict();assert(ok==nil and type(err)=='string' and getmetatable(_G)==foreign);assert(b.strict(false)==nil);setmetatable(_G,nil)
if b.workers then
 local job=assert(b.workers.spawn([[
  local i=assert(babet.runtimeInfo());assert(i.mode==worker.args.mode);assert(i.projectDir==worker.args.dir)
  if i.mode=='embedded' then assert(babet.embedded.read('empty')=='')end
  return true
 ]],{mode=arg[1],dir=arg[1]~='embedded' and info.projectDir or nil}))
 local success,value=job:join(10);assert(success and value,tostring(value))
end
print('RUNTIME_INFO_OK:'..arg[1])
'''
def run(cmd):
    p=subprocess.run(cmd,text=True,capture_output=True,timeout=45)
    assert p.returncode==0,(cmd,p.returncode,p.stdout,p.stderr)
    return p

def main():
    binary=str(Path(sys.argv[1]).resolve())
    with tempfile.TemporaryDirectory(prefix='babet-resources-')as temp:
        root=Path(temp);proj=root/'project';proj.mkdir();(proj/'main.lua').write_text(SCRIPT)
        (proj/'binary.dat').write_bytes(b'\0\xff\r\n\xef\xbb\xbf#data');(proj/'empty').write_bytes(b'');(proj/'été.txt').write_text('unicode')
        (root/'plain.txt').write_text('plain');(root/'link').symlink_to(root/'plain.txt')
        # A trailing slash (like `babet .`) must not leak into projectDir.
        for mode,target,label in [('file',str(proj/'main.lua'),'file'),('directory',str(proj),'directory'),('directory',str(proj)+'/','directory with trailing slash')]:
            p=run([binary,target,mode,temp]);assert 'RUNTIME_INFO_OK:'+mode in p.stdout;print('[PASS] runtime context/resources '+label)
        app=root/'application';run([binary,'-c',str(proj),str(app)]);proj.rename(root/'source-hidden')
        p=run([str(app),'embedded',temp]);assert 'RUNTIME_INFO_OK:embedded' in p.stdout
        print('[PASS] runtime context/resources embedded without source directory')
    print('Runtime information/resources: 4 PASS / 0 FAIL')
if __name__=='__main__':
    try:main()
    except Exception as e:print('[FAIL] runtime information:',e,file=sys.stderr);sys.exit(1)
