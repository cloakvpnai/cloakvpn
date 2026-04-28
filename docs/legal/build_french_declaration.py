#!/usr/bin/env python3
"""
Generate the French Encryption Declaration for Cloak VPN. France's
ANSSI (Agence nationale de la sécurité des systèmes d'information)
requires a declaration under Article 30 of Loi 2004-575 du 21 juin
2004 (LCEN) for any encryption product made available in France.

For mass-market software using only publicly-documented standard
cryptography, the procédure simplifiée (simplified procedure) applies —
a self-declaration is sufficient. Apple accepts this declaration as
"French Encryption Declaration Approval Form" when the app is
made available in the French App Store.

Generated bilingual (French + English) so both ANSSI and App Review
can parse it.
"""
import datetime
from reportlab.lib.pagesizes import letter
from reportlab.lib.styles import getSampleStyleSheet, ParagraphStyle
from reportlab.lib.units import inch
from reportlab.lib.enums import TA_LEFT
from reportlab.platypus import (
    SimpleDocTemplate, Paragraph, Spacer, Table, TableStyle
)
from reportlab.lib import colors

OUTPUT = "/sessions/loving-confident-dirac/mnt/cloak-vpn/docs/legal/CloakVPN-French-Encryption-Declaration.pdf"

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
styles.add(ParagraphStyle(
    name='French', parent=styles['Normal'],
    fontName='Helvetica-Oblique', fontSize=9, leading=12,
    spaceAfter=4, textColor=colors.HexColor('#333333'),
))

story = []

# --- Letterhead ---
story.append(Paragraph("Neuro AI Studios", styles['Header']))
story.append(Paragraph(
    f"French Encryption Declaration / D&eacute;claration de Cryptologie &nbsp;|&nbsp; "
    f"{datetime.date.today().strftime('%B %d, %Y')}",
    styles['SubHeader']
))

# --- Recipient ---
story.append(Paragraph(
    "<b>To / &Agrave;:</b> Apple Inc., App Review &mdash; Export Compliance",
    styles['Body2']
))
story.append(Paragraph(
    "<b>cc:</b> Agence nationale de la s&eacute;curit&eacute; des "
    "syst&egrave;mes d'information (ANSSI)",
    styles['Body2']
))
story.append(Paragraph(
    "<b>Re:</b> French Encryption Declaration for the iOS application "
    "<b>Cloak VPN</b> (Bundle ID <font name='Courier'>ai.cloakvpn.CloakVPN</font>)",
    styles['Body2']
))

# --- Body ---
story.append(Paragraph("1. Declarant / D&eacute;clarant", styles['SectionHead']))
story.append(Paragraph(
    "<b>Neuro AI Studios</b>, herein after &ldquo;the Declarant&rdquo;, "
    "publishes the iOS application Cloak VPN (the &ldquo;Product&rdquo;).",
    styles['Body2']
))
story.append(Paragraph(
    "<i>Neuro AI Studios, ci-apr&egrave;s &laquo;&nbsp;le D&eacute;clarant&nbsp;&raquo;, "
    "&eacute;dite l'application iOS Cloak VPN (le &laquo;&nbsp;Produit&nbsp;&raquo;).</i>",
    styles['French']
))

story.append(Paragraph(
    "2. Legal basis / Base l&eacute;gale", styles['SectionHead']
))
story.append(Paragraph(
    "This declaration is filed under Article 30 of Loi n&deg; 2004-575 "
    "du 21 juin 2004 pour la confiance dans l'&eacute;conomie "
    "num&eacute;rique (LCEN), as implemented by D&eacute;cret n&deg; 2007-663 "
    "du 2 mai 2007. The Product qualifies for the simplified procedure "
    "(<i>proc&eacute;dure simplifi&eacute;e</i>) applicable to mass-market "
    "cryptology means using only published standard algorithms.",
    styles['Body2']
))
story.append(Paragraph(
    "<i>La pr&eacute;sente d&eacute;claration est effectu&eacute;e au titre "
    "de l'article 30 de la LCEN, mis en &oelig;uvre par le D&eacute;cret "
    "n&deg; 2007-663. Le Produit relève de la proc&eacute;dure simplifi&eacute;e "
    "applicable aux moyens de cryptologie de grande diffusion utilisant "
    "exclusivement des algorithmes standardis&eacute;s.</i>",
    styles['French']
))

story.append(Paragraph(
    "3. Description of the Product / Description du Produit",
    styles['SectionHead']
))
story.append(Paragraph(
    "Cloak VPN is a consumer iOS application that establishes an "
    "encrypted Virtual Private Network tunnel between the user's "
    "device and the Declarant's region servers. Distribution is "
    "exclusively through the Apple App Store as a mass-market consumer "
    "product. The Product is not specifically designed for use by "
    "government, military, or law-enforcement end users.",
    styles['Body2']
))
story.append(Paragraph(
    "<i>Cloak VPN est une application iOS grand public &eacute;tablissant "
    "un tunnel VPN chiffr&eacute; entre l'appareil de l'utilisateur et les "
    "serveurs r&eacute;gionaux du D&eacute;clarant. Distribution exclusivement "
    "via l'App Store d'Apple, en tant que produit de grande diffusion "
    "destin&eacute; au grand public.</i>",
    styles['French']
))

