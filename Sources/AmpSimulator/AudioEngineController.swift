import AVFoundation
import AudioToolbox
import CoreAudio
import Foundation

enum AudioEngineControllerError: Error, LocalizedError {
  case invalidFormat
  case engineStartFailed(Error)

  var errorDescription: String? {
    switch self {
    case .invalidFormat:
      return "選択したデバイスのオーディオフォーマットを取得できませんでした。"
    case .engineStartFailed(let error):
      return "オーディオエンジンの起動に失敗しました: \(error.localizedDescription)"
    }
  }
}

/// Owns the AVAudioEngine graph and bridges it to NAMBridge:
///
///   input device --[tap]--> ring buffer --[AVAudioSourceNode render block]--> NAMEngine.process --> output device
///
/// A tap (rather than a direct node connection) is used on the input side so
/// that the input and output audio units — which are driven by independent
/// Core Audio render callbacks even when they belong to the same physical
/// interface — can be decoupled via the ring buffer.
// Not @MainActor: the AVAudioSourceNode render block below runs on a
// realtime Core Audio thread and must be able to read this object's state
// synchronously without hopping actors. UI-facing @Published properties are
// only ever mutated from the main thread in this file (button actions, and
// the Timer below, which runs on the run loop it was created on).
final class AudioEngineController: ObservableObject {
  @Published private(set) var isRunning = false
  @Published var lastErrorMessage: String?
  @Published var inputGainDb: Float = 0
  @Published var outputGainDb: Float = 0
  @Published private(set) var hasModel = false
  @Published private(set) var hasIR = false
  @Published private(set) var modelSampleRate: Double = -1
  @Published private(set) var outputPeakLevel: Float = 0
  @Published private(set) var currentSampleRate: Double = 0

  // Output-level auto-normalization (see nam_bridge_set_auto_normalize):
  // levels different models' inherent loudness to a common target using the
  // model's loudness metadata, when present.
  @Published var autoNormalizeEnabled: Bool = true
  @Published var targetLoudnessDb: Float = -18
  @Published private(set) var modelHasLoudness = false
  @Published private(set) var modelLoudnessDb: Double = 0

  // 3-band EQ (bass/mid/treble), applied after the cabinet IR stage.
  @Published var bassGainDb: Float = 0
  @Published var midGainDb: Float = 0
  @Published var trebleGainDb: Float = 0

  let namEngine = NAMEngine()

  private let engine = AVAudioEngine()
  private let eqNode = AVAudioUnitEQ(numberOfBands: 3)
  private var eqAttached = false
  private let ringBuffer = FloatRingBuffer(capacity: 8192)
  private var sourceNode: AVAudioSourceNode?
  private var meterTimer: Timer?

  // Fixed-size scratch buffers reused by the render block; sized generously
  // above any realistic device IO buffer size so processing never needs to
  // allocate. If a render callback ever asks for more frames than this, the
  // render block simply loops in chunks of this size.
  private let scratchCapacity = 4096
  private let inputScratch: UnsafeMutablePointer<Float>
  private let outputScratch: UnsafeMutablePointer<Float>
  // Dedicated downmix scratch for the input tap closure, kept separate from
  // inputScratch/outputScratch above since the tap (input device thread) and
  // the source node render block (output device thread) can run concurrently.
  private let downmixScratch: UnsafeMutablePointer<Float>

  private let blockSize = 512

  // Read on the audio thread from the render block; written from the main
  // thread via the @Published properties above. Plain Float reads/writes are
  // not torn on Apple platforms in practice, so this MVP skips a formal
  // atomic wrapper. A future revision could use a proper lock-free box.
  private var inputGainSnapshot: Float = 0
  private var outputGainSnapshot: Float = 0

