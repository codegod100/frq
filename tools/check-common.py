#!/usr/bin/env python3
"""What may appear in common/, checked.

common/ is compiled twice — by jolt and by ClojureDart — and only one of those
happens on the way to a desktop build. So the way this breaks is always the
same: shared code reaches for something only the JVM has, everything the
author ran still works, and the phone stops compiling at a namespace nobody
touched. `Math/ceil` in the compose bar was the third time.

The rule being enforced is CLAUDE.md's, unchanged: code under common/ may not
require jolt.*, glimmer* or a dart: library, and if it needs the host it asks
frq.io. This only sees the first half of that — a host call has to be named to
be caught, and the list below is the ones that have actually turned up.

Two things are stripped before anything is matched, and both are the
difference between a check people keep and one they route around.

Comments and strings, because the two namespaces that got this right explain
themselves by naming the very thing they avoid — a checker that fires on
`frq.clock`'s docstring teaches people to stop reading it.

And the reader-conditional branches ClojureDart does not read. A
`#?(:jolt [glimmer.ratom ...])` is not a violation, it is the sanctioned way
to say "desktop only": the cljd compiler never sees inside it. So this reads
the conditionals the way the compiler does — first branch whose feature is on,
with :cljd, :clj and :default on — and looks only at what is left.
"""
import re
import sys
from pathlib import Path

# Java that has no ClojureDart counterpart. Spelled as whole tokens: `Math/`
# catches java.lang.Math without catching a namespace alias ending in "math".
INTEROP = re.compile(
    r"""(?<![\w.-])(?:Math|Integer|Long|Double|Float|Short|Byte|Character
        |Boolean|System|Thread|Class|Arrays|Collections|StringBuilder
        |Instant|Duration|LocalDate|LocalDateTime|ZoneId|ZonedDateTime
        |File|Files|Paths|Base64|Charset|StandardCharsets)/""",
    re.VERBOSE,
)
# (String. x), (StringBuilder.) — constructor interop, whatever the class.
CTOR = re.compile(r"\((?:[A-Z]\w*\.)(?=[\s)])")
JAVA_PKG = re.compile(r"(?<![\w.-])java\.[\w.]+")
# .getBytes and friends: methods on a JVM object, by name.
METHODS = re.compile(r"(?<![\w.-])\.(?:getBytes|toUpperCase|toLowerCase|intValue|longValue|doubleValue|charAt)(?![\w-])")
# The requires CLAUDE.md rules out by name.
BAD_REQUIRE = re.compile(r"(?<![\w.-])(?:jolt\.[\w.]+|glimmer[\w.]*|\"dart:[\w.]+\")")

CHECKS = [
    (INTEROP, "Java class only the JVM has"),
    (CTOR, "Java constructor interop"),
    (JAVA_PKG, "a java.* package"),
    (METHODS, "a method only a JVM object has"),
    (BAD_REQUIRE, "a backend common/ may not name"),
]


def strip(src):
    """Comments and string literals blanked, newlines kept so lines still count.

    Clojure's character literals are why this is a scanner and not a regex:
    `\\"` is the double-quote character, and anything counting quotes without
    knowing that starts reading code as string at the first one it meets.
    """
    out, i, n = [], 0, len(src)
    while i < n:
        c = src[i]
        if c == "\\" and i + 1 < n:  # character literal — consume both
            out.append("  " if src[i + 1] != "\n" else " \n")
            i += 2
        elif c == ";":
            while i < n and src[i] != "\n":
                out.append(" ")
                i += 1
        elif c == '"':
            out.append(" ")
            i += 1
            while i < n:
                if src[i] == "\\" and i + 1 < n:
                    out.append("  " if src[i + 1] != "\n" else " \n")
                    i += 2
                    continue
                if src[i] == '"':
                    out.append(" ")
                    i += 1
                    break
                out.append("\n" if src[i] == "\n" else " ")
                i += 1
        else:
            out.append(c)
            i += 1
    return "".join(out)


ACTIVE = ("cljd", "clj", "default")


def _blank(src, lo, hi):
    """Characters lo..hi replaced with spaces, newlines kept.

    Positions are preserved rather than the text rewritten, so a line number
    in a message is the line number in the file.
    """
    return src[:lo] + "".join("\n" if c == "\n" else " " for c in src[lo:hi]) + src[hi:]


def _close(src, i):
    """Index just past the list opening at src[i], or None if unbalanced."""
    depth = 0
    while i < len(src):
        if src[i] == "(":
            depth += 1
        elif src[i] == ")":
            depth -= 1
            if depth == 0:
                return i + 1
        i += 1
    return None


