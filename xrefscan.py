import struct, sys
path=sys.argv[1]; target=int(sys.argv[2],0)
b=open(path,'rb').read()
for off in range(0,len(b)-16,4):
    w=struct.unpack_from('<I',b,off)[0]
    # ARM LDR Rt,[pc,+/-imm12], immediate word load
    if (w & 0x0e5f0000) != 0x041f0000:
        continue
    # require load bit, immediate pre-index
    if not (w & (1<<20)) or not (w & (1<<24)):
        continue
    u=(w>>23)&1; imm=w&0xfff; rt=(w>>12)&15
    va=off+0x10000
    litva=va+8+(imm if u else -imm)
    litoff=litva-0x10000
    if not (0<=litoff<=len(b)-4): continue
    val=struct.unpack_from('<I',b,litoff)[0]
    for j in range(1,6):
        o2=off+4*j
        if o2+4>len(b): break
        w2=struct.unpack_from('<I',b,o2)[0]
        rd=(w2>>12)&15; rn=(w2>>16)&15; rm=w2&15
        # ADD Rd,pc,Rm (register, no shift)
        if (w2 & 0x0fe00ff0)==0x00800000 and rd==rt and rn==15 and rm==rt:
            got=(o2+0x10000+8+val)&0xffffffff
            if got==target:
                print(f'ldr_off=0x{off:x} ldr_va=0x{va:x} add_off=0x{o2:x} literal_off=0x{litoff:x} literal=0x{val:x}')
