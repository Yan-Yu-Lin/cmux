import AppKit
import SwiftUI

enum DynamicNotchResizeAxis {
    case horizontal
    case vertical
    case both
}

struct DynamicNotchResizeSurface: NSViewRepresentable {
    let axis: DynamicNotchResizeAxis
    let currentSize: () -> CGSize
    let changed: (CGSize) -> Void
    let ended: (CGSize) -> Void

    func makeNSView(context: Context) -> DynamicNotchResizeNSView {
        let view = DynamicNotchResizeNSView()
        update(view)
        return view
    }

    func updateNSView(
        _ nsView: DynamicNotchResizeNSView,
        context: Context
    ) {
        update(nsView)
    }

    private func update(_ view: DynamicNotchResizeNSView) {
        view.axis = axis
        view.currentSize = currentSize
        view.changed = changed
        view.ended = ended
        view.window?.invalidateCursorRects(for: view)
    }
}

final class DynamicNotchResizeNSView: NSView {
    var axis: DynamicNotchResizeAxis = .both
    var currentSize: () -> CGSize = { .zero }
    var changed: (CGSize) -> Void = { _ in }
    var ended: (CGSize) -> Void = { _ in }

    private var pressLocation: CGPoint?
    private var pressSize = CGSize.zero
    private var latestSize = CGSize.zero

    private static let diagonalResizeCursor: NSCursor = {
        let selector = NSSelectorFromString(
            "_windowResizeNorthWestSouthEastCursor"
        )
        if NSCursor.responds(to: selector),
            let value = NSCursor.perform(selector)?
                .takeUnretainedValue() as? NSCursor {
            return value
        }
        return .crosshair
    }()

    override func resetCursorRects() {
        super.resetCursorRects()
        let cursor: NSCursor
        switch axis {
        case .horizontal:
            cursor = .resizeLeftRight
        case .vertical:
            cursor = .resizeUpDown
        case .both:
            cursor = Self.diagonalResizeCursor
        }
        addCursorRect(bounds, cursor: cursor)
    }

    override func mouseDown(with event: NSEvent) {
        pressLocation = NSEvent.mouseLocation
        pressSize = currentSize()
        latestSize = pressSize
    }

    override func mouseDragged(with event: NSEvent) {
        guard let pressLocation else { return }
        let point = NSEvent.mouseLocation
        let horizontalDelta = (point.x - pressLocation.x) * 2
        let verticalDelta = pressLocation.y - point.y
        latestSize = CGSize(
            width: axis == .vertical
                ? pressSize.width
                : pressSize.width + horizontalDelta,
            height: axis == .horizontal
                ? pressSize.height
                : pressSize.height + verticalDelta
        )
        changed(latestSize)
    }

    override func mouseUp(with event: NSEvent) {
        guard pressLocation != nil else { return }
        pressLocation = nil
        ended(latestSize)
    }
}
