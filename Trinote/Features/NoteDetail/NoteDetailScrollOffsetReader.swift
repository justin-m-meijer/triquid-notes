import SwiftUI
import UIKit

/// Reads the enclosing `UIScrollView`’s `contentOffset.y` and whether content exceeds the viewport vertically.
///
/// SwiftUI `ScrollView` + `GeometryReader` / `PreferenceKey` often **does not** refresh during a drag,
/// so the floating edit chip never sees scroll deltas. KVO on `contentOffset` matches what the user actually scrolls.
struct NoteDetailScrollOffsetReader: UIViewRepresentable {
    /// `offset` increases when scrolling **down**. `verticallyScrollable` is false when there is nothing to scroll.
    /// `scrollFraction` is 0–1 representing how far down the user has scrolled. `width` is the scroll view's.
    var onOffsetChange: (_ offset: CGFloat, _ verticallyScrollable: Bool, _ scrollFraction: CGFloat, _ width: CGFloat) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onOffsetChange: onOffsetChange)
    }

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.isUserInteractionEnabled = false
        v.backgroundColor = .clear
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onOffsetChange = onOffsetChange
        context.coordinator.attachIfNeeded(from: uiView)
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.detach()
    }

    /// Main actor: everything it touches is UIKit. KVO on `UIScrollView` fires on the main thread.
    @MainActor
    final class Coordinator: NSObject {
        var onOffsetChange: (CGFloat, Bool, CGFloat, CGFloat) -> Void
        private weak var scrollView: UIScrollView?
        private var offsetObservation: NSKeyValueObservation?
        private var contentSizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?

        init(onOffsetChange: @escaping (CGFloat, Bool, CGFloat, CGFloat) -> Void) {
            self.onOffsetChange = onOffsetChange
        }

        private var pageObserver: (any NSObjectProtocol)?

        /// Tabletop deck paging: only the reader that is on screen scrolls.
        private func observePageRequests() {
            guard pageObserver == nil else { return }
            pageObserver = NotificationCenter.default.addObserver(forName: .trinoteReaderPageRequest, object: nil, queue: .main) { [weak self] note in
                guard let direction = note.object as? TabletopPageDirection else { return }
                MainActor.assumeIsolated { self?.page(direction) }
            }
        }

        private func page(_ direction: TabletopPageDirection) {
            guard let sv = scrollView, sv.window != nil else { return }
            let insets = sv.adjustedContentInset
            let minY = -insets.top
            let maxY = max(minY, sv.contentSize.height - sv.bounds.height + insets.bottom)
            // A page is the visible height less a few lines, so the reader keeps their place.
            let step = max(80, sv.bounds.height - insets.top - insets.bottom - 64)
            let target: CGFloat = switch direction {
            case .up: max(minY, sv.contentOffset.y - step)
            case .down: min(maxY, sv.contentOffset.y + step)
            case .top: minY
            }
            sv.setContentOffset(CGPoint(x: sv.contentOffset.x, y: target), animated: true)
        }

        func attachIfNeeded(from view: UIView) {
            observePageRequests()
            guard scrollView == nil else { return }
            Task { @MainActor [weak self, weak view] in
                guard let self, let view, self.scrollView == nil else { return }
                guard let sv = Self.findEnclosingScrollView(from: view) else { return }
                self.scrollView = sv
                self.offsetObservation = sv.observe(\.contentOffset, options: [.new]) { [weak self] scrollView, _ in
                    MainActor.assumeIsolated { self?.emit(from: scrollView) }
                }
                self.contentSizeObservation = sv.observe(\.contentSize, options: [.new]) { [weak self] scrollView, _ in
                    MainActor.assumeIsolated { self?.emit(from: scrollView) }
                }
                self.boundsObservation = sv.observe(\.bounds, options: [.new]) { [weak self] scrollView, _ in
                    MainActor.assumeIsolated { self?.emit(from: scrollView) }
                }
                self.emit(from: sv)
            }
        }

        func detach() {
            if let pageObserver { NotificationCenter.default.removeObserver(pageObserver) }
            pageObserver = nil
            offsetObservation?.invalidate()
            offsetObservation = nil
            contentSizeObservation?.invalidate()
            contentSizeObservation = nil
            boundsObservation?.invalidate()
            boundsObservation = nil
            scrollView = nil
        }

        /// Offset, bounds and content-size changes all land here, often several per frame while scrolling;
        /// they share one pending callback that reads the scroll view's latest state.
        private var emitPending = false

        private func emit(from scrollView: UIScrollView) {
            guard !emitPending else { return }
            emitPending = true
            Task { @MainActor [weak self, weak scrollView] in
                guard let self else { return }
                self.emitPending = false
                guard let scrollView else { return }
                let y = scrollView.contentOffset.y
                let verticallyScrollable = scrollView.contentSize.height > scrollView.bounds.height + 0.5
                let maxOffset = scrollView.contentSize.height - scrollView.bounds.height
                let fraction = verticallyScrollable && maxOffset > 0 ? min(max(y / maxOffset, 0), 1) : 0
                self.onOffsetChange(y, verticallyScrollable, fraction, scrollView.bounds.width)
            }
        }

        private static func findEnclosingScrollView(from view: UIView) -> UIScrollView? {
            var current: UIView? = view.superview
            while let c = current {
                if let sv = c as? UIScrollView { return sv }
                current = c.superview
            }
            return nil
        }
    }
}

// MARK: - Floating chip scroll clearance

/// Layout for the floating edit / save chips and matching scroll clearance below note content.
enum NoteDetailFloatingChipLayout {
    static let chipHeight: CGFloat = 16
    static let breathingRoom: CGFloat = 3
    static let saveChipBottomInset: CGFloat = 62
    static let editChipBottomInset: CGFloat = 12
    static let editChipBottomInsetWithFindBar: CGFloat = 56

    /// Extra scrollable space below the last line so content can sit above the floating chip.
    static func scrollClearance(findBarPresented: Bool, editing: Bool) -> CGFloat {
        if editing {
            return saveChipBottomInset + chipHeight + breathingRoom
        }
        let chipBottom = findBarPresented ? editChipBottomInsetWithFindBar : editChipBottomInset
        return chipBottom + chipHeight + breathingRoom
    }
}
