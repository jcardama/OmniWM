import AppKit
import Foundation

extension CGFloat {
    func roundedToPhysicalPixel(scale: CGFloat) -> CGFloat {
        (self * scale).rounded() / scale
    }
}

extension CGPoint {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGPoint {
        CGPoint(
            x: x.roundedToPhysicalPixel(scale: scale),
            y: y.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGSize {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGSize {
        CGSize(
            width: width.roundedToPhysicalPixel(scale: scale),
            height: height.roundedToPhysicalPixel(scale: scale)
        )
    }
}

extension CGRect {
    func roundedToPhysicalPixels(scale: CGFloat) -> CGRect {
        CGRect(
            origin: origin.roundedToPhysicalPixels(scale: scale),
            size: size.roundedToPhysicalPixels(scale: scale)
        )
    }
}

struct LayoutResult {
    let frames: [WindowToken: CGRect]
    let hiddenHandles: [WindowToken: HideSide]
}

extension NiriLayoutEngine {
    private func workspaceSwitchOffset(
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        time: TimeInterval
    ) -> CGFloat {
        guard let monitorId = monitorContaining(workspace: workspaceId),
              let monitor = monitors[monitorId],
              let switch_ = monitor.workspaceSwitch,
              let workspaceIndex = switch_.index(of: workspaceId) else {
            return 0
        }

        let renderIndex = switch_.currentIndex(at: time)
        let delta = Double(workspaceIndex) - renderIndex
        if abs(delta) < 0.001 {
            return 0
        }

        let reduceMotionScale: CGFloat = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.25 : 1.0
        return CGFloat(delta) * monitorFrame.width * reduceMotionScale
    }

    func calculateLayout(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal
    ) -> [WindowToken: CGRect] {
        calculateLayoutWithVisibility(
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation
        ).frames
    }

    func calculateLayoutWithVisibility(
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = []
    ) -> LayoutResult {
        var frames: [WindowToken: CGRect] = [:]
        var hiddenHandles: [WindowToken: HideSide] = [:]
        calculateLayoutInto(
            frames: &frames,
            hiddenHandles: &hiddenHandles,
            state: state,
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            screenFrame: screenFrame,
            gaps: gaps,
            scale: scale,
            workingArea: workingArea,
            orientation: orientation,
            animationTime: animationTime,
            hiddenPlacementMonitor: hiddenPlacementMonitor,
            hiddenPlacementMonitors: hiddenPlacementMonitors
        )
        return LayoutResult(frames: frames, hiddenHandles: hiddenHandles)
    }

    func calculateLayoutInto(
        frames: inout [WindowToken: CGRect],
        hiddenHandles: inout [WindowToken: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext? = nil,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext] = []
    ) {
        let containers = columns(in: workspaceId)
        guard !containers.isEmpty else { return }

        let workingFrame = workingArea?.workingFrame ?? monitorFrame
        let viewFrame = workingArea?.viewFrame ?? screenFrame ?? monitorFrame
        let effectiveScale = workingArea?.scale ?? scale

        let primaryGap: CGFloat
        let secondaryGap: CGFloat
        switch orientation {
        case .horizontal:
            primaryGap = gaps.horizontal
            secondaryGap = gaps.vertical
        case .vertical:
            primaryGap = gaps.vertical
            secondaryGap = gaps.horizontal
        }

        let time = animationTime ?? CACurrentMediaTime()
        let workspaceOffset = workspaceSwitchOffset(
            workspaceId: workspaceId,
            monitorFrame: monitorFrame,
            time: time
        )
        let canonicalFullscreenRect = workingFrame.roundedToPhysicalPixels(scale: effectiveScale)

        for container in containers {
            switch orientation {
            case .horizontal:
                if container.cachedWidth <= 0 {
                    container.resolveAndCacheWidth(workingAreaWidth: workingFrame.width, gaps: primaryGap)
                }
            case .vertical:
                if container.cachedHeight <= 0 {
                    container.resolveAndCacheHeight(workingAreaHeight: workingFrame.height, gaps: primaryGap)
                }
            }
        }

        let containerSpans: [CGFloat] = switch orientation {
        case .horizontal: containers.map { $0.cachedWidth }
        case .vertical: containers.map { $0.cachedHeight }
        }
        let containerRenderOffsets = containers.map { $0.renderOffset(at: time) }
        let containerWindowNodes = containers.map { $0.windowNodes }

        var containerPositions = [CGFloat]()
        containerPositions.reserveCapacity(containers.count)
        var runningPos: CGFloat = 0
        for i in 0 ..< containers.count {
            containerPositions.append(runningPos)
            let span = containerSpans[i]
            runningPos += span + primaryGap
        }

        let viewOffset = state.viewOffsetPixels.value(at: time)
        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, containers.count - 1))
        let activePos = containers.isEmpty ? 0 : containerPositions[activeIdx]
        let viewPos = activePos + viewOffset

        for idx in 0 ..< containers.count {
            let containerPos = containerPositions[idx]
            let containerSpan = containerSpans[idx]
            let renderOffset = containerRenderOffsets[idx]
            let canonicalContainerRect = canonicalContainerRect(
                position: containerPos,
                span: containerSpan,
                workingFrame: workingFrame,
                scale: effectiveScale,
                orientation: orientation
            )
            let visibilityRect = visibleRenderedContainerRect(
                canonicalRect: canonicalContainerRect,
                viewPosition: viewPos,
                workspaceOffset: workspaceOffset,
                renderOffset: renderOffset,
                scale: effectiveScale,
                orientation: orientation
            )
            let isVisible = containerIntersectsViewport(
                visibilityRect,
                viewportFrame: workingFrame,
                orientation: orientation
            )

            let renderedContainerRect: CGRect
            if isVisible {
                renderedContainerRect = visibilityRect
            } else {
                let hideSide = hiddenSide(
                    for: visibilityRect,
                    viewportFrame: workingFrame,
                    fallback: idx == 0 ? .left : .right,
                    orientation: orientation
                )
                for window in containerWindowNodes[idx] {
                    hiddenHandles[window.token] = hideSide
                }
                renderedContainerRect = hiddenRenderedContainerRect(
                    canonicalRect: canonicalContainerRect,
                    side: hideSide,
                    viewFrame: viewFrame,
                    scale: effectiveScale,
                    orientation: orientation,
                    hiddenPlacementMonitor: hiddenPlacementMonitor,
                    hiddenPlacementMonitors: hiddenPlacementMonitors
                )
            }

            layoutContainer(
                container: containers[idx],
                canonicalContainerRect: canonicalContainerRect,
                renderedContainerRect: renderedContainerRect,
                fullscreenRect: canonicalFullscreenRect,
                secondaryGap: secondaryGap,
                scale: effectiveScale,
                animationTime: time,
                result: &frames,
                orientation: orientation
            )
        }
    }

