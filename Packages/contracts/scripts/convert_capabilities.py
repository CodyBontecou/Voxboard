#!/usr/bin/env python3
"""Deterministically convert the frozen M0 ledger into the M1 product inventory."""
import argparse, hashlib, json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[3]
SOURCE=ROOT/'docs/architecture/android-wear-m0-capabilities.json'
OUTPUT=ROOT/'Packages/contracts/product-capabilities.json'
CLOSURE='29ec869c8bda4d511af787af394658d0274b339b'
HEALTH='c70de9201ab7cfbadf2442183dfba23c0d248478'
CLASS={'shared':'shared','native':'native','adjusted':'adjusted'}
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def convert():
    src=json.loads(SOURCE.read_text())
    caps=[]
    for c in src['capabilities']:
        if c['owner'] not in CLASS: raise ValueError(f"unknown M0 owner: {c['owner']}")
        item={k:c[k] for k in ('id','outcome','evidence','platforms')}
        item.update(classification=CLASS[c['owner']], legacyParity=c['parity'], programScope=c['programScope'], milestone=c['milestone'], dependencies=c['dependencies'])
        item['acceptance']=[dict({'mappingID':f"{c['id']}.acceptance.{i+1}"},**a) for i,a in enumerate(c['acceptance'])]
        item['status']=c['status']; caps.append(item)
    return {'schemaVersion':1,'producerRevision':CLOSURE,'healthMdPrecedent':HEALTH,'source':{'path':str(SOURCE.relative_to(ROOT)),'sha256':digest(SOURCE)},'dependencyCatalog':src['dependencyCatalog'],'capabilities':caps}
def encoded(x): return (json.dumps(x,ensure_ascii=False,indent=2,sort_keys=True)+'\n').encode()
def main():
 p=argparse.ArgumentParser(); p.add_argument('--check',action='store_true'); a=p.parse_args(); data=encoded(convert())
 if a.check:
  if not OUTPUT.exists() or OUTPUT.read_bytes()!=data: raise SystemExit('product-capabilities.json drift; run convert_capabilities.py')
  print('Product capability conversion is deterministic and current.')
 else:
  OUTPUT.write_bytes(data); print(f'Wrote {OUTPUT.relative_to(ROOT)}')
if __name__=='__main__': main()
