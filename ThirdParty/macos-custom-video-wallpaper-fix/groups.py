import struct,sys
def boxes(buf,s,e):
    p=s;o=[]
    while p<e-8:
        sz=struct.unpack('>I',buf[p:p+4])[0];t=buf[p+4:p+8];h=8
        if sz==1:sz=struct.unpack('>Q',buf[p+8:p+16])[0];h=16
        elif sz==0:sz=e-p
        o.append((t,p,sz,h))
        if sz<=0:break
        p+=sz
    return o
def find(buf,path,s=0,e=None):
    if e is None:e=len(buf)
    cs,ce=s,e;r=None
    for name in path:
        f=None
        for t,p,sz,h in boxes(buf,cs,ce):
            if t==name.encode():f=(t,p,sz,h);break
        if not f:return None
        r=f;c=f[1]+f[3]
        if name=='stsd':c+=8
        if name in('hvc1','hev1'):c+=78
        cs,ce=c,f[1]+f[2]
    return r
buf=open(sys.argv[1],'rb').read()
stbl=find(buf,['moov','trak','mdia','minf','stbl'])
print(f"  {sys.argv[1].split('/')[-1]}:")
for t,p,sz,h in boxes(buf,stbl[1]+stbl[3],stbl[1]+stbl[2]):
    tn=t.decode('latin1')
    if tn in ('sgpd','sbgp','csgm'):
        # grouping_type is 4 bytes after version/flags(4)
        gt=buf[p+12:p+16].decode('latin1','replace')
        print(f"    [{tn}] grouping_type='{gt}' size={sz}")
