# amp-simulator

NAM (Neural Amp Modeler) キャプチャとキャビネットIRを使った、macOS用のギターアンプシミュレーターです。
現時点では **アンプ本体のみ**（歪みペダルやディレイ/リバーブなどのエフェクターは未実装）。

構成:

```
オーディオインターフェース入力
  → 入力ゲイン
  → NAMモデル (.nam キャプチャ、ニューラル推論)
  → キャビネットIR畳み込み
  → 出力ゲイン (+ 出力レベル自動正規化)
  → 3バンドEQ (Bass / Mid / Treble)
  → オーディオインターフェース出力
```

## 必要なもの

- macOS 13 (Ventura) 以降 / Xcode 15 以降
- ギター用オーディオインターフェース
- `.nam` モデルファイル（例: [TONE3000](https://www.tone3000.com/)、[ToneHunt](https://tonehunt.org/) などから）
- （任意）キャビネットIRの `.wav` ファイル。"Amp + Cab" タイプのキャプチャを使う場合は不要です

## セットアップ

このリポジトリは [NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore)（MITライセンス）を
git submodule として取り込んでいます。**Eigen のみ**を再帰的に取得してください（`AudioDSPTools` は本プロジェクトでは
未使用のため、`--recursive` を素直に使うと不要な依存まで取得してしまいます）。

```bash
git clone <このリポジトリのURL>
cd amp-simulator
git submodule update --init Sources/NAMBridge/NeuralAmpModelerCore
git -C Sources/NAMBridge/NeuralAmpModelerCore submodule update --init Dependencies/eigen
```

### ビルド・実行（Xcode）

1. `Package.swift` を Xcode で開く（Finderからダブルクリック、または `xed .`）
2. スキーム "AmpSimulator" を選択して実行 (⌘R)
3. 初回のマイク（オーディオ入力）アクセス許可のダイアログを許可する

### コマンドラインでの実行

```bash
swift run
```

## 使い方

1. 上部のプルダウンでオーディオインターフェースを選択し、「開始」を押す
2. 「モデルを読み込む…」から `.nam` ファイルを選択
3. （任意）「IRを読み込む…」からキャビネットIRの `.wav` ファイルを選択
   - IRのサンプルレートはエンジンのサンプルレート（通常48kHz、インターフェースの設定に依存）と
     一致している必要があります。一致しない場合はエラーになります
4. 入力ゲイン / 出力ゲインで音量・歪み量を調整
5. 「出力レベル自動正規化」をオンにすると、モデルが持つラウドネスのメタデータに応じて自動で
   メイクアップゲインがかかり、モデルを差し替えても体感音量が揃うようになります
   （メタデータを持たない古い/自作モデルでは効果なし）
6. EQセクションの Bass / Mid / Treble で簡単なトーン調整が可能

## 技術的な詳細

- **推論エンジン**: [NeuralAmpModelerCore](https://github.com/sdatkinson/NeuralAmpModelerCore)（C++, MIT）を
  `Sources/NAMBridge/NeuralAmpModelerCore` に submodule として同梱。依存は Eigen（ヘッダオンリー、submodule）と
  nlohmann/json（ヘッダオンリー、NAM Core に同梱済み）のみ
- **C++ ⇄ Swift 連携**: `Sources/NAMBridge` が NAM Core を薄いCのAPI (`nam_bridge.h`) でラップし、
  Swift Package Manager の C++ ターゲットとしてビルド。Swiftからは `import NAMBridge` でCの関数を直接呼び出す
  （Objective-C++ブリッジは不要）
- **キャビネットIR畳み込み**: `CabConvolver`（`cab_convolver.h/.cpp`）による直接畳み込み（FFTなし）。
  典型的なキャビIRの長さ（数千タップ程度）であれば実用上十分な速度です。より長いIRでCPU負荷が問題になる場合は
  パーティション化FFT畳み込みへの置き換えが次のステップになります
- **WAVファイル読み込み**: `wav_loader.h/.cpp` に最小限のWAVパーサを自作（PCM16/24/32、IEEE float32、モノ/マルチch
  ダウンミックスに対応）。外部依存を増やさないための選択です
- **オーディオI/O**: `AVAudioEngine` を使用。入力ノードにタップを張り、リングバッファ経由で
  `AVAudioSourceNode` のレンダーブロックに橋渡しする構成（同一デバイスであっても入力側・出力側は別々の
  Core Audio レンダーコールバックで駆動されるため）
- **モデル/IRのホットスワップ**: `nam::DSP` と `CabConvolver` は `std::shared_ptr` +
  `std::atomic_load`/`std::atomic_store` で保持し、バックグラウンドスレッドからのモデル読み込み中も
  オーディオスレッドの `process()` はロックせずに読み取れるようにしています
- **サンプルレート**: NAMモデルは学習時のサンプルレート（多くは48kHz）を前提とするため、リサンプリングは
  行わず、インターフェースのサンプルレートをそのままエンジンに使います。合わない場合はモデル側の音が
  想定と変わる可能性があります（モデルが学習時と異なるレートでロードされたときの警告UIは未実装）
- **プリウォーム**: モデル読み込み時に `nam::DSP::Reset()` を呼び、内部状態を事前に安定させています
  （NAM Core のデフォルト挙動）
- **出力レベル自動正規化**: `.nam` ファイルのメタデータに含まれる `loudness`（NAM Core の
  `DSP::HasLoudness()` / `GetLoudness()`）を読み取り、指定したターゲットラウドネス（デフォルト -18dB）との
  差分をメイクアップゲインとして出力ゲインに自動で加算します（`nam_bridge_set_auto_normalize` /
  `nam_bridge_set_target_loudness_db`）。ラウドネス情報を持たないモデルには効果がありません。
  実サンプルモデル（`wavenet.nam`: -20.02dB、`lstm.nam`: -37.84dB）で正しくゲインが計算されることを
  Linux上のテストで確認済みです
- **EQ**: `AVAudioUnitEQ`（Apple標準のAudioUnit）を3バンド（Bass: 120Hz low shelf / Mid: 900Hz
  parametric peak / Treble: 3.5kHz high shelf）で使用。キャビIRの後段、メインミキサーの前段に接続

## 検証について（重要）

このプロジェクトは **Xcode/macOSの実機ビルド環境がないコンテナ上で** 実装されました。そのため:

- `Sources/NAMBridge` のC++コード（`nam_bridge.cpp` / `cab_convolver.cpp` / `wav_loader.cpp` +
  NeuralAmpModelerCore本体）は、Linux上でclang++ (`-std=c++20`) を使って実際にコンパイル・リンクし、
  NAM Core同梱の実サンプルモデル（`example_models/*.nam`）を使って
  モデル読み込み・推論・IR畳み込み・エラーハンドリング（ファイル未検出、サンプルレート不一致など）の
  動作を確認済みです
- 一方、**Swiftのコード（`Sources/AmpSimulator/*.swift`）とXcodeでのビルドそのものは未検証**です
  （このコンテナにSwiftツールチェインがないため）。API呼び出しは標準的なパターンに沿って書いていますが、
  実機でビルドした際にタイポや型の不一致などのコンパイルエラーが出る可能性があります。エラーが出た場合は
  内容を教えてもらえれば修正します

### マイク許可が出ない場合

`swift run` や Xcodeでの直接実行でマイクの許可ダイアログが出ない/権限が取得できない場合、
プレーンなSPM実行ファイルはmacOSのTCC（プライバシー管理）から見て「正式なアプリバンドル」として
認識されないことがあります。`Package.swift` では `Info.plist` をリンカの `-sectcreate` で
実行ファイルに埋め込む方法で対処していますが、確実な回避策は Xcodeで新規Appプロジェクトを作成し、
このパッケージをローカルSPM依存として追加して `ContentView()` を呼び出す薄いラッパーにすることです。

## 既知の制約・今後の課題

- エフェクター（歪みペダル、ディレイ、コーラス、リバーブなど）は未実装（意図的にスコープ外）
- IRのサンプルレート自動リサンプリングは未実装（不一致時はエラー）
- ゲイン値・レベルメーターはオーディオスレッドとUIスレッド間でロックなしの単純な読み書きをしており、
  真の意味でのロックフリー保証はありません（MVPとして許容している簡略化です）
- モデル/IR読み込みはUIスレッドから同期的に呼び出しており、大きなモデルではUIが一瞬ブロックされます
- EQは各バンドのゲインのみ調整可能で、周波数/バンド幅は固定（Bass: 120Hz, Mid: 900Hz, Treble: 3.5kHz）です
