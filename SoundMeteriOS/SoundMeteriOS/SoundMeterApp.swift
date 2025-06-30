import SwiftUI

// Main entry point for the SoundMeter iOS application.
// Initializes and manages the lifecycle of core audio components and data handling services.
// Injects these services into the SwiftUI environment for use by views.
@main
struct SoundMeterApp: App {
    // Core services for audio processing and data collection.
    // Note: AudioProcessor is currently initialized from the root due to a tool issue.
    // Ideally, all Swift source files for this app target would be in the same directory.
    private var audioProcessor = AudioProcessor()
    private var audioEngine: AudioEngine
    private var dataCollector: DataCollector

    init() {
        // Initialize AudioEngine with the AudioProcessor.
        self.audioEngine = AudioEngine(audioProcessor: audioProcessor)
        // Initialize DataCollector with the AudioEngine.
        self.dataCollector = DataCollector(audioEngine: audioEngine)

        // TODO: Resolve AudioProcessor.swift file location. It should be in this target's source folder.
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                // Provide the core services as environment objects to the view hierarchy.
                .environmentObject(audioEngine)
                .environmentObject(audioProcessor)
                .environmentObject(dataCollector)
        }
    }
}

// The main view of the application.
// Displays the sound level (dB), EQ visualization, and controls for audio and data collection.
struct ContentView: View {
    @EnvironmentObject var audioEngine: AudioEngine
    @EnvironmentObject var audioProcessor: AudioProcessor
    @EnvironmentObject var dataCollector: DataCollector // Observe DataCollector

    @State private var showingDataSheet = false // To present a sheet for data management

    var body: some View {
        VStack {
            Text("Sound Level Meter")
                .font(.title)
                .padding(.top)

            // Display the decibel reading
            Text(String(format: "%.2f dB", audioEngine.averageDecibels))
                .font(.system(size: 48, weight: .bold, design: .monospaced))
                .foregroundColor(colorForDecibels(audioEngine.averageDecibels))
                .padding(.bottom)

            // EQ Visualization
            EQView(frequencySpectrum: audioProcessor.frequencySpectrum)
                .frame(height: 200)
                .padding(.horizontal)

            Spacer()

            HStack(spacing: 10) {
                Button {
                    audioEngine.start()
                } label: {
                    Label("Start Audio", systemImage: "mic.fill")
                }
                .padding()
                .buttonStyle(.borderedProminent)

                Button {
                    audioEngine.stop()
                } label: {
                    Label("Stop Audio", systemImage: "mic.slash.fill")
                }
                .padding()
                .buttonStyle(.bordered)
            }

            HStack(spacing: 10) {
                Button {
                    if dataCollector.isCollecting {
                        dataCollector.stopCollecting()
                    } else {
                        dataCollector.startCollecting()
                    }
                } label: {
                    Label(dataCollector.isCollecting ? "Stop Collecting" : "Start Collecting",
                          systemImage: dataCollector.isCollecting ? "pause.circle.fill" : "record.circle.fill")
                }
                .padding()
                .tint(dataCollector.isCollecting ? .orange : .blue)
                .buttonStyle(.borderedProminent)

                Button {
                    showingDataSheet = true
                } label: {
                    Label("View Data (\(dataCollector.collectedData.count))", systemImage: "list.bullet")
                }
                .padding()
                .buttonStyle(.bordered)
            }
            .padding(.bottom)
        }
        .onAppear {
            // audioEngine.start() // Optional: auto-start audio
            dataCollector.loadCollectedData() // Load any previously saved data
        }
        .onDisappear {
            if dataCollector.isCollecting {
                dataCollector.stopCollecting() // Ensure collection stops
            }
            dataCollector.saveCollectedData() // Save data when view disappears
            audioEngine.stop()
        }
        .sheet(isPresented: $showingDataSheet) {
            DataListView()
                .environmentObject(dataCollector) // Pass DataCollector to the sheet view
        }
    }

    // Helper function to determine the color for the dB text based on its value.
    func colorForDecibels(_ dB: Float) -> Color {
        // Thresholds can be adjusted for different visual feedback.
        switch dB {
        case -160 ..< -60:
            return .green
        case -60 ..< -30:
            return .yellow
        case -30 ..< -10:
            return .orange
        case -10 ...Float.infinity:
            return .red
        default:
            return .gray // for very low or invalid values
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        // Create mock/stub instances for previewing the ContentView.
        // This allows the UI to be rendered in Xcode Previews without live audio.
        let mockAudioProcessor = AudioProcessor() // Still uses root version for preview
        let mockAudioEngine = AudioEngine(audioProcessor: mockAudioProcessor)
        let mockDataCollector = DataCollector(audioEngine: mockAudioEngine)
        // Example: Set a mock dB value for preview
        // mockAudioEngine.averageDecibels = -42.5
        // Example: Set mock spectrum data for preview
        // mockAudioProcessor.frequencySpectrum = Array(repeating: 0.0, count: 16).enumerated().map { Float($0.offset * -5) - 10 }

        ContentView()
            .environmentObject(mockAudioEngine)
            .environmentObject(mockAudioProcessor)
            .environmentObject(mockDataCollector) // Add data collector for preview consistency
    }
}

// A view to display the frequency spectrum (EQ) as a bar chart.
struct EQView: View {
    var frequencySpectrum: [Float] // The spectrum data (magnitudes in dB).
    let barCount: Int = 32         // Number of bars to display for the EQ.
                                   // TODO: Make barCount configurable via settings.

