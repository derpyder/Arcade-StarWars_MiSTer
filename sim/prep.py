#!/usr/bin/env python3
"""Prepare hex inputs for tb_drawer.

Reads:
  ../../starwars-mister/.tools/mame0287/snap/vec_T01500.bin  (16KB AVG memory)
  ../../starwars-mister/.tools/mame0287/roms/starwars.zip    (extracts AVG PROM)

Writes:
  sim/vec_mem.hex       (one hex byte per line, 16384 lines)
  sim/avg_prom.hex      (256 hex bytes, one per line)
"""

import os
import zipfile

HERE = os.path.dirname(__file__)
ROOT = os.path.abspath(os.path.join(HERE, '..'))
MAME = os.path.join(ROOT, '..', 'starwars-mister', '.tools', 'mame0287')

# 1. Vector memory: 16KB from the MAME dump
src_mem = os.path.join(MAME, 'snap', 'vec_T01500.bin')
with open(src_mem, 'rb') as f:
    mem = f.read()
assert len(mem) == 16384, f'unexpected mem size {len(mem)}'
with open(os.path.join(HERE, 'vec_mem.hex'), 'w') as f:
    for b in mem:
        f.write(f'{b:02x}\n')

# 2. AVG PROM: 256B from starwars.zip
src_zip = os.path.join(MAME, 'roms', 'starwars.zip')
with zipfile.ZipFile(src_zip) as z:
    prom = z.read('136021-109.4b')
assert len(prom) == 256, f'unexpected prom size {len(prom)}'
with open(os.path.join(HERE, 'avg_prom.hex'), 'w') as f:
    for b in prom:
        f.write(f'{b:02x}\n')

print(f'wrote vec_mem.hex ({len(mem)} bytes) and avg_prom.hex ({len(prom)} bytes)')