    private func canonicalContainerRect(
        position: CGFloat,
        span: CGFloat,
        workingFrame: CGRect,
        scale: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            let width = span.roundedToPhysicalPixel(scale: scale)
            return CGRect(
                x: workingFrame.origin.x + position,
                y: workingFrame.origin.y,
                width: width,
                height: workingFrame.height
            ).roundedToPhysicalPixels(scale: scale)
        case .vertical:
            let height = span.roundedToPhysicalPixel(scale: scale)
            return CGRect(
                x: workingFrame.origin.x,
                y: workingFrame.origin.y + position,
                width: workingFrame.width,
                height: height
            ).roundedToPhysicalPixels(scale: scale)
        }
    }

    private func visibleRenderedContainerRect(
        canonicalRect: CGRect,
        viewPosition: CGFloat,
        workspaceOffset: CGFloat,
        renderOffset: CGPoint,
        scale: CGFloat,
        orientation: Monitor.Orientation
    ) -> CGRect {
        let translation: CGPoint = switch orientation {
        case .horizontal:
            CGPoint(
                x: -viewPosition + workspaceOffset + renderOffset.x,
                y: renderOffset.y
            )
        case .vertical:
            CGPoint(
                x: workspaceOffset + renderOffset.x,
                y: -viewPosition + renderOffset.y
            )
        }
        return canonicalRect.offsetBy(dx: translation.x, dy: translation.y)
            .roundedToPhysicalPixels(scale: scale)
    }

    private func containerIntersectsViewport(
        _ containerRect: CGRect,
        viewportFrame: CGRect,
        orientation: Monitor.Orientation
    ) -> Bool {
        switch orientation {
        case .horizontal:
            containerRect.maxX > viewportFrame.minX && containerRect.minX < viewportFrame.maxX
        case .vertical:
            containerRect.maxY > viewportFrame.minY && containerRect.minY < viewportFrame.maxY
        }
    }