  init() {
    inputScratch = .allocate(capacity: scratchCapacity)
    outputScratch = .allocate(capacity: scratchCapacity)
    downmixScratch = .allocate(capacity: scratchCapacity)
    inputScratch.initialize(repeating: 0, count: scratchCapacity)
    outputScratch.initialize(repeating: 0, count: scratchCapacity)
    downmixScratch.initialize(repeating: 0, count: scratchCapacity)

    // Bass (low shelf) / Mid (parametric peak) / Treble (high shelf), a
    // simple 3-band tone-shaping EQ. Frequencies chosen for guitar amp tone
    // stacks; gains default to flat (0 dB) and are set via the UI.
    let bass = eqNode.bands[0]
    bass.filterType = .lowShelf
    bass.frequency = 120
    bass.gain = 0
    bass.bypass = false

    let mid = eqNode.bands[1]
    mid.filterType = .parametric
    mid.frequency = 900
    mid.bandwidth = 1.5
    mid.gain = 0
    mid.bypass = false

    let treble = eqNode.bands[2]
    treble.filterType = .highShelf
    treble.frequency = 3500
    treble.gain = 0
    treble.bypass = false
  }

  deinit {
    inputScratch.deallocate()
    outputScratch.deallocate()
    downmixScratch.deallocate()
  }

  func availableDevices() -> [AudioDeviceInfo] {
    AudioDeviceManager.listDevices().filter { $0.inputChannelCount > 0 && $0.outputChannelCount > 0 }
  }

