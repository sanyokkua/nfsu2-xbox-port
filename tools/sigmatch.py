"""Find reference XBE functions in a target XBE by masked byte signature.
   tools/sigmatch.py <reference.xbe> <target.xbe> <hex va> ...   (capstone; .venv)"""
import struct, sys, re
from capstone import Cs, CS_ARCH_X86, CS_MODE_32
def load(p):
    d=open(p,'rb').read(); base,=struct.unpack_from('<I',d,0x104)
    n,sa=struct.unpack_from('<II',d,0x11C); secs=[]
    for i in range(n):
        o=sa-base+i*56; fl,va,vs,ra,rs,na=struct.unpack_from('<IIIIII',d,o)
        secs.append((d[na-base:na-base+12].split(b'\0')[0].decode(),va,vs,d[ra:ra+rs]))
    return secs
def read(secs,va,n):
    for nm,v,vs,b in secs:
        if v<=va<v+len(b): return b[va-v:va-v+n]
def sig(secs,va,n=64):
    code=read(secs,va,n+16); md=Cs(CS_ARCH_X86,CS_MODE_32); md.detail=True
    pat=b''; used=0
    for ins in md.disasm(code,va):
        if used>=n: break
        b=bytearray(ins.bytes); mask=[False]*len(b)
        # mask 4-byte immediates/displacements and rel branches
        if ins.imm_offset and ins.imm_size>=4: mask[ins.imm_offset:ins.imm_offset+ins.imm_size]=[True]*ins.imm_size
        if ins.disp_offset and ins.disp_size>=4: mask[ins.disp_offset:ins.disp_offset+ins.disp_size]=[True]*ins.disp_size
        if ins.group(7) or ins.mnemonic.startswith('j') or ins.mnemonic=='call':  # rel
            if ins.imm_offset: mask[ins.imm_offset:]=[True]*(len(b)-ins.imm_offset)
        for x,m in zip(b,mask): pat+= b'.' if m else re.escape(bytes([x]))
        used+=len(b)
        if ins.mnemonic in('ret','jmp') and used>=24: break
    return re.compile(pat,re.S),used
if __name__=="__main__":
  ref,tgt=load(sys.argv[1]),load(sys.argv[2])
  for a in sys.argv[3:]:
      va=int(a,16); r,used=sig(ref,va); hits=[]
      for nm,v,vs,b in tgt:
          for m in r.finditer(b): hits.append((nm,v+m.start()))
      print(f'{va:#010x} ({used}B): {[(n,hex(h)) for n,h in hits[:6]]}{" +more" if len(hits)>6 else ""}')
