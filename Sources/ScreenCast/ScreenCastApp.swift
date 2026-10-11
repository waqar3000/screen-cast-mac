import SwiftUI

@main
struct ScreenCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Screen Cast", id: "main") {
            ContentView(model: appDelegate.model)
        }
        .windowResizability(.contentSize)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = AppModel()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--test-cast") {
            let seconds = arguments.indices.contains(index + 1) ? Int(arguments[index + 1]) ?? 20 : 20
            model.runTestCast(seconds: seconds)
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard model.isActive else { return .terminateNow }
        // Tell the TV to stop first, so it doesn't sit on a frozen picture.
        model.stopCasting { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
