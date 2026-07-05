// Copyright (c) 2026 GitSwift LLC
//
// Licensed under the MIT License.
// See LICENSE for details.

import TraversioMoshWire

public struct MoshSSPSendTimingConfiguration: Equatable, Sendable {
    public var acknowledgementIntervalMilliseconds: UInt64
    public var activeRetryTimeoutMilliseconds: UInt64
    public var sendMinimumDelayMilliseconds: UInt64
    public var minimumSendIntervalMilliseconds: UInt64
    public var maximumSendIntervalMilliseconds: UInt64
    public var minimumTimeoutMilliseconds: UInt64
    public var maximumTimeoutMilliseconds: UInt64
    public var maximumRoundTripSampleMilliseconds: UInt64
    public var initialSmoothedRoundTripMilliseconds: Double
    public var initialRoundTripVariationMilliseconds: Double
    public var shutdownMaximumAttempts: Int

    public init(
        sendIntervalMilliseconds: UInt64? = nil,
        acknowledgementIntervalMilliseconds: UInt64 = 3_000,
        activeRetryTimeoutMilliseconds: UInt64 = 10_000,
        sendMinimumDelayMilliseconds: UInt64 = 8,
        timeoutMilliseconds: UInt64? = nil,
        shutdownMaximumAttempts: Int = 16,
        minimumSendIntervalMilliseconds: UInt64 = 20,
        maximumSendIntervalMilliseconds: UInt64 = 250,
        minimumTimeoutMilliseconds: UInt64 = 50,
        maximumTimeoutMilliseconds: UInt64 = 1_000,
        maximumRoundTripSampleMilliseconds: UInt64 = 5_000,
        initialSmoothedRoundTripMilliseconds: Double = 1_000,
        initialRoundTripVariationMilliseconds: Double = 500
    ) {
        self.acknowledgementIntervalMilliseconds = acknowledgementIntervalMilliseconds
        self.activeRetryTimeoutMilliseconds = activeRetryTimeoutMilliseconds
        self.sendMinimumDelayMilliseconds = sendMinimumDelayMilliseconds
        if let sendIntervalMilliseconds {
            self.minimumSendIntervalMilliseconds = sendIntervalMilliseconds
            self.maximumSendIntervalMilliseconds = sendIntervalMilliseconds
            self.initialSmoothedRoundTripMilliseconds = Double(sendIntervalMilliseconds) * 2
        } else {
            self.minimumSendIntervalMilliseconds = minimumSendIntervalMilliseconds
            self.maximumSendIntervalMilliseconds = max(
                minimumSendIntervalMilliseconds,
                maximumSendIntervalMilliseconds
            )
            self.initialSmoothedRoundTripMilliseconds = max(0, initialSmoothedRoundTripMilliseconds)
        }
        if let timeoutMilliseconds {
            self.minimumTimeoutMilliseconds = timeoutMilliseconds
            self.maximumTimeoutMilliseconds = timeoutMilliseconds
            self.initialRoundTripVariationMilliseconds = max(
                0,
                (Double(timeoutMilliseconds) - self.initialSmoothedRoundTripMilliseconds) / 4
            )
        } else {
            self.minimumTimeoutMilliseconds = minimumTimeoutMilliseconds
            self.maximumTimeoutMilliseconds = max(
                minimumTimeoutMilliseconds,
                maximumTimeoutMilliseconds
            )
            self.initialRoundTripVariationMilliseconds = max(0, initialRoundTripVariationMilliseconds)
        }
        self.maximumRoundTripSampleMilliseconds = maximumRoundTripSampleMilliseconds
        self.shutdownMaximumAttempts = shutdownMaximumAttempts
    }
}

struct MoshSSPRoundTripEstimator: Equatable, Sendable {
    private let minimumSendIntervalMilliseconds: UInt64
    private let maximumSendIntervalMilliseconds: UInt64
    private let minimumTimeoutMilliseconds: UInt64
    private let maximumTimeoutMilliseconds: UInt64
    private let maximumRoundTripSampleMilliseconds: UInt64

    private var hasRoundTripSample: Bool
    private var smoothedRoundTripMillisecondsStorage: Double
    private var roundTripVariationMillisecondsStorage: Double

