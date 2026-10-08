# LinkedIn Post — Lattice VPN Monitoring Dashboards (video post)

Attach the screen-recording of the dashboards. Suggested video length: 60–90s.
A shot list matching the narrative is at the bottom of this file.

---

## The post

Most VPN dashboards watch servers. Mine watches cryptography.

The video below is a tour of the monitoring stack behind Lattice VPN — a 10-region post-quantum VPN fleet I run solo. Here's what you're looking at.

**Dashboard 1: PQC Fleet Health.** This is the one that doesn't exist anywhere else. Lattice rotates every tunnel's post-quantum key (Rosenpass: Classic McEliece + ML-KEM) roughly every two minutes. A key that stops rotating is a security regression that no off-the-shelf exporter will ever notice — so I wrote custom collectors for it. Per region, this board tracks: the age of every derived key, orphaned key material that should have been reaped, the health of the key-exchange daemon and the unix control socket it takes peer updates on, and whether the component that installs each fresh key into WireGuard is alive. That last one earns its panel: it once died silently and the symptom was "VPN connects, no traffic flows." Every panel on this board exists because something it watches actually broke once.

**Dashboard 2: Infrastructure Overview.** The classical layer — CPU, memory, disk, network per box. Post-quantum crypto makes even this interesting: a single Classic McEliece public key is ~524 KB, so peer count translates to RAM in a way ops people won't expect. Capacity planning here means planning for cryptography.

**Dashboard 3: Fleet Logs.** Every box streams journals to a central Loki instance. When a handshake fails on a server in Johannesburg at 2am, I grep one place, not eleven.

The stack is deliberately boring: Prometheus, Grafana, Loki, Alloy, node_exporter — plus the custom PQC collectors, since nobody ships metrics for "is your post-quantum key exchange healthy." It all lives on a dedicated VM behind a zero-trust access layer, reachable from nothing but my own identity.

The lesson that built this: alerts designed from imagination watch the wrong things. Every alert here maps to a real incident from the road to launch.

One person can run a global crypto fleet. But only if the fleet tells you the truth.

→ latticevpn.ai

#SRE #Observability #PostQuantum #Grafana #DevOps #BuildInPublic

---

## Video shot list (60–90s, matches the narrative)

1. (0:00–0:10) Grafana home, the three dashboards visible. Slow cursor.
2. (0:10–0:40) PQC Fleet Health: hover the per-region PSK-age cells, the
   rpd/installer/socket status row, orphaned-PSK stat. Let one auto-refresh
   tick happen on camera — live data reads as authentic.
3. (0:40–0:60) Infrastructure Overview: pick one region with the instance
   variable, sweep CPU/RAM/network panels.
4. (0:60–0:80) Fleet Logs: filter by unit, show log lines streaming from
   multiple regions in one view.
5. (0:80–0:90) Optional: end on the green wall of the fleet-health row.

## Redaction checklist — BEFORE recording

- Hide/avoid panels showing client source IPs or WireGuard peer endpoints
  (the Fleet Health board can surface peer identifiers; keep the video at
  region granularity).
- Don't show the Grafana URL bar if you'd rather not advertise the
  monitoring hostname (it's behind Cloudflare Access, but no need to
  invite door-knockers).
- Check the Fleet Logs view for journal lines containing peer names or
  public keys before letting it stream on camera.
- Mute Grafana notification toasts (top-right) — they can contain alert
  details.
