# Lattice VPN — Privacy Policy

> **DRAFT — must be reviewed before publishing.** This policy is written
> to match the no-logs posture described in the project README. Before
> you publish it, confirm every statement is true of your *actual*
> server configuration and business practices, and fill in every
> `[PLACEHOLDER]`. A privacy policy that does not match reality is both a
> legal liability and grounds for removal from Google Play.

**Effective date:** [EFFECTIVE DATE]
**Applies to:** the Lattice VPN Android application (`ai.latticevpn.android`)
and the Lattice VPN service.
**Provider:** [LEGAL ENTITY NAME] ("Lattice", "we", "us").
**Contact:** legal@latticevpn.ai

---

## Summary

Lattice VPN is a no-logs VPN. We do not record what you do online. We
collect the minimum needed to connect your device to a VPN server and
nothing that would let us — or anyone else — reconstruct your browsing.
We do not sell or rent data to anyone, and the app contains no
advertising or analytics trackers.

## What we do NOT collect

We do not log, store, or monitor:

- the websites, apps, or services you connect to;
- your DNS queries;
- your traffic content, or traffic metadata such as timestamps and
  bandwidth tied to your identity;
- a history of when you connected or disconnected;
- your originating IP address in association with your activity.

Our VPN servers run in volatile memory (RAM). They are not configured to
write traffic or connection logs to disk.

## What we process to provide the service

To create and route your encrypted tunnel, the app and servers handle the
following — kept to the minimum and not linked to your real-world
identity:

- **Provisioning data.** When you select a location, the app contacts our
  provisioning API and registers your device as a VPN peer. This request
  includes a randomly generated per-installation identifier and the
  public keys your device generates locally (its WireGuard public key and
  its Rosenpass post-quantum public key). It does **not** include your
  name, email address, or phone number. The corresponding private keys
  are generated on your device and never leave it.
- **Routing state.** While you are connected, the server holds your
  assigned internal VPN IP address and your public key in memory so it
  can route packets. This is operational state, not a log, and is not
  retained as a record of your activity.
- **Network-level IP address.** As with any internet connection, our
  server necessarily receives the IP address your device connects from in
  order to establish the tunnel. We do not store it as part of an
  activity log.
- **Local app data.** Your selected region and your VPN configuration are
  stored on your device so the app works between launches. This data
  stays on your device.

## Third-party services

- **IP address display.** To show you your current IP address inside the
  app, the app makes a request to a third-party IP-lookup service
  (ipify.org). That service receives the IP address of the request. No
  other personal information is sent to it.
- **No analytics or advertising.** The app integrates no analytics,
  advertising, attribution, or third-party crash-reporting SDKs.
- **Payments.** Subscriptions are purchased on our website
  (latticevpn.ai), where payments are processed by Stripe, Inc. Stripe
  handles your payment details under its own privacy policy; we do not
  receive or store full payment card numbers. No payment is taken inside
  the Android app.

## Data sharing and legal requests

We do not sell, rent, or trade personal data. Because we do not keep
activity logs, we have nothing to disclose that would reveal what a user
did online. If we receive a legally binding request, we can only provide
the limited information we actually hold, which does not include browsing
or connection history.

## Data retention

Operational state (such as routing state) exists only for the life of
your connection and is held in server memory. [State your retention
period for any provisioning records, e.g. peer registrations, and for any
payment/account records if applicable — confirm this with your actual
server and billing setup.]

## Security

Traffic between your device and our servers is encrypted with WireGuard
and additionally protected by Rosenpass post-quantum key exchange, which
refreshes the tunnel's pre-shared key every few minutes. No method of
transmission or storage is perfectly secure, but we design the service to
minimize the data that exists to be exposed in the first place.

## Children

Lattice VPN is not directed at children and is intended for users aged
18 and over. We do not knowingly collect personal information from
children.

## Your rights

Depending on where you live, you may have rights to access, correct, or
delete personal data we hold about you, or to object to certain
processing. Because we intentionally hold very little data, some requests
may have little to act on. To make a request, contact us at
legal@latticevpn.ai.

## Changes to this policy

We may update this policy from time to time. Material changes will be
posted at this URL with an updated effective date.

## Contact

Questions about this policy or your privacy: **legal@latticevpn.ai**
[LEGAL ENTITY NAME], [REGISTERED ADDRESS]
Governing law: [JURISDICTION / COUNTRY]
