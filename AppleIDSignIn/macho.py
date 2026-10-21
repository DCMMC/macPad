import struct,hashlib,json,collections
from pathlib import Path
B=Path(__file__).parent
H=lambda b:hashlib.sha256(b).hexdigest()
def thin(b):
 if b[:4] in [b'\xca\xfe\xba\xbe',b'\xca\xfe\xba\xbf']:
  n=struct.unpack_from('>I',b,4)[0];wide=b[3]==0xbf;size=32 if wide else 20
  return [b[int(struct.unpack_from('>IIQQII' if wide else '>IIIII',b,8+i*size)[2]):][:int(struct.unpack_from('>IIQQII' if wide else '>IIIII',b,8+i*size)[3])] for i in range(n)]
 return [b]
def parse(b):
 if b[:4] not in [b'\xcf\xfa\xed\xfe',b'\xce\xfa\xed\xfe']:return None
 wide=b[0]==0xcf;hdr=struct.unpack_from('<8I' if wide else '<7I',b,0);cpu,sub,n,cs=hdr[1],hdr[2],hdr[4],hdr[5];off=32 if wide else 28
 sections={};deps=[];uuid=None;cmds=[];sig=None
 for _ in range(n):
  cmd,size=struct.unpack_from('<II',b,off);assert size>=8 and off+size<=len(b)
  raw=b[off:off+size]
  if cmd==0x1b:uuid=raw[8:24].hex()
  if cmd==0x1d:sig=struct.unpack_from('<II',raw,8)
  if cmd in [0xc,0x80000018,0x8000001f,0x80000023,0x20]:
   idx=struct.unpack_from('<I',raw,8)[0];deps.append({'cmd':hex(cmd),'name':raw[idx:].split(b'\0')[0].decode(errors='replace')})
  if cmd==0x19:
   seg=raw[8:24].split(b'\0')[0].decode();count=struct.unpack_from('<I',raw,64)[0]
   for i in range(count):
    so=72+i*80;name=raw[so:so+16].split(b'\0')[0].decode();ss,fo=struct.unpack_from('<QI',raw,so+40);flags=struct.unpack_from('<I',raw,so+64)[0];kind=flags&0xff
    if kind not in [1,12,18] and fo+ss<=len(b):sections[seg+','+name]={'size':ss,'sha256':H(b[fo:fo+ss])}
  cmds.append({'cmd':hex(cmd),'size':size,'sha256':H(raw)});off+=size
 return {'cpu':cpu,'subtype':sub,'uuid':uuid,'sections':sections,'dependencies':deps,'load_commands':cmds,'signature':sig,'size':len(b)}
