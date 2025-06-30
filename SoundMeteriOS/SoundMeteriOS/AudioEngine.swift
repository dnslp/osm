import AVFoundation
import Combine

// Manages the audio capture session using AVAudioEngine.
// It requests microphone permissions, starts/stops the audio engine,
// and provides raw audio buffers to an AudioProcessor.
// It also subscribes to decibel updates from the AudioProcessor to publish them.
class AudioEngine: ObservableObject {
    private var audioEngine: AVAudioEngine?
    private var inputNode: AVAudioInputNode?
    private var audioProcessor: AudioProcessor?

    @Published var averageDecibels: Float = -160.0 // Represents silence

    private var cancellables = Set<AnyCancellable>()

    init(audioProcessor: AudioProcessor) {
        self.audioProcessor = audioProcessor
        setupAudioSession()
        setupEngine()

        // Subscribe to processor's decibel updates
        self.audioProcessor?.$averageDecibels
            .receive(on: DispatchQueue.main)
            .sink { [weak self] newDecibelValue in
                self?.averageDecibels = newDecibelValue
            }
            .store(in: &cancellables)
    }

    private func setupAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            try audioSession.setCategory(.playAndRecord, mode: .measurement, options: [.defaultToSpeaker, .allowBluetoothA2DP])
            try audioSession.setActive(true)
        } catch {
            print("Failed to set up audio session: \(error.localizedDescription)")
            // Handle error appropriately in a real app (e.g., alert user)
        }
    }

    private func setupEngine() {
        audioEngine = AVAudioEngine()
        guard let audioEngine = audioEngine else {
            print("AudioEngine could not be initialized.")
            return
        }

        inputNode = audioEngine.inputNode
        guard let inputNode = inputNode else {
            print("Input node could not be obtained.")
            return
        }

        let inputFormat = inputNode.outputFormat(forBus: 0)

        inputNode.installTap(onBus: 0, bufferSize: 1024, format: inputFormat) { [weak self] (buffer, when) in
            self?.audioProcessor?.process(buffer: buffer)
        }

        audioEngine.prepare()
    }

    func start() {
        // Request microphone permission first
        AVAudioSession.sharedInstance().requestRecordPermission { [weak self] granted in
            guard let self = self else { return }
            if granted {
                do {
                    try self.audioEngine?.start()
                    print("AudioEngine started.")
                } catch {
                    print("Could not start audioEngine: \(error.localizedDescription)")
                    // Handle error (e.g., inform the user)
                }
            } else {
                print("Microphone permission denied.")
                // Handle permission denial (e.g., guide user to settings)
            }
        }
    }

    func stop() {
        audioEngine?.stop()
        // inputNode?.removeTap(onBus: 0) // removeTap can be problematic if engine is not running or preparing
        print("AudioEngine stopped.")
    }

    deinit {
        stop()
        // Release the audio session if no longer needed by other parts of the app
        // Note: This might affect other audio playing in the app. Manage carefully.
        // try? AVAudioSession.sharedInstance().setActive(false)
    }
}
