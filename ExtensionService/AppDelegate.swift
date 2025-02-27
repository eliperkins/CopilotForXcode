import Combine
import FileChangeChecker
import GitHubCopilotService
import LaunchAgentManager
import Logger
import Preferences
import Service
import ServiceManagement
import SwiftUI
import UpdateChecker
import UserDefaultsObserver
import UserNotifications
import XcodeInspector
import XPCShared

let bundleIdentifierBase = Bundle.main
    .object(forInfoDictionaryKey: "BUNDLE_IDENTIFIER_BASE") as! String
let serviceIdentifier = bundleIdentifierBase + ".ExtensionService"

class ExtensionUpdateCheckerDelegate: UpdateCheckerDelegate {
    func prepareForRelaunch(finish: @escaping () -> Void) {
        Task {
            await Service.shared.prepareForExit()
            finish()
        }
    }
}

@main
class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let service = Service.shared
    var statusBarItem: NSStatusItem!
    var xpcController: XPCController?
    let updateChecker =
        UpdateChecker(
            hostBundle: Bundle(url: locateHostBundleURL(url: Bundle.main.bundleURL)),
            checkerDelegate: ExtensionUpdateCheckerDelegate()
        )
    let statusChecker: AuthStatusChecker = AuthStatusChecker()
    var xpcExtensionService: XPCExtensionService?
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_: Notification) {
        if ProcessInfo.processInfo.environment["IS_UNIT_TEST"] == "YES" { return }
        _ = XcodeInspector.shared
        service.start()
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true,
        ] as CFDictionary)
        setupQuitOnUpdate()
        setupQuitOnUserTerminated()
        setupQuitOnFeatureFlag()
        xpcController = .init()
        Logger.service.info("XPC Service started.")
        NSApp.setActivationPolicy(.accessory)
        buildStatusBarMenu()
    }

    @objc func quit() {
        Task { @MainActor in
            await service.prepareForExit()
            await xpcController?.quit()
            NSApp.terminate(self)
        }
    }

    @objc func openCopilotForXcode() {
        let task = Process()
        let appPath = locateHostBundleURL(url: Bundle.main.bundleURL)
        task.launchPath = "/usr/bin/open"
        task.arguments = [appPath.absoluteString]
        task.launch()
        task.waitUntilExit()
    }

    @objc func openGlobalChat() {
        Task { @MainActor in
            let serviceGUI = Service.shared.guiController
            serviceGUI.openGlobalChat()
        }
    }

    func setupQuitOnUpdate() {
        Task {
            guard let url = Bundle.main.executableURL else { return }
            let checker = await FileChangeChecker(fileURL: url)

            // If Xcode or Copilot for Xcode is made active, check if the executable of this program
            // is changed. If changed, quit this program.

            let sequence = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didActivateApplicationNotification)
            for await notification in sequence {
                try Task.checkCancellation()
                guard let app = notification
                    .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.isUserOfService
                else { continue }
                guard await checker.checkIfChanged() else {
                    Logger.service.info("Extension Service is not updated, no need to quit.")
                    continue
                }
                Logger.service.info("Extension Service will quit.")
                #if DEBUG
                #else
                quit()
                #endif
            }
        }
    }

    func setupQuitOnUserTerminated() {
        Task {
            // Whenever Xcode or the host application quits, check if any of the two is running.
            // If none, quit the XPC service.

            let sequence = NSWorkspace.shared.notificationCenter
                .notifications(named: NSWorkspace.didTerminateApplicationNotification)
            for await notification in sequence {
                try Task.checkCancellation()
                guard UserDefaults.shared.value(for: \.quitXPCServiceOnXcodeAndAppQuit)
                else { continue }
                guard let app = notification
                    .userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                    app.isUserOfService
                else { continue }
                if NSWorkspace.shared.runningApplications.contains(where: \.isUserOfService) {
                    continue
                }
                quit()
            }
        }
    }

    func setupQuitOnFeatureFlag() {
        FeatureFlagNotifierImpl.shared.featureFlagsDidChange.sink { [weak self] (flags) in
            if flags.x != true {
                Logger.service.info("Xcode feature flag not granted, quitting.")
                self?.quit()
            }
        }.store(in: &cancellables)
    }

    func requestAccessoryAPIPermission() {
        AXIsProcessTrustedWithOptions([
            kAXTrustedCheckOptionPrompt.takeRetainedValue() as NSString: true,
        ] as NSDictionary)
    }

    @objc func checkForUpdate() {
        guard let updateChecker = updateChecker else {
            Logger.service.error("Unable to check for updates: updateChecker is nil.")
            return
        }
        updateChecker.checkForUpdates()
    }

    func getXPCExtensionService() -> XPCExtensionService {
        if let service = xpcExtensionService { return service }
        let service = XPCExtensionService(logger: .service)
        xpcExtensionService = service
        return service
    }
}

extension NSRunningApplication {
    var isUserOfService: Bool {
        [
            "com.apple.dt.Xcode",
            bundleIdentifierBase,
        ].contains(bundleIdentifier)
    }
}

func locateHostBundleURL(url: URL) -> URL {
    var nextURL = url
    while nextURL.path != "/" {
        nextURL = nextURL.deletingLastPathComponent()
        if nextURL.lastPathComponent.hasSuffix(".app") {
            return nextURL
        }
    }
    let devAppURL = url
        .deletingLastPathComponent()
        .appendingPathComponent("GitHub Copilot for Xcode Dev.app")
    return devAppURL
}

