//
//  KeynoteBlurApp.swift
//  KeynoteBlur
//
//  Created by christian on 9/5/25.
//

import SwiftUI
import AppKit

@main
struct KeynoteBlurApp: App {
    @StateObject private var vm = KeynoteBlurViewModel.shared
    @StateObject private var optionKeyMonitor = OptionKeyMonitor()

    private var shouldUseMaskedCopyMenuAction: Bool {
        optionKeyMonitor.isOptionPressed && vm.hasMaskTemplateAvailable
    }

    private var copyMenuTitle: String {
        shouldUseMaskedCopyMenuAction ? "Copy masked image" : "Copy image"
    }

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        NSWindow.allowsAutomaticWindowTabbing = false
        NotificationCenter.default.addObserver(
            forName: NSApplication.didFinishLaunchingNotification,
            object: nil,
            queue: .main
        ) { _ in
            DispatchQueue.main.async {
                Self.configureApplicationIcon()
                Self.removeUnneededMenuItems()
            }
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .tint(Color("AccentColor"))
        }
        .commands {
            CommandGroup(replacing: .pasteboard) {
                Button(copyMenuTitle) {
                    if shouldUseMaskedCopyMenuAction {
                        _ = vm.copyMaskedSlideForKeynoteFromTemplate()
                    } else {
                        vm.copySlideForKeynote()
                    }
                }
                .keyboardShortcut("c", modifiers: [.command])
                .disabled(vm.originalImage == nil)

                Button("Paste") {
                    _ = vm.pasteSlideFromPasteboard()
                }
                .keyboardShortcut("v", modifiers: [.command])
                .disabled(!vm.canPasteFromPasteboard())
            }

            CommandGroup(replacing: .help) {
            }
        }
    }

    private static func configureApplicationIcon() {
        var candidates: [String] = []
        if let bundleIconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String {
            candidates.append(bundleIconName)
        }
        candidates.append(contentsOf: ["KeynoteBlur", "AppIcon"])

        for candidate in candidates {
            if let icon = NSImage(named: NSImage.Name(candidate)) {
                NSApplication.shared.applicationIconImage = icon
                return
            }
        }
    }

    private static func removeUnneededMenuItems() {
        for window in NSApplication.shared.windows {
            window.tabbingMode = .disallowed
        }

        guard let mainMenu = NSApplication.shared.mainMenu else { return }

        if let fileIndex = mainMenu.items.firstIndex(where: { $0.title == "File" }) {
            mainMenu.removeItem(at: fileIndex)
        }

        if let helpIndex = mainMenu.items.firstIndex(where: { $0.title == "Help" }) {
            mainMenu.removeItem(at: helpIndex)
        }

        let tabActions: [Selector] = [
            Selector(("toggleTabBar:")),
            Selector(("selectNextTab:")),
            Selector(("selectPreviousTab:")),
            Selector(("moveTabToNewWindow:")),
            Selector(("mergeAllWindows:"))
        ]

        for menuItem in mainMenu.items {
            pruneMenuItems(in: menuItem.submenu, actions: tabActions)
        }
    }

    private static func pruneMenuItems(in menu: NSMenu?, actions: [Selector]) {
        guard let menu else { return }

        for item in menu.items.reversed() {
            if let action = item.action, actions.contains(action) {
                menu.removeItem(item)
                continue
            }
            if let submenu = item.submenu {
                pruneMenuItems(in: submenu, actions: actions)
            }
        }
    }
}
