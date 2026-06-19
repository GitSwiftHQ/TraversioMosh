// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshWire

public struct MoshSSPSendTimingConfiguration: Equatable, Sendable {
    public var sendIntervalMilliseconds: UInt64
    public var acknowledgementIntervalMilliseconds: UInt64
    public var activeRetryTimeoutMilliseconds: UInt64
    public var sendMinimumDelayMilliseconds: UInt64
    public var timeoutMilliseconds: UInt64

    public init(
        sendIntervalMilliseconds: UInt64 = 20,
        acknowledgementIntervalMilliseconds: UInt64 = 3_000,
        activeRetryTimeoutMilliseconds: UInt64 = 10_000,
        sendMinimumDelayMilliseconds: UInt64 = 8,
        timeoutMilliseconds: UInt64 = 1_000
    ) {
        self.sendIntervalMilliseconds = sendIntervalMilliseconds
        self.acknowledgementIntervalMilliseconds = acknowledgementIntervalMilliseconds
        self.activeRetryTimeoutMilliseconds = activeRetryTimeoutMilliseconds
        self.sendMinimumDelayMilliseconds = sendMinimumDelayMilliseconds
        self.timeoutMilliseconds = timeoutMilliseconds
    }
}

public enum MoshSSPSendEvent: Equatable, Sendable {
    case data(MoshTransportInstruction)
    case acknowledgement(MoshTransportInstruction)
}

public struct MoshSSPSendScheduler<State: MoshSynchronizedState>: Sendable {
    public private(set) var sender: MoshSSPSender<State>

    private let timing: MoshSSPSendTimingConfiguration
    private var nextAcknowledgementAtMilliseconds: UInt64
    private var nextSendAtMilliseconds: UInt64?
    private var firstPendingChangeAtMilliseconds: UInt64?
    private var lastHeardAtMilliseconds: UInt64?
    private var pendingDataAcknowledgement: Bool

    public init(
        initialState: State,
        initialNowMilliseconds: UInt64 = 0,
        timing: MoshSSPSendTimingConfiguration = MoshSSPSendTimingConfiguration(),
        chaffSource: MoshSSPChaffSource = .random
    ) {
        self.sender = MoshSSPSender(
            initialState: initialState,
            initialSentAtMilliseconds: initialNowMilliseconds,
            chaffSource: chaffSource
        )
        self.timing = timing
        self.nextAcknowledgementAtMilliseconds = Self.saturatingAdd(
            initialNowMilliseconds,
            timing.acknowledgementIntervalMilliseconds
        )
        self.nextSendAtMilliseconds = nil
        self.firstPendingChangeAtMilliseconds = nil
        self.lastHeardAtMilliseconds = nil
        self.pendingDataAcknowledgement = false
    }

    public mutating func setCurrentState(_ state: State, nowMilliseconds: UInt64) {
        self.sender.setCurrentState(state)
        if self.sender.currentStateMatchesLastSentState {
            self.firstPendingChangeAtMilliseconds = nil
        } else if self.firstPendingChangeAtMilliseconds == nil {
            self.firstPendingChangeAtMilliseconds = nowMilliseconds
        }
    }

    public mutating func noteReceivedState(number: UInt64, nowMilliseconds: UInt64) {
        self.sender.setAcknowledgementNumber(number)
        self.pendingDataAcknowledgement = true
        self.lastHeardAtMilliseconds = nowMilliseconds
        self.scheduleDelayedAcknowledgement(from: nowMilliseconds)
    }

    public mutating func noteRemoteHeard(nowMilliseconds: UInt64) {
        self.lastHeardAtMilliseconds = nowMilliseconds
    }

    public mutating func processAcknowledgement(through acknowledgementNumber: UInt64, nowMilliseconds: UInt64) {
        self.sender.processAcknowledgement(through: acknowledgementNumber)
        self.lastHeardAtMilliseconds = nowMilliseconds
    }

    public mutating func waitTime(nowMilliseconds: UInt64) throws -> UInt64? {
        try self.recalculateTimers(nowMilliseconds: nowMilliseconds)

        var nextWakeup = self.nextAcknowledgementAtMilliseconds
        if let nextSendAtMilliseconds, nextSendAtMilliseconds < nextWakeup {
            nextWakeup = nextSendAtMilliseconds
        }

        guard nextWakeup < UInt64.max else {
            return nil
        }

        if nextWakeup > nowMilliseconds {
            return nextWakeup - nowMilliseconds
        }
        return 0
    }