    init(timing: MoshSSPSendTimingConfiguration) {
        self.minimumSendIntervalMilliseconds = timing.minimumSendIntervalMilliseconds
        self.maximumSendIntervalMilliseconds = timing.maximumSendIntervalMilliseconds
        self.minimumTimeoutMilliseconds = timing.minimumTimeoutMilliseconds
        self.maximumTimeoutMilliseconds = timing.maximumTimeoutMilliseconds
        self.maximumRoundTripSampleMilliseconds = timing.maximumRoundTripSampleMilliseconds
        self.hasRoundTripSample = false
        self.smoothedRoundTripMillisecondsStorage = timing.initialSmoothedRoundTripMilliseconds
        self.roundTripVariationMillisecondsStorage = timing.initialRoundTripVariationMilliseconds
    }

    var smoothedRoundTripMilliseconds: Double {
        self.smoothedRoundTripMillisecondsStorage
    }

    var roundTripVariationMilliseconds: Double {
        self.roundTripVariationMillisecondsStorage
    }

    var sendIntervalMilliseconds: UInt64 {
        self.clampedCeiling(
            self.smoothedRoundTripMillisecondsStorage / 2,
            lowerBound: self.minimumSendIntervalMilliseconds,
            upperBound: self.maximumSendIntervalMilliseconds
        )
    }

    var timeoutMilliseconds: UInt64 {
        self.clampedCeiling(
            self.smoothedRoundTripMillisecondsStorage + 4 * self.roundTripVariationMillisecondsStorage,
            lowerBound: self.minimumTimeoutMilliseconds,
            upperBound: self.maximumTimeoutMilliseconds
        )
    }

    mutating func observePacketTimestampReply(
        _ timestampReply: UInt16,
        nowMilliseconds: UInt64
    ) {
        guard timestampReply != UInt16.max else {
            return
        }

        let nowTimestamp = UInt16(truncatingIfNeeded: nowMilliseconds)
        self.observeRoundTripSample(milliseconds: UInt64(nowTimestamp &- timestampReply))
    }

    private mutating func observeRoundTripSample(milliseconds sampleMilliseconds: UInt64) {
        guard sampleMilliseconds < self.maximumRoundTripSampleMilliseconds else {
            return
        }

        let sample = Double(sampleMilliseconds)
        if self.hasRoundTripSample == false {
            self.smoothedRoundTripMillisecondsStorage = sample
            self.roundTripVariationMillisecondsStorage = sample / 2
            self.hasRoundTripSample = true
            return
        }

        let alpha = 1.0 / 8.0
        let beta = 1.0 / 4.0
        let oldSmoothedRoundTrip = self.smoothedRoundTripMillisecondsStorage
        self.roundTripVariationMillisecondsStorage = (1 - beta) * self.roundTripVariationMillisecondsStorage
            + beta * abs(oldSmoothedRoundTrip - sample)
        self.smoothedRoundTripMillisecondsStorage = (1 - alpha) * oldSmoothedRoundTrip + alpha * sample
    }

    private func clampedCeiling(
        _ value: Double,
        lowerBound: UInt64,
        upperBound: UInt64
    ) -> UInt64 {
        let rounded = UInt64(max(0, value.rounded(.up)))
        return min(max(rounded, lowerBound), upperBound)
    }
}

public enum MoshSSPSendEvent: Equatable, Sendable {
    case data(MoshTransportInstruction)
    case acknowledgement(MoshTransportInstruction)
}

public struct MoshSSPSendScheduler<State: MoshSynchronizedState>: Sendable {
    public private(set) var sender: MoshSSPSender<State>

