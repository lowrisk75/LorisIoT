import Foundation

/// A priced time slot (from an EDF Tempo / spot / TOU / flat `TariffProvider`).
public struct TariffSlot: Sendable, Hashable {
    public let start: Date
    public let end: Date
    public let pricePerKWh: Double        // or a carbon proxy for a "greenest" objective
    public init(start: Date, end: Date, pricePerKWh: Double) {
        self.start = start; self.end = end; self.pricePerKWh = pricePerKWh
    }
    public var duration: TimeInterval { end.timeIntervalSince(start) }
}

public protocol TariffProvider: Sendable {
    /// Contiguous priced slots covering [from, to). Impls: Tempo, spot/hourly, TOU, flat.
    func slots(from: Date, to: Date) async throws -> [TariffSlot]
}

/// What the caller needs run, and by when.
public struct LoadConstraint: Sendable, Hashable {
    public enum Requirement: Sendable, Hashable {
        case duration(TimeInterval)   // "run the pump 4h"
        case energy(kWh: Double)      // "put 30 kWh in the battery"
    }
    public let requirement: Requirement
    public let deadline: Date
    public let powerKW: Double         // draw while running
    public let splittable: Bool        // can the load pause/resume (EV) vs one contiguous block (pump)?
    public init(requirement: Requirement, deadline: Date, powerKW: Double, splittable: Bool) {
        self.requirement = requirement; self.deadline = deadline; self.powerKW = powerKW; self.splittable = splittable
    }
}

public struct TariffPlan: Sendable, Hashable {
    public let windows: [DateInterval]  // when to run
    public let estimatedCost: Double
    public init(windows: [DateInterval], estimatedCost: Double) { self.windows = windows; self.estimatedCost = estimatedCost }
}

public enum TariffSchedulingError: Error, Sendable, Equatable { case noSlots, cannotMeetDeadline }

/// Pure, network-free optimizer: pick the cheapest window(s) that satisfy a load constraint before its
/// deadline. Output feeds a `SchedulingProvider` to pre-provision on an always-on system (Shelly cron
/// / HA automation) — the app never fires the load itself at the target time (the pre-provisioning law).
public enum DynamicTariffScheduler {

    /// - Parameter now: injectable clock for deterministic tests.
    public static func plan(_ constraint: LoadConstraint, slots rawSlots: [TariffSlot],
                            now: Date) throws -> TariffPlan {
        let slots = rawSlots.filter { $0.end > now && $0.start < constraint.deadline }
                            .sorted { $0.start < $1.start }
        guard !slots.isEmpty else { throw TariffSchedulingError.noSlots }

        let neededDuration: TimeInterval
        switch constraint.requirement {
        case .duration(let d): neededDuration = d
        case .energy(let kWh): neededDuration = constraint.powerKW > 0 ? kWh / constraint.powerKW * 3600 : 0
        }
        guard neededDuration > 0 else { return TariffPlan(windows: [], estimatedCost: 0) }

        return constraint.splittable
            ? try planSplittable(neededDuration, powerKW: constraint.powerKW, deadline: constraint.deadline, now: now, slots: slots)
            : try planContiguous(neededDuration, powerKW: constraint.powerKW, deadline: constraint.deadline, now: now, slots: slots)
    }

    /// Splittable (EV): fill cheapest slots first until the duration is met.
    private static func planSplittable(_ needed: TimeInterval, powerKW: Double, deadline: Date,
                                       now: Date, slots: [TariffSlot]) throws -> TariffPlan {
        var remaining = needed
        var cost = 0.0
        var windows: [DateInterval] = []
        for slot in slots.sorted(by: { $0.pricePerKWh < $1.pricePerKWh }) where remaining > 0 {
            let from = max(slot.start, now)
            let to = min(slot.end, deadline)
            let usable = to.timeIntervalSince(from)
            guard usable > 0 else { continue }
            let take = min(usable, remaining)
            windows.append(DateInterval(start: from, duration: take))
            cost += powerKW * (take / 3600) * slot.pricePerKWh
            remaining -= take
        }
        guard remaining <= 0.5 else { throw TariffSchedulingError.cannotMeetDeadline }
        return TariffPlan(windows: windows.sorted { $0.start < $1.start }, estimatedCost: cost)
    }

    /// Contiguous (pump): slide a `needed`-long window over the price curve, pick the cheapest that
    /// fits before the deadline. Prices are piecewise-constant per slot.
    private static func planContiguous(_ needed: TimeInterval, powerKW: Double, deadline: Date,
                                       now: Date, slots: [TariffSlot]) throws -> TariffPlan {
        // Candidate start times = each slot boundary (optimum for piecewise-constant prices starts on a boundary).
        var best: (start: Date, cost: Double)?
        let starts = slots.map { max($0.start, now) }
        for start in starts {
            let end = start.addingTimeInterval(needed)
            guard end <= deadline else { continue }
            guard let cost = cost(from: start, to: end, powerKW: powerKW, slots: slots) else { continue }
            if best == nil || cost < best!.cost { best = (start, cost) }
        }
        guard let best else { throw TariffSchedulingError.cannotMeetDeadline }
        return TariffPlan(windows: [DateInterval(start: best.start, duration: needed)], estimatedCost: best.cost)
    }

    /// Cost of running [from,to) across piecewise-constant priced slots; nil if not fully covered.
    private static func cost(from: Date, to: Date, powerKW: Double, slots: [TariffSlot]) -> Double? {
        var cursor = from
        var total = 0.0
        while cursor < to {
            guard let slot = slots.first(where: { $0.start <= cursor && $0.end > cursor }) else { return nil }
            let segEnd = min(slot.end, to)
            total += powerKW * (segEnd.timeIntervalSince(cursor) / 3600) * slot.pricePerKWh
            cursor = segEnd
        }
        return total
    }
}