    private func hiddenSide(
        for renderedRect: CGRect,
        viewportFrame: CGRect,
        fallback: HideSide,
        orientation: Monitor.Orientation
    ) -> HideSide {
        switch orientation {
        case .horizontal:
            if renderedRect.maxX <= viewportFrame.minX {
                return .left
            }
            if renderedRect.minX >= viewportFrame.maxX {
                return .right
            }
        case .vertical:
            if renderedRect.maxY <= viewportFrame.minY {
                return .left
            }
            if renderedRect.minY >= viewportFrame.maxY {
                return .right
            }
        }
        return fallback
    }

    private func hiddenRenderedContainerRect(
        canonicalRect: CGRect,
        side: HideSide,
        viewFrame: CGRect,
        scale: CGFloat,
        orientation: Monitor.Orientation,
        hiddenPlacementMonitor: HiddenPlacementMonitorContext?,
        hiddenPlacementMonitors: [HiddenPlacementMonitorContext]
    ) -> CGRect {
        switch orientation {
        case .horizontal:
            if let hiddenPlacementMonitor {
                return HiddenWindowPlacementResolver.placement(
                    for: canonicalRect.size,
                    requestedSide: side,
                    targetY: canonicalRect.minY,
                    baseReveal: 1.0,
                    scale: scale,
                    monitor: hiddenPlacementMonitor,
                    monitors: hiddenPlacementMonitors
                )
                .frame(for: canonicalRect.size)
                .roundedToPhysicalPixels(scale: scale)
            }

            return hiddenColumnRect(
                side: side,
                width: canonicalRect.width,
                height: canonicalRect.height,
                screenY: canonicalRect.minY,
                edgeFrame: viewFrame,
                scale: scale
            ).roundedToPhysicalPixels(scale: scale)
        case .vertical:
            return hiddenRowRect(
                screenRect: viewFrame,
                width: canonicalRect.width,
                height: canonicalRect.height
            ).roundedToPhysicalPixels(scale: scale)
        }
    }

    private func layoutContainer(
        container: NiriContainer,
        canonicalContainerRect: CGRect,
        renderedContainerRect: CGRect,
        fullscreenRect: CGRect,
        secondaryGap: CGFloat,
        scale: CGFloat,
        animationTime: TimeInterval? = nil,
        result: inout [WindowToken: CGRect],
        orientation: Monitor.Orientation
    ) {
        container.frame = canonicalContainerRect
        container.renderedFrame = renderedContainerRect

        let tabOffset = container.isTabbed ? renderStyle.tabIndicatorWidth : 0
        let contentRect = CGRect(
            x: canonicalContainerRect.origin.x + tabOffset,
            y: canonicalContainerRect.origin.y,
            width: max(0, canonicalContainerRect.width - tabOffset),
            height: canonicalContainerRect.height
        )

        let windows = container.windowNodes
        guard !windows.isEmpty else { return }

        let isTabbed = container.isTabbed
        let time = animationTime ?? CACurrentMediaTime()

        let availableSpace: CGFloat = switch orientation {
        case .horizontal: contentRect.height
        case .vertical: contentRect.width
        }

        let resolvedSpans = resolveWindowSpans(
            windows: windows,
            availableSpace: availableSpace,
            gap: secondaryGap,
            isTabbed: isTabbed,
            orientation: orientation
        )

        let sizingModes = windows.map { $0.sizingMode }
        let windowRenderOffsets = windows.map { $0.renderOffset(at: time) }
        let windowTokens = windows.map { $0.token }

        var pos: CGFloat = switch orientation {
        case .horizontal: contentRect.origin.y
        case .vertical: contentRect.origin.x
        }

        for i in 0 ..< windows.count {
            let span = resolvedSpans[i]
            let sizingMode = sizingModes[i]

            let frame: CGRect
            switch sizingMode {
            case .fullscreen:
                frame = fullscreenRect.roundedToPhysicalPixels(scale: scale)
            case .normal:
                switch orientation {
                case .horizontal:
                    frame = CGRect(
                        x: contentRect.origin.x,
                        y: isTabbed ? contentRect.origin.y : pos,
                        width: contentRect.width,
                        height: span
                    ).roundedToPhysicalPixels(scale: scale)
                case .vertical:
                    frame = CGRect(
                        x: isTabbed ? contentRect.origin.x : pos,
                        y: contentRect.origin.y,
                        width: span,
                        height: contentRect.height
                    ).roundedToPhysicalPixels(scale: scale)
                }
            }

            windows[i].frame = frame
            switch orientation {
            case .horizontal:
                windows[i].resolvedHeight = span
            case .vertical:
                windows[i].resolvedWidth = span
            }

            let windowOffset = windowRenderOffsets[i]
            let renderTranslation = CGPoint(
                x: renderedContainerRect.origin.x - canonicalContainerRect.origin.x + windowOffset.x,
                y: renderedContainerRect.origin.y - canonicalContainerRect.origin.y + windowOffset.y
            )
            let animatedFrame = frame.offsetBy(dx: renderTranslation.x, dy: renderTranslation.y)
                .roundedToPhysicalPixels(scale: scale)
            windows[i].renderedFrame = animatedFrame
            result[windowTokens[i]] = animatedFrame

            if !isTabbed {
                pos += span
                if i < windows.count - 1 {
                    pos += secondaryGap
                }
            }
        }
    }

