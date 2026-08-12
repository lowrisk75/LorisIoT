import Testing
import Foundation
@testable import IoTCore

@Suite struct DynamicTariffSchedulerTests {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)   // arbitrary fixed "now"
    private func slot(_ h0: Int, _ h1: Int, _ price: Double) -> TariffSlot {
        TariffSlot(start: t0.addingTimeInterval(Double(h0) * 3600),
                   end: t0.addingTimeInterval(Double(h1) * 3600), pricePerKWh: price)
    }

    @Test func contiguousPicksCheapestWindow() throws {
        // Prices: [0-2]=0.30, [2-6]=0.10 (cheap), [6-8]=0.25. Need 2h contiguous by +8h.
        let slots = [slot(0, 2, 0.30), slot(2, 6, 0.10), slot(6, 8, 0.25)]
        let c = LoadConstraint(requirement: .duration(2 * 3600), deadline: t0.addingTimeInterval(8 * 3600),
                               powerKW: 1, splittable: false)
        let plan = try DynamicTariffScheduler.plan(c, slots: slots, now: t0)
        #expect(plan.windows.count == 1)
        #expect(plan.windows.first?.start == t0.addingTimeInterval(2 * 3600))   // starts at the cheap slot
        #expect(abs(plan.estimatedCost - 0.20) < 1e-6)                          // 2h × 1kW × 0.10
    }

    @Test func splittableFillsCheapestSlotsFirst() throws {
        // Need 30 kWh at 10 kW (=3h) by +6h. Cheap 2h @0.10 then 4h @0.20 → 2h cheap + 1h expensive.
        let slots = [slot(0, 2, 0.10), slot(2, 6, 0.20)]
        let c = LoadConstraint(requirement: .energy(kWh: 30), deadline: t0.addingTimeInterval(6 * 3600),
                               powerKW: 10, splittable: true)
        let plan = try DynamicTariffScheduler.plan(c, slots: slots, now: t0)
        // cost = 2h*10kW*0.10 + 1h*10kW*0.20 = 2.0 + 2.0 = 4.0
        #expect(abs(plan.estimatedCost - 4.0) < 1e-6)
    }

    @Test func throwsWhenDeadlineCannotBeMet() {
        let slots = [slot(0, 1, 0.10)]
        let c = LoadConstraint(requirement: .duration(4 * 3600), deadline: t0.addingTimeInterval(1 * 3600),
                               powerKW: 1, splittable: false)
        #expect(throws: TariffSchedulingError.self) {
            try DynamicTariffScheduler.plan(c, slots: slots, now: t0)
        }
    }
}
