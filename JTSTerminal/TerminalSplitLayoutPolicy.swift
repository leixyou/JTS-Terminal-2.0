//
//  TerminalSplitLayoutPolicy.swift
//  JTSTerminal
//
//  Created by Codex on 2026/7/28.
//

import Foundation

/// Keeps split creation aligned with the actual terminal viewport. The same
/// minimum is also applied to every rendered leaf so the capacity check and
/// SwiftUI layout cannot drift apart.
@MainActor
enum TerminalSplitLayoutPolicy {
    static let minimumPaneSize = CGSize(width: 320, height: 200)
    static let splitterThickness: CGFloat = 1
    private static let fitTolerance: CGFloat = 0.5

    static func requiredMinimumSize(
        for node: TerminalWorkspaceState.LayoutNode
    ) -> CGSize {
        switch node {
        case .pane:
            return minimumPaneSize
        case .split(_, let axis, let first, let second):
            let firstSize = requiredMinimumSize(for: first)
            let secondSize = requiredMinimumSize(for: second)
            switch axis {
            case .horizontal:
                return CGSize(
                    width: firstSize.width
                        + splitterThickness
                        + secondSize.width,
                    height: max(firstSize.height, secondSize.height)
                )
            case .vertical:
                return CGSize(
                    width: max(firstSize.width, secondSize.width),
                    height: firstSize.height
                        + splitterThickness
                        + secondSize.height
                )
            }
        }
    }

    static func fits(
        _ node: TerminalWorkspaceState.LayoutNode,
        in availableSize: CGSize
    ) -> Bool {
        guard availableSize.width.isFinite,
              availableSize.height.isFinite,
              availableSize.width > 0,
              availableSize.height > 0 else {
            return false
        }

        let requiredSize = requiredMinimumSize(for: node)
        return requiredSize.width <= availableSize.width + fitTolerance
            && requiredSize.height <= availableSize.height + fitTolerance
    }
}
