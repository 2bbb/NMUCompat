# ENTTEC ODE Mk1 — ESP configuration protocol (as implemented by NMU 1.85)

Derived from static analysis of `NMU.app` 1.85 (x86_64 Mach-O, symbols intact) and
the public ESP v1.4 spec. Discovery and the poll-reply layout are **verified on a real
ODE Mk1** (MAC 00:50:C2:07:77:B1, firmware 0x16, Art-Net 1.06 in ArtPollReply).
Writes (`ESCP`, `ESZZ`) are not yet verified — items marked _(unverified)_.

Relevant NMU functions: `ESPNet::Poll`, `ESPNet::ODEPoll`, `ESPNet::RecvData`,
`ESPNet::add_ode_to_list(…, ODEPollReplyPacket*)`, `ESPNet::ODE_SendConfig`,
`ESPNet::ODE_Reset_Send`, `ESPNet::SendFactoryConfig`, `Config_Dialog::OnSetButtonClick`,
`Config_Dialog::UpdateDevice`.

## Transport

- Host → node: UDP to port **3333** (0x0D05). NMU sends from source port 3333.
- Node → host: the ODE **broadcasts its replies to `255.255.255.255:3330`** (0x0D02),
  regardless of the poll's source port. A client listening only on 3333 sees nothing.
  (Verified by capture; matches NMU's second socket bound to `0.0.0.0:3330`.)
- NMU sends every packet to `255.255.255.255:3333`. Nodes are addressed by **MAC**, not IP, so this works even when
  the node's IP is on another subnet (factory IP is `10.a.b.c`).
- Multi-byte integers are big-endian.

## Poll — `ESPP`

| off | size | value |
|----:|-----:|-------|
| 0 | 4 | `"ESPP"` |
| 4 | 1 | reply type: NMU discovery sends `0x01`; `ODEPoll(ip)` sends `0x04` unicast |

Observed on ODE Mk1 fw 0x16: types `0x01` and `0x04` both get the same 83-byte reply
(unicast, subnet-broadcast and limited-broadcast polls all answered); types `0x00` and
`0x02` get no reply.

## Poll reply from ODE — `ESPR` (`ODEPollReplyPacket`)

`RecvData` dispatches on the node type at offset 10. ODE is handled for **node type
`0x000B`** (not the `0x0004`/`0x0011` listed in the public spec).

| off | size | field | NMU device-struct field |
|----:|-----:|-------|-------------------------|
| 0 | 4 | `"ESPR"` | |
| 4 | 6 | MAC (serial) | `+0x78` |
| 10 | 2 | node type (`0x000B`) | low byte → `+0x98` |
| 12 | 1 | firmware version | `+0x9c` |
| 13 | 1 | sub-type / plugin state (2, 3 checked for merge plugin) | `+0x9f` |
| 14 | 10 | short name | |
| 24 | 1 | option | |
| 25 | 1 | TOS | |
| 26 | 1 | TTL | `+0x1e9` |
| 27 | 20 | device name (NUL-terminated) | name |
| 47 | 1 | port direction (0=disabled, 1=output, 2=input) | `+0x9a` |
| 48 | 1 | protocol (0=ESP, 1=Art-Net) | `+0x99` |
| 49 | 1 | universe (Art-Net: `subnet<<4 \| universe`; ESP: 0–255) | `+0x9b` |
| 51 | 8 | plugin info (fw ≥ 0x0F) | `+0x1c1` |
| 59 | 24 | merge config (fw ≥ 0x0F, sub-type 3) | `+0x1c9` |
| 83 | 1 | refresh-rate code (fw ≥ 0x18) | `+0x1ea` |
| 84 | 1 | option B (fw ≥ 0x18) | `+0x1eb` |
| 85 | 1 | option C (fw ≥ 0x18) | `+0x1ec` |

The node's current IP is the UDP source address of the reply.

Captured reply (fw 0x16, name "Kyakuden", output, Art-Net, universe 0):

```
0000  45 53 50 52 00 50 c2 07 77 b1 00 0b 16 00 4b 79
0010  61 6b 75 64 65 6e 00 a0 01 00 00 4b 79 61 6b 75
0020  64 65 6e 00 00 00 00 00 00 00 00 00 00 00 00 01
0030  01 00 00 00 00 00 00 00 00 00 00 00 00 00 00 ff
0040  ff ff ff ff ff ff ff ff ff ff ff ff ff ff ff 00
0050  00 00 00
```

## Set config — `ESCP`

Sent to broadcast; the node selects itself by MAC.

| off | size | value |
|----:|-----:|-------|
| 0 | 4 | `"ESCP"` |
| 4 | 2 | node type, `0x000B` |
| 6 | 4 | **new** IP address |
| 10 | 6 | target MAC |
| 16 | 2 | payload length: `0x0018` (fw < 0x18) or `0x001B` (fw ≥ 0x18) |
| 18 | 1 | config format: `0x01` (fw < 0x18) or `0x05` (fw ≥ 0x18) |
| 19 | 20 | device name, NUL-terminated (max 19 chars) |
| 39 | 1 | port direction |
| 40 | 1 | protocol |
| 41 | 1 | universe |
| 42 | 1 | refresh-rate code (fw ≥ 0x18 only) |
| 43 | 1 | option B (fw ≥ 0x18 only) |
| 44 | 1 | option C (fw ≥ 0x18 only) |

Total length 42 bytes (fw < 0x18) or 45 bytes (fw ≥ 0x18).

Refresh-rate code from Hz (`Config_Dialog::UpdateDevice`):
`code = floor((1000/max(hz,2) - 23) / 2.052 + 0.5)`.

Factory reset (`SendFactoryConfig`) is the same packet with IP `10.MAC[3].MAC[4].MAC[5]`
(NMU runs `strtol(…,16)` over raw MAC bytes here, which looks like a bug; nmucompat uses the
byte values, matching the manual's "10.a.b.c from the serial"), name `"ODE Factory"`, direction 1, protocol 1, universe 0, format 1, length 0x18.

## Reset / apply — `ESZZ`

| off | size | value |
|----:|-----:|-------|
| 0 | 4 | `"ESZZ"` |
| 4 | 6 | target MAC |

NMU sequence on "Save Config":

1. If the IP **changed**: `ESCP` → sleep 444 ms → `ESZZ` (node reboots with new IP).
2. Otherwise: `ESCP` only.
3. Re-poll and compare fields to verify (`Config_Dialog::CompareParams`).

## Open questions _(unverified)_

- Whether the ODE answers `ESCP` with `ESAP`.
- Exact meaning of option B/C (`No Input Behavior`, `HTP Merging` radio boxes).
- Whether Mk1 rev A (old firmware) also reports node type `0x000B`.
