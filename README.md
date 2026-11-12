# NMUCompat

macOS replacement for ENTTEC's discontinued **NMU (Node Management Utility)**, targeting the
**ODE Mk1** (70305/70306). Discovers ODEs over ESP and changes IP, name, protocol (ESP/Art-Net),
universe and port direction — the same packets NMU 1.85 sends.

Protocol details and their provenance: [docs/PROTOCOL.md](docs/PROTOCOL.md).

> Status: packet formats are reverse-engineered from NMU 1.85 and unit-tested, but
> **not yet verified on hardware**. Try `set --dry-run` and a single sacrificial unit first.

## Build

```sh
swift build -c release
.build/release/nmucompat --help
```

## Usage

```sh
nmucompat interfaces                       # pick the NIC the ODEs are on
nmucompat discover -i en8                  # list ODEs (and other ESP nodes)
nmucompat show 00:50:C2:12:34:56 -i en8    # details + raw poll reply hex
nmucompat set 00:50:C2:12:34:56 -i en8 --ip 192.168.1.50 --name "Truss 1" \
          --protocol artnet --artnet 0.3 --direction output --dry-run
nmucompat reset 00:50:C2:12:34:56 -i en8   # ESZZ (reboot/apply)
nmucompat factory 00:50:C2:12:34:56 -i en8 --yes
```

Nodes are addressed by MAC over `255.255.255.255:3333`, so the Mac does not need an IP in the
ODE's subnet. UDP port 3333 must be free.
