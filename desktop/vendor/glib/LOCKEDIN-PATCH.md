# GLib 0.18 compatibility security backport

This directory contains the `glib` 0.18.5 library source published on crates.io,
under its original MIT license. Only `Cargo.toml`, `LICENSE`, `README.md`, and
`src/` are included. The unmodified crate archive has SHA-256
`233daaf6e83ae6a12a52055f568f9d7cf4671dabb78ff9560ab6da230ce00ee5`.

The sole source change applies the two-line fix from
[gtk-rs-core pull request 1343](https://github.com/gtk-rs/gtk-rs-core/pull/1343)
to `src/variant_iter.rs`: declare the out-pointer mutable and pass `&mut p` to
the C function that writes it. This corrects
[RUSTSEC-2024-0429](https://rustsec.org/advisories/RUSTSEC-2024-0429.html).
The fix shipped in the upstream 0.20 API, but the current GTK3 desktop framework
still requires the 0.18 API. No API, package version, or license is changed.

The desktop workspace pins this local backport with `[patch.crates-io]`.
`scripts/verify-glib-backport.mjs` compares every retained file with the
checksum-pinned upstream crate, permitting exactly these two source-line
changes. The Linux optimized regression test exercises forward and reverse
string iteration, including empty input and Unicode. Version-based advisory
tools can still report 0.18.5; the source comparison and native regression are
required in addition to the advisory report. There is no blanket advisory
suppression.

Remove this backport when the framework consumes the patched upstream API.
The upstream project's separate unmaintained `proc-macro-error` build dependency
is tracked in the desktop security notes; this patch does not resolve it.
