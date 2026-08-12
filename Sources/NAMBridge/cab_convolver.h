#pragma once

#include <cstddef>
#include <vector>

namespace ampsim
{

/// Direct-form (time-domain) mono convolution against a fixed cabinet
/// impulse response.
///
/// This is deliberately the simplest correct implementation: a sliding dot
/// product against a history buffer, no FFT. Typical guitar-cabinet IRs run
/// a few thousand taps (roughly up to ~0.5s at 48kHz), which direct
/// convolution handles comfortably in real time on any modern Mac. A
/// partitioned FFT convolution would be a natural follow-up if CPU load
/// ever becomes a problem with very long IRs.
class CabConvolver
{
public:
  /// impulseResponse must be non-empty. maxBlockSize is the largest
  /// numFrames that will ever be passed to Process(); buffers are
  /// pre-sized so steady-state Process() calls never allocate.
  CabConvolver(std::vector<float> impulseResponse, double sampleRate, int maxBlockSize);

  double GetSampleRate() const { return mSampleRate; }
  size_t GetLength() const { return mIR.size(); }

  /// input and output must each point to numFrames contiguous floats and
  /// must not alias each other. Realtime-safe as long as numFrames <=
  /// maxBlockSize passed to the constructor.
  void Process(const float* input, float* output, int numFrames);

private:
  std::vector<float> mIR; // IR taps, time-reversed for the sliding dot product
  double mSampleRate;
  int mMaxBlockSize;

  // Tail of previous input blocks: the most recent (mIR.size() - 1) samples,
  // needed so each output sample can be computed from a contiguous window.
  std::vector<float> mHistory;
  // Scratch = [history | current block], reused across calls.
  std::vector<float> mScratch;
};

} // namespace ampsim
