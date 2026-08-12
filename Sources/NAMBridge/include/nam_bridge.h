#ifndef NAM_BRIDGE_H
#define NAM_BRIDGE_H

#ifdef __cplusplus
extern "C"
{
#endif

/// Opaque handle to a NAM + cab-IR processing context.
typedef struct NAMBridgeContext NAMBridgeContext;

typedef enum
{
  NAMBridgeStatusOK = 0,
  NAMBridgeStatusFileNotFound = 1,
  NAMBridgeStatusModelLoadFailed = 2,
  NAMBridgeStatusIRLoadFailed = 3,
  NAMBridgeStatusIRSampleRateMismatch = 4,
  NAMBridgeStatusInvalidArgument = 5,
  NAMBridgeStatusNotPrepared = 6,
} NAMBridgeStatus;

/// Create a new context. Must be paired with nam_bridge_destroy.
NAMBridgeContext* nam_bridge_create(void);

/// Destroy a context created by nam_bridge_create.
void nam_bridge_destroy(NAMBridgeContext* ctx);

/// Configure the sample rate and maximum block size the engine will run at.
/// Call this once before starting audio, and again whenever either changes
/// (e.g. the user picks a different audio device). Not realtime-safe; call
/// from a setup/background thread, never from the audio render callback.
void nam_bridge_prepare(NAMBridgeContext* ctx, double sampleRate, int maxBlockSize);

/// Load a NAM capture (.nam) file. Not realtime-safe: performs file IO,
/// allocation, and model prewarming. Call from a background thread; the
/// audio thread will atomically pick up the new model on its next block.
/// Requires nam_bridge_prepare() to have been called first.
NAMBridgeStatus nam_bridge_load_model(NAMBridgeContext* ctx, const char* namFilePath);

/// Remove the currently loaded model (audio passes through unprocessed).
void nam_bridge_clear_model(NAMBridgeContext* ctx);

/// Load a cabinet impulse response from a WAV file (mono or stereo; stereo
/// is downmixed to mono). The IR's sample rate must match the sample rate
/// passed to nam_bridge_prepare(), otherwise NAMBridgeStatusIRSampleRateMismatch
/// is returned. Not realtime-safe; call from a background thread.
NAMBridgeStatus nam_bridge_load_ir(NAMBridgeContext* ctx, const char* wavFilePath);

/// Remove the currently loaded cabinet IR (no convolution is applied).
void nam_bridge_clear_ir(NAMBridgeContext* ctx);

/// Process one block of mono audio: NAM model -> cabinet IR convolution.
/// input/output must each point to numFrames contiguous floats and must not
/// overlap. Gains are applied in dB before the model (input) and after the
/// cabinet IR (output). Realtime-safe: performs no locking, allocation, or
/// file IO. Safe to call even if no model/IR is loaded (passes audio through,
/// with gain applied).
void nam_bridge_process(NAMBridgeContext* ctx, const float* input, float* output, int numFrames, float inputGainDb,
                         float outputGainDb);

/// True if a NAM model is currently loaded.
int nam_bridge_has_model(const NAMBridgeContext* ctx);

/// True if a cabinet IR is currently loaded.
int nam_bridge_has_ir(const NAMBridgeContext* ctx);

/// The currently loaded model's expected sample rate in Hz, or -1 if unknown
/// or no model is loaded.
double nam_bridge_model_sample_rate(const NAMBridgeContext* ctx);

#ifdef __cplusplus
}
#endif

#endif // NAM_BRIDGE_H
