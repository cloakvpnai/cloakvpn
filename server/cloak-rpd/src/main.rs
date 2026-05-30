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

use std::io::{BufRead, BufReader};
use std::net::SocketAddr;
use std::os::unix::net::UnixListener as StdUnixListener;
use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, Sender};
use std::sync::Arc;

use anyhow::{bail, Context, Result};

use rosenpass::app_server::AppServer;
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

// The event loop's control channel carries `(peerName, pubkeyPath)` tuples
// (see event_loop_with_control). REMOVE is intentionally unsupported: there is
// no runtime CryptoServer peer removal at b096cb1; stale peers are harmless and
// drop on the next (rare) daemon restart, which reloads from the on-disk
// registry. See the design doc.
type AddReq = (String, PathBuf);

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
/// each, forward to the loop, and wake it via the mio Waker. Runs on its own
/// thread so socket I/O never blocks the crypto loop.
fn control_thread(path: PathBuf, tx: Sender<AddReq>, waker: Arc<mio::Waker>) {
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
                        let _ = tx.send((name.to_string(), PathBuf::from(path)));
                        let _ = waker.wake();
                    }
                }
                Some("REMOVE") => { /* deferred; see ControlMsg */ }
                _ => {}
            }
        }
    }
}

/// Load every `*.rosenpass-public` in the peers dir as an initial peer, so a
/// cold start / crash / upgrade recovers the full peer set from disk before
/// accepting runtime ADDs.
fn preload_peers(srv: &mut AppServer, peers_dir: &Path, psk_dir: &Path) -> Result<usize> {
    let mut n = 0;
    for entry in std::fs::read_dir(peers_dir)? {
        let p = entry?.path();
        if p.extension().and_then(|e| e.to_str()) == Some("rosenpass-public") {
            // peer name = file stem (e.g. peer-ab12cd34ef56)
            if let Some(stem) = p.file_stem().and_then(|s| s.to_str()) {
                if let Err(e) = add_peer(srv, psk_dir, stem, &p) {
                    eprintln!("cloak-rpd: preload {p:?} failed: {e}");
                } else {
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

    if let Some(dir) = args.peers_dir.as_ref() {
        let n = preload_peers(&mut srv, dir, &args.psk_dir).unwrap_or(0);
        eprintln!("cloak-rpd: preloaded {n} peers from {dir:?}");
    }

    // Waker on the server's own mio poll so a queued control command interrupts
    // the blocking poll promptly even when the box is momentarily idle.
    let waker = Arc::new(mio::Waker::new(srv.mio_poll.registry(), CONTROL_WAKE_TOKEN)?);

    let (tx, rx): (Sender<AddReq>, Receiver<AddReq>) = mpsc::channel();
    {
        let path = args.control.clone();
        std::thread::spawn(move || control_thread(path, tx, waker));
    }

    eprintln!("cloak-rpd: listening on {} (rosenpass), control {:?}", args.listen, args.control);

    // Patched loop: drains `rx` (calling add_peer) at the top of each iteration,
    // otherwise identical to AppServer::event_loop. See patches/app_server_control.md.
    srv.event_loop_with_control(rx, args.psk_dir.clone())
}
