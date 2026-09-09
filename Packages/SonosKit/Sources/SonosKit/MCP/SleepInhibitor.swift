/// SleepInhibitor.swift — Holds a power assertion while agent access is on.
import Foundation
import IOKit.pwr_mgt

@MainActor
public final class SleepInhibitor {
    private var assertionID: IOPMAssertionID = 0
    public private(set) var isActive = false

    public init() {}

    public func set(_ active: Bool, reason: String) {
        guard active != isActive else { return }
        if active {
            let result = IOPMAssertionCreateWithName(kIOPMAssertionTypePreventUserIdleSystemSleep as CFString,
                                                     IOPMAssertionLevel(kIOPMAssertionLevelOn),
                                                     reason as CFString, &assertionID)
            isActive = result == kIOReturnSuccess
        } else {
            IOPMAssertionRelease(assertionID)
            assertionID = 0
            isActive = false
        }
    }
}
