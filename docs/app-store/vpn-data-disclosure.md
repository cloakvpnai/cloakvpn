# Apple App Review — VPN Data Disclosure Response

This document is the canonical response to Apple's standard
"VPN data handling" review questions. Two versions:

  1. **Short version (~3,950 chars)** — paste into the
     Resolution Center reply box. Apple caps that at 4,000 chars.
  2. **Long version** — paste into the App Review Information →
     Notes field, which has no character limit. Future reviews see
     the same disclosure without re-prompting.

The content below mirrors `cloakvpn.ai/privacy` and the actual
app/server behavior committed in this repo. If either changes,
update this file too.

---

## Short version (Resolution Center reply, ≤ 4000 chars)

```
Cloak VPN — VPN data-handling answers. Matches our public Privacy
Policy at https://cloakvpn.ai/privacy.

1) WHAT INFORMATION THE APP COLLECTS

(a) Per-install UUID generated locally on first launch. Used only
to authenticate the device when requesting a VPN configuration
from our region API. Not linked to Apple ID, name, email,
phone, IDFA, IDFV, or any real-world identity.

(b) Cryptographic public keys (Curve25519 WireGuard + Classic
McEliece rosenpass), generated on device. Only PUBLIC halves
are sent to our servers, to register the device as a peer.
Private halves never leave the device. These are cryptographic
identifiers, not personal information.

(c) StoreKit subscription transaction ID (when IAP ships). Used
only to verify the user has an active subscription. We do NOT
receive payment info, name, billing address, Apple ID, or
email from Apple.

(d) Transient session metadata held in RAM only on our region
servers: the user's already-registered public keys, an
internal-only private VPN IP in 10.99.0.0/22 (not internet-
routable), and the encrypted UDP packet stream itself
(forwarded immediately, never written to disk). Discarded
within minutes of session end.

We do NOT collect or log: real public IP, websites/services
visited, DNS queries, connection timestamps, bandwidth, name,
email, phone, address, IDFA/IDFV, cookies, location beyond
the user-chosen exit country.

2) WHY WE COLLECT IT — COMPLETE LIST OF USES

(a) Per-install UUID: device authentication for VPN config
requests; prevents unauthorized peer registration.
(b) Public keys: establish + operate the encrypted WireGuard
tunnel and the post-quantum Rosenpass key exchange that
rotates a fresh quantum-safe PSK every 120 seconds.
(c) Transaction ID: verify active subscription before serving a
VPN configuration.
(d) Session metadata: route the user's encrypted traffic.

We do NOT use any data for advertising, profiling, analytics,
marketing, sale to third parties, behavioral profiling, linking
sessions across time, or any purpose other than operating the
VPN service. There are no plans to add any such use.

3) THIRD PARTIES

We use only operational vendors. None receive user-identifiable
information.

(a) Apple Inc. (StoreKit). Receives nothing from us. We receive
a subscription transaction ID. https://www.apple.com/legal/privacy/
(b) Hetzner Online GmbH (Germany). Hosts our region servers.
Encrypted VPN bytes transit through; not logged or retained.
https://www.hetzner.com/legal/privacy-policy/
(c) Cloudflare, Inc. Hosts cloakvpn.ai DNS + routes our
provisioning HTTPS traffic. Sees only TLS-encrypted requests.
https://www.cloudflare.com/privacypolicy/
(d) Quad9. DNS resolution inside the encrypted tunnel so DNS
queries don't leak to the user's ISP. No-logging policy for
PII: https://quad9.net/service/privacy/

The iOS app contains NO third-party analytics, advertising,
crash-reporting, telemetry, or tracking SDKs. No plans to add any.

DATA RETENTION
- Per-install UUID (hashed): up to 30 days post last connection,
then deleted.
- Subscription transaction IDs: lifetime of subscription + 90
days for billing reconciliation, then deleted.
- Session metadata: discarded within minutes of disconnect;
never written to long-term storage.

ADDITIONAL CONTEXT

Cloak VPN is published by Neuro AI Studios. Our business model
is the subscription fee. We do not sell user data or share with
data brokers. Post-quantum encryption (NIST-standardized
algorithms) means even our region servers cannot decrypt
traffic in transit. Full policy at https://cloakvpn.ai/privacy.

Contact: support@cloakvpn.ai
```

---

## Long version (App Review Notes, no length limit)


Thank you for reviewing Cloak VPN. Below are the complete and accurate
responses to your questions about our app's VPN functionality and data
handling. This information also matches our public Privacy Policy at
https://cloakvpn.ai/privacy.

## 1. What user information is the app collecting using VPN?

Cloak VPN collects the absolute minimum information required to
operate the service:

**(a) Per-install identifier.**
A random UUID generated locally on the user's iPhone the first time
they open the app. Used solely to authenticate the device when it
requests a VPN configuration from our region API. This UUID is never
associated with the user's Apple ID, name, email, phone number,
IDFA, IDFV, or any real-world identity.