story.append(Paragraph(
    "4. Cryptographic components / Composants cryptographiques",
    styles['SectionHead']
))
story.append(Paragraph(
    "All cryptographic primitives used by the Product are publicly "
    "documented, peer-reviewed, and standardized by recognized "
    "international standards bodies (IETF, NIST, IEEE). No proprietary "
    "cryptography is implemented.",
    styles['Body2']
))

components = [
    ["Component / Composant", "Standard / R&eacute;f&eacute;rence"],
    ["TLS 1.3", "RFC 8446 (IETF)"],
    ["WireGuard transport", "Donenfeld 2017; IETF wg WG"],
    ["ChaCha20-Poly1305 AEAD", "RFC 8439 (IETF)"],
    ["Curve25519 ECDH", "RFC 7748 (IETF)"],
    ["BLAKE2s", "RFC 7693 (IETF)"],
    ["Rosenpass post-quantum KEX", "IEEE EuroS&amp;P 2024"],
    ["Classic McEliece KEM", "NIST PQC Round 4"],
    ["ML-KEM (Kyber-768)", "FIPS 203 (NIST, Aug 2024)"],
    ["SHA-256, SHA-3, HMAC, HKDF", "FIPS 180-4, 202; RFC 2104, 5869"],
]

t = Table([[Paragraph(c, styles['Body2']) for c in row] for row in components],
          colWidths=[2.6*inch, 4.0*inch])
t.setStyle(TableStyle([
    ('BACKGROUND', (0, 0), (-1, 0), colors.lightgrey),
    ('FONTSIZE', (0, 0), (-1, -1), 9),
    ('ALIGN', (0, 0), (-1, -1), 'LEFT'),
    ('VALIGN', (0, 0), (-1, -1), 'TOP'),
    ('GRID', (0, 0), (-1, -1), 0.25, colors.grey),
    ('LEFTPADDING', (0, 0), (-1, -1), 6),
    ('RIGHTPADDING', (0, 0), (-1, -1), 6),
    ('TOPPADDING', (0, 0), (-1, -1), 4),
    ('BOTTOMPADDING', (0, 0), (-1, -1), 4),
]))
story.append(t)

story.append(Paragraph(
    "5. Use of cryptography / Utilisation de la cryptographie",
    styles['SectionHead']
))
story.append(Paragraph(
    "Encryption is used solely to establish a confidential and "
    "authenticated tunnel for the user's network traffic, and to "
    "authenticate the user's device to the Declarant's provisioning "
    "API. No covert use, no anti-forensic features, no end-user "
    "configurable parameters that would enable non-standard usage.",
    styles['Body2']
))
story.append(Paragraph(
    "<i>La cryptographie est utilis&eacute;e exclusivement pour &eacute;tablir "
    "un tunnel confidentiel et authentifi&eacute; pour le trafic r&eacute;seau "
    "de l'utilisateur, et pour authentifier l'appareil aupr&egrave;s de "
    "l'API de provisionnement du D&eacute;clarant.</i>",
    styles['French']
))

story.append(Paragraph(
    "6. Free movement within the EU / Libre circulation au sein de l'UE",
    styles['SectionHead']
))
story.append(Paragraph(
    "As mass-market software using only standardized cryptography, the "
    "Product is eligible for free movement under EU Regulation 2021/821 "
    "(Annex IV-bis exemptions for items meeting the Cryptography Note "
    "criteria of Annex I, category 5 part 2).",
    styles['Body2']
))

story.append(Paragraph(
    "7. Declaration / D&eacute;claration",
    styles['SectionHead']
))
story.append(Paragraph(
    "I, the undersigned, certify that the information provided in this "
    "declaration is accurate, that the Product uses only publicly "
    "documented and standardized cryptographic algorithms, and that the "
    "Product qualifies for the simplified procedure under French and EU "
    "encryption regulations.",
    styles['Body2']
))
story.append(Paragraph(
    "<i>Je soussign&eacute; certifie que les informations fournies dans la "
    "pr&eacute;sente d&eacute;claration sont exactes, que le Produit utilise "
    "exclusivement des algorithmes cryptographiques publiquement "
    "document&eacute;s et standardis&eacute;s, et que le Produit relève de la "
    "proc&eacute;dure simplifi&eacute;e applicable au titre de la r&eacute;glementation "
    "fran&ccedil;aise et europ&eacute;enne en matière de cryptologie.</i>",
    styles['French']
))

# --- Signature block ---
story.append(Spacer(1, 30))
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
