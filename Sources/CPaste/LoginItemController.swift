import Combine
import ServiceManagement

protocol LoginItemService {
    var status: SMAppService.Status { get }
    func register() throws
    func unregister() throws
}

extension SMAppService: LoginItemService {}

final class LoginItemController: ObservableObject {
    @Published private(set) var status: SMAppService.Status
    @Published private(set) var lastError: Error?

    private let service: LoginItemService
    private let openSettings: () -> Void

    init(
        service: LoginItemService = SMAppService.mainApp,
        openSettings: @escaping () -> Void = { SMAppService.openSystemSettingsLoginItems() }
    ) {
        self.service = service
        self.openSettings = openSettings
        status = service.status
    }

    var isEnabled: Bool { status == .enabled }
    var needsApproval: Bool { status == .requiresApproval }

    func refresh() {
        let currentStatus = service.status
        if currentStatus != status { lastError = nil }
        status = currentStatus
    }

    func setEnabled(_ enabled: Bool) {
        refresh()
        lastError = nil
        if enabled {
            guard !isEnabled else { return }
            // Registration cannot override a choice made in System Settings.
            if needsApproval {
                openSystemSettings()
                return
            }
        } else if status == .notRegistered || status == .notFound {
            return
        }

        do {
            if enabled {
                try service.register()
            } else {
                try service.unregister()
            }
        } catch {
            lastError = error
        }
        // A successful call can still require approval; never cache intent as
        // the enabled state or register again automatically at app launch.
        refresh()
    }

    func openSystemSettings() {
        openSettings()
    }
}
