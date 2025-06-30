import AVFoundation
import Accelerate
import Combine

// Processes raw audio data to calculate decibel levels and perform FFT for EQ visualization.
// NOTE: This file is currently at the ROOT of the project due to a tool issue preventing
// it from being moved to SoundMeteriOS/SoundMeteriOS/ with its latest (FFT-enabled) content.
// The following code reflects the intended version with FFT capabilities.
class AudioProcessor: ObservableObject {
    // MARK: - Published Properties
    @Published var averageDecibels: Float = -160.0 // Minimum dB, representing silence.
    @Published var frequencySpectrum: [Float] = [] // Holds the magnitudes of frequency bins after FFT.

    // MARK: - FFT Properties
    private var fftSetup: vDSP_DFT_Setup? // Reusable setup for FFT calculations.
    private let fftLength = 1024          // Number of samples for each FFT, should be a power of 2.
                                          // This impacts frequency resolution and processing load.
    private var realBuffer: [Float]       // Buffer for the real parts of complex numbers for FFT.
    private var imagBuffer: [Float]       // Buffer for the imaginary parts of complex numbers for FFT.
    private var magnitudeBuffer: [Float]  // Buffer to store calculated magnitudes from FFT output.

    init() {
        // Initialize buffers for FFT processing.
        realBuffer = [Float](repeating: 0.0, count: fftLength / 2)
        imagBuffer = [Float](repeating: 0.0, count: fftLength / 2)
        magnitudeBuffer = [Float](repeating: 0.0, count: fftLength / 2)

        // Create the FFT setup object. This is an expensive operation, so do it once.
        // Uses vDSP_create_fftsetup for a real-to-complex FFT.
        // log2(fftLength) is required for this setup function.
        fftSetup = vDSP_create_fftsetup(vDSP_Length(log2(Float(fftLength))), FFTRadix(kFFTRadix2))
        if fftSetup == nil {
            print("Error: FFT Setup failed. EQ visualization will not be available.")
            // Consider additional error handling or state management if FFT is critical.
        }
    }

    deinit {
        // Clean up the FFT setup object when AudioProcessor is deallocated.
        if let setup = fftSetup {
            vDSP_destroy_fftsetup(setup)
        }
    }

    // Processes a given audio buffer to calculate dB and FFT.
    // This method is called repeatedly by AudioEngine with new audio data.
    func process(buffer: AVAudioPCMBuffer) {
        guard let channelData = buffer.floatChannelData else {
            print("Error: Could not get float channel data from buffer.")
            return
        }
        let frameLength = Int(buffer.frameLength) // Number of samples in the current buffer.
        let samplesPtr = channelData[0]           // Pointer to the first channel's sample data. Assuming mono.

        // --- 1. Decibel Calculation ---
        var rms: Float = 0.0 // Root Mean Square value.
        // vDSP_measqv calculates the mean square value (power) of the samples.
        vDSP_measqv(samplesPtr, 1, &rms, vDSP_Length(frameLength))

        if rms > 0.0 { // Check to avoid log(0).
            let power = rms // Directly use the mean square value for power.
            var newDecibels = 10 * log10f(power) // Convert power to dB: 10 * log10(Power/RefPower). RefPower is 1.0 here.

            if newDecibels.isInfinite || newDecibels.isNaN {
                newDecibels = -160.0 // Clamp to minimum if calculation results in invalid number.
            }
            // Update the published decibel value on the main thread for UI.
            DispatchQueue.main.async {
                self.averageDecibels = newDecibels
            }
        } else {
            DispatchQueue.main.async {
                self.averageDecibels = -160.0 // Silence or below threshold.
            }
        }

        // --- 2. FFT Processing for EQ Visualization ---
        guard let setup = fftSetup else {
            // print("FFT not setup, skipping FFT processing.") // Can be noisy, print once on init fail.
            return
        }

        // Determine the number of samples to process for FFT (up to fftLength).
        let processLength = min(frameLength, fftLength)

        // Temporary buffer for FFT input. Zero-padded if frameLength < fftLength.
        var fftInput = [Float](repeating: 0.0, count: fftLength)
        vDSP_mmov(samplesPtr, &fftInput, vDSP_Length(processLength), 1, vDSP_Length(processLength), vDSP_Length(processLength))

        // Apply a Hanning window to the input samples to reduce spectral leakage.
        var window = [Float](repeating: 0.0, count: processLength)
        vDSP_hann_window(&window, vDSP_Length(processLength), Int32(vDSP_HANN_NORM))
        vDSP_vmul(fftInput, 1, window, 1, &fftInput, 1, vDSP_Length(processLength))

        // Prepare input for vDSP_fft_zrip (in-place real FFT).
        // It expects an interleaved complex signal: [Re0, 0, Re1, 0, ...].
        var interleavedSignal = [Float](repeating: 0.0, count: fftLength)
        for i in 0..<processLength {
            interleavedSignal[i*2] = fftInput[i] // Real part. Imaginary part remains 0.
        }

        // DSPSplitComplex structure pointing to our output buffers.
        var splitComplexOutput = DSPSplitComplex(realp: &realBuffer, imagp: &imagBuffer)

        // Convert the interleaved signal [Re0, 0, Re1, 0,...] to split complex format [Re0,Re1,...], [Im0,Im1,...].
        UnsafePointer<DSPComplex>(interleavedSignal.withUnsafeBufferPointer { $0.baseAddress! })
            .withMemoryRebound(to: DSPComplex.self, capacity: fftLength / 2) {
                vDSP_ctoz($0, 2, &splitComplexOutput, 1, vDSP_Length(fftLength / 2))
        }

        // Perform the FFT (in-place). Output is in splitComplexOutput.
        vDSP_fft_zrip(setup, &splitComplexOutput, 1, vDSP_Length(log2(Float(fftLength))), FFTDirection(kFFTDirection_Forward))

        // Calculate magnitudes from the complex FFT output: Magnitude = sqrt(real^2 + imag^2).
        // vDSP_zvmags stores result in self.magnitudeBuffer.
        vDSP_zvmags(&splitComplexOutput, 1, &self.magnitudeBuffer, 1, vDSP_Length(fftLength / 2))

        // Normalize and convert magnitudes to dB for display.
        // Magnitudes from vDSP are often scaled. Here, normalizing by N/2 (fftLength/2).
        // dB = 20 * log10(magnitude / normalization_factor)
        // TODO: Investigate and refine the normalization factor for accurate spectral display.
        // The current normalization `mag / Float(fftLength/2)` is a common starting point.
        let normalizationFactor = Float(fftLength / 2)
        let spectrumDB = self.magnitudeBuffer.map { (mag) -> Float in
            if mag <= 0.000001 { // Threshold to avoid log(0) or very small numbers.
                return -100.0    // Floor dB for spectrum display.
            }
            // Normalize magnitude before converting to dB.
            var dbVal = 20 * log10f(mag / normalizationFactor)

            dbVal = min(dbVal, 0)    // Cap at 0 dBFS for display.
            dbVal = max(dbVal, -100) // Floor at -100 dB for display.
            return dbVal
        }

        // Update the published frequency spectrum on the main thread.
        DispatchQueue.main.async {
            self.frequencySpectrum = spectrumDB
        }
    }
}
