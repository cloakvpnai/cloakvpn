# Cloak VPN Privacy Policy

**Last updated: April 27, 2026**

Cloak VPN ("we", "our", or "the Service") is operated by Neuro AI Studios. This Privacy Policy describes how Cloak VPN handles information when you use our iOS application and VPN service.

## TL;DR

- We do not log, store, or sell your browsing activity.
- We do not log connection timestamps, source IP addresses, or DNS queries.
- We collect the minimum required to run the service: a per-install identifier, your subscription status, and an IPv4/IPv6 address temporarily assigned inside our private VPN network.
- We do not share your data with advertisers, data brokers, or third parties for marketing.
- Post-quantum encryption (WireGuard + Rosenpass) is end-to-end between your device and our region servers; we cannot decrypt your traffic in transit.

## Information we collect

### 1. Per-install identifier

When you launch Cloak VPN for the first time, your device generates a random UUID that is stored on the device and used to authenticate calls to our region API. We never associate this identifier with your real-world identity, your Apple ID, or any other account.

### 2. Subscription status (when in-app purchases are active)

If you subscribe through the App Store, we receive a transaction identifier from Apple via StoreKit so we can confirm you have an active subscription. We do not receive your payment information, name, billing address, or Apple ID. The transaction identifier is used solely to authorize VPN provisioning calls.

### 3. VPN session metadata (transient)

To route your traffic, our region servers temporarily hold:
- Your device's WireGuard and Rosenpass public keys (cryptographic identifiers — not personal data)
- A private IP address (in `10.99.0.0/22`, not internet-routable) assigned to your device for the duration of your session
- The encrypted UDP packet stream itself, which is forwarded immediately and not retained

We do not log:
- Your real (public) IP address
- The websites or services you connect to through the VPN
- DNS queries you make
- Connection start/stop timestamps
- Bandwidth used per session

### 4. Aggregate operational metrics

We collect anonymous aggregate metrics (total active connections per region, bandwidth utilization per region, software error counts) to operate and scale the service. These metrics cannot be used to identify any individual user.

## Information we do **not** collect

- Personally identifiable information (name, email, phone number, address) — unless you contact our support team voluntarily
- Browsing history or destination URLs
- DNS queries
- Real-world device identifiers (IDFA, IDFV are not collected or transmitted)
- Cookies or web tracking data
- Location data beyond the country your VPN exit is in (which you choose)

## How we use the information

The minimal information we collect is used solely to:
- Authenticate your device to our region API
- Provision and maintain your VPN tunnel
- Prevent abuse and operate the service reliably

We do **not** use it for advertising, profiling, marketing, sale to third parties, or any purpose other than operating the VPN service.

## Data retention

- Per-install identifier: stored on your device only; we hold a hash for rate-limiting purposes for up to 30 days after your last connection
- Subscription transaction IDs: retained for as long as your subscription is active, plus 90 days for billing reconciliation, then deleted
- VPN session metadata: deleted within minutes of session disconnect; never written to long-term storage

## Third parties

We use the following third-party services strictly for operational purposes:

- **Apple StoreKit / App Store Connect** — for subscription billing. Apple's privacy policy applies: <https://www.apple.com/legal/privacy/>
- **Hetzner Online GmbH** — hosts our region servers. Hetzner's privacy policy: <https://www.hetzner.com/legal/privacy-policy/>
- **Cloudflare, Inc.** — hosts DNS for `cloakvpn.ai` and our subscription auth endpoint. Cloudflare's privacy policy: <https://www.cloudflare.com/privacypolicy/>
- **Quad9** — DNS resolution inside the VPN tunnel (so your DNS queries don't leak to your ISP). Quad9 logs no personally identifiable data by policy: <https://quad9.net/service/privacy/>

We do not embed analytics SDKs, advertising SDKs, or third-party trackers in the iOS application.

## Children's privacy

Cloak VPN is not directed at children under 13. We do not knowingly collect any information from children under 13.

## Your rights

You may at any time:
- Delete the Cloak VPN app, which removes your per-install identifier and all locally stored cryptographic keys
- Cancel your subscription via the App Store
- Email us at `support@cloakvpn.ai` to request deletion of any data we hold associated with your subscription transaction ID

## Changes to this policy

We may update this Privacy Policy from time to time. The "Last updated" date at the top reflects the current version. Material changes will be announced in-app on next launch.

## Contact

Questions about this policy or your data: `support@cloakvpn.ai`
