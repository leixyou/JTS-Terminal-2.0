import CoreGraphics
import Foundation
import Testing
@testable import JTSTerminal

@MainActor
struct TerminalSplitLayoutPolicyTests {
    @Test func requiredMinimumSizeTracksHorizontalAndVerticalTreeShape() {
        let first = TerminalWorkspaceState.LayoutNode.pane(UUID())
        let second = TerminalWorkspaceState.LayoutNode.pane(UUID())
        let third = TerminalWorkspaceState.LayoutNode.pane(UUID())
        let fourth = TerminalWorkspaceState.LayoutNode.pane(UUID())

        let twoAcross = TerminalWorkspaceState.LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            first: first,
            second: second
        )
        let threeAcross = TerminalWorkspaceState.LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            first: twoAcross,
            second: third
        )
        let fourAcross = TerminalWorkspaceState.LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            first: threeAcross,
            second: fourth
        )

        #expect(
            TerminalSplitLayoutPolicy.requiredMinimumSize(for: twoAcross)
                == CGSize(width: 641, height: 200)
        )
        #expect(
            TerminalSplitLayoutPolicy.requiredMinimumSize(for: threeAcross)
                == CGSize(width: 962, height: 200)
        )
        #expect(
            TerminalSplitLayoutPolicy.requiredMinimumSize(for: fourAcross)
                == CGSize(width: 1_283, height: 200)
        )

        let twoDown = TerminalWorkspaceState.LayoutNode.split(
            id: UUID(),
            axis: .vertical,
            first: first,
            second: second
        )
        let threeDown = TerminalWorkspaceState.LayoutNode.split(
            id: UUID(),
            axis: .vertical,
            first: twoDown,
            second: third
        )

        #expect(
            TerminalSplitLayoutPolicy.requiredMinimumSize(for: twoDown)
                == CGSize(width: 320, height: 401)
        )
        #expect(
            TerminalSplitLayoutPolicy.requiredMinimumSize(for: threeDown)
                == CGSize(width: 320, height: 602)
        )
    }

    @Test func fitDecisionUsesBothDimensionsAndRejectsUnknownViewport() {
        let first = TerminalWorkspaceState.LayoutNode.pane(UUID())
        let second = TerminalWorkspaceState.LayoutNode.pane(UUID())
        let horizontal = TerminalWorkspaceState.LayoutNode.split(
            id: UUID(),
            axis: .horizontal,
            first: first,
            second: second
        )
        let vertical = TerminalWorkspaceState.LayoutNode.split(
            id: UUID(),
            axis: .vertical,
            first: first,
            second: second
        )

        #expect(TerminalSplitLayoutPolicy.fits(
            horizontal,
            in: CGSize(width: 641, height: 200)
        ))
        #expect(!TerminalSplitLayoutPolicy.fits(
            horizontal,
            in: CGSize(width: 640, height: 200)
        ))
        #expect(TerminalSplitLayoutPolicy.fits(
            vertical,
            in: CGSize(width: 320, height: 401)
        ))
        #expect(!TerminalSplitLayoutPolicy.fits(
            vertical,
            in: CGSize(width: 320, height: 400)
        ))
        #expect(!TerminalSplitLayoutPolicy.fits(horizontal, in: .zero))
    }

    @Test func workspaceAppliesAxisSpecificCapacityBeforeMutatingLayout() throws {
        let workspace = TerminalWorkspaceState(initialKind: .ssh)

        #expect(!workspace.canSplitSelectedPane(
            axis: .horizontal,
            availableSize: CGSize(width: 640, height: 500)
        ))
        #expect(workspace.canSplitSelectedPane(
            axis: .horizontal,
            availableSize: CGSize(width: 641, height: 500)
        ))
        #expect(!workspace.canSplitSelectedPane(
            axis: .vertical,
            availableSize: CGSize(width: 700, height: 400)
        ))
        #expect(workspace.canSplitSelectedPane(
            axis: .vertical,
            availableSize: CGSize(width: 700, height: 401)
        ))

        let second = try #require(workspace.splitSelectedPane(
            axis: .horizontal,
            availableSize: CGSize(width: 641, height: 500)
        ))
        #expect(workspace.selectedPane?.id == second.id)
        #expect(workspace.selectedTab?.panes.count == 2)

        #expect(!workspace.canSplitSelectedPane(
            axis: .horizontal,
            availableSize: CGSize(width: 900, height: 500)
        ))
        #expect(workspace.canSplitSelectedPane(
            axis: .horizontal,
            availableSize: CGSize(width: 962, height: 500)
        ))
    }
}