    public mutating func tick(nowMilliseconds: UInt64) throws -> MoshSSPSendEvent? {
        try self.recalculateTimers(nowMilliseconds: nowMilliseconds)

        let acknowledgementDue = nowMilliseconds >= self.nextAcknowledgementAtMilliseconds
        let sendDue = self.nextSendAtMilliseconds.map { nowMilliseconds >= $0 } ?? false
        guard acknowledgementDue || sendDue else {
            return nil
        }

        if let instruction = try self.sender.makeDataInstruction(
            nowMilliseconds: nowMilliseconds,
            timeoutMilliseconds: self.timing.timeoutMilliseconds
        ) {
            self.recordInstructionSent(nowMilliseconds: nowMilliseconds)
            return .data(instruction)
        }

        if acknowledgementDue {
            let instruction = try self.sender.makeAcknowledgementInstruction(
                nowMilliseconds: nowMilliseconds,
                timeoutMilliseconds: self.timing.timeoutMilliseconds
            )
            self.recordInstructionSent(nowMilliseconds: nowMilliseconds)
            return .acknowledgement(instruction)
        }

        self.nextSendAtMilliseconds = nil
        self.firstPendingChangeAtMilliseconds = nil
        return nil
    }

    private mutating func recalculateTimers(nowMilliseconds: UInt64) throws {
        try self.sender.refreshAssumedReceiverState(
            nowMilliseconds: nowMilliseconds,
            timeoutMilliseconds: self.timing.timeoutMilliseconds
        )

        if self.pendingDataAcknowledgement {
            self.scheduleDelayedAcknowledgement(from: nowMilliseconds)
        }

        if self.sender.currentStateMatchesLastSentState == false {
            if self.firstPendingChangeAtMilliseconds == nil {
                self.firstPendingChangeAtMilliseconds = nowMilliseconds
            }

            let minimumDelayAt = Self.saturatingAdd(
                self.firstPendingChangeAtMilliseconds ?? nowMilliseconds,
                self.timing.sendMinimumDelayMilliseconds
            )
            let intervalAt = Self.saturatingAdd(
                self.sender.lastSentAtMilliseconds,
                self.timing.sendIntervalMilliseconds
            )
            self.nextSendAtMilliseconds = max(minimumDelayAt, intervalAt)
            return
        }

        if self.sender.currentStateMatchesAssumedReceiverState == false && self.hasHeardRemoteRecently(nowMilliseconds) {
            var nextSendAtMilliseconds = Self.saturatingAdd(
                self.sender.lastSentAtMilliseconds,
                self.timing.sendIntervalMilliseconds
            )
            if let firstPendingChangeAtMilliseconds {
                nextSendAtMilliseconds = max(
                    nextSendAtMilliseconds,
                    Self.saturatingAdd(firstPendingChangeAtMilliseconds, self.timing.sendMinimumDelayMilliseconds)
                )
            }
            self.nextSendAtMilliseconds = nextSendAtMilliseconds
            return
        }

        if self.sender.currentStateMatchesKnownAcknowledgedState == false && self.hasHeardRemoteRecently(nowMilliseconds) {
            self.nextSendAtMilliseconds = Self.saturatingAdd(
                self.sender.lastSentAtMilliseconds,
                Self.saturatingAdd(
                    self.timing.timeoutMilliseconds,
                    MoshSSPSender<State>.acknowledgementDelayMilliseconds
                )
            )
            return
        }

        self.nextSendAtMilliseconds = nil
    }

    private mutating func recordInstructionSent(nowMilliseconds: UInt64) {
        self.nextAcknowledgementAtMilliseconds = Self.saturatingAdd(
            nowMilliseconds,
            self.timing.acknowledgementIntervalMilliseconds
        )
        self.nextSendAtMilliseconds = nil
        self.firstPendingChangeAtMilliseconds = nil
        self.pendingDataAcknowledgement = false
    }

    private mutating func scheduleDelayedAcknowledgement(from nowMilliseconds: UInt64) {
        let delayedAcknowledgementAt = Self.saturatingAdd(
            nowMilliseconds,
            MoshSSPSender<State>.acknowledgementDelayMilliseconds
        )
        if self.nextAcknowledgementAtMilliseconds > delayedAcknowledgementAt {
            self.nextAcknowledgementAtMilliseconds = delayedAcknowledgementAt
        }
    }

    private func hasHeardRemoteRecently(_ nowMilliseconds: UInt64) -> Bool {
        guard let lastHeardAtMilliseconds else {
            return false
        }
        return Self.saturatingAdd(
            lastHeardAtMilliseconds,
            self.timing.activeRetryTimeoutMilliseconds
        ) > nowMilliseconds
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
    }
}