    private let timing: MoshSSPSendTimingConfiguration
    private var roundTripEstimator: MoshSSPRoundTripEstimator
    private var nextAcknowledgementAtMilliseconds: UInt64
    private var nextSendAtMilliseconds: UInt64?
    private var firstPendingChangeAtMilliseconds: UInt64?
    private var connectionLastHeardAtMillisecondsStorage: UInt64?
    private var senderLastHeardAtMillisecondsStorage: UInt64?
    private var pendingDataAcknowledgement: Bool
    private var shutdownStartedAtMilliseconds: UInt64?
    private var shutdownAttemptCountStorage: Int

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
        self.roundTripEstimator = MoshSSPRoundTripEstimator(timing: timing)
        self.nextAcknowledgementAtMilliseconds = Self.saturatingAdd(
            initialNowMilliseconds,
            timing.acknowledgementIntervalMilliseconds
        )
        self.nextSendAtMilliseconds = nil
        self.firstPendingChangeAtMilliseconds = nil
        self.connectionLastHeardAtMillisecondsStorage = nil
        self.senderLastHeardAtMillisecondsStorage = nil
        self.pendingDataAcknowledgement = false
        self.shutdownStartedAtMilliseconds = nil
        self.shutdownAttemptCountStorage = 0
    }

    public var shutdownInProgress: Bool {
        self.shutdownStartedAtMilliseconds != nil
    }

    public var shutdownAcknowledged: Bool {
        self.sender.shutdownAcknowledged
    }

    public var shutdownAttemptCount: Int {
        self.shutdownAttemptCountStorage
    }

    /// Clock time (ms) of the most recent **in-sequence datagram** from the peer.
    /// `nil` until first contact.
    ///
    /// Official Mosh keeps two distinct last-heard signals, and this scheduler
    /// mirrors both:
    ///
    /// - **Connection-level** (`Connection::last_heard`, `network/network.cc`
    ///   `recv_one`): advances for every authenticated in-order datagram
    ///   regardless of instruction content; an out-of-order/replayed datagram
    ///   never moves it. That is this property, fed by `noteRemoteHeard` (and,
    ///   for standalone-scheduler callers, `processAcknowledgement`'s
    ///   in-sequence path). It is surfaced for host-visible liveness rendering
    ///   ("last contact Ns ago", `frontend/terminaloverlay.cc` ~205-217) and
    ///   does not gate retransmission.
    /// - **Transport-sender-level** (`TransportSender::last_heard`, "last time
    ///   received new state", `network/transportsender.h`): advances only when
    ///   a genuinely new state is appended at the back of the receiver queue
    ///   (`noteReceivedState`, mirroring `sender.remote_heard()` in
    ///   `Transport::recv`), independent of datagram sequence order. It feeds
    ///   `hasHeardRemoteRecently`, which gates the ACTIVE_RETRY_TIMEOUT
    ///   retransmission window in `recalculateTimers` — so it does drive send
    ///   behavior, not teardown.
    public var lastHeardAtMilliseconds: UInt64? {
        self.connectionLastHeardAtMillisecondsStorage
    }

    public var sendIntervalMilliseconds: UInt64 {
        self.roundTripEstimator.sendIntervalMilliseconds
    }

    public var timeoutMilliseconds: UInt64 {
        self.roundTripEstimator.timeoutMilliseconds
    }

    public var smoothedRoundTripMilliseconds: Double {
        self.roundTripEstimator.smoothedRoundTripMilliseconds
    }

    public var roundTripVariationMilliseconds: Double {
        self.roundTripEstimator.roundTripVariationMilliseconds
    }

    public mutating func startShutdown(nowMilliseconds: UInt64) {
        guard self.shutdownStartedAtMilliseconds == nil else {
            return
        }
        self.shutdownStartedAtMilliseconds = nowMilliseconds
        self.nextAcknowledgementAtMilliseconds = min(
            self.nextAcknowledgementAtMilliseconds,
            Self.saturatingAdd(self.sender.lastSentAtMilliseconds, self.sendIntervalMilliseconds)
        )
    }

    public func shutdownTimedOut(nowMilliseconds: UInt64) -> Bool {
        guard let shutdownStartedAtMilliseconds, self.shutdownAcknowledged == false else {
            return false
        }

        if self.shutdownAttemptCountStorage >= self.timing.shutdownMaximumAttempts {
            return true
        }

        guard nowMilliseconds >= shutdownStartedAtMilliseconds else {
            return false
        }
        return nowMilliseconds - shutdownStartedAtMilliseconds >= self.timing.activeRetryTimeoutMilliseconds
    }

    public mutating func setCurrentState(_ state: State, nowMilliseconds: UInt64) {
        self.sender.setCurrentState(state)
        self.refreshPendingChange(nowMilliseconds: nowMilliseconds)
    }

    /// Appends a delta to the sender-owned current state. Preferred over
    /// `setCurrentState` for growing streams, because `rationalizeStates` prunes
    /// the sender's copy and a full re-injection would undo that pruning.
    public mutating func modifyCurrentState(
        nowMilliseconds: UInt64,
        _ body: (inout State) -> Void
    ) {
        self.sender.modifyCurrentState(body)
        self.refreshPendingChange(nowMilliseconds: nowMilliseconds)
    }

    private mutating func refreshPendingChange(nowMilliseconds: UInt64) {
        if self.sender.currentStateMatchesLastSentState {
            self.firstPendingChangeAtMilliseconds = nil
        } else if self.firstPendingChangeAtMilliseconds == nil {
            self.firstPendingChangeAtMilliseconds = nowMilliseconds
        }
    }

    /// Records that a numbered state was appended at the **back** of the
    /// receiver's queue. Callers must invoke this only for a genuinely new
    /// latest state — never for a duplicate, an out-of-order state number
    /// inserted mid-queue, or a dropped (queue-full) state. This mirrors the
    /// tail of official Mosh `Transport::recv`
    /// (`network/networktransport-impl.h` ~167-173): only after
    /// `received_states.push_back` does it run `sender.set_ack_num`,
    /// `sender.remote_heard`, and — gated on `!inst.diff().empty()` —
    /// `set_data_ack()`; the duplicate and insert-in-middle paths return before
    /// reaching any of them.
    ///
    /// Datagram sequence order is deliberately NOT a gate here: official's
    /// transport layer never sees it (`Connection::recv_one` returns
    /// out-of-order payloads for full transport processing), so a
    /// multi-fragment instruction completed by an out-of-order datagram still
    /// advances the transport-sender last-heard signal and arms the delayed
    /// data-acknowledgement. A true replay appends nothing, so it never reaches
    /// this method and can neither arm the acknowledgement nor keep the
    /// active-retry window hot. The non-empty-diff gate on the
    /// data-acknowledgement prevents an endless empty-ack ping-pong between two
    /// instances.
    public mutating func noteReceivedState(
        number: UInt64,
        hadNonEmptyDiff: Bool = true,
        nowMilliseconds: UInt64
    ) {
        self.sender.setAcknowledgementNumber(number)
        self.senderLastHeardAtMillisecondsStorage = nowMilliseconds
        if hadNonEmptyDiff {
            self.pendingDataAcknowledgement = true
            self.scheduleDelayedAcknowledgement(from: nowMilliseconds)
        }
    }

    /// Records connection-level contact: an authenticated **in-sequence**
    /// datagram arrived. Mirrors `Connection::recv_one` advancing
    /// `Connection::last_heard` (`network/network.cc` ~524). Callers must not
    /// invoke this for an out-of-order/replayed datagram (`recv_one` returns
    /// such a payload before touching `last_heard`), so a replay cannot mask a
    /// real outage in the liveness signal. This does not feed the active-retry
    /// gate, which follows the transport-sender-level new-state-appended rule
    /// (`noteReceivedState`).
    public mutating func noteRemoteHeard(nowMilliseconds: UInt64) {
        self.connectionLastHeardAtMillisecondsStorage = nowMilliseconds
    }

    public mutating func processPacketTimestampReply(_ timestampReply: UInt16, nowMilliseconds: UInt64) {
        self.roundTripEstimator.observePacketTimestampReply(
            timestampReply,
            nowMilliseconds: nowMilliseconds
        )
    }

    /// Advances the sender's knowledge of what the peer has acknowledged. The
    /// ack-number pruning (`sender.processAcknowledgement`) is monotonic and
    /// idempotent — guarded by a `contains` check on the retained sent states — so
    /// it runs regardless of datagram ordering, exactly as official Mosh's
    /// `Transport::recv` runs `process_acknowledgment_through` for every
    /// assembled instruction, including one completed by an out-of-order
    /// datagram. Ack processing never advances the transport-sender-level
    /// last-heard signal that gates active retransmission (official's
    /// `process_acknowledgment_through` does not touch
    /// `TransportSender::last_heard`; only a new state appended at the back
    /// does, via `remote_heard`). For an in-sequence datagram this records
    /// connection-level contact — redundant behind `MoshSSPInMemoryLoop`, which
    /// already called `noteRemoteHeard`, but meaningful for
    /// standalone-scheduler callers that have no separate datagram hook.
    public mutating func processAcknowledgement(
        through acknowledgementNumber: UInt64,
        nowMilliseconds: UInt64,
        isInSequenceOrder: Bool = true
    ) {
        self.sender.processAcknowledgement(through: acknowledgementNumber)
        if isInSequenceOrder {
            self.connectionLastHeardAtMillisecondsStorage = nowMilliseconds
        }
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
            timeoutMilliseconds: self.timeoutMilliseconds,
            isShutdown: self.shutdownInProgress
        ) {
            self.recordInstructionSent(instruction, nowMilliseconds: nowMilliseconds)
            return .data(instruction)
        }

        if acknowledgementDue {
            let instruction = try self.sender.makeAcknowledgementInstruction(
                nowMilliseconds: nowMilliseconds,
                timeoutMilliseconds: self.timeoutMilliseconds,
                isShutdown: self.shutdownInProgress
            )
            self.recordInstructionSent(instruction, nowMilliseconds: nowMilliseconds)
            return .acknowledgement(instruction)
        }

        self.nextSendAtMilliseconds = nil
        self.firstPendingChangeAtMilliseconds = nil
        return nil
    }

    private mutating func recalculateTimers(nowMilliseconds: UInt64) throws {
        try self.sender.refreshAssumedReceiverState(
            nowMilliseconds: nowMilliseconds,
            timeoutMilliseconds: self.timeoutMilliseconds
        )

        // Cut out the common prefix of all states, exactly where official Mosh's
        // `calculate_timers` does (`network/transportsender-impl.h`).
        self.sender.rationalizeStates()

        if self.pendingDataAcknowledgement {
            self.scheduleDelayedAcknowledgement(from: nowMilliseconds)
        }

        if self.shutdownInProgress || self.sender.acknowledgementNumber == UInt64.max {
            self.nextAcknowledgementAtMilliseconds = Self.saturatingAdd(
                self.sender.lastSentAtMilliseconds,
                self.sendIntervalMilliseconds
            )
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
                self.sendIntervalMilliseconds
            )
            self.nextSendAtMilliseconds = max(minimumDelayAt, intervalAt)
            return
        }

        if self.sender.currentStateMatchesAssumedReceiverState == false && self.hasHeardRemoteRecently(nowMilliseconds) {
            var nextSendAtMilliseconds = Self.saturatingAdd(
                self.sender.lastSentAtMilliseconds,
                self.sendIntervalMilliseconds
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
                    self.timeoutMilliseconds,
                    MoshSSPSender<State>.acknowledgementDelayMilliseconds
                )
            )
            return
        }

        self.nextSendAtMilliseconds = nil
    }

    private mutating func recordInstructionSent(
        _ instruction: MoshTransportInstruction,
        nowMilliseconds: UInt64
    ) {
        if instruction.newNumber == UInt64.max {
            self.shutdownAttemptCountStorage += 1
        }
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

    /// The ACTIVE_RETRY_TIMEOUT gate on retransmission, following official
    /// `calculate_timers`'s `last_heard + ACTIVE_RETRY_TIMEOUT > now` — where
    /// `last_heard` is the transport-sender-level "last time received new
    /// state" signal, advanced only by `noteReceivedState`. Connection-level
    /// datagram contact alone does not keep this window hot.
    private func hasHeardRemoteRecently(_ nowMilliseconds: UInt64) -> Bool {
        guard let senderLastHeardAtMilliseconds = self.senderLastHeardAtMillisecondsStorage else {
            return false
        }
        return Self.saturatingAdd(
            senderLastHeardAtMilliseconds,
            self.timing.activeRetryTimeoutMilliseconds
        ) > nowMilliseconds
    }

    private static func saturatingAdd(_ lhs: UInt64, _ rhs: UInt64) -> UInt64 {
        lhs > UInt64.max - rhs ? UInt64.max : lhs + rhs
    }
}
