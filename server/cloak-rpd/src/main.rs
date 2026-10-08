// cloak-rpd — Cloak Rosenpass Daemon
// =====================================================================
// STATUS: WIP / FIRST DRAFT — NOT YET COMPILED OR VERIFIED.
// Grounded line-by-line on rosenpass b096cb1 (cli.rs:440-505 construction
// path; app_server.rs add_peer:1038, event loop:1116, poll:1311). Built as a
// [[bin]] inside the patched rosenpass workspace with --features experiment_api
// (see build.sh). Requires the `event_loop_with_control` method added to
// AppServer (see patches/app_server_control.md).
//
// PURPOSE: run the rosenpass responder for a whole region box in ONE process on
// ONE UDP port, and add peers AT RUNTIME over a line-based unix control socket
// — so provisioning a new device never restarts the daemon (a restart drops
// every peer's in-flight handshake; that is the fleet-wide PQC churn we are
// eliminating). regionsvc writes one line per provision:
//     ADD <peerName> <rosenpass-public-path>
// and the daemon calls AppServer::add_peer, which is zero-disruption to all
// existing peers (independent CryptoServer entries).
//
// PSK output is unchanged: each peer's derived key is written to
// /run/rosenpass/psk-<peerName> via the peer's `outfile`, exactly where
// cloak-psk-installer already watches.
// =====================================================================

use std::collections::HashMap;
use std::io::{BufRead, BufReader};
use std::net::SocketAddr;
use std::os::unix::net::UnixListener as StdUnixListener;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;

use anyhow::{bail, Context, Result};

use rosenpass::app_server::{AppServer, PeerCtl};
use rosenpass::config::{ProtocolVersion, Verbosity};
use rosenpass::protocol::basic_types::{SPk, SSk};
use rosenpass::protocol::osk_domain_separator::OskDomainSeparator;
use rosenpass_util::file::LoadValue; // brings `SSk::load` / `SPk::load` into scope

/// mio token used purely to wake the event loop when a control command is
/// queued. It is intentionally NOT registered in AppServer.io_source_index —
/// try_recv_from_mio_token treats an unknown token as a harmless no-op (logs a
/// dev-warning, returns None), which is exactly the "break the blocking poll"
/// behaviour we want. (app_server.rs:1548-1556)
const CONTROL_WAKE_TOKEN: mio::Token = mio::Token(0xC0_FFEE);

/// Where derived PSKs are written, matching cloak-psk-installer's watch dir.
const PSK_DIR: &str = "/run/rosenpass";

// The event loop's control channel carries `PeerCtl` commands, defined in the
// patched rosenpass crate (see patches/app_server_remove_peer.md) so the
// rosenpass-side event_loop_with_control carries no type dependency on this bin.
//   ADD    <name> <pubkeyPath>  — register a peer at runtime (zero disruption).
//   REMOVE <name>               — drop a revoked/region-switched peer so it
//                                 stops deriving psk-<name> immediately, instead
//                                 of lingering until the next (now-rare) daemon
//                                 restart and accumulating orphaned PSK files
//                                 cloak-psk-installer can never apply.

struct Args {
    secret_key: PathBuf,
    public_key: PathBuf,
    listen: SocketAddr,
    control: PathBuf,
    peers_dir: Option<PathBuf>,
    psk_dir: PathBuf,
}

fn parse_args() -> Result<Args> {
    let mut secret_key = None;
    let mut public_key = None;
    let mut listen: Option<SocketAddr> = None;
    let mut control = PathBuf::from("/run/rosenpass/control.sock");
    let mut peers_dir = None;
    let mut psk_dir = PathBuf::from(PSK_DIR);

    let mut it = std::env::args().skip(1);
    while let Some(a) = it.next() {
        match a.as_str() {
            "--secret-key" => secret_key = Some(PathBuf::from(it.next().context("--secret-key")?)),
            "--public-key" => public_key = Some(PathBuf::from(it.next().context("--public-key")?)),
            "--listen" => listen = Some(it.next().context("--listen")?.parse()?),
            "--control" => control = PathBuf::from(it.next().context("--control")?),
            "--peers-dir" => peers_dir = Some(PathBuf::from(it.next().context("--peers-dir")?)),
            "--psk-dir" => psk_dir = PathBuf::from(it.next().context("--psk-dir")?),
            other => bail!("unknown arg: {other}"),
        }
    }
    Ok(Args {
        secret_key: secret_key.context("--secret-key required")?,
        public_key: public_key.context("--public-key required")?,
        listen: listen.context("--listen required, e.g. 0.0.0.0:9999")?,
        control,
        peers_dir,
        psk_dir,
    })
}

