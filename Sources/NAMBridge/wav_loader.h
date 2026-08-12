#pragma once

#include <string>
#include <vector>

namespace ampsim
{

struct WavData
{
  std::vector<float> samples; // mono, downmixed if the source file was multi-channel
  double sampleRate = 0.0;
};

/// Minimal WAV reader for cabinet impulse responses: PCM16/24/32 and
/// IEEE-float32, mono or multi-channel (downmixed to mono by averaging).
/// Throws std::runtime_error with a human-readable message on any parse
/// failure (missing file, unsupported format, truncated data, ...).
WavData LoadWavMono(const std::string& path);

} // namespace ampsim
