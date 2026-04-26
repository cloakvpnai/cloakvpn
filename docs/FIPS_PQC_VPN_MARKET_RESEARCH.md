# FIPS 140-3 Validated Post-Quantum VPN Market Research

**Prepared:** 25 April 2026
**Audience:** Solo technical founder evaluating a pivot from consumer Rosenpass-based PQC VPN to a FIPS-validated commercial product targeting DoD, US federal civilian, and regulated private enterprise (healthcare, finance).
**Methodology note:** Web research conducted April 2026 against authoritative sources (NIST CSRC, vendor blogs, NIAP, FedRAMP Marketplace, GAO/CISA publications, trade press). Where a primary source was paywalled or required direct vendor contact for pricing, that is flagged inline. Citation links appear at the end of each major section.

---

## 0. Bottom Line Up Front (BLUF)

1. **The market gap is real but narrow and closing fast.** As of April 2026, exactly **zero FIPS 140-3 validated cryptographic modules with ML-KEM (FIPS 203) inside a shipping commercial VPN product** exist on the CMVP Active list. AWS-LC, wolfCrypt, OpenSSL 3.5/3.6, and SafeLogic CryptoComply are all in the CMVP "Modules in Process" pipeline. First active certificates are expected late 2026 / first half 2027.
2. **You are not competing with Cisco/Palo Alto on VPN appliances.** You are competing on (a) iOS/mobile PQC VPN clients in the federal space, where almost nothing exists, and (b) being the small-business prime / sub for SBIR contracts where giants do not bid.
3. **Realistic capital requirement to ship a FIPS-validated PQC VPN to a federal customer is $750K - $2.5M and 18-30 months.** If you want FedRAMP Moderate hosting on top of that, add another $500K-$1.5M and 12-18 months. Solo-founder execution at this scale is extremely difficult without SBIR Phase II funding ($1.5-2M typical) or an acquihire/sub-prime relationship.
4. **The DoDIN APL was sunset 30 September 2025.** Cybersecurity acceptance for DoD now flows through DISA's RME STIG program plus FIPS 140-3 + NIAP CC. This is actually slightly *better* news for new entrants — one fewer multi-year gauntlet.
5. **Architecturally, IPsec/IKEv2 with strongSwan + a FIPS-validated crypto module is the only currently viable federal path.** WireGuard's mandatory ChaCha20/Poly1305/Curve25519 are not FIPS-approved primitives. Rosenpass is academic / experimental — there is no path to federal sale without re-architecting.

---

## 1. Current State of FIPS 140-3 Validated Modules with ML-KEM (FIPS 203)

### 1.1 Status by module (as of 9 April 2026, last CMVP IG update)

| Module | Vendor | ML-KEM in module? | FIPS 140-3 status | Cert # |
|--------|--------|-------------------|-------------------|--------|
| AWS-LC FIPS 3.0 | AWS | Yes (512/768/1024) | **Modules In Process** (submitted, no Active cert yet) | TBD; predecessors: #4631, #4759, #4816 |
| AWS-LC FIPS 2.0 | AWS | No | Active (Oct 2024) | #4759 / #4816 |
| wolfCrypt FIPS 140-3 (current) | wolfSSL | No | Active | #4718, #5041 (valid through 17 Jul 2030) |
| wolfCrypt FIPS 140-3 + PQC | wolfSSL | Yes (FIPS 203/204/205) | Announced Feb 2026, **CMVP submission in process** | TBD |
| OpenSSL 3.5.4 FIPS provider | OpenSSL Project | ML-KEM in software, not in FIPS module | Submitted to CMVP Oct 2025; cert unlikely before Jan 2027 | TBD |
| OpenSSL 3.6 FIPS provider (with PQC) | OpenSSL Project | Yes (LMS, ML-KEM, ML-DSA, SLH-DSA) | Submitted autumn 2025, in review | TBD |
| SafeLogic CryptoComply (Core / Mobile / Java / Go v3.5 / v4) | SafeLogic | Yes (ML-KEM, ML-DSA, SLH-DSA) | **CAVP algorithm validations achieved** (their 158th); CMVP module validation in process | TBD |
| Microsoft SymCrypt | Microsoft | Yes (ML-KEM, XMSS via CNG, GA early 2026) | Multiple historical FIPS 140 validations; PQC module submission status not publicly disclosed | Various |
| Apple corecrypto (iOS) | Apple | Public PQC API (kSecKeyAlgorithm... ML-KEM) since iOS 18; FIPS module update unclear | Apple states it "will aim to meet and transition to FIPS 140-3 as soon as practicable." No public ML-KEM-in-FIPS-module cert as of April 2026 | iOS-specific certs vary by release |
| Red Hat RHEL 10 crypto (NSS / OpenSSL) | Red Hat | Yes (ML-KEM in OpenSSL 3.5 backed) | RHEL 10's OpenSSL FIPS provider validation in process | TBD |
| BoringSSL FIPS | Google | No public ML-KEM-in-FIPS-module yet | BoringSSL FIPS modules historically validated; PQC inclusion not announced | Various |

### 1.2 Realistic developer timeline

- **Today (April 2026):** No production-grade FIPS 140-3 module on CMVP **Active** list contains ML-KEM. You can build against AWS-LC 3.0 or wolfCrypt today and claim "FIPS-pending PQC" but **not "FIPS 140-3 validated PQC"** on a federal solicitation.
- **Q3-Q4 2026:** AWS-LC FIPS 3.0 expected to land an Active cert (highest probability candidate for "first").
- **Late 2026 / Q1 2027:** wolfCrypt PQC cert and SafeLogic CryptoComply v3.5/v4 PQC certs likely.
- **Q2 2027+:** OpenSSL 3.5.4 / 3.6 FIPS provider Active cert (pessimistic — Chainguard publicly stated it "will not arrive before the January 2027 deadline").

