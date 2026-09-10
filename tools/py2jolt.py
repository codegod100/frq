#!/usr/bin/env python3
"""Turn uniffi-bindgen's Python output into jolt `defcfn` declarations.

The Python backend emits, for every entry point in the library, a pair of
lines that together are an exact ABI description:

    _UniffiLib.uniffi_moq_ffi_fn_method_moqclient_connect.argtypes = (
        ctypes.c_uint64, _UniffiRustBuffer, ctypes.POINTER(_UniffiRustCallStatus),
    )
    _UniffiLib.uniffi_moq_ffi_fn_method_moqclient_connect.restype = ctypes.c_uint64

That is generated from the metadata embedded in the .so itself, so it matches
the object being bound rather than a header shipped alongside it -- which for
this release is a different build (the Apple artifact carries audio/ video, the
Linux and Android ones do not).
"""
import re, sys, collections

CTYPE = {
    "ctypes.c_int8": ":int8",     "ctypes.c_uint8": ":uint8",
    "ctypes.c_int16": ":int16",   "ctypes.c_uint16": ":uint16",
    "ctypes.c_int32": ":int32",   "ctypes.c_uint32": ":uint32",
    "ctypes.c_int64": ":int64",   "ctypes.c_uint64": ":uint64",
    "ctypes.c_float": ":float",   "ctypes.c_double": ":double",
    "ctypes.c_void_p": ":pointer", "ctypes.c_size_t": ":uint64",
    "None": ":void",
}
# A RustBuffer crosses by value; a status is always a pointer out-param.
RB = "[:by-value [:struct [[:capacity :uint64] [:len :uint64] [:data :pointer]]]]"
STATUS = ":pointer"

def conv(t):
    t = t.strip().rstrip(",").strip()
    if not t:
        return None
    if t in CTYPE:
        return CTYPE[t]
    if "RustCallStatus" in t:
        return STATUS
    if "RustBuffer" in t:
        return RB
    if "ForeignBytes" in t:
        return "[:by-value [:struct [[:len :int32] [:data :pointer]]]]"
    if t.startswith("ctypes.POINTER"):
        return ":pointer"
    # A function-pointer typedef (the future continuation) -- jolt lowers an
    # ffi/callback to a plain pointer, so that is what the slot takes.
    if "callback" in t.lower() or "struct" in t.lower():
        return ":pointer"
    return None  # unknown -- reported, never guessed

def split_args(s):
    out, depth, cur = [], 0, ""
    for ch in s:
        if ch == "(":
            depth += 1
        elif ch == ")":
            depth -= 1
        if ch == "," and depth == 0:
            out.append(cur); cur = ""
        else:
            cur += ch
    if cur.strip():
        out.append(cur)
    return out

def main(path):
    src = open(path).read()
    args = dict(re.findall(r"_UniffiLib\.(\w+)\.argtypes\s*=\s*\(([^)]*(?:\([^)]*\)[^)]*)*)\)", src))
    rets = dict(re.findall(r"_UniffiLib\.(\w+)\.restype\s*=\s*(.+)", src))
    names = sorted(set(args) | set(rets))
    unknown = collections.Counter()
    rows = []
    for n in names:
        a = [conv(x) for x in split_args(args.get(n, ""))]
        r = conv(rets.get(n, "None"))
        if None in a or r is None:
            for x in split_args(args.get(n, "")) + [rets.get(n, "None")]:
                if conv(x) is None:
                    unknown[x.strip()] += 1
            continue
        rows.append((n, a, r))
    return rows, unknown, len(names)

def error_variants(path):
    """The MoqError variant table, read from the same generated bindings.

    Hand-maintaining this is a trap: the variants are not appended to, they are
    INSERTED into. Turning moq-ffi\'s audio/video features on adds Audio and
    Video at 5 and 6 and shifts every later variant down two, so a stale table
    does not report an unknown variant -- it reports a confidently wrong name
    for a real one.
    """
    src = open(path).read()
    i = src.index("class _UniffiFfiConverterTypeMoqError")
    blk = src[i:]
    blk = blk[:blk.index("\nclass ", 10)]
    pairs = re.findall(r"if variant == (\d+):\s*\n\s*return MoqError\.(\w+)\(", blk)
    def kebab(n):
        return re.sub(r"(?<!^)(?=[A-Z])", "-", n).lower()
    return [(int(n), kebab(name)) for n, name in pairs]


if __name__ == "__main__":
    rows, unknown, total = main(sys.argv[1])
    print(f";; {len(rows)} of {total} entry points bound", file=sys.stderr)
    if unknown:
        print(";; UNMAPPED (left unbound rather than guessed):", file=sys.stderr)
        for t, c in unknown.most_common():
            print(f";;   {t}  x{c}", file=sys.stderr)
    variants = error_variants(sys.argv[1])
    print(";; MoqError, as UniFFI numbers it in THIS object. Generated with the")
    print(";; entry points above, and for the same reason: the variants are")
    print(";; inserted into rather than appended to, so a table written by hand")
    print(";; against one build names the wrong error in the next.")
    print("(def moq-error-variants")
    print("  {" + "\n   ".join("%d :%s" % (n, k) for n, k in variants) + "})")
    print()
    for n, a, r in rows:
        # Anchored, longest-first: "uniffi_moq_ffi_checksum_" must not be
        # eaten by the "ffi_moq_ffi_" that also matches inside it.
        for pre in ("uniffi_moq_ffi_fn_", "uniffi_moq_ffi_checksum_",
                    "ffi_moq_ffi_", "uniffi_moq_ffi_"):
            if n.startswith(pre):
                stem = n[len(pre):]
                if pre.endswith("checksum_"):
                    stem = "checksum-" + stem
                break
        else:
            stem = n
        jolt_name = stem.replace("_", "-")
        argv = " ".join(a) if a else ""
        print(f'(ffi/defcfn {jolt_name} "{n}" [{argv}] {r})')
