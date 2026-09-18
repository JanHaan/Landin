#!/usr/bin/env python3
"""Compiler-host checks of the complete driver's manual lifetime boundary."""
import argparse
import json
from pathlib import Path
import re
import subprocess

HERE=Path(__file__).resolve().parent
ROOT=HERE.parents[2]
CASES={
 'frame-buffer': ('start: () -> none =\n    mut local: [8]u8 = zeroed\n    _ = uart.open(115200,32,local[0..<8]) else (problem)\n        _ = problem\n        return\n    end\nend start\n','L0314'),
 'readonly-buffer': ('data: [8]u8 = zeroed\nstart: () -> none =\n    _ = uart.open(115200,32,data[0..<8]) else (problem)\n        _ = problem\n        return\n    end\nend start\n','L0301'),
 'missing-derivation': ('wrap: (escaping buf: []mut u8) -> (r: uart.rx) ! ... =\n    r = try uart.open(115200,32,buf)\nend wrap\n','L0316'),
}

def main():
 p=argparse.ArgumentParser(description=__doc__)
 p.add_argument('--refine',type=Path,required=True)
 p.add_argument('--output',type=Path,required=True)
 a=p.parse_args();a.output.mkdir(parents=True,exist_ok=False)
 records=[]
 for name,(body,expected) in CASES.items():
  d=a.output/name;d.mkdir();source=d/'main.ldn'
  source.write_text('import drivers/uart\n'+body)
  argv=[str(a.refine.resolve()),'--root='+str(HERE),'--root='+str(ROOT/'devices/generated'),
        '--root='+str(ROOT),'--target=cortex-m0',str(d.resolve())]
  result=subprocess.run(argv,capture_output=True,text=True,timeout=30)
  (d/'stdout.txt').write_text(result.stdout);(d/'stderr.txt').write_text(result.stderr)
  actual=re.findall(r'error\[(L\d+)\]',result.stderr)
  records.append({'case':name,'argv':argv,'timeout_seconds':30,'exit':result.returncode,
                  'expected':[expected],'actual':actual})
  (a.output/'result.json').write_text(json.dumps(records,indent=2)+'\n')
  if result.returncode!=1 or actual!=[expected]:
   raise RuntimeError(name+': expected '+expected+', got '+repr(actual))
 print('R690_SOURCE_REFUSALS_PASS '+str(len(records)))

if __name__=='__main__': main()
