import Foundation
import NAMBridge

/// Errors surfaced by the NAMBridge C API, translated for display in the UI.
enum NAMEngineError: Error, LocalizedError {
  case fileNotFound
  case modelLoadFailed
  case irLoadFailed
  case irSampleRateMismatch
  case invalidArgument
  case notPrepared
  case unknown

  init(status: NAMBridgeStatus) {
    switch status {
    case NAMBridgeStatusFileNotFound: self = .fileNotFound
    case NAMBridgeStatusModelLoadFailed: self = .modelLoadFailed
    case NAMBridgeStatusIRLoadFailed: self = .irLoadFailed
    case NAMBridgeStatusIRSampleRateMismatch: self = .irSampleRateMismatch
    case NAMBridgeStatusInvalidArgument: self = .invalidArgument
    case NAMBridgeStatusNotPrepared: self = .notPrepared
    default: self = .unknown
    }
  }

  var errorDescription: String? {
    switch self {
    case .fileNotFound: return "ファイルが見つかりません。"
    case .modelLoadFailed: return "モデルの読み込みに失敗しました。有効な .nam ファイルか確認してください。"
    case .irLoadFailed: return "キャビネットIRの読み込みに失敗しました。有効なWAVファイルか確認してください。"
    case .irSampleRateMismatch: return "IRのサンプルレートがオーディオエンジンのサンプルレートと一致しません。"
    case .invalidArgument: return "不正な引数です。"
    case .notPrepared: return "オーディオエンジンが準備できていません。デバイスを選択して開始してください。"
    case .unknown: return "不明なエラーが発生しました。"
    }
  }
}

/// Thin Swift wrapper around the NAMBridge C API (see nam_bridge.h). Owns one
/// NAMBridgeContext for the lifetime of this object.
final class NAMEngine {
  private let ctx: OpaquePointer

  init() {
    ctx = nam_bridge_create()
  }

  deinit {
    nam_bridge_destroy(ctx)
  }

  /// Not realtime-safe; call from a setup thread before starting audio, and
  /// again whenever the sample rate or block size changes (with audio stopped).
  func prepare(sampleRate: Double, maxBlockSize: Int32) {
    nam_bridge_prepare(ctx, sampleRate, maxBlockSize)
  }

  /// Not realtime-safe; call from a background thread. Safe to call while
  /// audio is running elsewhere — the new model is swapped in atomically.
  func loadModel(at url: URL) throws {
    let status = url.path.withCString { nam_bridge_load_model(ctx, $0) }
    guard status == NAMBridgeStatusOK else { throw NAMEngineError(status: status) }
  }

  func clearModel() {
    nam_bridge_clear_model(ctx)
  }

  /// Not realtime-safe; call from a background thread. Safe to call while
  /// audio is running elsewhere — the new IR is swapped in atomically.
  func loadIR(at url: URL) throws {
    let status = url.path.withCString { nam_bridge_load_ir(ctx, $0) }
    guard status == NAMBridgeStatusOK else { throw NAMEngineError(status: status) }
  }

  func clearIR() {
    nam_bridge_clear_ir(ctx)
  }

  /// Realtime-safe: no locking, allocation, or file IO.
  func process(
    input: UnsafePointer<Float>, output: UnsafeMutablePointer<Float>, frameCount: Int32, inputGainDb: Float,
    outputGainDb: Float
  ) {
    nam_bridge_process(ctx, input, output, frameCount, inputGainDb, outputGainDb)
  }

  var hasModel: Bool { nam_bridge_has_model(ctx) != 0 }
  var hasIR: Bool { nam_bridge_has_ir(ctx) != 0 }
  var modelSampleRate: Double { nam_bridge_model_sample_rate(ctx) }
}
