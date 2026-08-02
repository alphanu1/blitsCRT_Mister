# The committed bitstream

`release/blitscrt.rbf` is the FPGA bitstream, built locally and committed.

CI does not run Quartus. It is a ~10 GB licensed install and a hosted runner has
about 14 GB of free disk and no state between runs, so building it there is not
worth the trouble. The `.rbf` is ~2 MB and changes only when the fabric does,
which makes committing it the cheaper arrangement.

## Before bumping VERSION

```
make bitstream
cp quartus/output_files/blitscrt.rbf release/blitscrt.rbf
git add release/blitscrt.rbf
```

Then bump `VERSION` and push. The release workflow refuses to publish without
it, since an image with no bitstream boots to nothing, and warns if anything in
`rtl/` is newer than the `.rbf` -- which usually means a fabric change that
never reached here.

## Why not gitignore it

`quartus/output_files/` is ignored, as build output should be. This is a
different thing: a release artefact, deliberately versioned so that any tag can
be rebuilt into the exact image it shipped.