### 1.3 The September 21 2026 cliff

All FIPS 140-2 certificates move to Historical on **21 September 2026**. After that date, federal agencies cannot use 140-2 modules for new procurements. This creates a real procurement scramble in 2026-2027 because so many vendors are mid-revalidation.

### 1.4 Sources
- [NIST CMVP](https://csrc.nist.gov/projects/cryptographic-module-validation-program)
- [CMVP Modules In Process](https://csrc.nist.gov/projects/cryptographic-module-validation-program/modules-in-process/modules-in-process-list)
- [FIPS 140-3 IG announcements (last updated 9 Apr 2026)](https://csrc.nist.gov/projects/cryptographic-module-validation-program/fips-140-3-ig-announcements)
- [AWS-LC FIPS 3.0 announcement](https://aws.amazon.com/blogs/security/aws-lc-fips-3-0-first-cryptographic-library-to-include-ml-kem-in-fips-140-3-validation/)
- [wolfCrypt FIPS 140-3 with PQC](https://www.wolfssl.com/wolfcrypt-fips-140-3-with-post-quantum-cryptography-available-now/)
- [SafeLogic CAVP for CryptoComply 140-3 with PQC](https://www.safelogic.com/blog/safelogic-advances-fips-140-3-pqc-readiness-with-new-cavp-validation)
- [Chainguard FIPS Q1 2026 update](https://www.chainguard.dev/unchained/chainguard-fips-enters-2026-with-openssl-3-1-2-and-better-cmvp-visibility)
- [Apple cryptographic module status](https://support.apple.com/guide/certifications/cryptographic-module-validation-status-apc33ea4bd77/web)
- [Microsoft PQC GA announcement](https://techcommunity.microsoft.com/blog/microsoft-security-blog/post-quantum-cryptography-apis-now-generally-available-on-microsoft-platforms/4469093)

---

## 2. Competitive Landscape — Commercial FIPS-Validated PQC VPN Products

The critical distinction: **"PQ-enabled but not FIPS-validated"** vs. **"FIPS 140-3 validated module containing PQ algorithms."** Almost everything in market today is the former.

### 2.1 Vendor-by-vendor

| Vendor | Product | PQ enabled? | Crypto module FIPS-validated for PQ? | Shipping today? |
|--------|---------|-------------|--------------------------------------|-----------------|
| **Cisco** | Secure Firewall Threat Defense (FTD) 10.5, ASA 9.25 | Yes — ML-KEM in IKEv2 | **No** — FTD 10.5 / ASA 9.25 GA targeted late 2026; FIPS 140-3 PQC module not yet validated | Announced; not GA |
| **Cisco** | FTD/ASA 11.0 (ML-DSA + SLH-DSA) | Yes (planned) | No | 2027 roadmap |
| **Palo Alto Networks** | PAN-OS NGFW post-quantum IPsec VPN | Yes — ML-KEM (FIPS 203), RFC 9242, RFC 9370 hybrid keys, up to 8 round key exchange | **No** — VM-Series FIPS 140-2 cert (#3144) doesn't include ML-KEM; new validation in process | Shipping PQ-enabled (not FIPS-validated PQC) |
| **Fortinet** | FortiGate / FortiOS PQ VPN | Yes — deployed in production with Singtel quantum-safe network (Nov 2024) | No public FIPS-validated PQ module | Shipping PQ-enabled |
| **Juniper** | SRX Series | No public PQ VPN announcement found | N/A | Not announced |
| **Ivanti** | Connect Secure (formerly Pulse) | No public PQ VPN announcement found | N/A | Not announced |
| **F5** | BIG-IP | TLS PQ pilots; no IPsec PQ VPN | No | Not for VPN |
| **Microsoft** | Windows Server 2025 / Win 11 IPsec via CNG | Yes — ML-KEM + ML-DSA via CNG (Nov 2025 update) | SymCrypt has FIPS history; PQ module cert TBD | Shipping in Windows; FIPS-validated PQ module pending |
| **OpenVPN Inc** | OpenVPN Cloud / Access Server | TLS 1.3 hybrid via OpenSSL roadmap | No | Not yet shipping PQ |
| **AWS** | Site-to-Site VPN, Client VPN | TLS PQ on KMS/ACM/Secrets Manager via AWS-LC; VPN service not yet PQ | AWS-LC is in CMVP pipeline | Limited (not VPN service) |
| **Google Cloud** | Cloud VPN | No PQ VPN GA; BoringSSL FIPS doesn't include PQ | No | No |
| **Cloudflare** | WARP | ML-KEM-768 hybrid in WARP client; **WARP is inside Cloudflare's FedRAMP FIPS boundary** | Cloudflare's FIPS boundary covers WARP; whether that boundary includes ML-KEM is internal | Closest to "shipping FedRAMP-aligned PQC VPN" but WARP is not a federal-sold standalone product |
| **Senetas** | CN/CV encryptors (layer-2/3) | Crypto-agile; PQ supported | Senetas has FIPS 140-2 validations, FIPS 140-3 PQ pending | Niche (telco / gov links) |
| **General Dynamics Mission Systems** | TACLANE family (NSA Type-1) | Type-1 is classified; NSA-controlled algorithm transitions on CNSA 2.0 timeline | N/A — different program (NSA approved, not CMVP) | Type-1 is a separate world from CMVP |
| **QuSecure** | QuProtect | Yes — orchestration overlay; secured U.S. Space Force satellite link Mar 2023; $28M Series A extension Feb 2025 | Wraps third-party crypto modules; not itself a FIPS module | Shipping (orchestration, not a VPN per se) |
| **PQShield** | PQC IP cores (chip/firmware) | Yes — Dilithium/Kyber cores | IP licensed to module vendors | Not a VPN |
| **SandboxAQ** | AQtive Guard | Discovery/inventory, not a VPN | N/A | Not a VPN |
| **NordVPN** | Consumer VPN | ML-KEM in all apps May 2025; PQ authentication H1 2026 | Consumer; FIPS not applicable | Consumer only |

### 2.2 Reality check

- **No vendor today ships a FIPS 140-3 validated cryptographic module containing ML-KEM that is generally available inside a federal-procurable VPN product.** The "first" claim is genuinely available.
- **Cisco's FTD 10.5 is the closest large-vendor candidate**, with ML-KEM IKEv2 GA targeted late 2026. They will almost certainly land both FIPS 140-3 + NIAP CC + FedRAMP within 2027. After that, the "first" claim window closes for VPN appliances.
- **iOS/mobile is wide open.** No major vendor has announced a FIPS-validated PQC VPN client for iOS specifically.

### 2.3 Sources
- [Cisco Secure Firewall PQC roadmap](https://blogs.cisco.com/security/preparing-for-post-quantum-cryptography-the-secure-firewall-roadmap)
- [Palo Alto PQC IKEv2 docs](https://docs.paloaltonetworks.com/network-security/quantum-security/administration/configure-quantum-resistant-ikev2-vpns)
- [Singtel quantum-safe network (Palo Alto + Fortinet)](https://thequantuminsider.com/2024/11/12/singtel-upgrades-cybersecurity-with-quantum-safe-network-powered-by-palo-alto-networks-and-fortinet/)
- [Cloudflare WARP PQC + FedRAMP FIPS boundary](https://blog.cloudflare.com/post-quantum-warp/)
- [QuSecure World Quantum Day 2026](https://www.channelinsider.com/security/world-quantum-day-qusecure-pqc-shift/)
- [Quantum Insider 25 PQC companies 2026](https://thequantuminsider.com/2026/03/25/25-companies-building-the-quantum-cryptography-communications-markets/)

---

## 3. NIST CMVP / CAVP Recent Activity (2025-2026)

### 3.1 CAVP for ML-KEM
- **CAVP testing for FIPS 203 (ML-KEM)** is live. SafeLogic publicly cited their CAVP cert for CryptoComply 140-3 FIPS Provider with PQC as their **158th** CAVP cert (announced 2025/2026), demonstrating the algorithm-test infrastructure is fully operational.
- ACVTS (Automated Cryptographic Validation Test System) supports ML-KEM, ML-DSA, SLH-DSA test vectors as of late 2024 / early 2025.

### 3.2 CMVP module-level activity
- **Modules In Process (MIP) list** tracks four phases: Review Pending, In Review, Coordination, Finalization. As of April 2026, AWS-LC FIPS 3.0, wolfCrypt-PQC, OpenSSL 3.5.4 / 3.6, RHEL 10 OpenSSL provider, and SafeLogic CryptoComply v4 are all visible on MIP.
- Lab queue is the bottleneck — atsec, Acumen, UL, Leidos all report queue depths of 12-18+ months from submission to issued cert.
- **CMVP fee schedule effective 1 January 2026** (NIST cost recovery): published by NIST for review of new module submissions, modified module submissions, and Extended Cost Recovery for complex/poor-quality reports. Public schedule lists fees in the **$15,000-$45,000 range** for NIST CR review alone (this is the NIST fee — separate from lab costs).

### 3.3 The 21 September 2026 transition
- All FIPS 140-2 certs move to Historical on this date.
- Federal agencies cannot make new procurements citing 140-2 after that date.
- This is a forcing function for federal buyers and a sales tailwind for new 140-3 entrants.

### 3.4 Sources
- [CMVP Modules In Process](https://csrc.nist.gov/projects/cryptographic-module-validation-program/modules-in-process/modules-in-process-list)
- [NIST CMVP Cost Recovery Fees](https://csrc.nist.gov/projects/cryptographic-module-validation-program/nist-cost-recovery-fees)
- [SafeLogic CAVP 158th cert announcement](https://www.safelogic.com/blog/safelogic-advances-fips-140-3-pqc-readiness-with-new-cavp-validation)
- [FIPS 140-3 CMVP Management Manual](https://csrc.nist.gov/csrc/media/Projects/cryptographic-module-validation-program/documents/fips%20140-3/FIPS-140-3-CMVP%20Management%20Manual.pdf)

---

## 4. NSA CNSA 2.0 Timeline and DoD/Federal PQC Mandates

### 4.1 CNSA 2.0 (NSS — National Security Systems)
Original CSA published Sept 2022; reaffirmed in updated NSA CSA dated 30 May 2025 (DoD media library).

| Asset class | Support & prefer CNSA 2.0 by | Use exclusively by |
|-------------|------------------------------|--------------------|
| Software / firmware signing | ASAP | 2030 |
| **Networking equipment (VPNs, routers)** | **2026** | **2030** |
| Operating systems | 2027 | 2033 |
| Niche / custom equipment | 2030 | 2033 |
| **All NSS** | — | **By end of 2031, full enforcement** |

**Hard date that matters for VPN founders:** 1 January 2027 — **all new acquisitions of NSS equipment must be CNSA 2.0-compliant by default.** That is 20 months from today.

CNSA 2.0 mandates:
- **ML-KEM-1024** for key establishment (note: -1024, not -768)
- **ML-DSA-87** for signatures
- AES-256, SHA-384/512, LMS/XMSS for firmware

### 4.2 OMB / civilian federal
- **OMB M-23-02** (Nov 2022): annual cryptographic inventory submissions through 2035; required designation of agency PQC migration leads.
- **Quantum Computing Cybersecurity Preparedness Act** required OMB migration guidance by August 2025; whether issued on time is unclear (PQShield's plain-English guide flags this).
- **Executive Order 14306** (6 June 2025): broader cybersecurity EO that triggered CISA's January 23 2026 release of "Product Categories for Technologies That Use Post-Quantum Cryptography Standards."
- **DoD CIO memo, 20 November 2025:** directed all Pentagon components and combatant commands to inventory all cryptography across NSS, weapons systems, cloud, mobile, IoT, unmanned systems, and OT — with PQC migration leads designated within 20 days. Cited M-23-02 as governing.
- **FedRAMP** is gradually adding PQC requirements to its Rev 5 baseline; expected formalization 2026-2027.

### 4.3 Sources
- [NSA CNSA 2.0 Algorithms CSA, May 2025](https://media.defense.gov/2025/May/30/2003728741/-1/-1/0/CSA_CNSA_2.0_ALGORITHMS.PDF)
- [CNSA 2.0 FAQ](https://media.defense.gov/2022/Sep/07/2003071836/-1/-1/0/CSI_CNSA_2.0_FAQ_.PDF)
- [PostQuantum.com US PQC regulatory framework 2026](https://postquantum.com/quantum-policies/us-pqc-regulatory-framework-2026/)
- [OMB M-23-02 memo](https://www.whitehouse.gov/wp-content/uploads/2022/11/M-23-02-M-Memo-on-Migrating-to-Post-Quantum-Cryptography.pdf)
- [PQShield plain-English regulatory guide](https://pqshield.com/guide-to-recent-white-house-guidance-post-quantum-cryptography/)
- [Tychon DoD PQC mandate explainer](https://tychon.io/the-department-of-wars-new-pqc-mandate/)

---

## 5. Federal Procurement Pathways: Costs and Timelines

All figures are published April 2026 ranges; assume +20% slippage in practice. Get specific lab quotes (atsec, Acumen, Leidos, UL Lightship, Booz Allen) before committing.

### 5.1 FIPS 140-3 module validation
- **NIST CR fee:** ~$15K-$45K (CMVP Cost Recovery fee schedule effective 1 Jan 2026).
- **Accredited lab fees:** $100K-$400K typical for a fresh module validation, depending on complexity (atsec, Acumen, UL Lightship, Booz Allen, Leidos). PQC adds 20-40% to lab effort.
- **Timeline:** atsec and other labs publicly state "2+ year" end-to-end validation has gotten longer; realistic plan is **18-30 months from kickoff to issued cert**, with 9-15 months of that being lab queue + CMVP review queue.
- **Software-only modules** (e.g., what you'd build wrapping AWS-LC or wolfCrypt) tend toward the lower end; hardware modules (HSMs) toward the higher.
- **Cheapest path:** Use a vendor's pre-validated module (AWS-LC, wolfCrypt, CryptoComply) and inherit their cert via "OEM" or "rebadged module" pattern — but you need a license agreement and your *boundary* must be carefully drawn.

### 5.2 Common Criteria EAL2 / EAL4+ via NIAP
- **CCTL (testing lab) cost:** "$150,000 and upwards" per Archon Secure / NIAP-aligned guidance. Realistic full evaluation: **$200K-$500K.**
- **Timeline:** **6-12 months** from kickoff to certification.
- For a VPN client, the relevant Protection Profile is **PP-Module for VPN Client v2.4** (PP-Configuration_VPN_Client_V2.4 + cPP_ND_v3.0 base).
- Note: NIAP itself charges nothing; all costs go to the CCTL. Approved labs include Acumen Security, atsec, Booz Allen, Lightship, Leidos, UL.

### 5.3 DoDIN APL — **SUNSET 30 SEPT 2025**
- DoDIN APL was **officially sunset 30 September 2025**, with all currently-scheduled APL testing completed by 31 December 2025.
- Replaced by **DISA RME Vendor Security Technical Implementation Guides (STIG) program** (cybersecurity) and **Unified Capabilities Requirements (UCR)-CORE** (interoperability), enforced through contractual provisions rather than a list.
- Practical impact for new entrants: **one less multi-year, six-figure gauntlet.** STIG compliance is documentation-heavy but does not require dedicated lab testing.

### 5.4 FedRAMP
| Tier | Cost (3PAO + remediation + tooling) | ConMon annual | Timeline |
|------|-------------------------------------|----------------|----------|
| Low | $200K-$500K | $50K-$150K | 6-12 months traditional, ~3 months under FedRAMP 20x |
| **Moderate** | **$500K-$2M upfront** ($350K-$650K is just the 3PAO portion) | **$150K-$350K/yr** | 12-18 months traditional, ~3 months under FedRAMP 20x for mature posture |
| High | $1M-$3M+ | $300K-$700K/yr | 18-24+ months |

- **FedRAMP 20x** (announced 2025): program authorization (no agency sponsor required) + automated continuous monitoring. Phase 3 opens Low/Moderate for wide-scale adoption **FY26 Q3-Q4** — i.e., right now / very soon.
- **Realistic timeline for a solo founder hitting Moderate via 20x with strong posture:** 6-9 months and ~$500K-$1M, contingent on hosting on AWS GovCloud or another already-Authorized cloud.

### 5.5 ATO / RMF
- **Authority to Operate** is per-agency (not transferable). Each agency-issued ATO requires NIST 800-53 controls, security assessment, and continuous monitoring.
- **Cost:** $50K-$300K per agency engagement on top of FedRAMP.
- **Timeline:** 6-12 months once you have FedRAMP P-ATO or JAB authorization.

### 5.6 STIG compliance
- DISA STIGs are free to download and self-attest. Compliance is **engineering effort (1-3 engineer-months)** plus auditor cost ($25K-$75K). No lab fee.

### 5.7 CMMC (DoD contractor cybersecurity)
- For most VPN sub-contracts to DoD: **CMMC Level 2** is becoming standard. Third-party assessment fee: $30K-$100K. ~3-6 months prep + assessment.

### 5.8 Sources
- [NIST CMVP Cost Recovery Fees 2026](https://csrc.nist.gov/projects/cryptographic-module-validation-program/nist-cost-recovery-fees)
- [atsec FIPS 140-3 testing services](https://www.atsec.com/services/cryptographic-testing/fips-140-3-testing/)
- [NIAP Protection Profile for VPN Client v2.4](https://www.niap-ccevs.org/protectionprofiles/467)
- [Archon Secure NIAP cost guidance](https://www.archonsecure.com/niap)
- [DoDIN APL Sunset FAQ](https://aplits.disa.mil/docs/DODIN_APL_SUNSET_FAQ.pdf)
- [FedRAMP cost analysis 2026 (Paramify)](https://www.paramify.com/blog/fedramp-cost)
- [FedRAMP 20x guide](https://www.workstreet.com/blog/fedramp-20x-requirements)

---

## 6. Specific Market Gap Analysis

Things federal/enterprise buyers explicitly want and that **do not exist** as FIPS 140-3 validated, GA today (April 2026):

| Gap | Exists? | Notes |
|-----|---------|-------|
| **First commercial FIPS 140-3 validated PQC VPN client for iOS** | **No** | Apple corecrypto has not publicly added an ML-KEM cert. No third-party iOS VPN (OpenVPN Connect, Cisco AnyConnect, Ivanti) ships PQC inside a FIPS-validated module on iOS. **This is the single most defensible niche from your existing build.** |
| **First FIPS 140-3 validated IPsec/IKEv2 module with ML-KEM for Linux** | **No, but close** | strongSwan has integrated ML-KEM via plugin; but strongSwan itself is not a FIPS module — you'd ship strongSwan over a FIPS-validated wolfCrypt or AWS-LC FIPS 3.0 once those land their PQ-inclusive certs (likely Q3-Q4 2026). |
| FIPS 140-3 validated PQC VPN gateway appliance for SMB federal | No (Cisco FTD 10.5 closest, late 2026) | The big-vendor wave is coming; sub-$10K appliance niche is wide open if you can ship hardware. |
| FIPS 140-3 validated PQC SD-WAN | No | Versa, Cato, Aryaka — none have shipped FIPS-validated PQ. Heavier lift than VPN. |
| FedRAMP Moderate authorized PQC VPN-as-a-Service | No | Cloudflare WARP has FedRAMP boundary but not sold as standalone federal product. Closest competitor. |
| Quantum-resistant Always-on VPN for federal mobile (CSfC-aligned) | Partial | NSA's **CSfC (Commercial Solutions for Classified)** program already has Mobile Access Capability Package; PQ-augmented version not yet on CSfC components list. Real opportunity here. |
| WireGuard-with-FIPS-validated-PQ stack | Effectively no | Vendor commentary (SafeLogic, wolfSSL) is supportive, but **WireGuard's mandatory primitives (ChaCha20Poly1305, Curve25519, BLAKE2s) are not FIPS-approved.** A FIPS WireGuard requires the protocol itself to be modified — not just the crypto library. |

### 6.1 The CSfC angle is underappreciated
NSA's **CSfC (Commercial Solutions for Classified)** program lets you protect classified data using two layers of independently-evaluated commercial encryption. CSfC accepts FIPS+CC validated VPN clients/gateways. Capability Packages exist for Mobile Access, Multi-Site Connectivity, Campus WLAN, Data-at-Rest. PQ-augmented CSfC components are explicitly part of CNSA 2.0 transition. **Solo founder route:** become a CSfC component vendor on the **Mobile Access** capability package with a FIPS-validated iOS PQ VPN client.

---

## 7. Procurement Realities for Solo Founder

### 7.1 Vehicles (in order of solo-founder feasibility)
1. **SBIR / STTR.** Best route. Phase I $50K-$300K (6 months feasibility). Phase II $1.5-2M (24 months prototype/commercialization). Phase III unlimited (sole-source government contracts derived from Phase II results).
   - **DoD SBIR 2025.4 / 2026 BAA**: components include Army, Air Force, DARPA, SOCOM, with DoD SBIR 2025.4 closing 13 May 2026 and Air Force BAA closing 3 June 2026.
   - **SBIR Reauthorization signed 13 April 2026** (S. 3971, through 30 Sept 2031). New "strategic breakthrough awards" up to **$30M per company** with 100% match and 48-month timeline (0.5% set-aside at agencies with $100M+ SBIR budgets).
   - **NIST SBIR** also funds quantum / cryptography work ($3.19M February 2026 round).
2. **OTA (Other Transaction Authority).** Faster, less paperwork than FAR contracts. Often via consortia (DIU, ARCWERX, AFWERX, Tradewind). Award sizes $250K-$10M+. Needs a sponsor / problem statement.
3. **CSO competitions** (Commercial Solutions Opening). DIU is the canonical example. Solicitation-driven, 60-90 day prototype awards.
4. **GSA Schedule (MAS).** SaaS/software via SIN 54151S. Solo founder can apply but it's a **6-12 month prep** and you need ~$25K in revenue history. Useful once you have product-market fit on at least one agency.
5. **Sub-prime to a large contractor** (Booz Allen, Leidos, SAIC, Northrop, GDIT). Fastest route to actual delivery for a solo founder. They handle ATO, contract vehicles, past-performance — you provide the IP. Margins are thinner but cash flows fast.
6. **Standard FAR contracts.** Realistically out of reach for solo founder until you have past performance.

### 7.2 Mandatory infrastructure
- **SAM.gov registration** (free, 2-4 weeks).
- **UEI (Unique Entity ID)** — replaces DUNS.
- **CAGE code** — automatic with SAM registration.
- **NAICS codes**: primary candidates for a PQC VPN business —
  - `541512` Computer Systems Design Services (size standard $34M)
  - `541519` Other Computer Related Services (often used for cybersecurity)
  - `541511` Custom Computer Programming Services
  - `541330` Engineering Services (occasionally)
  - `513210` Software Publishers (if you sell software products)
- **CMMC** — at least Level 1 self-assessment baseline. Level 2 for any DoD CUI work.
- **DCAA-compliant accounting system** if you take cost-reimbursement contracts (not needed for SBIR firm-fixed-price).

### 7.3 Sources
- [DoD SBIR/STTR](https://www.defensesbirsttr.mil/)
- [SBIR awards database](https://www.sbir.gov/awards)
- [SBIR Reauthorization 2026](https://collaboration.ai/blog/the-sbir-bill-2026-a-once-in-a-decade-gift-to-every-small-innovator-in-america/)
- [NIST quantum SBIR awards Feb 2026](https://thequantuminsider.com/2026/02/11/nist-allocates-3-million-sbir-ai-biotechnology-semiconductors-quantum/)
- [GSA Schedule registration](https://www.gsa.gov/small-business/register-your-business)
- [SBA basic federal contracting requirements](https://www.sba.gov/federal-contracting/contracting-guide/basic-requirements)
- [NAICS code guidance](https://blogs.usfcr.com/top-it-naics-codes)

---

## 8. Realistic Cost and Timeline Estimates for Solo Founder

Three scenarios, all assuming you start from your current Rosenpass + WireGuard iOS+Linux working prototype (April 2026).

### Scenario A: "FIPS-pending" pilot in 9-12 months — minimum viable federal entry
- **Pivot crypto:** drop Rosenpass, drop WireGuard. Adopt strongSwan + IKEv2 + ML-KEM-1024 + ML-DSA-87 (CNSA 2.0 aligned). Pin to **wolfCrypt FIPS** (already has Active 140-3 cert; PQ cert pending). 4-6 engineer-months.
- **iOS client:** Native NetworkExtension + IKEv2 with custom IKEv2 daemon linked to wolfCrypt. 3-5 engineer-months. (Apple's native IKEv2 won't accept arbitrary KEMs.)
- **Server:** Linux strongSwan + wolfCrypt. 1-2 engineer-months.
- **Compliance start:** SAM.gov, CMMC L1, NAICS, SBIR Phase I proposal. 1-2 months.
- **Cost:** $50K-$150K (mostly your time + compliance setup + ~$10-20K legal).
- **Capital required:** $100K-$200K.
- **First revenue:** SBIR Phase I award ($150K-$300K) or pilot contract via sub-prime, **6-9 months out.**
- **Outcome:** "FIPS-validation-in-progress, CNSA 2.0 algorithm-aligned" PQC IPsec VPN. Saleable to early adopters and SBIR-funded pilots. **Not yet sellable as "FIPS 140-3 validated PQC."**

### Scenario B: Ship a real FIPS 140-3 validated PQC iOS VPN client in 18-24 months
- Everything in Scenario A, plus —
- **Submit your own software cryptographic module to CMVP**, OR (more realistically) ship over wolfCrypt-PQC / AWS-LC FIPS 3.0 once their certs land (Q4 2026 / Q1 2027), inheriting validation.
- **NIAP CC evaluation against PP-Module for VPN Client v2.4.** $200K-$500K + 9-12 months. CCTL queue is real.
- **ATO at one pilot agency** (likely via SBIR Phase II sponsor). $50K-$150K + 6 months.
- **Engineering total:** 12-18 engineer-months (you + 1-2 contractors).
- **Validation/cert costs:** $300K-$700K (CC + lab fees + CMVP if doing your own boundary).
- **Capital required:** **$750K-$1.5M.**
- **First revenue:** SBIR Phase II ($1.5-2M) is the most realistic capital source. Commercial revenue ~12-18 months after award.
- **Outcome:** Genuine "first FIPS 140-3 + NIAP CC validated PQC VPN client for iOS." Highly defensible niche.

### Scenario C: FedRAMP Moderate hosted SaaS PQ VPN service in 30-36 months
- Everything in Scenario B, plus —
- **Migrate hosting** from Hetzner Finland/Germany (definitely not FedRAMP-eligible — non-US, no FedRAMP baseline) to **AWS GovCloud (US)** or Azure Government. Months of migration work and ~3-5x infra cost.
- **FedRAMP Moderate authorization via FedRAMP 20x** (Phase 3 opens FY26 Q3-Q4). Best case **6-9 months and $500K**; realistic case **12-18 months and $1-1.5M.**
- **CMMC Level 2** assessment ($30-100K).
- **Capital required:** **$1.5M-$3M total.**
- **First federal SaaS revenue:** 24-30 months after starting.
- **Outcome:** Fully federal-procurable PQC VPNaaS. Multi-agency upside.

### Reality check on solo founder execution
At Scenario B level ($750K+, 18-24 months), this is no longer a solo project. Realistic team: **founder + 1 senior crypto/network engineer + 1 part-time compliance lead + outside fractional CISO/proposal writer.** Burn rate ~$50-80K/month. Without SBIR Phase II ($1.5-2M) or seed venture capital, this is not financeable on $1K starting capital.

---

## 9. Architectural Recommendations for an April 2026 Entrant

### 9.1 Protocol: IPsec/IKEv2, not WireGuard, not Rosenpass
- **WireGuard:** non-FIPS primitives (ChaCha20Poly1305, Curve25519, BLAKE2s). To FIPS-validate WireGuard you'd need to modify the protocol itself — not just the library — and obtain FIPS exemption. The wolfSSL "FIPS-Certified WireGuard" framing is real but is wolfSSL re-implementing on wolfCrypt; even then, the WireGuard primitives themselves are not on the FIPS-approved list. Federal procurement rejection risk is high.
- **Rosenpass:** academic / experimental. No FIPS path. Excellent for consumer; non-starter for federal.
- **IPsec/IKEv2** with **RFC 9242 (IKE-INTERMEDIATE)** + **RFC 9370 (Multiple Key Exchanges)** + ML-KEM is the **only protocol with active vendor traction (Cisco, Palo Alto, strongSwan) AND a clean FIPS algorithm story.** Use ML-KEM-1024 for CNSA 2.0; offer ML-KEM-768 hybrid for non-NSS commercial.
- IETF draft: `draft-ietf-ipsecme-ikev2-mlkem` is the canonical reference.

### 9.2 Crypto library: wolfCrypt FIPS (today) → wolfCrypt-PQC FIPS (when active) or AWS-LC FIPS 3.0
- **wolfCrypt** has active 140-3 certs (#4718, #5041), valid through July 2030. PQ cert in process.
- **AWS-LC FIPS 3.0** is the highest-profile PQ-FIPS candidate; tightly integrated with AWS ecosystem; permissive license.
- **OpenSSL 3.5/3.6 FIPS provider** is widely adoptable but cert timing is 2027.
- **SafeLogic CryptoComply** is the commercial drop-in option with strongest mobile (iOS) story — they have explicit CryptoComply Mobile v3.5 with PQ. License costs are commercial (estimate $20-100K/yr; not publicly listed).

### 9.3 Cloud architecture
- **AWS GovCloud (US)** for federal hosted SaaS — mandatory. FedRAMP High baked in; supports DoD SRG IL4/IL5, CMMC 2.0, CJIS, ITAR.
- **Hetzner Finland/Germany is unusable for federal.** Foreign data residency, no FedRAMP. Keep for the consumer business if you continue it.
- For DoD IL5 workloads: AWS GovCloud (US-East / US-West) or Azure Government (Secret).

### 9.4 iOS specifics
- iOS 18+ exposes ML-KEM via Security framework (Apple corecrypto) but Apple's own FIPS module update for PQ is not public — assume you cannot rely on it as a FIPS-validated source.
- Therefore: ship your own crypto module inside a NetworkExtension PacketTunnelProvider, linked statically to wolfCrypt-FIPS or CryptoComply Mobile.
- App Store approval for federal-targeting VPN is fine; getting on Apple Business Manager for federal MDM deployment is the harder part.
- **Existing build advantage:** your iOS NetworkExtension wiring + Apple Developer Program membership is exactly the foundation needed; the rework is replacing the Rust/Rosenpass FFI with a wolfCrypt-FIPS-backed strongSwan-style IKEv2.

### 9.5 Sources
- [strongSwan ML-KEM integration (Kivicore)](https://kivicore.com/en/embedded-security-blog/integrating-pqc-into-strongswan)
- [draft-ietf-ipsecme-ikev2-mlkem](https://www.ietf.org/archive/id/draft-ietf-ipsecme-ikev2-mlkem-03.html)
- [RFC 9370 — Multiple Key Exchanges in IKEv2](https://www.rfc-editor.org/rfc/rfc9370.html)
- [SafeLogic implementing FIPS 140-3 in WireGuard (caveats)](https://www.safelogic.com/blog/implementing-fips-140-3-cryptography-in-wireguard)
- [wolfSSL FIPS-Certified WireGuard discussion](https://www.wolfssl.com/fips-certified-wireguard-bringing-wolfcrypt-into-the-vpn-solution/)
- [AWS GovCloud overview](https://www.caplinked.com/blog/aws-govcloud-in-government-adoption-fedramp-vdrs-and-compliance/)

---

## 10. Direct Competitor Watch

### 10.1 Pure-play "first FIPS PQC VPN" startups
- **No direct hits.** No early-stage company has publicly announced its identity as "the first FIPS-validated PQC VPN" specifically. The space is dominated by (a) crypto-library/orchestration plays and (b) appliance giants.
- **QuSecure** is the closest adjacency — orchestration overlay, secured Space Force satellite link March 2023, $28M Series A extension Feb 2025 led by Accenture Ventures. They are not a VPN per se but compete in DoD pilot dollars.
- **Post-Quantum (UK)** raised $21.2M total. Not a VPN-specific play.
- **Project Eleven** $20M Series A January 2026 — blockchain-focused, not a VPN.
- **Ambit Inc.** (US) — appears in PQC-VPN-related searches; obscure; worth direct outreach if competitor scout warranted.
- **PQShield** — IP cores, not a VPN. Could be a partner (license their Kyber/Dilithium IP for hardware variants).
- **SandboxAQ** — discovery, not VPN. Could be a sales partner (they identify cryptography in customer environments; they want vendors to recommend).

### 10.2 Acquisitions
- **IonQ acquired ID Quantique** (2025). Quantum-key-distribution + PQC software adjacency. Suggests IonQ may build a cryptography arm.
- **IonQ acquired SkyWater Technology** ($1.8B, January 2026). US chip foundry — likely hardware Trojan-resistance / sovereign supply story, useful context for federal hardware plays.

### 10.3 Big-vendor PQ funding/M&A signals
- Cisco, Palo Alto, Fortinet are organic-build. No VPN-specific PQC tuck-ins announced as of April 2026.
- AWS, Microsoft, Google all building in-house (AWS-LC, SymCrypt, BoringSSL).

### 10.4 Sources
- [Quantum Insider: 25 PQC companies 2026](https://thequantuminsider.com/2026/03/25/25-companies-building-the-quantum-cryptography-communications-markets/)
- [QuSecure Series A extension Feb 2025](https://www.qusecure.com/)
- [Project Eleven $20M Series A](https://www.coindesk.com/business/2026/01/15/post-quantum-crypto-startup-project-eleven-raises-usd20-million-in-funding-round)
- [Symlex VPN PQC guide 2026](https://symlexvpn.com/quantum-safe-vpn-post-quantum-cryptography/)
- [Top PQC startups (Seedtable)](https://www.seedtable.com/best-post-quantum-cryptography-startups)

---

## 11. Synthesis — Decision Framework

### 11.1 The honest case FOR pivoting

- **You have a working iOS+Linux PQC tunnel today.** Most "first FIPS PQC VPN" claimants are starting from a slidedeck. You are starting from a shippable consumer product. That is real product-market validation that translates.
- **The federal forcing function is real:** 1 January 2027 NSS new-acquisition mandate, 21 September 2026 FIPS 140-2 sunset, OMB / DoD CIO inventory mandates. Buyers are *looking*.
- **The iOS PQC FIPS niche is empty.** None of Cisco AnyConnect, Ivanti Connect Secure, Palo Alto GlobalProtect, OpenVPN Connect have shipped FIPS-validated PQC iOS clients.
- **DoDIN APL sunset removes one major barrier** that previously favored incumbents.
- **SBIR Phase I is achievable for a solo founder with a working prototype.** $150-300K, 6 months, government IP retention.

### 11.2 The honest case AGAINST pivoting

- **$750K-$2.5M and 18-30 months** is the real cost basis for Scenario B. With $1K starting capital and no current commitments to dilute, you'd need SBIR Phase I+II, an angel round, or a sub-prime relationship to fund it.
- **Federal sales cycles are 12-24 months from first conversation to first PO.** Even with a great product.
- **Cisco FTD 10.5 (late 2026) closes the appliance-VPN window.** You must commit to mobile/iOS or CSfC niche where Cisco is weak.
- **FIPS validation queue depth is the binding constraint.** Lab queues are 9-15 months long. You cannot accelerate this with money.
- **Your current tech stack (Rosenpass, WireGuard, Hetzner EU) is 100% throwaway in the federal pivot.** Keep zero of it for the federal product. The only thing that transfers is your iOS NetworkExtension knowledge, your Apple Developer Program membership, and your own skill.
- **Consumer revenue ramps faster.** A $5/mo PQ VPN with 5,000 paying users is $300K ARR in 12-18 months and is not gated on labs / certs / SBIR.

### 11.3 Hybrid path worth considering
1. **Q2-Q3 2026:** Apply for **DoD SBIR Phase I** ($150-300K) for "FIPS 140-3-aligned PQC VPN client for iOS, CNSA 2.0 algorithms" while continuing consumer product on Rosenpass. ~6 weeks of writing time.
2. **In parallel,** keep Rosenpass consumer product live as a market-presence asset and revenue source.
3. **If Phase I awarded:** Build IPsec/IKEv2 + wolfCrypt FIPS variant with Phase I funds. Use the 6-month feasibility window to identify pilot agency sponsor.
4. **If pilot agency identified:** Phase II ($1.5-2M, 24 months) funds full FIPS+CC validation. This is the only path that does not require raising significant outside capital.
5. **If Phase I declined:** Stay consumer. Revisit in 12 months with revenue and traction.

This hybrid path costs ~$30K and 8 weeks of opportunity cost if it fails. It is dramatically cheaper than committing to the full pivot upfront.

---

## 12. Limitations of this Research

- **Web search–based.** Primary source documents (NIAP CCTL price quotes, specific lab SOWs, full FedRAMP 3PAO RFPs, internal SBIR topic lists post-13 May 2026 deadlines) require direct vendor contact / paid procurement intelligence (GovWin IQ, Bloomberg Government).
- **CMVP MIP list is updated weekly.** The April 2026 snapshot in this report will drift; verify current state at the CMVP MIP page before any commitment.
- **Cisco FTD 10.5 GA date** is "targeted late 2026" per Cisco's own blog — it may slip.
- **NIAP / CCTL pricing is highly negotiable** and varies by lab familiarity with the Protection Profile. Get 3 quotes before signing.
- **CNSA 2.0 NSS deadline (1 Jan 2027)** is an NSA-stated milestone, not a hard contractual deadline — actual procurement will mention "CNSA 2.0 compliant" and let buyers/sellers interpret. There will be slippage.

---

## Appendix A — Concrete next-7-day actions if pivoting

1. Register on SAM.gov (start the 2-4 week clock). Obtain UEI + CAGE.
2. Read the **DoD SBIR 2025.4 BAA** topic list and the **Air Force AFWERX** open topics — search "post-quantum," "PQC," "VPN," "IKEv2," "tactical mobile." Identify 3 topic candidates closing 13 May 2026 / 3 June 2026.
3. Contact **wolfSSL** sales (commercial license / FIPS module access for pre-cert PQC build).
4. Contact **Acumen Security** and **atsec** for a NIAP CC quote on PP-Module for VPN Client v2.4 (free, 1-2 weeks turnaround).
5. Read **NSA CSfC Mobile Access Capability Package v2.5** + **CNSA 2.0 FAQ** end to end.
6. Decide: commit to IPsec/IKEv2 + ML-KEM-1024 + ML-DSA-87 stack on paper. Stop investing engineering hours in Rosenpass on the federal track.
7. Identify one or two Tier-2 prime contractors (Booz Allen Cyber, Leidos, GDIT) and warm up sub-contracting conversations.

## Appendix B — Key documents to download and read

- NSA CSA "Announcing CNSA 2.0 Algorithms" (May 2025 update)
- OMB M-23-02 (Nov 2022)
- NIST FIPS 203 (ML-KEM), FIPS 204 (ML-DSA), FIPS 205 (SLH-DSA)
- NIAP PP-Module for VPN Client v2.4 + cPP_ND_v3.0
- FIPS 140-3 CMVP Management Manual (latest)
- NSA CSfC Mobile Access Capability Package v2.5
- CISA "Product Categories for Technologies That Use Post-Quantum Cryptography Standards" (23 Jan 2026)
- DoD CIO PQC Memo (20 Nov 2025, if obtainable via FOIA / DoD release)

---

*End of report. Decision quality of this document is a function of citation freshness — re-verify the CMVP MIP list, Cisco GA dates, and CCTL price quotes within 30 days of any go/no-go commitment.*
