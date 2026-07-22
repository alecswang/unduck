import AppKit
import ApplicationServices
import SwiftUI

/// First-run checklist.
///
/// Unduck needs two grants and neither can be fully automated: audio capture can at
/// least raise a prompt, but Accessibility is one macOS refuses to let an app request
/// — the user has to find a Settings pane and flip a switch. Left to a README that is
/// a silent, invisible failure, because a denied tap returns zeros rather than an
/// error and a missing Accessibility grant just means media never resumes.
///
/// So the checklist lives in the app: it shows what is missing, why it matters, and
/// opens the exact pane. It hides itself entirely once everything is granted, so it
/// costs a returning user nothing.
struct SetupView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        if !controller.setupComplete {
            VStack(alignment: .leading, spacing: 10) {
                Text("Setup")
                    .font(.headline)

                step(done: controller.permission.isUsable,
                     title: "Allow audio capture",
                     detail: "Lets Unduck hear other apps so it can rebalance them.",
                     action: controller.permission.isUsable ? nil : ("Allow\u{2026}", {
                         controller.requestAudioCapture()
                     }))

                step(done: controller.accessibilityGranted,
                     title: "Allow Accessibility",
                     detail: "Only used to un-pause the music your call interrupted.",
                     action: controller.accessibilityGranted ? nil : ("Open Settings\u{2026}", {
                         controller.openAccessibilitySettings()
                     }),
                     // Skip is offered rather than assumed: this grant is genuinely
                     // optional, but leaving it out silently costs auto-resume and
                     // nothing else would ever say so.
                     skip: controller.accessibilityGranted ? nil : {
                         controller.accessibilitySkipped = true
                     })

                step(done: controller.isInstalled,
                     title: "Move Unduck to Applications",
                     detail: "Keeps the login item working after updates.",
                     action: nil)

                Divider()
            }
        }
    }

    @ViewBuilder
    private func step(done: Bool, title: String, detail: String,
                      action: (String, () -> Void)?,
                      skip: (() -> Void)? = nil) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(done ? Color.green : .secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.callout)
                Text(detail).font(.caption).foregroundStyle(.secondary)
                if let skip {
                    Button("Skip \u{2014} I don't need auto-resume", action: skip)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            Spacer()
            if let (label, run) = action {
                Button(label, action: run).font(.caption)
            }
        }
    }
}
