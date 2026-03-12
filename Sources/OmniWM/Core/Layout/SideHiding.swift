import CoreGraphics
import Foundation

enum HideSide {
    case left
    case right
}

struct HiddenPlacementMonitorContext {
    let id: Monitor.ID
    let frame: CGRect
    let visibleFrame: CGRect

    init(id: Monitor.ID, frame: CGRect, visibleFrame: CGRect) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
    }

    init(_ monitor: Monitor) {
        self.init(id: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame)
    }

    init(_ monitor: NiriMonitor) {
        self.init(id: monitor.id, frame: monitor.frame, visibleFrame: monitor.visibleFrame)
    }
}

struct HiddenWindowPlacement {
    let requestedSide: HideSide
    let resolvedSide: HideSide
    let origin: CGPoint

    func frame(for size: CGSize) -> CGRect {
        CGRect(origin: origin, size: size)
    }
}

enum HiddenWindowPlacementResolver {
    static func placement(
        for size: CGSize,
        requestedSide: HideSide,
        targetY: CGFloat,
        baseReveal: CGFloat,
        scale: CGFloat,
        monitor: HiddenPlacementMonitorContext,
        monitors: [HiddenPlacementMonitorContext]
    ) -> HiddenWindowPlacement {
        let reveal = baseReveal / max(1.0, scale)

        func origin(for side: HideSide) -> CGPoint {
            switch side {
            case .left:
                return CGPoint(
                    x: monitor.visibleFrame.minX - size.width + reveal,
                    y: targetY
                )
            case .right:
                return CGPoint(
                    x: monitor.visibleFrame.maxX - reveal,
                    y: targetY
                )
            }
        }

        func overlapArea(for origin: CGPoint) -> CGFloat {
            let rect = CGRect(origin: origin, size: size)
            var area: CGFloat = 0
            for other in monitors where other.id != monitor.id {
                let intersection = rect.intersection(other.frame)
                if intersection.isNull { continue }
                area += intersection.width * intersection.height
            }
            return area
        }

        let primaryOrigin = origin(for: requestedSide)
        let primaryOverlap = overlapArea(for: primaryOrigin)
        if primaryOverlap == 0 {
            return HiddenWindowPlacement(
                requestedSide: requestedSide,
                resolvedSide: requestedSide,
                origin: primaryOrigin
            )
        }

        let alternateSide: HideSide = requestedSide == .left ? .right : .left
        let alternateOrigin = origin(for: alternateSide)
        let alternateOverlap = overlapArea(for: alternateOrigin)
        if alternateOverlap < primaryOverlap {
            return HiddenWindowPlacement(
                requestedSide: requestedSide,
                resolvedSide: alternateSide,
                origin: alternateOrigin
            )
        }

        return HiddenWindowPlacement(
            requestedSide: requestedSide,
            resolvedSide: requestedSide,
            origin: primaryOrigin
        )
    }
}
