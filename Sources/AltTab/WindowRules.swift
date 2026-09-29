import Foundation

/// Where a window is, which decides how it is drawn and how it is brought back.
enum WindowKind {
    /// Drawn on a desktop in front of you right now.
    case onScreen
    /// Behind another tab of the same window, or set aside by Stage Manager.
    case tab
    /// On another desktop, or a full-screen app's own.
    case otherDesktop
    /// Its app was hidden with ⌘H.
    case hidden
    /// In the Dock.
    case minimized
}

/// The rules that decide which windows get a row, and in what order.
///
/// Kept apart from AppKit and from the calls that gather the evidence, so the
/// decisions can be read — and checked — on their own.
enum WindowRules {

    /// What the app itself said about the window, through Accessibility.
    /// Accessibility only sees the desktop in front of you.
    struct Reported {
        var isMinimized: Bool
        var isWindowLike: Bool
        var subrole: String?
    }

    /// Where the window server has put the window.
    enum Placement {
        /// Drawn on a desktop that some display is showing.
        case drawnHere
        /// Drawn on another desktop, or on a full-screen app's own.
        case drawnElsewhere
        /// Attached to a desktop but not drawn: minimised, or its app hidden.
        case parked
        /// Attached to no desktop at all: closed but kept alive, or a helper.
        case nowhere
    }

    struct Evidence {
        var onScreen: Bool
        var ownerIsRegular: Bool
        var ownerIsHidden: Bool
        var titled: Bool
        /// Big enough to be a window a person means, even with nothing else
        /// to vouch for it.
        var sizable: Bool
        /// Same app, same frame as a window on screen: what a tab looks like.
        var sharesFrameWithVisibleWindow: Bool
        var reported: Reported?
        /// `nil` when the window server's desktops could not be read.
        var placement: Placement?
    }

    enum Verdict: Equatable {
        case include(WindowKind)
        case reject(String)
    }

    static func judge(_ e: Evidence, includeMinimized: Bool, includeOtherSpaces: Bool) -> Verdict {
        let minimized: Verdict = includeMinimized
            ? .include(.minimized) : .reject("minimized, off in Settings")
        let hidden: Verdict = includeOtherSpaces
            ? .include(.hidden) : .reject("hidden app, off in Settings")
        let otherDesktop: Verdict = includeOtherSpaces
            ? .include(.otherDesktop) : .reject("other desktop, off in Settings")

        if e.onScreen {
            // A menu bar utility draws mostly popovers and HUDs; only what it
            // calls a window of its own gets a row.
            guard e.ownerIsRegular || e.reported?.isWindowLike == true else {
                return .reject("menu bar app, not a standard window")
            }
            return .include(.onScreen)
        }

        if let reported = e.reported {
            if reported.isMinimized { return minimized }
            if e.placement == .parked && !e.ownerIsHidden { return minimized }
            guard reported.isWindowLike else {
                return .reject("off screen, subrole \(reported.subrole ?? "none")")
            }
            guard e.titled || e.sizable else { return .reject("off screen, untitled and small") }
            if e.ownerIsHidden {
                guard e.placement != .nowhere else {
                    return .reject("hidden app, window not on any desktop")
                }
                return hidden
            }
            if e.placement == .drawnElsewhere { return otherDesktop }
            // Known to the app on this desktop, not minimised, and yet not
            // drawn: a tab behind another tab, or a window Stage Manager set
            // aside. The app lists nothing it merely closed.
            return .include(.tab)
        }

        guard e.ownerIsRegular else { return .reject("menu bar app, off screen") }
        guard e.titled || e.sizable else { return .reject("off screen, untitled and small") }

        // Not drawn anywhere, yet exactly the size and place of a window its
        // app is showing: a tab behind that one. Apps do not always list
        // those, which is why the window server's word is enough here.
        if e.sharesFrameWithVisibleWindow && !e.ownerIsHidden
            && (e.placement == nil || e.placement == .nowhere) {
            return .include(.tab)
        }

        guard let placement = e.placement else {
            return .reject("off screen, unknown to Accessibility")
        }
        guard e.sizable else { return .reject("off screen, too small to be sure") }

        switch placement {
        case .drawnHere:
            return .include(.onScreen)
        case .drawnElsewhere:
            return otherDesktop
        case .parked:
            return e.ownerIsHidden ? hidden : minimized
        case .nowhere:
            return .reject("not on any desktop: closed, or a helper")
        }
    }

    /// This desktop in stacking order — which is the order of use there —
    /// with every other window merged in by when it was last used.
    ///
    /// The stacking order says nothing about other desktops, so without this
    /// the window you had just left on another desktop sat at the far end of
    /// the grid. A window here counts as used at least as recently as any
    /// window stacked below it; that is what lets the two orders be merged.
    static func arrange<ID: Hashable>(here: [ID],
                                      elsewhere: [(id: ID, kind: WindowKind, order: Int)],
                                      lastUse: [ID: UInt64]) -> [ID] {
        func stamp(_ id: ID) -> UInt64 { lastUse[id] ?? 0 }

        let rest = elsewhere.sorted { a, b in
            let (sa, sb) = (stamp(a.id), stamp(b.id))
            if sa != sb { return sa > sb }
            let (ra, rb) = (rank(a.kind), rank(b.kind))
            if ra != rb { return ra < rb }
            return a.order < b.order
        }.map { $0.id }

        var recency = [UInt64](repeating: 0, count: here.count)
        var newest: UInt64 = 0
        for index in here.indices.reversed() {
            newest = max(newest, stamp(here[index]))
            recency[index] = newest
        }

        var result: [ID] = []
        result.reserveCapacity(here.count + rest.count)
        var h = 0
        var r = 0
        if !here.isEmpty {
            result.append(here[0])
            h = 1
        }
        while h < here.count || r < rest.count {
            if r < rest.count, h >= here.count || stamp(rest[r]) > recency[h] {
                result.append(rest[r])
                r += 1
            } else {
                result.append(here[h])
                h += 1
            }
        }
        return result
    }

    /// Among windows nobody has used lately: this desktop's tabs first, then
    /// the other desktops, then hidden apps, then the Dock.
    static func rank(_ kind: WindowKind) -> Int {
        switch kind {
        case .onScreen: return 0
        case .tab: return 1
        case .otherDesktop: return 2
        case .hidden: return 3
        case .minimized: return 4
        }
    }
}
