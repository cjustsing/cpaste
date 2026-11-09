import Foundation
import ServiceManagement

private func check(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fputs("Login item check failed: \(message)\n", stderr)
        exit(1)
    }
}

private enum SimulatedFailure: Error { case denied }

private final class FakeLoginItemService: LoginItemService {
    var status: SMAppService.Status = .notRegistered
    var registrationStatus: SMAppService.Status = .enabled
    var failRegistration = false
    var failUnregistration = false
    var registrations = 0
    var unregistrations = 0

    func register() throws {
        registrations += 1
        if failRegistration { throw SimulatedFailure.denied }
        status = registrationStatus
    }

    func unregister() throws {
        unregistrations += 1
        if failUnregistration { throw SimulatedFailure.denied }
        status = .notRegistered
    }
}

private let service = FakeLoginItemService()
private var settingsOpens = 0
private let controller = LoginItemController(service: service, openSettings: { settingsOpens += 1 })
check(!controller.isEnabled && service.registrations == 0, "launching or reading settings must never register automatically")
controller.setEnabled(true)
check(controller.isEnabled && service.registrations == 1, "explicit enable must register and read the system result")
controller.setEnabled(true)
check(service.registrations == 1, "enabling an enabled service must be idempotent")
controller.setEnabled(false)
check(!controller.isEnabled && service.unregistrations == 1, "disable must unregister")
controller.setEnabled(false)
check(service.unregistrations == 1, "disabling an unregistered service must be idempotent")

service.registrationStatus = .requiresApproval
controller.setEnabled(true)
check(!controller.isEnabled && controller.needsApproval, "registration success must not imply permission to launch")
let registrationsBeforeApproval = service.registrations
controller.setEnabled(true)
check(settingsOpens == 1 && service.registrations == registrationsBeforeApproval, "pending approval must open settings without overriding the system choice")
service.status = .enabled
controller.refresh()
check(controller.isEnabled && !controller.needsApproval, "returning from System Settings must reflect granted approval")
service.status = .requiresApproval
controller.refresh()
check(!controller.isEnabled && controller.needsApproval, "external revocation must immediately turn the displayed state off")
controller.setEnabled(false)
check(service.status == .notRegistered, "a pending registration can be removed")

service.failRegistration = true
controller.setEnabled(true)
check(!controller.isEnabled && controller.lastError != nil, "registration failure must retain the real off state and expose an error")
service.failRegistration = false
service.registrationStatus = .enabled
controller.setEnabled(true)
check(controller.isEnabled && controller.lastError == nil, "an explicit successful retry must clear the error")
service.failUnregistration = true
controller.setEnabled(false)
check(controller.isEnabled && controller.lastError != nil, "unregistration failure must retain the real on state")
service.status = .notRegistered
controller.refresh()
check(!controller.isEnabled && controller.lastError == nil, "external correction must clear a stale error")

service.status = .notFound
controller.refresh()
check(!controller.isEnabled, "a missing service must never appear enabled")
controller.setEnabled(true)
check(controller.isEnabled, "an explicit enable must recover a missing registration")
service.failUnregistration = false
controller.setEnabled(false)
service.registrationStatus = .notRegistered
controller.setEnabled(true)
check(!controller.isEnabled, "the toggle must read the actual result even if register returns without enabling")
controller.openSystemSettings()
check(settingsOpens == 2, "the settings button must open the system login items pane")
print("Login item state, approval, errors, and explicit-consent checks passed")
