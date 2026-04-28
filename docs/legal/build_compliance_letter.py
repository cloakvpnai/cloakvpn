#!/usr/bin/env python3
"""
Generate the App Encryption Compliance Letter PDF that gets uploaded to
App Store Connect when the export-compliance wizard requires
documentation. Self-classification under ECCN 5D992.c (mass-market
software using only publicly-available standard encryption).

This letter is what the user signs, dates, and uploads. Apple accepts
self-prepared classification letters for first-time submissions while
the developer files the formal Year-End Self-Classification Report
with BIS in parallel (which they need anyway by Feb 1 each year).
"""
import datetime
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.lib.enums import TA_LEFT, TA_CENTER
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle, PageBreak
)
from reportlab.lib import colors

OUTPUT = "/sessions/loving-confident-dirac/mnt/cloak-vpn/docs/legal/CloakVPN-Encryption-Compliance.pdf"

doc = SimpleDocTemplate(
    OUTPUT, pagesize=letter,
    leftMargin=0.9*inch, rightMargin=0.9*inch,
    topMargin=0.9*inch, bottomMargin=0.9*inch,
)

styles = getSampleStyleSheet()
styles.add(ParagraphStyle(
    name='Header', parent=styles['Title'],
    fontName='Helvetica-Bold', fontSize=14, alignment=TA_LEFT,
    spaceAfter=2,
))
styles.add(ParagraphStyle(
    name='SubHeader', parent=styles['Normal'],
    fontName='Helvetica', fontSize=10, textColor=colors.grey,
    spaceAfter=20,
))
styles.add(ParagraphStyle(
    name='SectionHead', parent=styles['Heading2'],
    fontName='Helvetica-Bold', fontSize=12, spaceAfter=4, spaceBefore=14,
))
styles.add(ParagraphStyle(
    name='Body2', parent=styles['Normal'],
    fontName='Helvetica', fontSize=10, leading=14,
    spaceAfter=6,
))

story = []

# --- Letterhead ---
story.append(Paragraph("Neuro AI Studios", styles['Header']))
story.append(Paragraph(
    f"App Encryption Compliance Statement &nbsp;&nbsp;|&nbsp;&nbsp; "
    f"{datetime.date.today().strftime('%B %d, %Y')}",
    styles['SubHeader']
))

# --- Recipient ---
story.append(Paragraph(
    "<b>To:</b> Apple Inc., App Review &mdash; Export Compliance",
    styles['Body2']
))
story.append(Paragraph(
    "<b>Re:</b> App Encryption Documentation for <b>Cloak VPN</b> "
    "(Bundle ID <font name='Courier'>ai.cloakvpn.CloakVPN</font>)",
    styles['Body2']
))

# --- Body ---
story.append(Paragraph("1. Product description", styles['SectionHead']))
story.append(Paragraph(
    "Cloak VPN is a consumer mobile application (the &ldquo;App&rdquo;) "
    "that provides a Virtual Private Network service for iOS devices. "
    "The App is published by Neuro AI Studios and distributed to "
    "the general public through the Apple App Store. The App is intended "
    "for mass-market consumer use.",
    styles['Body2']
))

story.append(Paragraph(
    "2. Export classification",
    styles['SectionHead']
))
story.append(Paragraph(
    "We hereby self-classify the App under U.S. Export Administration "
    "Regulations Export Control Classification Number "
    "<b>5D992.c</b> &mdash; mass-market encryption software meeting the "
    "criteria of EAR &sect;&sect; 740.17(b)(1) and 742.15(b)(1). "
    "The App is eligible for export to all destinations not embargoed "
    "by the United States.",
    styles['Body2']
))

story.append(Paragraph(
    "3. Encryption components",
    styles['SectionHead']
))
story.append(Paragraph(
    "The App implements only standard, publicly-documented encryption "
    "algorithms. Specifically:",
    styles['Body2']
))

components = [
    ["Component", "Standard / Reference"],
    ["TLS 1.3 (HTTPS API)",
     "RFC 8446 (IETF standard)"],
    ["WireGuard data plane",
     "Whitepaper by Donenfeld; RFC drafts in IETF wg WG"],
    ["ChaCha20-Poly1305 AEAD (WireGuard)",
     "RFC 8439 (IETF standard)"],
    ["Curve25519 ECDH (WireGuard)",
     "RFC 7748 (IETF standard)"],
    ["BLAKE2s hash (WireGuard)",
     "RFC 7693 (IETF standard)"],
    ["Rosenpass post-quantum key exchange",
     "Peer-reviewed at IEEE EuroS&amp;P 2024"],
    ["Classic McEliece KEM (Rosenpass)",
     "NIST PQC Round 4 candidate, public spec"],
    ["ML-KEM (Kyber-768) (Rosenpass)",
     "FIPS 203 (NIST standard, Aug 2024)"],
    ["SHA-256, SHA-3, HMAC, HKDF",
     "FIPS 180-4, FIPS 202, RFC 2104, RFC 5869"],
]

