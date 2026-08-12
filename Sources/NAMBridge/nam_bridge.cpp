#include "include/nam_bridge.h"

#include <algorithm>
#include <cmath>
#include <filesystem>
#include <memory>
#include <vector>

#include "NAM/dsp.h"
#include "NAM/get_dsp.h"

#include "cab_convolver.h"
#include "wav_loader.h"

namespace
{
float DbToLinear(float db)
{
  return std::pow(10.0f, db / 20.0f);
}
} // namespace

struct NAMBridgeContext
{
  double sampleRate = 48000.0;
  int maxBlockSize = 0;
  bool prepared = false;

  // Current model/convolver, swapped from a background thread while the
  // audio thread reads them via the std::atomic_load/store free functions
  // below (real-time reads, no blocking allocation on the audio thread).
  std::shared_ptr<nam::DSP> model;
  std::shared_ptr<ampsim::CabConvolver> convolver;

  // Scratch buffers, sized once in nam_bridge_prepare() so
  // nam_bridge_process() never allocates.
  std::vector<float> stageA;
  std::vector<float> stageB;
  std::vector<double> inD;
  std::vector<double> outD;
};

namespace
{
void ProcessChunk(NAMBridgeContext* ctx, const float* input, float* output, int numFrames, float inGain,
                   float outGain)
{
  auto model = std::atomic_load(&ctx->model);
  auto convolver = std::atomic_load(&ctx->convolver);

  for (int i = 0; i < numFrames; ++i)
    ctx->stageA[static_cast<size_t>(i)] = input[i] * inGain;

  const float* preCab = ctx->stageA.data();
  if (model)
  {
    for (int i = 0; i < numFrames; ++i)
      ctx->inD[static_cast<size_t>(i)] = static_cast<double>(ctx->stageA[static_cast<size_t>(i)]);

    NAM_SAMPLE* inCh[1] = {ctx->inD.data()};
    NAM_SAMPLE* outCh[1] = {ctx->outD.data()};
    model->process(inCh, outCh, numFrames);

    for (int i = 0; i < numFrames; ++i)
      ctx->stageB[static_cast<size_t>(i)] = static_cast<float>(ctx->outD[static_cast<size_t>(i)]);
    preCab = ctx->stageB.data();
  }

  if (convolver)
  {
    convolver->Process(preCab, output, numFrames);
  }
  else
  {
    std::copy(preCab, preCab + numFrames, output);
  }

  for (int i = 0; i < numFrames; ++i)
    output[i] *= outGain;
}
} // namespace

NAMBridgeContext* nam_bridge_create(void)
{
  return new NAMBridgeContext();
}

void nam_bridge_destroy(NAMBridgeContext* ctx)
{
  delete ctx;
}

void nam_bridge_prepare(NAMBridgeContext* ctx, double sampleRate, int maxBlockSize)
{
  if (!ctx || sampleRate <= 0.0 || maxBlockSize <= 0)
    return;

  ctx->sampleRate = sampleRate;
  ctx->maxBlockSize = maxBlockSize;
  ctx->stageA.assign(static_cast<size_t>(maxBlockSize), 0.0f);
  ctx->stageB.assign(static_cast<size_t>(maxBlockSize), 0.0f);
  ctx->inD.assign(static_cast<size_t>(maxBlockSize), 0.0);
  ctx->outD.assign(static_cast<size_t>(maxBlockSize), 0.0);
  ctx->prepared = true;

  // Re-settle the currently loaded model (if any) for the new sample
  // rate/block size. Not realtime-safe: callers must not invoke this while
  // audio is actively being processed on another thread.
  if (ctx->model)
    ctx->model->Reset(sampleRate, maxBlockSize);
}