def _forms(src, i, end):
    """(start, stop) of each top-level form in src[i:end]."""
    out = []
    while i < end:
        if src[i].isspace():
            i += 1
            continue
        if src[i] == "(" or src[i] == "[":
            shut = {"(": ")", "[": "]"}[src[i]]
            depth, j = 0, i
            while j < end:
                if src[j] in "([":
                    depth += 1
                elif src[j] in ")]":
                    depth -= 1
                    if depth == 0:
                        j += 1
                        break
                j += 1
            out.append((i, j))
            i = j
        else:
            j = i
            while j < end and not src[j].isspace() and src[j] not in "()[]{}":
                j += 1
            out.append((i, j))
            i = j
    return out


def select(src):
    """Reader-conditional branches ClojureDart never reads, blanked out.

    Splicing (`#?@`) and plain (`#?`) are the same job here: what matters is
    which branch survives, not how it is spliced in.
    """
    i = 0
    while True:
        hit = src.find("#?", i)
        if hit < 0:
            return src
        open_paren = hit + (3 if src[hit:hit + 3] == "#?@" else 2)
        while open_paren < len(src) and src[open_paren].isspace():
            open_paren += 1
        if open_paren >= len(src) or src[open_paren] != "(":
            i = hit + 2
            continue
        end = _close(src, open_paren)
        if end is None:
            return src
        forms = _forms(src, open_paren + 1, end - 1)
        # keyword, form, keyword, form — take the first keyword that is on.
        keep = None
        for k in range(0, len(forms) - 1, 2):
            kw = src[forms[k][0]:forms[k][1]]
            if kw.lstrip(":") in ACTIVE and keep is None:
                keep = forms[k + 1]
        # Blank everything in the conditional except the branch that survives,
        # including the `#?` itself so it is not rescanned.
        cut = end if keep is None else keep[0]
        src = _blank(src, hit, cut)
        if keep is not None:
            src = _blank(src, keep[1], end)
        i = hit + 2


def cells_enumerated(root):
    """frq.cells/all-cells against the cells actually defined.

    The phone watches what this list names and nothing else, so a cell missing
    from it is a control that flips state and repaints nothing — which is a
    bug that looks like a dead button and gets reported as one.
    """
    path = root / "frq" / "cells.cljc"
    if not path.exists():
        return []
    src = strip(path.read_text())
    defined = re.findall(r"\(defonce ([\w?!*<>+-]+) \(atom ", src)
    body = src[src.index("(defn all-cells"):] if "(defn all-cells" in src else ""
    listed = set(re.findall(r"[\w?!*<>+-]+", body[body.index("[", body.index("[]") + 2):])) if body else set()
    missing = [d for d in defined if d not in listed]
    return [
        (path, 0, d, "defined but missing from frq.cells/all-cells — the phone will not repaint for it")
        for d in missing
    ]


def entries_keyed(root):
    """Every `[:entry ...]` in a shared screen carries a `:key`.

    The phone keeps one TextEditingController per key, and an entry without
    one falls back to a single shared controller — so two unkeyed entries on a
    screen are the same controller, and whichever renders last wins. It has
    cost two bugs: the connect screen's host field showed the port, and the
    emoji search would not hold more than one character, because the composer
    rendered after it with an empty draft and wiped it.

    glimmer wants the key too, to match children across a render. Nothing
    enforced it, which is why it kept coming back.
    """
    bad = []
    for path in sorted(root.rglob("*.cljc")):
        src = strip(path.read_text())
        for i, line in enumerate(src.split("\n")):
            if "[:entry" not in line:
                continue
            # the props map may run over a few lines; :key belongs in it
            blob = "\n".join(src.split("\n")[i:i + 8])
            if ":key" not in blob:
                bad.append((path, i + 1, ":entry",
                            "written without a :key — unkeyed entries share one "
                            "text controller on the phone"))
    return bad


def main():
    root = Path(sys.argv[1] if len(sys.argv) > 1 else "common")
    bad = []
    for path in sorted(root.rglob("*.cljc")):
        source = select(strip(path.read_text()))
        for lineno, line in enumerate(source.splitlines(), 1):
            for pattern, why in CHECKS:
                m = pattern.search(line)
                if m:
                    bad.append((path, lineno, m.group(0).strip(), why))
    bad += cells_enumerated(root)
    bad += entries_keyed(root)
    for path, lineno, tok, why in bad:
        where = f"{path}:{lineno}" if lineno else str(path)
        print(f"{where}: {tok!r} is {why}", file=sys.stderr)
    if bad:
        print(
            f"\n{len(bad)} thing(s) wrong under {root}/, which both backends compile.\n"
            "If it needs the host, ask frq.io and add the call to both\n"
            "implementations. See CLAUDE.md.",
            file=sys.stderr,
        )
        return 1
    print(f"{root}/ is clean: nothing here that only one backend has.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
