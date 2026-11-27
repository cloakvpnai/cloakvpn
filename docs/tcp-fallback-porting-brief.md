# Porting brief: TCP 443 fallback for the iPhone, Mac and Android apps

Created by Demetris Dangerfield
Written 26 November 2026 from the working Windows implementation.

## Why

The gateways listen on UDP 1194. Hotels, schools, offices and some carriers block it, and the app then never connects. Five gateways now also accept the same CNSA 2.0 tunnel over TCP 443 on a second address. The Windows app uses it and connects in about 2.4 seconds on a network that blocks UDP. The iPhone, Mac and Android apps need the same.

This is a transport change only. Nothing about the cryptography, certificates, enrollment or the traffic hold changes.

## The reference

Branch `windows-client`. Read these before writing anything:

| What | Where |
|---|---|
| Framing over TCP, with tests | `clients/windows/src/Lattice.Tunnel/TcpFraming.cs`, `tests/Lattice.Tunnel.Tests/TcpFramingTests.cs` |
| Engine: UDP or TCP socket, non-blocking TCP connect | `clients/windows/src/Lattice.Tunnel/TunnelEngine.cs` |
| Connect logic: both ways tried side by side | `clients/windows/src/Lattice.Tunnel/VpnController.cs`, the worker loop |
| Gateway list fields | `clients/windows/src/Lattice.Tunnel/AccountApi.cs` (`ParseGateways`), `Enrollment.cs` (`GatewayRecord`), `VpnController.cs` (`TcpPaths`) |
| Account service | `server/api/internal/cnsa2/cnsa2.go` (`Gateway`) |
| Gateway side | `server/cnsa2-tls/gateway/add-tcp443.sh` |

Commits: `fc6c606` (framing and engine), `2f5595d` (side by side connect), `07493e9` (gateway list).

## What goes on the wire

1. **Framing.** Over TCP every tunnel packet (control and data alike) is preceded by its length as two bytes, high byte first. A 300 byte packet is sent as `01 2C` followed by the 300 bytes. Send the two bytes and the packet in one write. On receive, bytes arrive in pieces of any size: collect them and cut whole packets back out. A length of zero means this is not a Lattice tunnel; drop the connection.
2. **Options string.** In the key method 2 message the client's options string says `proto TCPv4_CLIENT` where it says `proto UDPv4` today. Nothing else in that string changes.
3. **Everything else is identical:** packet formats, the reliability layer for control packets, TLS 1.3 with `TLS_AES_256_GCM_SHA384`, `MLKEM1024`, `mldsa87`, AES-256-GCM data channel, key change every 600 seconds, keepalive. Do not add any other suite or option.
4. **TCP socket:** no delay (TCP_NODELAY) on.

## Where the TCP address comes from

The gateway list from the account service (in the enrollment reply and in `GET /v1/cnsa2/gateways`) may carry two more fields per gateway:

```
"tcp_host": "198.51.100.8",   an IPv4 address, never a name
"tcp_port": 443
```

Rules:
- Use them only when `tcp_host` parses as an IPv4 address and `tcp_port` is 1 to 65535. Anything else: the gateway has no TCP way in. Never guess.
- A gateway without the fields is UDP only, exactly as now.
- Save the fields with the stored gateway list.
- No address may be built into a release build.
- The list is fetched at enrollment and renewal today. Also refresh it in the background (Windows does so every 6 hours and when the account is refreshed), so new addresses arrive within a day and not weeks.

The account service change may not be deployed when you start. Until it is, use a debug-only launch option to supply a TCP address for testing. Mexico: gateway `mx1`, TCP address `216.238.75.153`, port `443`. That option must not exist in release builds.

## How to connect

Both ways in are tried side by side, so a blocked network costs about two seconds.

1. Start the UDP attempt.
2. If the gateway has a TCP way in, start the TCP attempt 0.5 seconds later. Do not wait for UDP to fail.
3. First to finish the handshake wins, with one rule: if TCP finishes first, still wait until 2.0 seconds after the start for UDP, and take UDP if it finishes by then. UDP is the better carrier.
4. Close the attempt that lost, telling its gateway.
5. If TCP won, remember it for this connection: later reconnects go straight to TCP without trying UDP. Forget that when the network changes, when the device wakes from sleep, or when the region changes, so UDP is always tried first on a new network.
6. If neither answers, treat it as today (back off and retry), and try both again next time.
7. If one attempt fails with a real reason (the gateway refused the certificate, for example), report that reason. Silence from the other one does not replace it.
8. Over TCP, a closed connection is known at once. Reconnect then; do not wait for the keepalive to time out.

Each attempt needs its own session object and its own copy of the device identity. Do not share one between the two.

Making the TCP connection must not block the thread that drives the UDP attempt.

## Things that differ by platform

- **The app's own sockets must not go into the tunnel.** Windows adds a route for each address it connects to. On Android, call `protect()` on the TCP socket exactly as for the UDP one. On Apple platforms confirm how the UDP socket is kept out of the tunnel today and do the same for TCP, for the second address as well as the first.
- **The exit address does not change.** Over TCP the outside world still sees the gateway's first address. The second address is only the way in. Do not show it as the exit.
- **Report the transport.** Windows adds `transport` (`udp` or `tcp`) to its status. Do the same, and show a short note in the app when it is TCP, for example "via TCP 443".
- **Traffic stays held throughout.** Trying two ways in must not open any gap. Nothing leaves outside the tunnel while either attempt is in progress.

## Tests each app must pass before it is called done

1. **Unit:** framing round trip with packets of 1, 2, 40, 1400 and 65535 bytes, delivered one byte at a time, three at a time, and all at once. A zero length is refused. The Windows tests show the cases.
2. **UDP blocked:** block outbound UDP 1194 on the test device or its network, connect to a gateway that has a TCP way in. Expect: connected over TCP in about 2 to 4 seconds, the outside world sees the gateway's first address, DNS works through the tunnel, a 25 MB download completes, and no traffic leaves outside the tunnel at any point.
3. **UDP allowed:** same gateway. Expect UDP, as fast as before.
4. **A gateway with no TCP way in:** connects over UDP as before.
5. **Change of network while on TCP:** the app tries UDP first on the new network.
6. **Existing tests still pass.**

Windows results for comparison (Hawaii to Mexico): UDP blocked 2.4 s over TCP; UDP allowed 1.9 s over UDP.

## Limits to respect

- Do not change the cipher suite, certificates, enrollment, or the traffic hold.
- Never read, print or log the account number.
- Work on a new branch. Commit locally. Do not push and do not submit anything to the App Store or Google Play. Both need Demetris.
- Do not change any server. The gateways and the account service are handled from the Windows session.
- If something in the existing app code contradicts this brief, stop and say so. Do not guess.

## Order

1. Apple first. The iPhone and Mac apps share the tunnel code, so one change covers both.
2. Then Android.

## What to report at the end

For each app: what changed and in which files, the test results from the list above with numbers, what could not be tested and why, the branch and commit, and anything that needs a person holding a device.
