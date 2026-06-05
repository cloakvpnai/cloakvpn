// SPDX-License-Identifier: MIT
//
// Lattice VPN — open-source acknowledgements screen.
//
// Displays the bundled ThirdPartyNotices.txt (WireGuard, Rosenpass, liboqs,
// and their MIT / Apache-2.0 license texts). Required to comply with the
// attribution terms of those licenses. Pure in-app text — no external links.

import SwiftUI

struct AcknowledgementsView: View {
    @State private var notices: String = ""

    var body: some View {
        ScrollView {
            Text(notices)
                .font(.system(size: 12, design: .monospaced))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle("Open-Source Licenses")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            if let url = Bundle.main.url(forResource: "ThirdPartyNotices", withExtension: "txt"),
               let text = try? String(contentsOf: url, encoding: .utf8) {
                notices = text
            } else {
                notices = "Lattice VPN is built on open-source software including "
                    + "WireGuard, Rosenpass, and liboqs (Open Quantum Safe). "
                    + "Full license texts could not be loaded; see latticevpn.ai."
            }
        }
    }
}
