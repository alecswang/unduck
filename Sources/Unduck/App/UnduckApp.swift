import AppKit
import SwiftUI

@main
struct UnduckApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var controller = Controller()

    var body: some Scene {
        Window("Unduck", id: "mixer") {
            MixerView(controller: controller)
                .frame(minWidth: 320, minHeight: 340)
        }
        .windowResizability(.contentSize)

        MenuBarExtra {
            MixerView(controller: controller)
        } label: {
            // Text, not an SF Symbol: a symbol name that does not exist on the
            // running OS renders as an empty image, which looks exactly like the
            // app failing to launch. Text always draws something.
            Text(controller.isEngaged ? "◉ CM" : "CM")
        }
        .menuBarExtraStyle(.window)
        .onChange(of: controller.isEngaged) { _, engaged in
            delegate.controller = engaged ? controller : nil
        }
    }
}

/// Restores the user's volume on every termination path the process can still
/// observe. The on-disk fallback in VolumeGuard covers the ones it cannot.
final class AppDelegate: NSObject, NSApplicationDelegate {
    var controller: Controller?

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { controller?.restoreEverything() }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Come to the front on launch. Without this the window can open behind
        // whatever the user was already looking at, which reads as "nothing
        // happened" — the same complaint the menu bar item caused.
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Clicking the Dock icon reopens the mixer instead of doing nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { NSApp.windows.first?.makeKeyAndOrderFront(nil) }
        return true
    }
}

struct MixerView: View {
    @ObservedObject var controller: Controller

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            SetupView(controller: controller)

            HStack {
                Circle()
                    .fill(controller.isEngaged ? Color.green : (controller.isOnCall ? .orange : .secondary))
                    .frame(width: 8, height: 8)
                Text(controller.status)
                    .font(.callout)
                Spacer()
                Toggle("", isOn: Binding(get: { controller.enabled },
                                         set: { controller.setEnabled($0) }))
                    .labelsHidden()
                    .toggleStyle(.switch)
            }

            Divider()

            fader("Call voice", value: $controller.callLevel)
            fader("Music", value: $controller.mediaLevel)
            fader("Master", value: $controller.masterLevel)

            Divider()

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text("Duck compensation").font(.callout)
                    Spacer()
                    Text(String(format: "%.0f dB", controller.compensationDB))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Slider(value: $controller.compensationDB, in: 0...60)
                Text("FaceTime cuts other audio by 30 dB. This puts it back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Divider()

            Toggle("Un-pause media when a call starts", isOn: $controller.autoResume)
                .font(.callout)
            Toggle("Start Unduck at login", isOn: $controller.launchAtLogin)
                .font(.callout)
            if !controller.isInstalled {
                Text("Running from a build folder — move Unduck to /Applications so the login item keeps working.")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            HStack {
                Text("Only resumes apps that were playing right before the call.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Grant\u{2026}") { controller.requestResumePermissions() }
                    .font(.caption)
            }

            Divider()

            if controller.testModeAvailable {
                HStack {
                    Button(controller.isEngaged ? "Stop test" : "Test takeover") {
                        controller.isEngaged ? controller.disengage() : controller.engage(compensate: false)
                    }
                    Text("no makeup gain, volume untouched")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Divider()
            }

            HStack {
                Button("Restore everything") { controller.restoreEverything() }
                Spacer()
                Button("Quit") { NSApplication.shared.terminate(nil) }
            }
            .font(.callout)
        }
        .padding(14)
        .frame(width: 300)
        // Permissions are granted in System Settings, in another process. Re-read them
        // whenever the user comes back to Unduck, or the checklist keeps showing steps
        // they have already done.
        .onReceive(NotificationCenter.default.publisher(
            for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.refreshSetupState()
        }
    }

    private func fader(_ title: String, value: Binding<Float>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title).font(.callout)
                Spacer()
                Text(value.wrappedValue <= 0.001
                     ? "muted"
                     : String(format: "%+.0f dB", 20 * log10(value.wrappedValue)))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: 0...1)
        }
    }
}
