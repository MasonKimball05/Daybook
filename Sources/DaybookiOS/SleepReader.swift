import DaybookCore
import Foundation
import HealthKit

/// Reads sleep from Apple Health: whatever wrote it (Garmin Connect here, or an
/// Apple Watch or a sleep app). Only sleep is asked for, and only to read.
@MainActor
enum SleepReader {
    private static let health = HKHealthStore()

    /// The last 60 nights, handed to the store (which shares them with the Mac).
    static func refresh(_ store: CalendarStore) async {
        guard HKHealthStore.isHealthDataAvailable() else { return }
        let type = HKCategoryType(.sleepAnalysis)
        // The first time, iOS asks; after that this returns at once.
        do {
            try await health.requestAuthorization(toShare: [], read: [type])
        } catch {
            return
        }
        let since = Calendar.current.date(byAdding: .day, value: -60, to: .now)!
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: HKQuery.predicateForSamples(withStart: since, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        guard let found = try? await query.result(for: health) else { return }
        let samples = found.compactMap { sample -> Sleep.Sample? in
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .awake: nil // awake in the night: neither asleep nor a night of its own
            case .inBed: Sleep.Sample(start: sample.startDate, end: sample.endDate, asleep: false)
            default: Sleep.Sample(start: sample.startDate, end: sample.endDate, asleep: true) // any sleep stage
            }
        }
        // iOS doesn't say whether reading was allowed; no samples means not allowed, or no data.
        guard !samples.isEmpty else { return }
        await store.updateSleep(Sleep.nights(samples))
    }
}