t = Table(components, colWidths=[2.6*inch, 4.0*inch])
t.setStyle(TableStyle([
    ('FONTNAME', (0, 0), (-1, 0), 'Helvetica-Bold'),
    ('FONTSIZE', (0, 0), (-1, -1), 9),
    ('BACKGROUND', (0, 0), (-1, 0), colors.lightgrey),
    ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
    ('VALIGN', (0, 0), (-1, -1), 'TOP'),
    ('GRID', (0, 0), (-1, -1), 0.25, colors.grey),
    ('LEFTPADDING', (0, 0), (-1, -1), 6),
    ('RIGHTPADDING', (0, 0), (-1, -1), 6),
    ('TOPPADDING', (0, 0), (-1, -1), 4),
    ('BOTTOMPADDING', (0, 0), (-1, -1), 4),
]))
story.append(t)

story.append(Paragraph("4. No proprietary encryption", styles['SectionHead']))
story.append(Paragraph(
    "The App does <b>not</b> implement, contain, or rely on any "
    "proprietary or unpublished encryption algorithms. All cryptographic "
    "primitives used are publicly available, peer-reviewed, and "
    "standardized by recognized international standards bodies "
    "(IETF, NIST, IEEE).",
    styles['Body2']
))

story.append(Paragraph("5. Use of encryption", styles['SectionHead']))
story.append(Paragraph(
    "Encryption is used in the App for the following purposes only:",
    styles['Body2']
))
story.append(Paragraph(
    "&bull; Establishing a secure tunnel between the user&rsquo;s device "
    "and our region servers, so the user&rsquo;s internet traffic is "
    "protected from network observers (the App&rsquo;s primary purpose).",
    styles['Body2']
))
story.append(Paragraph(
    "&bull; Authenticating the user&rsquo;s device to our provisioning "
    "API via short-lived JWT tokens.",
    styles['Body2']
))
story.append(Paragraph(
    "&bull; Verifying the integrity of configuration data exchanged "
    "with our region servers.",
    styles['Body2']
))

story.append(Paragraph("6. Distribution", styles['SectionHead']))
story.append(Paragraph(
    "The App is distributed exclusively through the Apple App Store "
    "and is generally available to any consumer with an Apple ID. "
    "It is not specifically designed or marketed for use by government "
    "or military end users.",
    styles['Body2']
))

story.append(Paragraph("7. Annual self-classification report", styles['SectionHead']))
story.append(Paragraph(
    "Neuro AI Studios will file the Year-End Self-Classification Report "
    "with the U.S. Bureau of Industry and Security via SNAP-R prior to "
    "the next applicable filing deadline (February 1, "
    f"{datetime.date.today().year + 1 if datetime.date.today().month > 1 else datetime.date.today().year}).",
    styles['Body2']
))

# --- Signature block ---
story.append(Spacer(1, 30))
story.append(Paragraph(
    "I certify that the information in this statement is true and accurate "
    "to the best of my knowledge.",
    styles['Body2']
))
story.append(Spacer(1, 36))

sig_table = Table([
    ["__________________________________", "__________________________________"],
    ["Signature", "Date"],
    ["", ""],
    ["Demetris Dangerfield", ""],
    ["Neuro AI Studios", ""],
    ["support@cloakvpn.ai", ""],
], colWidths=[3.0*inch, 3.0*inch])
sig_table.setStyle(TableStyle([
    ('FONTNAME', (0, 0), (-1, -1), 'Helvetica'),
    ('FONTSIZE', (0, 0), (-1, -1), 9),
    ('FONTSIZE', (0, 1), (-1, 1), 8),
    ('TEXTCOLOR', (0, 1), (-1, 1), colors.grey),
    ('VALIGN', (0, 0), (-1, -1), 'TOP'),
    ('LEFTPADDING', (0, 0), (-1, -1), 0),
    ('RIGHTPADDING', (0, 0), (-1, -1), 0),
    ('TOPPADDING', (0, 0), (-1, -1), 0),
    ('BOTTOMPADDING', (0, 0), (-1, -1), 2),
]))
story.append(sig_table)

doc.build(story)

import os
print(f"Wrote {OUTPUT}  ({os.path.getsize(OUTPUT)} bytes)")
