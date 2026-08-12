#include "cab_convolver.h"

#include <algorithm>
#include <stdexcept>

#include <Eigen/Dense>

namespace ampsim
{

CabConvolver::CabConvolver(std::vector<float> impulseResponse, double sampleRate, int maxBlockSize)
: mSampleRate(sampleRate)
, mMaxBlockSize(std::max(1, maxBlockSize))
{
  if (impulseResponse.empty())
    throw std::invalid_argument("CabConvolver: impulse response must not be empty");

  // Time-reverse once up front so Process() is a plain forward dot product:
  // y[n] = sum_i mIR[i] * scratch[n + i], with scratch = [history | block].
  mIR.resize(impulseResponse.size());
  std::reverse_copy(impulseResponse.begin(), impulseResponse.end(), mIR.begin());

  const size_t historyLength = mIR.size() - 1;
  mHistory.assign(historyLength, 0.0f);
  mScratch.reserve(historyLength + static_cast<size_t>(mMaxBlockSize));
}

void CabConvolver::Process(const float* input, float* output, int numFrames)
{
  const size_t historyLength = mHistory.size();
  const size_t irLength = mIR.size();

  mScratch.resize(historyLength + static_cast<size_t>(numFrames));
  std::copy(mHistory.begin(), mHistory.end(), mScratch.begin());
  std::copy(input, input + numFrames, mScratch.begin() + static_cast<long>(historyLength));

  const Eigen::Map<const Eigen::VectorXf> ir(mIR.data(), static_cast<Eigen::Index>(irLength));
  for (int n = 0; n < numFrames; ++n)
  {
    const Eigen::Map<const Eigen::VectorXf> window(mScratch.data() + n, static_cast<Eigen::Index>(irLength));
    output[n] = ir.dot(window);
  }

  // Carry the last historyLength samples of this block (or the tail of the
  // scratch buffer, if numFrames < historyLength) forward as the new history.
  const size_t total = mScratch.size();
  std::copy(mScratch.begin() + static_cast<long>(total - historyLength), mScratch.end(), mHistory.begin());
}

} // namespace ampsim
