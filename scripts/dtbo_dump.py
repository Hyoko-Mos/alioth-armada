import struct
import sys

DTBO_MAGIC = 0xD7B7AB1E
FDT_MAGIC = 0xD00DFEED

FDT_BEGIN_NODE = 1
FDT_END_NODE = 2
FDT_PROP = 3
FDT_NOP = 4
FDT_END = 9


def split_dtbo(blob):
    """Yield each embedded FDT blob from an Android DTBO image."""
    magic, total, hdr_size, ent_size, ent_count, ent_off = struct.unpack_from(">6I", blob, 0)
    if magic != DTBO_MAGIC:
        raise SystemExit("not a DTBO image: magic=0x%08x" % magic)
    print(f"dtbo: total={total} entries={ent_count} ent_size={ent_size} off={ent_off}")
    for i in range(ent_count):
        # dtbo_entry: dtb_size, dtb_offset, id, rev
        size, off, dtb_id, _rev = struct.unpack_from(">4I", blob, ent_off + i * ent_size)
        if size == 0:
            continue
        yield i, off, size, dtb_id, blob[off:off + size]


def parse_fdt(buf):
    """Return (root, path_map) where path_map maps path -> (props, children)."""
    magic, totalsize, off_struct, off_strings = struct.unpack_from(">4I", buf, 0)
    if magic != FDT_MAGIC:
        raise ValueError("bad fdt magic 0x%08x" % magic)
    size_strings = struct.unpack_from(">I", buf, 32)[0]

    strings = buf[off_strings:off_strings + size_strings]
    pos = off_struct
    path = []
    tree = {"__props": {}, "__children": {}, "__name": ""}
    cur = tree
    stack = []

    while True:
        tok = struct.unpack_from(">I", buf, pos)[0]
        pos += 4
        if tok == FDT_BEGIN_NODE:
            end = buf.index(b"\0", pos)
            name = buf[pos:end].decode("utf-8", "replace")
            pos = (end + 4) & ~3
            node = {"__props": {}, "__children": {}, "__name": name}
            cur["__children"][name] = node
            stack.append(cur)
            cur = node
            path.append(name)
        elif tok == FDT_END_NODE:
            cur = stack.pop()
            path.pop()
        elif tok == FDT_PROP:
            ln, nameoff = struct.unpack_from(">2I", buf, pos)
            pos += 8
            data = buf[pos:pos + ln]
            pos = (pos + ln + 3) & ~3
            end = strings.index(b"\0", nameoff)
            pname = strings[nameoff:end].decode("utf-8", "replace")
            cur["__props"][pname] = data
        elif tok == FDT_NOP:
            continue
        elif tok == FDT_END:
            break
        else:
            raise ValueError("bad token 0x%x at %d" % (tok, pos))
    return tree


def fmt(data):
    if not data:
        return "<empty>"
    try:
        s = data.decode("utf-8")
        if s.isprintable() and s.endswith("\0"):
            return repr(s.rstrip("\0"))
    except UnicodeDecodeError:
        pass
    if len(data) % 4 == 0 and len(data) <= 32:
        vals = struct.unpack(">%dI" % (len(data) // 4), data)
        return " ".join("0x%x" % v for v in vals)
    return data.hex()


def walk(node, prefix, out, needle, depth=0):
    name = node["__name"]
    path = f"{prefix}/{name}" if name else prefix or "/"
    hit = needle.lower() in path.lower()
    if hit:
        out.append(path)
        for k, v in node["__props"].items():
            out.append(f"    {k} = {fmt(v)}")
    for child in node["__children"].values():
        walk(child, path, out, needle, depth + 1)


def main():
    blob = open(sys.argv[1], "rb").read()
    needle = sys.argv[2] if len(sys.argv) > 2 else "cs35l41"
    for idx, off, size, dtb_id, fdt in split_dtbo(blob):
        try:
            tree = parse_fdt(fdt)
        except Exception as exc:
            print(f"[{idx}] off={off} size={size} id=0x{dtb_id:x} -> parse error: {exc}")
            continue
        root = tree["__children"].get("", None)
        model = ""
        if root:
            m = root["__props"].get("model", b"")
            model = m.rstrip(b"\0").decode("utf-8", "replace")
        out = []
        if root:
            walk(root, "", out, needle)
        print(f"[{idx}] off={off} size={size} id=0x{dtb_id:x} model={model!r} matches={sum(1 for l in out if not l.startswith('    '))}")
        for line in out:
            print(line)


if __name__ == "__main__":
    main()
