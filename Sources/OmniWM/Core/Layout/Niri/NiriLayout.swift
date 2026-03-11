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
    let frames: [WindowHandle: CGRect]
    let hiddenHandles: [WindowHandle: HideSide]
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
    ) -> [WindowHandle: CGRect] {
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
        animationTime: TimeInterval? = nil
    ) -> LayoutResult {
        var frames: [WindowHandle: CGRect] = [:]
        var hiddenHandles: [WindowHandle: HideSide] = [:]
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
            animationTime: animationTime
        )
        return LayoutResult(frames: frames, hiddenHandles: hiddenHandles)
    }

    func calculateLayoutInto(
        frames: inout [WindowHandle: CGRect],
        hiddenHandles: inout [WindowHandle: HideSide],
        state: ViewportState,
        workspaceId: WorkspaceDescriptor.ID,
        monitorFrame: CGRect,
        screenFrame: CGRect? = nil,
        gaps: (horizontal: CGFloat, vertical: CGFloat),
        scale: CGFloat = 2.0,
        workingArea: WorkingAreaContext? = nil,
        orientation: Monitor.Orientation = .horizontal,
        animationTime: TimeInterval? = nil
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
        let offsetScreenRect = viewFrame.offsetBy(dx: workspaceOffset, dy: 0)
        let offsetFullscreenRect = workingFrame.offsetBy(dx: workspaceOffset, dy: 0)

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
        var totalSpan: CGFloat = 0
        for i in 0 ..< containers.count {
            containerPositions.append(runningPos)
            let span = containerSpans[i]
            runningPos += span + primaryGap
            totalSpan += span
            if i < containers.count - 1 {
                totalSpan += primaryGap
            }
        }

        let viewOffset = state.viewOffsetPixels.value(at: time)
        let activeIdx = state.activeColumnIndex.clamped(to: 0 ... max(0, containers.count - 1))
        let activePos = containers.isEmpty ? 0 : containerPositions[activeIdx]
        let viewPos = activePos + viewOffset
        let viewStart = viewPos
        let viewportSpan: CGFloat = switch orientation {
        case .horizontal: workingFrame.width
        case .vertical: workingFrame.height
        }
        let viewEnd = viewStart + viewportSpan

        var usedIndices = Set<Int>()
        var containerSides: [Int: HideSide] = [:]

        for idx in 0 ..< containers.count {
            let containerPos = containerPositions[idx]
            let containerSpan = containerSpans[idx]
            let containerEnd = containerPos + containerSpan
            let renderOffset = containerRenderOffsets[idx]

            let isVisible = containerEnd > viewStart && containerPos < viewEnd

            if isVisible {
                usedIndices.insert(idx)

                let containerRect: CGRect
                switch orientation {
                case .horizontal:
                    let screenX = workingFrame.origin.x + containerPos - viewPos + renderOffset.x + workspaceOffset
                    let width = containerSpan.roundedToPhysicalPixel(scale: effectiveScale)
                    containerRect = CGRect(
                        x: screenX,
                        y: workingFrame.origin.y,
                        width: width,
                        height: workingFrame.height
                    ).roundedToPhysicalPixels(scale: effectiveScale)
                case .vertical:
                    let screenY = workingFrame.origin.y + containerPos - viewPos + renderOffset.y
                    let height = containerSpan.roundedToPhysicalPixel(scale: effectiveScale)
                    containerRect = CGRect(
                        x: workingFrame.origin.x + workspaceOffset,
                        y: screenY,
                        width: workingFrame.width,
                        height: height
                    ).roundedToPhysicalPixels(scale: effectiveScale)
                }

                layoutContainer(
                    container: containers[idx],
                    containerRect: containerRect,
                    screenRect: offsetScreenRect,
                    fullscreenRect: offsetFullscreenRect,
                    secondaryGap: secondaryGap,
                    scale: effectiveScale,
                    containerRenderOffset: renderOffset,
                    animationTime: time,
                    result: &frames,
                    orientation: orientation
                )
            } else {
                let hideSide: HideSide = containerEnd <= viewStart ? .left : .right
                containerSides[idx] = hideSide
                for window in containerWindowNodes[idx] {
                    hiddenHandles[window.handle] = hideSide
                }
            }
        }

        if containers.count > usedIndices.count {
            let avgSpan = totalSpan / CGFloat(max(1, containers.count))
            let hiddenSpan = max(1, avgSpan).roundedToPhysicalPixel(scale: effectiveScale)
            for (idx, container) in containers.enumerated() {
                if usedIndices.contains(idx) { continue }

                let hiddenRect: CGRect
                switch orientation {
                case .horizontal:
                    let side = containerSides[idx] ?? .right
                    hiddenRect = hiddenColumnRect(
                        side: side,
                        width: hiddenSpan,
                        height: workingFrame.height,
                        screenY: viewFrame.maxY - 2,
                        edgeFrame: viewFrame,
                        scale: effectiveScale
                    ).offsetBy(dx: workspaceOffset, dy: 0).roundedToPhysicalPixels(scale: effectiveScale)
                case .vertical:
                    hiddenRect = hiddenRowRect(
                        screenRect: viewFrame,
                        width: workingFrame.width,
                        height: hiddenSpan
                    ).offsetBy(dx: workspaceOffset, dy: 0).roundedToPhysicalPixels(scale: effectiveScale)
                }

                layoutContainer(
                    container: container,
                    containerRect: hiddenRect,
                    screenRect: offsetScreenRect,
                    fullscreenRect: offsetFullscreenRect,
                    secondaryGap: secondaryGap,
                    scale: effectiveScale,
                    containerRenderOffset: .zero,
                    animationTime: time,
                    result: &frames,
                    orientation: orientation
                )
            }
        }
    }

    private func layoutContainer(
        container: NiriContainer,
        containerRect: CGRect,
        screenRect: CGRect,
        fullscreenRect: CGRect,
        secondaryGap: CGFloat,
        scale: CGFloat,
        containerRenderOffset: CGPoint = .zero,
        animationTime: TimeInterval? = nil,
        result: inout [WindowHandle: CGRect],
        orientation: Monitor.Orientation
    ) {
        container.frame = containerRect

        let tabOffset = container.isTabbed ? renderStyle.tabIndicatorWidth : 0
        let contentRect = CGRect(
            x: containerRect.origin.x + tabOffset,
            y: containerRect.origin.y,
            width: max(0, containerRect.width - tabOffset),
            height: containerRect.height
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
        let windowHandles = windows.map { $0.handle }

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
            let totalOffset = CGPoint(
                x: containerRenderOffset.x + windowOffset.x,
                y: containerRenderOffset.y + windowOffset.y
            )
            let animatedFrame = frame.offsetBy(dx: totalOffset.x, dy: totalOffset.y)
                .roundedToPhysicalPixels(scale: scale)
            result[windowHandles[i]] = animatedFrame

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
