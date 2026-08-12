// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "AmpSimulator",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "AmpSimulator", targets: ["AmpSimulator"])
    ],
    targets: [
        // C++ bridge: wraps NeuralAmpModelerCore (NAM model inference) and a
        // cabinet-IR convolver behind a plain C API so Swift can call it directly.
        .target(
            name: "NAMBridge",
            path: "Sources/NAMBridge",
            sources: [
                "nam_bridge.cpp",
                "cab_convolver.cpp",
                "wav_loader.cpp",
                "NeuralAmpModelerCore/NAM",
            ],
            publicHeadersPath: "include",
            cxxSettings: [
                .headerSearchPath("NeuralAmpModelerCore"),
                .headerSearchPath("NeuralAmpModelerCore/Dependencies/eigen"),
                .headerSearchPath("NeuralAmpModelerCore/Dependencies/nlohmann"),
            ]
        ),
        .executableTarget(
            name: "AmpSimulator",
            dependencies: ["NAMBridge"],
            path: "Sources/AmpSimulator",
            exclude: ["Info.plist"],
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("AudioToolbox"),
                // Embed Info.plist into the built executable so macOS treats it
                // as a proper bundle for TCC purposes (microphone permission
                // prompts require this even for a plain SPM executable). See
                // README "Known limitations" if the mic prompt doesn't appear
                // when run this way — wrapping in a thin Xcode App target is
                // the fully bulletproof fallback.
                .unsafeFlags([
                    "-Xlinker", "-sectcreate",
                    "-Xlinker", "__TEXT",
                    "-Xlinker", "__info_plist",
                    "-Xlinker", "Sources/AmpSimulator/Info.plist",
                ], .when(platforms: [.macOS])),
            ]
        ),
    ],
    cxxLanguageStandard: .cxx20
)
