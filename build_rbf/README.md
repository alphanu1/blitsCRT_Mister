# The committed bitstream

`build_rbf/blitscrt.rbf` is the FPGA bitstream, built locally and committed.

CI does not run Quartus. It is a ~10 GB licensed install and a hosted runner has
about 14 GB of free disk and no state between runs, so building it there is not
worth the trouble. The `.rbf` is ~2 MB and changes only when the fabric does,
which makes committing it the cheaper arrangement.

## Why a third directory

The bitstream already exists in two places, and both are gitignored:

| | |
|---|---|
| `quartus/output_files/` | where Quartus writes it |
| `build/` | the staged card layout, from `make build` |

Ignoring those is right -- they are build output. But it means a bitstream can be
built, staged, and written to a card without ever entering the repository, which
is exactly what happened: CI failed on a missing `.rbf` that was present on the
machine that built it.

So `make bitstream` copies it here as well, and this directory is not ignored.

## Before bumping VERSION

```
make bitstream          # also stages build_rbf/blitscrt.rbf
git add build_rbf/blitscrt.rbf
```

Then bump `VERSION` and push. The release workflow refuses to publish without it,
since an image with no bitstream boots to nothing, and warns if anything in
`rtl/` is newer -- which usually means a fabric change that never reached here.

`git ls-files build_rbf/` is the check that matters. It shows what git *tracks*,
which is not the same as what is on disk.

## It works the other way too

A clone with no Quartus has this file and nothing else. `tools/install_sd.sh`
falls back to it, so `make sd` and `make image` both work without ever building
a bitstream -- which is how CI produces a card image, and how anyone can build
one from a tagged release without an FPGA toolchain.