  func start(deviceID: AudioDeviceID) {
    stop()

    let input = engine.inputNode
    let output = engine.outputNode

    do {
      if let inputUnit = input.audioUnit {
        try AudioDeviceManager.setDevice(deviceID, on: inputUnit)
      }
      if let outputUnit = output.audioUnit {
        try AudioDeviceManager.setDevice(deviceID, on: outputUnit)
      }
    } catch {
      lastErrorMessage = error.localizedDescription
      return
    }

    let inputFormat = input.inputFormat(forBus: 0)
    guard inputFormat.sampleRate > 0, let monoFormat = AVAudioFormat(standardFormatWithSampleRate: inputFormat.sampleRate, channels: 1)
    else {
      lastErrorMessage = AudioEngineControllerError.invalidFormat.localizedDescription
      return
    }

    currentSampleRate = inputFormat.sampleRate
    namEngine.prepare(sampleRate: currentSampleRate, maxBlockSize: Int32(blockSize))
    hasModel = namEngine.hasModel
    hasIR = namEngine.hasIR

    let inputChannelCount = Int(inputFormat.channelCount)
    let ring = ringBuffer
    let downmix = downmixScratch
    let downmixCap = scratchCapacity

    input.installTap(onBus: 0, bufferSize: AVAudioFrameCount(blockSize), format: inputFormat) { buffer, _ in
      guard let channelData = buffer.floatChannelData else { return }
      let frameLength = Int(buffer.frameLength)
      guard frameLength > 0 else { return }

      if inputChannelCount == 1 {
        ring.write(channelData[0], count: frameLength)
      } else {
        // Downmix to mono for a guitar-style single input source, in chunks
        // of the preallocated scratch buffer so this stays allocation-free.
        var offset = 0
        while offset < frameLength {
          let chunk = min(downmixCap, frameLength - offset)
          for i in 0..<chunk {
            var sum: Float = 0
            for c in 0..<inputChannelCount { sum += channelData[c][offset + i] }
            downmix[i] = sum / Float(inputChannelCount)
          }
          ring.write(downmix, count: chunk)
          offset += chunk
        }
      }
    }

    let namEngineRef = namEngine
    let scratchCap = scratchCapacity
    let inScratch = inputScratch
    let outScratch = outputScratch
    var latestPeak: Float = 0

    let node = AVAudioSourceNode(format: monoFormat) { [weak self] _, _, frameCount, audioBufferList in
      guard let self else { return noErr }
      let totalFrames = Int(frameCount)
      let abl = UnsafeMutableAudioBufferListPointer(audioBufferList)
      guard let outPtr = abl[0].mData?.assumingMemoryBound(to: Float.self) else { return noErr }

      let inGain = self.inputGainSnapshot
      let outGain = self.outputGainSnapshot

      var offset = 0
      var peak: Float = 0
      while offset < totalFrames {
        let chunk = min(scratchCap, totalFrames - offset)
        ring.read(into: inScratch, count: chunk)
        namEngineRef.process(input: inScratch, output: outScratch, frameCount: Int32(chunk), inputGainDb: inGain, outputGainDb: outGain)
        for i in 0..<chunk {
          let v = outScratch[i]
          outPtr[offset + i] = v
          peak = max(peak, abs(v))
        }
        offset += chunk
      }
      latestPeak = peak
      return noErr
    }

    sourceNode = node
    engine.attach(node)
    engine.attach(eqNode)
    eqAttached = true
    // NAM source --> 3-band EQ --> main mixer --> output device.
    engine.connect(node, to: eqNode, format: monoFormat)
    engine.connect(eqNode, to: engine.mainMixerNode, format: nil)
    engine.connect(engine.mainMixerNode, to: output, format: nil)

    engine.prepare()
    do {
      try engine.start()
    } catch {
      lastErrorMessage = AudioEngineControllerError.engineStartFailed(error).localizedDescription
      input.removeTap(onBus: 0)
      engine.disconnectNodeOutput(node)
      engine.detach(node)
      sourceNode = nil
      engine.disconnectNodeOutput(eqNode)
      engine.detach(eqNode)
      eqAttached = false
      return
    }

    isRunning = true
    lastErrorMessage = nil
    meterTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
      self?.outputPeakLevel = latestPeak
    }
  }

  func stop() {
    meterTimer?.invalidate()
    meterTimer = nil

    if engine.isRunning {
      engine.stop()
    }
    engine.inputNode.removeTap(onBus: 0)
    if let node = sourceNode {
      engine.disconnectNodeOutput(node)
      engine.detach(node)
    }
    sourceNode = nil
    if eqAttached {
      engine.disconnectNodeOutput(eqNode)
      engine.detach(eqNode)
      eqAttached = false
    }
    isRunning = false
    outputPeakLevel = 0
  }

  func setInputGainDb(_ value: Float) {
    inputGainDb = value
    inputGainSnapshot = value
  }

  func setOutputGainDb(_ value: Float) {
    outputGainDb = value
    outputGainSnapshot = value
  }

  func setAutoNormalizeEnabled(_ enabled: Bool) {
    autoNormalizeEnabled = enabled
    namEngine.setAutoNormalize(enabled: enabled)
  }

  func setTargetLoudnessDb(_ value: Float) {
    targetLoudnessDb = value
    namEngine.setTargetLoudnessDb(value)
  }

  func setBassGainDb(_ value: Float) {
    bassGainDb = value
    eqNode.bands[0].gain = value
  }

  func setMidGainDb(_ value: Float) {
    midGainDb = value
    eqNode.bands[1].gain = value
  }

  func setTrebleGainDb(_ value: Float) {
    trebleGainDb = value
    eqNode.bands[2].gain = value
  }

  func loadModel(url: URL) {
    do {
      try namEngine.loadModel(at: url)
      hasModel = true
      modelSampleRate = namEngine.modelSampleRate
      modelHasLoudness = namEngine.modelHasLoudness
      modelLoudnessDb = namEngine.modelLoudnessDb
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func clearModel() {
    namEngine.clearModel()
    hasModel = false
    modelSampleRate = -1
    modelHasLoudness = false
    modelLoudnessDb = 0
  }

  func loadIR(url: URL) {
    do {
      try namEngine.loadIR(at: url)
      hasIR = true
      lastErrorMessage = nil
    } catch {
      lastErrorMessage = error.localizedDescription
    }
  }

  func clearIR() {
    namEngine.clearIR()
    hasIR = false
  }
}
