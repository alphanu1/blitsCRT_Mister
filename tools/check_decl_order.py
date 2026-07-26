#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
"""Find identifiers used before they are declared.

Icarus builds disagree about this. Mine accepts it; other versions reject it
outright with "Unable to bind wire/reg/memory". Quartus never complains, so the
first sign of trouble is somebody else's build failing.

This has bitten twice: `slave_sda` in the I2C testbench and `apply_ack` in the
register file. Cheap to check, so it is checked.

Usage:
    python3 tools/check_decl_order.py rtl/*.v sim/*.v
"""
import re
import sys

# Declarations we care about, and the name list that follows them.
DECL = re.compile(
    r'^\s*(?:(?:input|output|inout)\s+)?'
    r'(?:reg|wire|logic|integer|real|genvar)\b'
    r'(?:\s+signed)?'
    r'(?:\s*\[[^\]]*\])?\s*'
    r'([A-Za-z_][\w$]*(?:\s*,\s*[A-Za-z_][\w$]*)*)'
)

# Ports are declared in the header and may legitimately be referenced anywhere.
PORT = re.compile(r'^\s*(input|output|inout)\b')

KEYWORDS = {
    'begin', 'end', 'if', 'else', 'case', 'endcase', 'always', 'assign',
    'posedge', 'negedge', 'or', 'and', 'not', 'module', 'endmodule',
    'parameter', 'localparam', 'default', 'for', 'while', 'initial',
    'function', 'endfunction', 'task', 'endtask', 'generate', 'endgenerate',
    'reg', 'wire', 'logic', 'integer', 'real', 'genvar', 'signed', 'input',
    'output', 'inout', 'repeat', 'forever', 'disable', 'wait', 'fork', 'join',
}


def strip_comments(text):
    text = re.sub(r'/\*.*?\*/', '', text, flags=re.S)
    return re.sub(r'//[^\n]*', '', text)


def check(path):
    raw = open(path, encoding='utf-8', errors='replace').read()
    lines = strip_comments(raw).split('\n')

    declared = {}     # name -> line number
    ports = set()

    for i, line in enumerate(lines, 1):
        m = DECL.match(line)
        if not m:
            continue
        for name in re.split(r'\s*,\s*', m.group(1)):
            name = name.strip()
            if not name or name in KEYWORDS:
                continue
            declared.setdefault(name, i)
            if PORT.match(line):
                ports.add(name)

    # Instance port maps resolve at elaboration, so a signal passed into a
    # port is not a textual forward reference the way a combinational use is.
    # Icarus accepts  .a(sig)  with sig declared later; it is only procedural
    # and continuous-assignment uses that the strict builds reject. Detect a
    # port-map line by its leading  .name(  and skip it wholesale.
    port_line = re.compile(r'^\s*\.\s*[A-Za-z_][\w$]*\s*\(')

    problems = []
    for i, line in enumerate(lines, 1):
        if DECL.match(line):
            continue
        if port_line.match(line):
            continue
        for name in re.findall(r'\b([A-Za-z_][\w$]*)\b', line):
            if name in KEYWORDS or name in ports:
                continue
            first = declared.get(name)
            if first is not None and i < first:
                problems.append((i, name, first))

    seen = set()
    out = []
    for ln, name, decl in problems:
        if name in seen:
            continue
        seen.add(name)
        out.append((ln, name, decl))
    return out


def main():
    paths = sys.argv[1:]
    if not paths:
        print(__doc__)
        return 2

    bad = 0
    for p in paths:
        issues = check(p)
        if issues:
            bad += len(issues)
            print("%s:" % p)
            for ln, name, decl in issues:
                print("  line %-4d uses '%s', declared at line %d"
                      % (ln, name, decl))

    if bad:
        print("\n%d use-before-declaration %s"
              % (bad, "problem" if bad == 1 else "problems"))
        return 1

    print("checked %d file%s, no use before declaration"
          % (len(paths), "" if len(paths) == 1 else "s"))
    return 0


if __name__ == '__main__':
    sys.exit(main())