NAMBridgeStatus nam_bridge_load_model(NAMBridgeContext* ctx, const char* namFilePath)
{
  if (!ctx || !namFilePath)
    return NAMBridgeStatusInvalidArgument;
  if (!ctx->prepared)
    return NAMBridgeStatusNotPrepared;

  const std::filesystem::path path(namFilePath);
  if (!std::filesystem::exists(path))
    return NAMBridgeStatusFileNotFound;

  std::shared_ptr<nam::DSP> newModel;
  try
  {
    newModel = nam::get_dsp(path);
  }
  catch (...)
  {
    return NAMBridgeStatusModelLoadFailed;
  }
  if (!newModel)
    return NAMBridgeStatusModelLoadFailed;

  newModel->Reset(ctx->sampleRate, ctx->maxBlockSize); // also prewarms by default
  std::atomic_store(&ctx->model, newModel);
  return NAMBridgeStatusOK;
}

void nam_bridge_clear_model(NAMBridgeContext* ctx)
{
  if (!ctx)
    return;
  std::atomic_store(&ctx->model, std::shared_ptr<nam::DSP>());
}

NAMBridgeStatus nam_bridge_load_ir(NAMBridgeContext* ctx, const char* wavFilePath)
{
  if (!ctx || !wavFilePath)
    return NAMBridgeStatusInvalidArgument;
  if (!ctx->prepared)
    return NAMBridgeStatusNotPrepared;

  if (!std::filesystem::exists(std::filesystem::path(wavFilePath)))
    return NAMBridgeStatusFileNotFound;

  ampsim::WavData wav;
  try
  {
    wav = ampsim::LoadWavMono(wavFilePath);
  }
  catch (...)
  {
    return NAMBridgeStatusIRLoadFailed;
  }
  if (wav.samples.empty())
    return NAMBridgeStatusIRLoadFailed;

  // Guitar cabinet IRs are captured at a specific rate; convolving against
  // an IR captured at the wrong rate shifts every formant in the cabinet
  // response, so we require an exact match rather than silently resampling.
  if (std::abs(wav.sampleRate - ctx->sampleRate) > 0.5)
    return NAMBridgeStatusIRSampleRateMismatch;

  std::shared_ptr<ampsim::CabConvolver> newConvolver;
  try
  {
    newConvolver = std::make_shared<ampsim::CabConvolver>(std::move(wav.samples), wav.sampleRate, ctx->maxBlockSize);
  }
  catch (...)
  {
    return NAMBridgeStatusIRLoadFailed;
  }

  std::atomic_store(&ctx->convolver, newConvolver);
  return NAMBridgeStatusOK;
}

void nam_bridge_clear_ir(NAMBridgeContext* ctx)
{
  if (!ctx)
    return;
  std::atomic_store(&ctx->convolver, std::shared_ptr<ampsim::CabConvolver>());
}

void nam_bridge_process(NAMBridgeContext* ctx, const float* input, float* output, int numFrames, float inputGainDb,
                         float outputGainDb)
{
  if (!ctx || !input || !output || numFrames <= 0)
    return;

  const float inGain = DbToLinear(inputGainDb);
  const float outGain = DbToLinear(outputGainDb);

  if (!ctx->prepared)
  {
    // Not yet configured: pass through with gain applied, no scratch buffers needed.
    for (int i = 0; i < numFrames; ++i)
      output[i] = input[i] * inGain * outGain;
    return;
  }

  int offset = 0;
  while (offset < numFrames)
  {
    const int chunk = std::min(ctx->maxBlockSize, numFrames - offset);
    ProcessChunk(ctx, input + offset, output + offset, chunk, inGain, outGain);
    offset += chunk;
  }
}

int nam_bridge_has_model(const NAMBridgeContext* ctx)
{
  if (!ctx)
    return 0;
  return std::atomic_load(&ctx->model) != nullptr ? 1 : 0;
}

int nam_bridge_has_ir(const NAMBridgeContext* ctx)
{
  if (!ctx)
    return 0;
  return std::atomic_load(&ctx->convolver) != nullptr ? 1 : 0;
}

double nam_bridge_model_sample_rate(const NAMBridgeContext* ctx)
{
  if (!ctx)
    return -1.0;
  auto model = std::atomic_load(&ctx->model);
  return model ? model->GetExpectedSampleRate() : -1.0;
}