    var body: some View {
        HStack(alignment: .bottom, spacing: 2) {
            // Group spectrum data if necessary, or take a slice
            let displayData = prepareDisplayData(spectrum: frequencySpectrum, count: barCount)

            ForEach(0..<displayData.count, id: \.self) { index in
                let magnitude = displayData[index] // Should be a value from approx -100 to 0 dB
                let normalizedMagnitude = CGFloat(1.0 - (min(max(magnitude, -100), 0) / -100.0)) // Normalize 0 to 1 (0dB = top, -100dB = bottom)

                Rectangle()
                    .fill(colorForMagnitude(magnitude))
                    .frame(height: max(0, normalizedMagnitude * 200)) // Max height 200
                    .animation(.easeOut(duration: 0.05), value: normalizedMagnitude)
            }
        }
        .background(Color.gray.opacity(0.2))
        .cornerRadius(5)
        // TODO: Add frequency labels below the EQ chart.
    }

    // Prepares the spectrum data for display by binning/averaging into `count` bars.
    // If the raw spectrum has more points than `count`, averages are used.
    // If fewer, it's padded with low values.
    private func prepareDisplayData(spectrum: [Float], count: Int) -> [Float] {
        guard !spectrum.isEmpty else { return Array(repeating: -100.0, count: count) } // Return silence for empty spectrum

        let spectrumSize = spectrum.count
        if spectrumSize <= count { // If we have fewer or equal data points than bars, use them directly (or pad)
            var paddedSpectrum = spectrum
            while paddedSpectrum.count < count {
                paddedSpectrum.append(-100.0) // Pad with silence
            }
            return paddedSpectrum.prefix(count).map { $0 } // Ensure it's exactly 'count' elements
        }

        // Average into 'count' bins
        var binnedSpectrum = [Float](repeating: 0.0, count: count)
        let binSize = Float(spectrumSize) / Float(count)

        for i in 0..<count {
            let startIndex = Int(floor(Float(i) * binSize))
            let endIndex = Int(floor(Float(i + 1) * binSize))

            guard startIndex < endIndex, endIndex <= spectrumSize else {
                 binnedSpectrum[i] = -100.0 // Should not happen if logic is correct
                 continue
            }

            let slice = spectrum[startIndex..<endIndex]
            if slice.isEmpty {
                binnedSpectrum[i] = -100.0
            } else {
                // Average the magnitudes in the bin. Max might also be an option.
                let sum = slice.reduce(0, +)
                binnedSpectrum[i] = sum / Float(slice.count)
            }
        }
        return binnedSpectrum
    }

    private func colorForMagnitude(_ magnitude: Float) -> Color {
        // Example: Simple green to red gradient based on dB
        if magnitude > -20 { return .red }
        if magnitude > -40 { return .orange }
        if magnitude > -60 { return .yellow }
        return .green
    }
}

// MARK: - Data List View
// A view presented as a sheet to display, manage, and save collected sound data points.
struct DataListView: View {
    @EnvironmentObject var dataCollector: DataCollector // Access to the collected data.
    @Environment(\.dismiss) var dismiss // Used to close the sheet.

    var body: some View {
        NavigationView {
            VStack {
                List {
                    ForEach(dataCollector.collectedData) { dataPoint in
                        HStack {
                            Text(dataPoint.timestamp, style: .time)
                            Spacer()
                            Text(String(format: "%.2f dB", dataPoint.decibels))
                        }
                    }
                    .onDelete(perform: deleteItems)
                }
                .listStyle(.plain)

                HStack {
                    Button("Clear All Data") {
                        dataCollector.clearData()
                    }
                    .padding()
                    .tint(.red)

                    Spacer()

                    Button("Save Data") {
                        dataCollector.saveCollectedData()
                    }
                    .padding()
                }
            }
            .navigationTitle("Collected Sound Data")
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    EditButton() // For list editing (delete)
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
    }

    private func deleteItems(offsets: IndexSet) {
        dataCollector.collectedData.remove(atOffsets: offsets)
        // Optionally, save after delete: dataCollector.saveCollectedData()
    }
}
