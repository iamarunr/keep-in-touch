import SwiftUI
#if os(macOS)
import AppKit
#else
import UIKit
#endif

// The few places where iPhone and Mac need different code, so the screens themselves don't.

extension Color {
    static var pageBackground: Color {
        #if os(macOS)
        Color(nsColor: .windowBackgroundColor)
        #else
        Color(uiColor: .systemGroupedBackground)
        #endif
    }

    static var cardBackground: Color {
        #if os(macOS)
        Color(nsColor: .controlBackgroundColor)
        #else
        Color(uiColor: .secondarySystemGroupedBackground)
        #endif
    }
}

extension ToolbarItemPlacement {
    static var leading: ToolbarItemPlacement {
        #if os(macOS)
        .automatic
        #else
        .topBarLeading
        #endif
    }
}

extension View {
    @ViewBuilder func inlineTitle() -> some View {
        #if os(macOS)
        self
        #else
        navigationBarTitleDisplayMode(.inline)
        #endif
    }

    @ViewBuilder func emailEntry() -> some View {
        #if os(macOS)
        autocorrectionDisabled()
        #else
        keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
        #endif
    }

    @ViewBuilder func phoneEntry() -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(.phonePad)
        #endif
    }

    @ViewBuilder func digitsEntry() -> some View {
        #if os(macOS)
        self
        #else
        keyboardType(.numberPad)
        #endif
    }

    @ViewBuilder func noCapitals() -> some View {
        #if os(macOS)
        self
        #else
        textInputAutocapitalization(.never)
        #endif
    }

    /// Mac sheets and forms size to their content, so they need a minimum and the grouped look.
    @ViewBuilder func sheetSize() -> some View {
        #if os(macOS)
        formStyle(.grouped).frame(minWidth: 440, minHeight: 480)
        #else
        self
        #endif
    }
}

enum Platform {
    /// Where the person turns Contacts access on for this app.
    static var contactsSettingsURL: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Contacts")
        #else
        URL(string: UIApplication.openSettingsURLString)
        #endif
    }
}
