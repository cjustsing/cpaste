public struct HistoryPanelPresentationState: Equatable, Sendable {
    public var isSettingsPresented: Bool
    public var isConfirmingClear: Bool

    public init(
        isSettingsPresented: Bool = false,
        isConfirmingClear: Bool = false
    ) {
        self.isSettingsPresented = isSettingsPresented
        self.isConfirmingClear = isConfirmingClear
    }

    public mutating func resetTransientUI() {
        isSettingsPresented = false
        isConfirmingClear = false
    }
}

public struct SettingsPresentationState: Equatable, Sendable {
    public var isSupportPresented: Bool

    public init(isSupportPresented: Bool = false) {
        self.isSupportPresented = isSupportPresented
    }

    public mutating func presentSupport() {
        isSupportPresented = true
    }

    public mutating func dismissSupport() {
        isSupportPresented = false
    }

    public mutating func reset() {
        isSupportPresented = false
    }

    @discardableResult
    public mutating func handleCloseRequest() -> Bool {
        if isSupportPresented {
            isSupportPresented = false
            return false
        }
        return true
    }
}
