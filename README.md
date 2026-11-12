# NMUCompat

macOS replacement for ENTTEC's discontinued **NMU (Node Management Utility)**, targeting the
**ODE Mk1** (70305/70306). Discovers ODEs over ESP and changes IP, name, protocol (ESP/Art-Net),
universe and port direction — the same packets NMU 1.85 sends.

Protocol details and their provenance: [docs/PROTOCOL.md](docs/PROTOCOL.md).

> Status: discovery, name, Art-Net universe and IP changes are verified on a real ODE Mk1
> (fw 0x16). Protocol and direction use the same packet but have not been exercised yet.
> After an IP change the ODE still answers ARP/ping on its old address until power-cycled.

## GUI

```sh
./scripts/bundle.sh        # → dist/NMUCompat.app (ad-hoc signed)
open dist/NMUCompat.app
```

Scans all interfaces by default and remembers which NIC each ODE answered on. Select an ODE,
edit name / IP / protocol / direction / universe (Art-Net Sub-Net + Universe or Port-Address),
check the ESCP packet preview, then Apply. IP changes ask for confirmation and restart the node.

## Build

```sh
swift build -c release
.build/release/nmucompat --help
```

## Usage

```sh
nmucompat interfaces                       # pick the NIC the ODEs are on
nmucompat discover                         # list ODEs on all interfaces (or -i en8)
nmucompat show 00:50:C2:12:34:56 -i en8    # details + raw poll reply hex
nmucompat set 00:50:C2:12:34:56 -i en8 --ip 192.168.1.50 --name "Truss 1" \
          --protocol artnet --artnet 0.3 --direction output --dry-run
nmucompat reset 00:50:C2:12:34:56 -i en8   # ESZZ (reboot/apply)
nmucompat factory 00:50:C2:12:34:56 -i en8 --yes
```

Nodes are addressed by MAC over `255.255.255.255:3333`, so the Mac does not need an IP in the
ODE's subnet. UDP port 3333 must be free.
