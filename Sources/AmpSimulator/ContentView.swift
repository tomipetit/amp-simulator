import AVFoundation
import CoreAudio
import Foundation
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
  @StateObject private var controller = AudioEngineController()

  @State private var devices: [AudioDeviceInfo] = []
  @State private var selectedDeviceID: AudioDeviceID?
  @State private var isModelImporterPresented = false
  @State private var isIRImporterPresented = false
  @State private var loadedModelName: String?
  @State private var loadedIRName: String?

  private static let namContentType = UTType(filenameExtension: "nam") ?? .data

  var body: some View {
    VStack(alignment: .leading, spacing: 16) {
      Text("Amp Simulator")
        .font(.title)
        .bold()
      Text("NAM (Neural Amp Modeler) キャプチャ + キャビネットIR — エフェクターなし")
        .font(.subheadline)
        .foregroundStyle(.secondary)

      GroupBox("オーディオデバイス") {
        VStack(alignment: .leading, spacing: 8) {
          Picker("入出力デバイス", selection: $selectedDeviceID) {
            Text("選択してください").tag(AudioDeviceID?.none)
            ForEach(devices) { device in
              Text(device.name).tag(AudioDeviceID?.some(device.id))
            }
          }
          .onAppear { devices = controller.availableDevices() }

          HStack {
            Button(controller.isRunning ? "停止" : "開始") {
              if controller.isRunning {
                controller.stop()
              } else if let selectedDeviceID {
                controller.start(deviceID: selectedDeviceID)
              }
            }
            .disabled(!controller.isRunning && selectedDeviceID == nil)

            if controller.isRunning {
              Label("実行中 (\(Int(controller.currentSampleRate)) Hz)", systemImage: "waveform")
                .foregroundStyle(.green)
            }

            Spacer()

            Button("デバイス再読込") { devices = controller.availableDevices() }
          }
        }
        .padding(.vertical, 4)
      }

      GroupBox("アンプモデル (.nam)") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Button("モデルを読み込む…") { isModelImporterPresented = true }
            if controller.hasModel {
              Text(loadedModelName ?? "読み込み済み")
                .foregroundStyle(.secondary)
              if controller.modelSampleRate > 0 {
                Text("(\(Int(controller.modelSampleRate)) Hz)")
                  .foregroundStyle(.secondary)
              }
              Button("解除", role: .destructive) {
                controller.clearModel()
                loadedModelName = nil
              }
            } else {
              Text("未読み込み").foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 4)
      }
      .fileImporter(isPresented: $isModelImporterPresented, allowedContentTypes: [Self.namContentType]) { result in
        switch result {
        case .success(let url):
          loadWithSecurityScope(url) { controller.loadModel(url: $0) }
          loadedModelName = url.lastPathComponent
        case .failure(let error):
          controller.lastErrorMessage = error.localizedDescription
        }
      }

      GroupBox("キャビネットIR (.wav)") {
        VStack(alignment: .leading, spacing: 8) {
          HStack {
            Button("IRを読み込む…") { isIRImporterPresented = true }
            if controller.hasIR {
              Text(loadedIRName ?? "読み込み済み")
                .foregroundStyle(.secondary)
              Button("解除", role: .destructive) {
                controller.clearIR()
                loadedIRName = nil
              }
            } else {
              Text("未読み込み (IRなしでも動作します)").foregroundStyle(.secondary)
            }
          }
        }
        .padding(.vertical, 4)
      }
      .fileImporter(isPresented: $isIRImporterPresented, allowedContentTypes: [.wav]) { result in
        switch result {
        case .success(let url):
          loadWithSecurityScope(url) { controller.loadIR(url: $0) }
          loadedIRName = url.lastPathComponent
        case .failure(let error):
          controller.lastErrorMessage = error.localizedDescription
        }
      }

      GroupBox("ゲイン / レベル") {
        VStack(alignment: .leading, spacing: 12) {
          GainSlider(label: "入力ゲイン", valueDb: controller.inputGainDb) { controller.setInputGainDb($0) }
          GainSlider(label: "出力ゲイン", valueDb: controller.outputGainDb) { controller.setOutputGainDb($0) }
          LevelMeterView(peak: controller.outputPeakLevel)

          Divider()

          Toggle(
            "出力レベル自動正規化",
            isOn: Binding(get: { controller.autoNormalizeEnabled }, set: { controller.setAutoNormalizeEnabled($0) }))

          if controller.autoNormalizeEnabled {
            GainSlider(
              label: "ターゲットラウドネス", valueDb: controller.targetLoudnessDb, range: -36...0
            ) { controller.setTargetLoudnessDb($0) }

            if controller.hasModel {
              if controller.modelHasLoudness {
                Text("このモデルのラウドネス: \(String(format: "%.1f", controller.modelLoudnessDb)) dB")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              } else {
                Text("このモデルにはラウドネス情報がないため、自動正規化は適用されません")
                  .font(.caption)
                  .foregroundStyle(.secondary)
              }
            }
          }
        }
        .padding(.vertical, 4)
      }

      GroupBox("EQ (Bass / Mid / Treble)") {
        VStack(alignment: .leading, spacing: 12) {
          GainSlider(label: "Bass (120Hz shelf)", valueDb: controller.bassGainDb, range: -15...15) {
            controller.setBassGainDb($0)
          }
          GainSlider(label: "Mid (900Hz peak)", valueDb: controller.midGainDb, range: -15...15) {
            controller.setMidGainDb($0)
          }
          GainSlider(label: "Treble (3.5kHz shelf)", valueDb: controller.trebleGainDb, range: -15...15) {
            controller.setTrebleGainDb($0)
          }
        }
        .padding(.vertical, 4)
      }

      if let message = controller.lastErrorMessage {
        Text(message)
          .foregroundStyle(.red)
          .font(.callout)
      }

      Spacer()
    }
    .padding(20)
    .frame(minWidth: 480, minHeight: 520)
  }

  /// Files picked via .fileImporter on macOS may require security-scoped
  /// resource access outside the sandbox container; this is a no-op harmless
  /// bracket if the app isn't sandboxed.
  private func loadWithSecurityScope(_ url: URL, _ action: (URL) -> Void) {
    let didStartAccessing = url.startAccessingSecurityScopedResource()
    defer { if didStartAccessing { url.stopAccessingSecurityScopedResource() } }
    action(url)
  }
}

private struct GainSlider: View {
  let label: String
  let valueDb: Float
  var range: ClosedRange<Float> = -24...24
  let onChange: (Float) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("\(label): \(String(format: "%.1f", valueDb)) dB")
        .font(.caption)
      Slider(
        value: Binding(get: { valueDb }, set: onChange),
        in: range,
        step: 0.5)
    }
  }
}

private struct LevelMeterView: View {
  let peak: Float

  private var normalized: Double {
    // Map ~-48dB...0dB peak to a 0...1 bar width.
    guard peak > 0 else { return 0 }
    let db = 20 * log10(Double(peak))
    return max(0, min(1, (db + 48) / 48))
  }

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      Text("出力レベル").font(.caption)
      GeometryReader { proxy in
        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.2))
          RoundedRectangle(cornerRadius: 3)
            .fill(normalized > 0.9 ? Color.red : Color.green)
            .frame(width: proxy.size.width * normalized)
        }
      }
      .frame(height: 10)
    }
  }
}

#Preview {
  ContentView()
}