/// Derive the psk outfile for a peer name, matching the existing convention.
fn psk_outfile(dir: &Path, name: &str) -> PathBuf {
    dir.join(format!("psk-{name}"))
}

/// Add one peer to the (live) server. Mirrors cli.rs:483 minus the WG broker —
/// we deliver the PSK via the key_out file (cloak-psk-installer picks it up),
/// not via rosenpass's own WG broker.
fn add_peer(srv: &mut AppServer, psk_dir: &Path, name: &str, pubkey_path: &Path) -> Result<()> {
    let pk = SPk::load(pubkey_path).with_context(|| format!("load pubkey {pubkey_path:?}"))?;
    srv.add_peer(
        None,                              // psk: none (PQ-only; WG carries data)
        pk,                                // peer rosenpass public key
        Some(psk_outfile(psk_dir, name)),  // outfile -> <psk_dir>/psk-<name>
        None,                              // broker_peer: none
        None,                              // hostname/endpoint: responder learns it from packets
        ProtocolVersion::V03,              // MUST match the V03 clients
        OskDomainSeparator::default(),
    )?;
    Ok(())
}

/// Control socket: accept connections, read one `ADD <name> <pubkeyPath>` line
/// each, forward to the loop, and notify the loop. Runs on its own thread so
/// socket I/O never blocks the crypto loop.
///
/// NOTIFY = mio Waker + a self-poke datagram. The Waker alone is NOT enough:
/// `AppServer::poll()` services the waker's mio event via try_recv_from_mio_token,
/// which — because the waker token is intentionally not in io_source_index —
/// returns `None` (app_server.rs:1766-1771). `poll()` then finds no network
/// packet and RE-BLOCKS without ever returning to `event_loop_with_control`, so
/// on an idle box the top-of-loop control drain never runs until some unrelated
/// packet happens to arrive. (That is the desync that stranded clients on quiet
/// regions: regionsvc's ADD sat un-drained, the device's PQC peer was never
/// registered, no PSK was written, and the phone's applied PSK had no match.)
///
/// To force `poll()` to RETURN, we send one datagram to our own rosenpass listen
/// socket. That yields a real `ReceivedMessage`, so `event_loop_with_control`
/// iterates and drains the queued ADD/REMOVE immediately. The poke is a 1-byte
/// malformed rosenpass message that `handle_msg` just logs-and-ignores; it never
/// touches peer state. `poke_addr` is the loopback form of the listen port.
fn control_thread(
    path: PathBuf,
    tx: Sender<PeerCtl>,
    waker: Arc<mio::Waker>,
    poke_addr: SocketAddr,
) {
    let _ = std::fs::remove_file(&path);
    let listener = match StdUnixListener::bind(&path) {
        Ok(l) => l,
        Err(e) => {
            eprintln!("cloak-rpd: cannot bind control socket {path:?}: {e}");
            return;
        }
    };
    // root-only.
    let _ = std::fs::set_permissions(&path, std::os::unix::fs::PermissionsExt::from_mode(0o600));

    // Throwaway UDP socket for the self-poke, bound to the same family as the
    // listen socket so send_to can reach a v4 or v6 loopback target.
    let poke_sock = match poke_addr {
        SocketAddr::V4(_) => std::net::UdpSocket::bind(("0.0.0.0", 0)),
        SocketAddr::V6(_) => std::net::UdpSocket::bind(("::", 0)),
    }
    .ok();

    // Wake the blocking poll AND poke our listen socket so poll() returns and
    // the event loop drains the control channel even on a fully idle box.
    let notify = |waker: &Arc<mio::Waker>| {
        let _ = waker.wake();
        if let Some(s) = poke_sock.as_ref() {
            let _ = s.send_to(&[0u8], poke_addr);
        }
    };

    for conn in listener.incoming() {
        let conn = match conn {
            Ok(c) => c,
            Err(_) => continue,
        };
        let reader = BufReader::new(conn);
        for line in reader.lines().map_while(Result::ok) {
            let mut parts = line.split_whitespace();
            match parts.next() {
                Some("ADD") => {
                    if let (Some(name), Some(path)) = (parts.next(), parts.next()) {
                        let _ = tx.send(PeerCtl::Add {
                            name: name.to_string(),
                            pubkey_path: PathBuf::from(path),
                        });
                        notify(&waker);
                    }
                }
                Some("REMOVE") => {
                    if let Some(name) = parts.next() {
                        let _ = tx.send(PeerCtl::Remove {
                            name: name.to_string(),
                        });
                        notify(&waker);
                    }
                }
                _ => {}
            }
        }
    }
}