    private func resolveWindowSpans(
        windows: [NiriWindow],
        availableSpace: CGFloat,
        gap: CGFloat,
        isTabbed: Bool,
        orientation: Monitor.Orientation
    ) -> [CGFloat] {
        guard !windows.isEmpty else { return [] }

        let inputs: [NiriAxisSolver.Input] = windows.map { window in
            switch orientation {
            case .horizontal:
                let isFixed: Bool
                let fixedValue: CGFloat?
                switch window.height {
                case let .fixed(h):
                    isFixed = true
                    fixedValue = h
                case .auto:
                    isFixed = false
                    fixedValue = nil
                }
                return NiriAxisSolver.Input(
                    weight: max(0.1, window.heightWeight),
                    minConstraint: window.constraints.minSize.height,
                    maxConstraint: window.constraints.maxSize.height,
                    hasMaxConstraint: window.constraints.hasMaxHeight,
                    isConstraintFixed: window.constraints.isFixed,
                    hasFixedValue: isFixed,
                    fixedValue: fixedValue
                )
            case .vertical:
                let isFixed: Bool
                let fixedValue: CGFloat?
                switch window.windowWidth {
                case let .fixed(w):
                    isFixed = true
                    fixedValue = w
                case .auto:
                    isFixed = false
                    fixedValue = nil
                }
                return NiriAxisSolver.Input(
                    weight: max(0.1, window.widthWeight),
                    minConstraint: window.constraints.minSize.width,
                    maxConstraint: window.constraints.maxSize.width,
                    hasMaxConstraint: window.constraints.hasMaxWidth,
                    isConstraintFixed: window.constraints.isFixed,
                    hasFixedValue: isFixed,
                    fixedValue: fixedValue
                )
            }
        }

        let outputs = NiriAxisSolver.solve(
            windows: inputs,
            availableSpace: availableSpace,
            gapSize: gap,
            isTabbed: isTabbed
        )

        for (i, output) in outputs.enumerated() {
            switch orientation {
            case .horizontal:
                windows[i].heightFixedByConstraint = output.wasConstrained
            case .vertical:
                windows[i].widthFixedByConstraint = output.wasConstrained
            }
        }

        return outputs.map(\.value)
    }

    private func hiddenRowRect(
        screenRect: CGRect,
        width: CGFloat,
        height: CGFloat
    ) -> CGRect {
        let origin = CGPoint(
            x: screenRect.maxX - 2,
            y: screenRect.maxY - 2
        )
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }

    private func hiddenColumnRect(
        side: HideSide,
        width: CGFloat,
        height: CGFloat,
        screenY: CGFloat,
        edgeFrame: CGRect,
        scale: CGFloat
    ) -> CGRect {
        let edgeReveal = 1.0 / max(1.0, scale)
        let x: CGFloat
        switch side {
        case .left:
            x = edgeFrame.minX - width + edgeReveal
        case .right:
            x = edgeFrame.maxX - edgeReveal
        }
        let origin = CGPoint(x: x, y: screenY)
        return CGRect(origin: origin, size: CGSize(width: width, height: height))
    }
}
