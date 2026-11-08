#!/usr/bin/env python3
"""Minimal liblp (Android dynamic partitions) unpacker.

Parses super.img metadata and extracts logical partitions.
Self-validates by recomputing the SHA256 table/header checksums.
"""
import argparse, hashlib, os, struct, sys

SECTOR = 512
GEOM_MAGIC = 0x616C4467
HDR_MAGIC = 0x414C5030
RESERVED = 4096
GEOM_SIZE = 4096

def u(fmt, buf, off):
    return struct.unpack_from(fmt, buf, off)

class Meta:
    pass

def parse_geometry(f):
    f.seek(RESERVED)
    buf = f.read(GEOM_SIZE)
    magic, struct_size = u('<II', buf, 0)
    if magic != GEOM_MAGIC:
        # try backup
        f.seek(RESERVED + GEOM_SIZE)
        buf = f.read(GEOM_SIZE)
        magic, struct_size = u('<II', buf, 0)
        if magic != GEOM_MAGIC:
            raise SystemExit('not a super image: geometry magic missing')
    checksum = buf[8:40]
    max_size, slot_count, lbs = u('<III', buf, 40)
    body = bytearray(buf[:struct_size])
    body[8:40] = b'\0' * 32
    if hashlib.sha256(bytes(body)).digest() != checksum:
        raise SystemExit('geometry checksum mismatch (parser or image bad)')
    g = Meta(); g.max_size, g.slot_count, g.lbs = max_size, slot_count, lbs
    return g

def parse_metadata(f, geom, slot=0):
    off = RESERVED + GEOM_SIZE * 2 + geom.max_size * slot
    f.seek(off)
    hdr = f.read(256)
    magic, major, minor, header_size = u('<IHHI', hdr, 0)
    if magic != HDR_MAGIC:
        raise SystemExit('metadata header magic missing at slot %d' % slot)
    header_checksum = hdr[12:44]
    tables_size, = u('<I', hdr, 44)
    tables_checksum = hdr[48:80]
    descs = []
    for i in range(4):
        descs.append(u('<III', hdr, 80 + i * 12))  # offset, num_entries, entry_size
    h = bytearray(hdr[:header_size])
    h[12:44] = b'\0' * 32
    if hashlib.sha256(bytes(h)).digest() != header_checksum:
        raise SystemExit('header checksum mismatch')
    f.seek(off + header_size)
    tables = f.read(tables_size)
    if hashlib.sha256(tables).digest() != tables_checksum:
        raise SystemExit('tables checksum mismatch')

    (p_off, p_n, p_sz), (e_off, e_n, e_sz), (g_off, g_n, g_sz), (b_off, b_n, b_sz) = descs
    m = Meta()
    m.version = (major, minor)
    m.partitions = []
    for i in range(p_n):
        o = p_off + i * p_sz
        name = tables[o:o + 36].split(b'\0')[0].decode()
        attrs, first_extent, num_extents, group = u('<IIII', tables, o + 36)
        m.partitions.append(dict(name=name, attrs=attrs, first=first_extent,
                                 count=num_extents, group=group))
    m.extents = []
    for i in range(e_n):
        o = e_off + i * e_sz
        num_sectors, target_type = u('<QI', tables, o)
        target_data, target_source = u('<QI', tables, o + 12)
        m.extents.append(dict(sectors=num_sectors, type=target_type,
                              data=target_data, source=target_source))
    m.block_devices = []
    for i in range(b_n):
        o = b_off + i * b_sz
        first_sector, alignment, align_off, size = u('<QIIQ', tables, o)
        name = tables[o + 24:o + 60].split(b'\0')[0].decode()
        m.block_devices.append(dict(first_sector=first_sector, size=size, name=name))
    return m

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('super_img')
    ap.add_argument('outdir', nargs='?')
    ap.add_argument('-p', '--partition', action='append', default=[])
    ap.add_argument('-l', '--list', action='store_true')
    ap.add_argument('-s', '--slot', type=int, default=0)
    a = ap.parse_args()

    with open(a.super_img, 'rb') as f:
        geom = parse_geometry(f)
        m = parse_metadata(f, geom, a.slot)
        print('liblp v%d.%d  slot=%d  block=%d  partitions=%d' %
              (m.version[0], m.version[1], a.slot, geom.lbs, len(m.partitions)))
        for p in m.partitions:
            size = sum(m.extents[p['first'] + i]['sectors'] for i in range(p['count'])) * SECTOR
            print('  %-18s %12d bytes  extents=%d' % (p['name'], size, p['count']))
        if a.list:
            return
        if not a.outdir:
            raise SystemExit('outdir required')
        os.makedirs(a.outdir, exist_ok=True)
        want = set(a.partition)
        for p in m.partitions:
            if want and p['name'] not in want:
                continue
            out = os.path.join(a.outdir, p['name'] + '.img')
            with open(out, 'wb') as o:
                for i in range(p['count']):
                    e = m.extents[p['first'] + i]
                    if e['type'] != 0:  # ZERO target
                        o.write(b'\0' * (e['sectors'] * SECTOR))
                        continue
                    f.seek(e['data'] * SECTOR)
                    left = e['sectors'] * SECTOR
                    while left:
                        chunk = f.read(min(left, 8 << 20))
                        if not chunk:
                            raise SystemExit('short read on %s' % p['name'])
                        o.write(chunk)
                        left -= len(chunk)
            print('extracted %s -> %s (%d bytes)' % (p['name'], out, os.path.getsize(out)))

if __name__ == '__main__':
    main()
