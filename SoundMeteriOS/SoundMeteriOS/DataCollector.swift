import Foundation
import Combine

// Represents a single recorded sound measurement.
// Codable: Allows easy conversion to/from JSON for persistence.
// Identifiable: Useful for SwiftUI lists.
struct SoundDataPoint: Codable, Identifiable {
    let id = UUID()
    let timestamp: Date
    let decibels: Float
    // Optionally, include EQ data if needed for collection
    // let eqData: [Float]?

    // Conformance to Identifiable for SwiftUI lists, Codable for saving/loading
}

// Manages the collection, storage, and persistence of SoundDataPoints.
// Observes audio updates (currently just decibels from AudioEngine) and records them.
// Provides methods to start/stop collection, clear data, and save/load data to JSON.
class DataCollector: ObservableObject {
    @Published var collectedData: [SoundDataPoint] = [] // Array of collected sound data points.
    @Published var isCollecting: Bool = false           // Flag to control data collection.

    private var audioEngine: AudioEngine?       // Reference to AudioEngine for dB updates.
    // private var audioProcessor: AudioProcessor? // Future: For collecting EQ data.

    private var cancellables = Set<AnyCancellable>() // Stores Combine subscriptions.

    // Initializes the DataCollector with a reference to the AudioEngine.
    init(audioEngine: AudioEngine /*, audioProcessor: AudioProcessor? = nil */) {
        self.audioEngine = audioEngine
        // self.audioProcessor = audioProcessor // Future: Pass AudioProcessor if EQ data is also collected.
    }

    // Starts the data collection process.
    // Subscribes to decibel updates from the AudioEngine.
    func startCollecting() {
        guard !isCollecting else { return }
        isCollecting = true

        // Subscribe to decibel updates from AudioEngine
        audioEngine?.$averageDecibels
            .sink { [weak self] newDecibelValue in
                guard let self = self, self.isCollecting else { return }

                // Create a new data point
                let dataPoint = SoundDataPoint(timestamp: Date(), decibels: newDecibelValue)

                // Append to our collection
                // Ensure this happens on the main thread if UI is bound to collectedData directly
                // or if collectedData itself is frequently accessed from main thread.
                // For now, direct append is fine as long as processing in sink is light.
                self.collectedData.append(dataPoint)
                // print("Collected data point: \(dataPoint.decibels) dB at \(dataPoint.timestamp)")
            }
            .store(in: &cancellables) // Store this specific subscription

        // If collecting EQ data, subscribe to audioProcessor?.$frequencySpectrum similarly
    }

    // Stops the data collection process.
    // Cancels existing subscriptions to prevent further data recording.
    func stopCollecting() {
        guard isCollecting else { return }
        isCollecting = false

        // Cancel all current subscriptions to stop receiving updates.
        // Note: If this class had other, unrelated subscriptions, they would also be cancelled.
        // For more fine-grained control, manage cancellables individually.
        cancellables.forEach { $0.cancel() }
        cancellables.removeAll()
        print("Data collection stopped. Total points: \(collectedData.count)")
    }

    // Clears all collected data from the in-memory store.
    func clearData() {
        collectedData.removeAll()
        print("Collected data cleared from memory.")
        // Consider also deleting the persisted file here if desired, or provide a separate method.
    }

    // MARK: - Data Persistence
    // Handles saving and loading of sound data to/from a JSON file in the app's documents directory.

    // Returns the URL for the app's documents directory.
    private func getDocumentsDirectory() -> URL {
        // FileManager.default.urls(for: .documentDirectory, in: .userDomainMask) returns an array, take the first.
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    // Computed property for the full URL of the data file.
    private var dataFileURL: URL {
        getDocumentsDirectory().appendingPathComponent("soundMeterData.json") // Changed filename for clarity
    }

    // Saves the current `collectedData` array to a JSON file.
    func saveCollectedData() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601 // Or .secondsSince1970

        do {
            let data = try encoder.encode(collectedData)
            try data.write(to: dataFileURL, options: [.atomicWrite])
            print("Data saved to \(dataFileURL.path)")
        } catch {
            print("Error saving data: \(error.localizedDescription)")
            // Consider propagating this error or alerting the user.
        }
    }

    // Loads collected data from the JSON file into the `collectedData` array.
    func loadCollectedData() {
        guard FileManager.default.fileExists(atPath: dataFileURL.path) else {
            print("Data file \(dataFileURL.path) does not exist. Starting with empty collection.")
            return
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601 // Ensure this matches the encoding strategy.

        do {
            let data = try Data(contentsOf: dataFileURL)
            collectedData = try decoder.decode([SoundDataPoint].self, from: data)
            print("Data loaded successfully from \(dataFileURL.path). \(collectedData.count) points.")
        } catch {
            print("Error loading data: \(error.localizedDescription)")
            // collectedData = [] // Optionally reset to empty on error, or preserve existing in-memory data.
        }
    }
}
