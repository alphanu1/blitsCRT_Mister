#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0-or-later
#
# Make u-boot's device-tree includes name their own headers explicitly, so a
# host's libfdt cannot get in between them.
#
# The problem. tools/Makefile builds the host tools with:
#
#   $(patsubst -I%,-idirafter%, $(filter -I%, $(UBOOTINCLUDE)))
#
# which puts u-boot's include/ *after* the system directories. That is
# deliberate and correct -- the host tools want <stdio.h>, <malloc.h> and the
# rest from the host, and only u-boot-specific headers from include/. In 2018 it
# was harmless for libfdt too, because a build host had none of its own.
#
# With a distribution's dtc development package installed there is a
# /usr/include/libfdt.h, /usr/include/libfdt_env.h and /usr/include/fdt.h. Any
# u-boot source asking for <libfdt.h> now gets the host's, while the force-
# included ./include/libfdt_env.h is u-boot's. The two use different include
# guards -- _LIBFDT_ENV_H against LIBFDT_ENV_H -- so neither stops the other and
# every fdt type is defined twice:
#
#   /usr/include/libfdt_env.h:27:30: error: conflicting types for 'fdt64_t'
#
# Two fixes that do not work, recorded because both look like they should:
#
#   Adding -I$(srctree)/include alongside. gcc deduplicates the search path and
#   keeps the *later* entry -- "ignoring duplicate directory ./include" -- so it
#   stays behind /usr/include.
#
#   Taking include/ out of the -idirafter list so it is a plain -I. That fixes
#   libfdt and immediately breaks everything else, because <malloc.h> then finds
#   u-boot's instead of the host's.
#
# So change the includes rather than the search order, and only for the three
# headers that collide. Each is rewritten to a path relative to the file doing
# the including, which resolves before any -I or -idirafter directory and cannot
# be reordered out from under it.
#
# Idempotent, marked, and it fails loudly rather than silently doing nothing.

import os
import re
import sys

MARK = 'blitsCRT'
HEADERS = ('libfdt_env.h', 'libfdt.h', 'fdt.h')

# Where the real ones live, relative to the tree root.
HOME = {
    'libfdt_env.h': 'include',
    'libfdt.h':     'include',
    'fdt.h':        'include',
}

# Everything that ends up in a host tool. Sources under arch/, board/, drivers/
# and so on are cross-compiled with u-boot's own flags and never see the host's
# headers, so they are left alone.
ROOTS = ('include', 'tools', 'lib')


def patch(path, root):
    src = open(path).read()
    if MARK in src:
        return 0

    here = os.path.dirname(os.path.abspath(path))
    n = 0

    for h in HEADERS:
        target = os.path.join(os.path.abspath(root), HOME[h], h)

        beside = os.path.dirname(target) == here
        rel = os.path.relpath(target, here)
        fixed = '#include "%s"\t/* %s: the tree\'s own */' % (rel, MARK)

        # The angle form always needs rewriting: it goes straight to the search
        # path and never looks in this file's own directory, so even
        # include/libfdt.h asking for <libfdt_env.h> can get the host's.
        if ('#include <%s>' % h) in src:
            src = src.replace('#include <%s>' % h,
                              '#include "%s"\t/* %s: the tree\'s own */'
                              % (h if beside else rel, MARK))
            n += 1

        # The quoted form only needs it when the header is somewhere else. A
        # quote searches this file's directory first, so include/ is already
        # right; lib/ is not, and falls through to the same search path.
        if not beside and ('#include "%s"' % h) in src:
            src = src.replace('#include "%s"' % h, fixed)
            n += 1

    if n:
        open(path, 'w').write(src)
    return n


def main():
    if len(sys.argv) != 2:
        print('usage: uboot_fix_libfdt.py <u-boot-dir>', file=sys.stderr)
        return 2

    root = sys.argv[1]
    if not os.path.isdir(root + '/include'):
        print('%s does not look like a u-boot tree' % root, file=sys.stderr)
        return 1

    total = 0
    seen_mark = False

    for sub in ROOTS:
        for dirpath, _, names in os.walk(os.path.join(root, sub)):
            for name in names:
                if not name.endswith(('.c', '.h')):
                    continue
                p = os.path.join(dirpath, name)
                try:
                    if MARK in open(p).read():
                        seen_mark = True
                        continue
                    total += patch(p, root)
                except (OSError, UnicodeDecodeError):
                    continue

    if total:
        print('patched %d includes' % total)
    elif seen_mark:
        print('already patched')
    else:
        print('no angle-bracket fdt includes found -- has this tree changed?',
              file=sys.stderr)
        return 1
    return 0


sys.exit(main())
