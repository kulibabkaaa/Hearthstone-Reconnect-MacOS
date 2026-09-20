# Vendored HearthMirror runtime

This directory contains the HearthMirror framework and managed runtime files
extracted from a local build of
[HearthSim/HSTracker](https://github.com/HearthSim/HSTracker) at base revision
`9f60212e9c7fce3b791dfeab4a9ae349985dbdf1` for HS Reconnect's local lobby
reader. HearthMirror version and Mono/CoreCLR version markers are included
beside the binaries. `SHA256SUMS` records the release inputs checked by CI.

Licensing material retained here:

- `HSTracker-LICENSE.txt`
- `CoreCLR-LICENSE.txt`
- `CoreCLR-THIRD-PARTY-NOTICES.txt`

The build embeds these files into HS Reconnect's Resources through the vendored runtime copy phase.