**(b) Cryptographic public keys.**
The user's iPhone generates two key pairs locally on first launch
(a Curve25519 WireGuard key pair and a Classic McEliece rosenpass
key pair). Only the PUBLIC halves are sent to our region servers,
where they are stored to register the device as a peer. The private
halves never leave the device. Public keys are cryptographic
identifiers, not personal information.

**(c) Subscription transaction identifier (when in-app purchases ship).**
If the user subscribes through Apple's App Store, we receive a
transaction identifier from Apple via StoreKit. We use this solely
to verify that the user has an active subscription before serving a
VPN configuration. We do NOT receive payment information, name,
billing address, Apple ID, email address, or any personally
identifiable data from Apple.

**(d) Transient VPN session metadata (RAM-only, not persisted).**
During an active session, our region servers temporarily hold:
- The user's WireGuard and rosenpass public keys (already registered above)
- An internal-only private IP address in `10.99.0.0/22` (not internet-routable; assigned per session)
- The encrypted UDP packet stream itself, which is forwarded immediately and never written to disk

All of this metadata is held in RAM only and discarded within
minutes of the user's session ending.

We do NOT collect, log, or retain:
- The user's real (public) IP address
- Websites or services the user visits through the VPN
- DNS queries the user makes
- Connection start or stop timestamps
- Per-session bandwidth usage
- Personal information of any kind (name, email, phone, address)
- Real-world device identifiers (IDFA, IDFV)
- Cookies or any third-party web tracking data
- Location data beyond the country exit the user has chosen

## 2. For what purposes are you collecting this information?

**(a)** The per-install UUID is used solely to authenticate the user's
device when it asks our region API for a VPN configuration. This
prevents unauthorized devices from creating peers on our servers.

**(b)** The user's WireGuard and rosenpass public keys are used solely
to establish and operate the encrypted VPN tunnel. WireGuard public
key authenticates the WireGuard handshake; rosenpass public key is
one half of the post-quantum key-exchange protocol that rotates a
fresh quantum-safe pre-shared key every 120 seconds.

**(c)** The subscription transaction ID is used solely to verify the
user holds an active subscription before serving a VPN configuration.

**(d)** Transient session metadata is used solely to route the user's
encrypted traffic between their device and the public internet via
our region server.

We do NOT use any data for:
- Advertising
- User profiling
- Analytics
- Marketing
- Sale to third parties
- Building behavioral profiles
- Linking sessions across time
- Any purpose other than operating the VPN service itself

There are no plans to use any data for any purpose other than what
is described above.

## 3. Will the data be shared with any third parties?

We use the following third parties strictly for operational purposes.
None of these receive user-identifiable information.

**(a) Apple Inc. (StoreKit / App Store Connect).**
Receives nothing from us. We receive a subscription transaction
identifier from Apple to validate active subscription status.
Apple's privacy practices apply: <https://www.apple.com/legal/privacy/>

**(b) Hetzner Online GmbH (Germany — server infrastructure).**
Hosts our region servers in Falkenstein (DE), Helsinki (FI), and US
locations. Encrypted VPN traffic transits these servers but is not
logged or retained. Hetzner sees only encrypted bytes. Privacy
policy: <https://www.hetzner.com/legal/privacy-policy/>

**(c) Cloudflare, Inc. (DNS + provisioning auth endpoint).**
Hosts DNS for cloakvpn.ai and routes our region API HTTPS traffic.
Sees only TLS-encrypted requests. Privacy policy:
<https://www.cloudflare.com/privacypolicy/>

**(d) Quad9 (DNS resolution inside the VPN tunnel).**
Resolves DNS queries inside the encrypted tunnel so that DNS
requests do not leak to the user's ISP. Quad9 has a contractual
no-logging policy for personally identifiable data:
<https://quad9.net/service/privacy/>

We do NOT embed any third-party analytics SDKs, advertising SDKs,
crash-reporting SDKs, telemetry SDKs, or trackers in the iOS app.
There are no plans to add any.

### Data retention

- **Per-install identifier (hashed):** up to 30 days after the user's most recent connection, then permanently deleted.
- **Subscription transaction IDs:** retained for the lifetime of the active subscription plus 90 days for billing reconciliation, then permanently deleted.
- **VPN session metadata:** discarded within minutes of session disconnect; never written to long-term storage.

## Additional context

Cloak VPN is built by Neuro AI Studios. Our entire business model is
the subscription fee. We do not sell user data, share user data with
data brokers, or use user data for anything other than operating the
VPN service. Our complete data-handling policy is publicly published
at <https://cloakvpn.ai/privacy>.

The post-quantum encryption (WireGuard + Rosenpass with NIST-
standardized algorithms) means even our region servers cannot decrypt
the traffic in transit; the encryption is end-to-end between the
user's device and the destination they're connecting to.

If you need any further information, please contact us at
[email protected].
