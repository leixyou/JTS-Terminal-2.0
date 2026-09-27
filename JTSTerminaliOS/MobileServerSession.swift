//
//  MobileServerSession.swift
//  JTSTerminaliOS
//
//  Created by Codex on 2026/7/14.
//

import Combine
import Foundation

enum MobileWorkspacePanel: String, CaseIterable, Identifiable {
    case terminal
    case files

    var id: Self { self }

    var title: String {
        switch self {
        case .terminal:
            return "Terminal"
        case .files:
            return "Files"
        }
    }

    var systemImage: String {
        switch self {
        case .terminal:
            return "terminal"
        case .files:
            return "folder"
        }
    }
}

@MainActor
final class MobileServerSession: ObservableObject, Identifiable {
    let id: MobileServerProfile.ID
    let terminalController: MobileTerminalController
    let filesController: MobileRemoteFilesController

    @Published var selectedPanel: MobileWorkspacePanel = .terminal
    @Published var isHeaderExpanded = true

    init(profile: MobileServerProfile) {
        id = profile.id

        let transport = MobileSSHSessionTransport()
        terminalController = MobileTerminalController(sessionTransport: transport)
        filesController = MobileRemoteFilesController(
            profile: profile,
            transport: MobileCitadelFileTransport(sessionTransport: transport)
        )
    }

    func disconnect() {
        filesController.disconnect()
        terminalController.disconnect()
    }
}
