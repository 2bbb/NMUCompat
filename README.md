# NMUCompat

[![CI](https://github.com/2bbb/NMUCompat/actions/workflows/ci.yml/badge.svg)](https://github.com/2bbb/NMUCompat/actions/workflows/ci.yml)
[![Release](https://github.com/2bbb/NMUCompat/actions/workflows/release.yml/badge.svg)](https://github.com/2bbb/NMUCompat/actions/workflows/release.yml)

macOS replacement for ENTTEC's discontinued **NMU (Node Management Utility)**, targeting the
**ODE Mk1** (Open DMX Ethernet, 70305/70306). Discovers ODEs over ESP and changes IP, name,
protocol (ESP/Art-Net), port direction and universe — sending the same packets NMU 1.85 sends.

Comes as a SwiftUI app (`NMUCompat.app`) and a command-line tool (`nmucompat`).

## ⚠️ Disclaimer / 免責事項

**This software is provided "AS IS", without warranty of any kind.** It is an independent,
unofficial project and is **not affiliated with, endorsed by, or supported by ENTTEC**.
The configuration protocol was reverse-engineered and has only been tested on a small number
of devices. Writing a wrong configuration can make a node unreachable or interrupt DMX output.
You use it entirely at your own risk; the authors accept no liability for any damage, data
loss, show interruption or other consequences. See [LICENSE](LICENSE).

**本ソフトウェアは現状有姿（AS IS）で提供され、いかなる保証もありません。** ENTTEC 社とは
無関係の非公式プロジェクトであり、同社の承認・サポートを受けたものではありません。設定
プロトコルは解析により得たもので、検証した機器・ファームウェアは限られています。誤った設定
の書き込みにより、ノードに到達できなくなる・DMX 出力が途切れる等の可能性があります。利用は
すべて自己責任で行ってください。本ソフトウェアの使用により生じたいかなる損害（機器の不具合、
公演・展示の中断等を含む）についても、作者は一切の責任を負いません。

ENTTEC, ODE and NMU are trademarks of their respective owners.

## Status

Verified on a real ODE Mk1 (firmware 0x16):

| Operation | Status |
|-----------|--------|
| Discovery (ESP poll) | ✅ verified |
| Name change | ✅ verified |
| Art-Net universe change | ✅ verified (also confirmed via ArtPollReply) |
| IP change (ESCP + ESZZ) | ✅ verified |
| Protocol (ESP/Art-Net), port direction | ⚠️ same packet, not yet exercised |
| Refresh rate (firmware ≥ 0x18) | ⚠️ untested (no such unit available) |
| Factory reset | ⚠️ untested |

Known behaviour of the ODE itself:

- Every accepted configuration write makes the ODE **restart** (~1–2 s without DMX output).
- After an IP change the ODE keeps answering ARP/ping on the **old IP as well** until it is
  power-cycled.
- Art-Net **Net is fixed at 0** (the ODE stores Sub-Net/Universe in one byte → Port-Address 0–255).

Protocol details and how they were derived: [docs/PROTOCOL.md](docs/PROTOCOL.md).

## Install

Download `NMUCompat-<version>-macos-universal.zip` from
[Releases](https://github.com/2bbb/NMUCompat/releases) (`latest` is an automatic build of
`main`). The zip contains `NMUCompat.app` and the `nmucompat` CLI (Apple Silicon + Intel,
macOS 13+).

The binaries are ad-hoc signed, not notarized. After unzipping, clear the quarantine flag:

```sh
xattr -dr com.apple.quarantine NMUCompat.app nmucompat
```

On first launch macOS asks for **Local Network** access — allow it, or discovery finds nothing.

## GUI

- Scans all network interfaces by default and remembers which NIC each ODE answered on
  (writes go out through the same NIC).
- Select an ODE, edit name / IP / protocol / direction / universe (Art-Net Sub-Net + Universe,
  or Port-Address), check the ESCP packet preview, then **Apply**. The result is verified by
  polling the node again.
- IP changes ask for confirmation.

## CLI

```sh
nmucompat interfaces                       # list IPv4 interfaces
nmucompat discover                         # find ODEs on all interfaces (or -i en8)
nmucompat show 00:50:C2:12:34:56           # details + raw poll reply hex
nmucompat set 00:50:C2:12:34:56 --name "Truss 1" --artnet 0.3 --dry-run
nmucompat set 00:50:C2:12:34:56 --ip 192.168.1.50
nmucompat reset 00:50:C2:12:34:56          # ESZZ (restart)
nmucompat factory 00:50:C2:12:34:56 --yes
```

Nodes are addressed by MAC via broadcast, so the Mac does not need an IP in the ODE's subnet.
UDP ports 3333 and 3330 must be free (quit other ESP tools).

## Build from source

Requires Xcode 15+ / Swift 5.9+.

```sh
swift test
./scripts/bundle.sh                         # dist/NMUCompat.app + dist/nmucompat (host arch)
UNIVERSAL=1 ZIP=1 VERSION=1.0.0 ./scripts/bundle.sh   # universal zip
```

## Releases

- Push to `main` → CI, and the rolling **`latest`** pre-release is rebuilt
  (`NMUCompat-latest-macos-universal.zip`).
- Push a tag `vX.Y.Z` → versioned release with `NMUCompat-X.Y.Z-macos-universal.zip`.

## License

[MIT](LICENSE)
