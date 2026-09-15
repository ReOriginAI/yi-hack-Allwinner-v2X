#!/usr/bin/env python3
"""Hash before inspection; inventory extracted vendor files and ELF interfaces.

Input is a PRIVATE evidence directory containing home/, original/app/ and
backup/. Keep strings/disassembly/private recordings outside version control.
"""
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('evidence',type=Path)
p.add_argument('output',type=Path)
a = p.parse_args()
report=[]
for tree in ('home','original'):
    for path in sorted((a.evidence/tree).rglob('*')):
        if path.is_symlink():
            report.append({'path':str(path.relative_to(a.evidence)), 'symlink':str(path.readlink())})
            continue
        if not path.is_file(): continue
        data=path.read_bytes()
        r={'path':str(path.relative_to(a.evidence)), 'size':len(data),
           'mode':oct(path.stat().st_mode&0o777), 'md5':hashlib.md5(data).hexdigest(),
           'sha256':hashlib.sha256(data).hexdigest()}
        if data.startswith(b'\x7fELF'):
            r['file']=subprocess.check_output(['file','-b',str(path)],text=True).strip()
            dyn=subprocess.check_output(['readelf','-d',str(path)],text=True)
            sym=subprocess.check_output(['readelf','-Ws',str(path)],text=True)
            r['needed']=re.findall(r'Shared library: \[(.*?)\]',dyn)
            r['imports']=sorted(set(re.findall(r'\bUND\s+(\S+)',sym)))
            r['exports']=sorted(set(line.split()[-1] for line in sym.splitlines()
                if re.search(r'\b(GLOBAL|WEAK)\s+DEFAULT\s+(?!UND)\d+\s+\S+',line)))
        report.append(r)
a.output.write_text(json.dumps(report,indent=2)+'\n')
