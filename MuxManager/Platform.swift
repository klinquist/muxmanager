import SwiftUI
import MuxCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
enum AppPlatform {
    static func isLocal(_ profile: MuxCore.ConnectionProfile) -> Bool {
        #if os(macOS)
        profile.isLocalMac
        #else
        false
        #endif
    }
    static var isPhone: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .phone
        #else
        false
        #endif
    }
    static var isTablet: Bool {
        #if os(iOS)
        UIDevice.current.userInterfaceIdiom == .pad
        #else
        false
        #endif
    }
    static var isActive: Bool {
        #if os(iOS)
        UIApplication.shared.applicationState == .active
        #else
        true // macOS connections and notification navigation also work inactive.
        #endif
    }
    static func activate() {
        #if os(macOS)
        NSApp.activate(ignoringOtherApps: true)
        #endif
    }
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }
    static var notificationSettingsURL: URL {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!
        #else
        URL(string: UIApplication.openSettingsURLString)!
        #endif
    }
}

extension ToolbarItemPlacement {
    static var muxInfo: Self {
        #if os(macOS)
        .navigation
        #else
        .topBarLeading
        #endif
    }
}

extension View {
    @ViewBuilder func muxConnectionSheet() -> some View {
        #if os(macOS)
        frame(minWidth: 700, idealWidth: 740, minHeight: 600, idealHeight: 640)
        #else
        self
        #endif
    }

    @ViewBuilder func muxInlineTitle() -> some View {
        #if os(iOS)
        navigationBarTitleDisplayMode(.inline)
        #else
        self
        #endif
    }
    @ViewBuilder func muxNoCapitalization() -> some View {
        #if os(iOS)
        textInputAutocapitalization(.never)
        #else
        self
        #endif
    }
    @ViewBuilder func muxURLInput() -> some View {
        #if os(iOS)
        textContentType(.URL).keyboardType(.URL)
        #else
        self
        #endif
    }
    @ViewBuilder func muxNumberInput() -> some View {
        #if os(iOS)
        keyboardType(.numberPad)
        #else
        self
        #endif
    }
    @ViewBuilder func muxMediumSheet() -> some View {
        #if os(iOS)
        presentationDetents([.medium])
        #else
        frame(minWidth: 420, idealWidth: 480, minHeight: 200)
        #endif
    }
    @ViewBuilder func muxFormSheet() -> some View {
        #if os(macOS)
        frame(minWidth: 460, idealWidth: 520, minHeight: 420, idealHeight: 560)
        #else
        self
        #endif
    }
}