/// Load every `*.rosenpass-public` in the peers dir as an initial peer, so a
/// cold start / crash / upgrade recovers the full peer set from disk before
/// accepting runtime ADDs.
///
/// `known` maps peer name -> (peer slot index, raw pubkey bytes). The daemon's
/// AppServer starts with ZERO peers and `add_peer` appends slots sequentially,
/// so the index of each successfully preloaded peer is simply the running
/// count of successful adds. The event loop uses this map to REACTIVATE a
/// tombstoned slot on re-ADD instead of duplicating the pubkey (the 2026-07-01
/// tombstone/re-ADD bug — see patches/event_loop_with_control.rs.snippet).
fn preload_peers(
    srv: &mut AppServer,
    peers_dir: &Path,
    psk_dir: &Path,
    known: &mut HashMap<String, (usize, Vec<u8>)>,
) -> Result<usize> {
    let mut n = 0;
    for entry in std::fs::read_dir(peers_dir)? {
        let p = entry?.path();
        if p.extension().and_then(|e| e.to_str()) == Some("rosenpass-public") {
            // peer name = file stem (e.g. peer-ab12cd34ef56)
            if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
                let raw = match std::fs::read(&p) {
                    Ok(b) => b,
                    Err(e) => {
                        eprintln!("cloak-rpd: preload read {p:?} failed: {e}");
                        continue;
                    }
                };
                if let Err(e) = add_peer(srv, psk_dir, stem, &p) {
                    eprintln!("cloak-rpd: preload {p:?} failed: {e}");
                } else {
                    // Slot index == number of peers added before this one.
                    known.insert(stem.to_string(), (n, raw));
                    n += 1;
                }
            }
        }
    }
    Ok(n)
}

fn main() -> Result<()> {
    // MUST run before any secret is allocated/loaded (mirrors rosenpass's own
    // main.rs). Without it, the first SSk/SPk::load panics with
    // "Secret security policy not specified". We build without the
    // `experiment_memfd_secret` feature, so use the malloc-secret policy —
    // exactly the branch rosenpass's main.rs takes in that configuration.
    rosenpass_secret_memory::policy::secret_policy_use_only_malloc_secrets();

    let args = parse_args()?;
    std::fs::create_dir_all(&args.psk_dir).ok();

    let sk = SSk::load(&args.secret_key).context("load secret key")?;
    let pk = SPk::load(&args.public_key).context("load public key")?;

    let mut srv = Box::new(AppServer::new(
        Some((sk, pk)),
        vec![args.listen],
        Verbosity::Quiet,
        None,
    )?);

    let mut known_peers: HashMap<String, (usize, Vec<u8>)> = HashMap::new();
    if let Some(dir) = args.peers_dir.as_ref() {
        let n = preload_peers(&mut srv, dir, &args.psk_dir, &mut known_peers).unwrap_or(0);
        eprintln!("cloak-rpd: preloaded {n} peers from {dir:?}");
    }

    // Waker on the server's own mio poll so a queued control command interrupts
    // the blocking poll promptly even when the box is momentarily idle.
    let waker = Arc::new(mio::Waker::new(srv.mio_poll.registry(), CONTROL_WAKE_TOKEN)?);

    // Loopback target on the listen port for the control thread's self-poke
    // (see control_thread). A wildcard listener (0.0.0.0 / ::) receives loopback
    // traffic on the same port, so this reliably reaches our own socket.
    let poke_addr: SocketAddr = match args.listen {
        SocketAddr::V4(a) => SocketAddr::from((std::net::Ipv4Addr::LOCALHOST, a.port())),
        SocketAddr::V6(a) => SocketAddr::from((std::net::Ipv6Addr::LOCALHOST, a.port())),
    };

    let (tx, rx): (Sender<PeerCtl>, Receiver<PeerCtl>) = mpsc::channel();
    {
        let path = args.control.clone();
        std::thread::spawn(move || control_thread(path, tx, waker, poke_addr));
    }

    eprintln!("cloak-rpd: listening on {} (rosenpass), control {:?}", args.listen, args.control);

    // Patched loop: drains `rx` (calling add_peer) at the top of each iteration,
    // otherwise identical to AppServer::event_loop. See patches/app_server_control.md.
    srv.event_loop_with_control(rx, args.psk_dir.clone(), known_peers)
}
