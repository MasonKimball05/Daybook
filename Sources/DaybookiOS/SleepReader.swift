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
        guard HKHealthStore.isHealthDataAvailable() else {
            store.sleepStatus = "Health isn\u{2019}t available on this device."
            return
        }
        let type = HKCategoryType(.sleepAnalysis)
        // The first time, iOS asks; after that this returns at once.
        do {
            try await health.requestAuthorization(toShare: [], read: [type])
        } catch {
            store.sleepStatus = "Couldn\u{2019}t ask Health for sleep: \(error.localizedDescription)"
            return
        }
        let since = Calendar.current.date(byAdding: .day, value: -60, to: .now)!
        let query = HKSampleQueryDescriptor(
            predicates: [.categorySample(type: type, predicate: HKQuery.predicateForSamples(withStart: since, end: nil))],
            sortDescriptors: [SortDescriptor(\.startDate)])
        let found: [HKCategorySample]
        do {
            found = try await query.result(for: health)
        } catch {
            store.sleepStatus = "Health didn\u{2019}t answer: \(error.localizedDescription)"
            return
        }
        let samples = found.compactMap { sample -> Sleep.Sample? in
            switch HKCategoryValueSleepAnalysis(rawValue: sample.value) {
            case .awake: nil // awake in the night: neither asleep nor a night of its own
            case .inBed: Sleep.Sample(start: sample.startDate, end: sample.endDate, asleep: false)
            default: Sleep.Sample(start: sample.startDate, end: sample.endDate, asleep: true) // any sleep stage
            }
        }
        // iOS doesn't say whether reading was allowed; no samples means not allowed, or no data.
        guard !samples.isEmpty else {
            store.sleepStatus = await diagnosis(type, recent: found.count)
            return
        }
        let nights = Sleep.nights(samples)
        guard !nights.isEmpty else {
            store.sleepStatus = "Health had \(samples.count) sleep records, but none made a night of an hour or more."
            return
        }
        await store.updateSleep(nights)
    }

    /// Why nothing came back. iOS returns no data, rather than an error, when
    /// reading isn't allowed, so this lists every app that wrote sleep Daybook
    /// can see, with how many records and the newest: a source missing here but
    /// shown in Health is one Daybook isn't being given.
    private static func diagnosis(_ type: HKCategoryType, recent: Int) async -> String {
        let id = Bundle.main.bundleIdentifier ?? "?"
        let sources = (try? await HKSourceQueryDescriptor(predicate: .categorySample(type: type)).result(for: health)) ?? []
        guard !sources.isEmpty else {
            return "Health gave this copy of Daybook no sleep at all (\(id)). iOS does that when reading isn\u{2019}t allowed. In Settings \u{25B8} Health \u{25B8} Data Access & Devices \u{25B8} Daybook, turn Sleep off and on."
        }
        var lines: [String] = []
        for source in sources {
            let mine = HKQuery.predicateForObjects(from: [source])
            let newest = HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: mine)],
                                                 sortDescriptors: [SortDescriptor(\.endDate, order: .reverse)], limit: 1)
            let all = HKSampleQueryDescriptor(predicates: [.categorySample(type: type, predicate: mine)], sortDescriptors: [])
            let date = (try? await newest.result(for: health).first)?.endDate.formatted(date: .abbreviated, time: .omitted) ?? "?"
            let count = (try? await all.result(for: health).count) ?? 0
            lines.append("\(source.name) (\(source.bundleIdentifier)): \(count) records, newest \(date)")
        }
        let awake = recent > 0 ? " (only \(recent) awake records)" : ""
        return "No sleep in the last 60 days\(awake). Sources Daybook can see:\n" + lines.joined(separator: "\n")
    }
}
