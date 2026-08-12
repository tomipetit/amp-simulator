#include "wav_loader.h"

#include <cstdint>
#include <cstring>
#include <fstream>
#include <stdexcept>

namespace ampsim
{

namespace
{

uint32_t ReadU32LE(const unsigned char* p)
{
  return static_cast<uint32_t>(p[0]) | (static_cast<uint32_t>(p[1]) << 8) | (static_cast<uint32_t>(p[2]) << 16)
         | (static_cast<uint32_t>(p[3]) << 24);
}

uint16_t ReadU16LE(const unsigned char* p)
{
  return static_cast<uint16_t>(p[0]) | static_cast<uint16_t>(p[1] << 8);
}

constexpr uint16_t kFormatPCM = 1;
constexpr uint16_t kFormatIEEEFloat = 3;
constexpr uint16_t kFormatExtensible = 0xFFFE;

} // namespace

WavData LoadWavMono(const std::string& path)
{
  std::ifstream file(path, std::ios::binary);
  if (!file)
    throw std::runtime_error("WAV file not found or unreadable: " + path);

  std::vector<unsigned char> bytes((std::istreambuf_iterator<char>(file)), std::istreambuf_iterator<char>());
  if (bytes.size() < 44)
    throw std::runtime_error("WAV file too small to be valid: " + path);

  if (std::memcmp(bytes.data(), "RIFF", 4) != 0 || std::memcmp(bytes.data() + 8, "WAVE", 4) != 0)
    throw std::runtime_error("Not a RIFF/WAVE file: " + path);

  bool haveFmt = false;
  uint16_t formatTag = 0;
  uint16_t numChannels = 0;
  uint32_t sampleRate = 0;
  uint16_t bitsPerSample = 0;

  const unsigned char* dataBegin = nullptr;
  uint32_t dataSize = 0;

  size_t pos = 12; // past "RIFF"<size>"WAVE"
  while (pos + 8 <= bytes.size())
  {
    const unsigned char* chunkId = bytes.data() + pos;
    uint32_t chunkSize = ReadU32LE(bytes.data() + pos + 4);
    const unsigned char* chunkData = bytes.data() + pos + 8;

    if (pos + 8 + static_cast<size_t>(chunkSize) > bytes.size())
      break; // truncated chunk; stop parsing rather than reading out of bounds

    if (std::memcmp(chunkId, "fmt ", 4) == 0 && chunkSize >= 16)
    {
      formatTag = ReadU16LE(chunkData + 0);
      numChannels = ReadU16LE(chunkData + 2);
      sampleRate = ReadU32LE(chunkData + 4);
      bitsPerSample = ReadU16LE(chunkData + 14);
      if (formatTag == kFormatExtensible && chunkSize >= 40)
      {
        // First two bytes of the SubFormat GUID distinguish PCM (1) vs IEEE float (3).
        formatTag = ReadU16LE(chunkData + 24);
      }
      haveFmt = true;
    }
    else if (std::memcmp(chunkId, "data", 4) == 0)
    {
      dataBegin = chunkData;
      dataSize = chunkSize;
    }

    pos += 8 + chunkSize + (chunkSize % 2); // chunks are word-aligned
  }

  if (!haveFmt)
    throw std::runtime_error("WAV file has no fmt chunk: " + path);
  if (dataBegin == nullptr)
    throw std::runtime_error("WAV file has no data chunk: " + path);
  if (numChannels == 0)
    throw std::runtime_error("WAV file reports zero channels: " + path);
  if (formatTag != kFormatPCM && formatTag != kFormatIEEEFloat)
    throw std::runtime_error("Unsupported WAV format tag (only PCM and IEEE float are supported): " + path);

  const uint16_t bytesPerSample = bitsPerSample / 8;
  if (bytesPerSample == 0 || dataSize % (static_cast<uint32_t>(bytesPerSample) * numChannels) != 0)
    throw std::runtime_error("WAV file has an inconsistent data size: " + path);

  const size_t frameSize = static_cast<size_t>(bytesPerSample) * numChannels;
  const size_t numFrames = dataSize / frameSize;

  WavData result;
  result.sampleRate = static_cast<double>(sampleRate);
  result.samples.resize(numFrames);

  for (size_t frame = 0; frame < numFrames; ++frame)
  {
    const unsigned char* frameBase = dataBegin + frame * frameSize;
    float sum = 0.0f;
    for (uint16_t ch = 0; ch < numChannels; ++ch)
    {
      const unsigned char* s = frameBase + static_cast<size_t>(ch) * bytesPerSample;
      float sample = 0.0f;
      if (formatTag == kFormatIEEEFloat && bytesPerSample == 4)
      {
        uint32_t bits = ReadU32LE(s);
        std::memcpy(&sample, &bits, sizeof(float));
      }
      else if (formatTag == kFormatPCM && bytesPerSample == 2)
      {
        int16_t v = static_cast<int16_t>(ReadU16LE(s));
        sample = static_cast<float>(v) / 32768.0f;
      }
      else if (formatTag == kFormatPCM && bytesPerSample == 3)
      {
        int32_t v = (static_cast<int32_t>(s[0]) << 8) | (static_cast<int32_t>(s[1]) << 16)
                    | (static_cast<int32_t>(s[2]) << 24);
        sample = static_cast<float>(v >> 8) / 8388608.0f;
      }
      else if (formatTag == kFormatPCM && bytesPerSample == 4)
      {
        int32_t v = static_cast<int32_t>(ReadU32LE(s));
        sample = static_cast<float>(v) / 2147483648.0f;
      }
      else
      {
        throw std::runtime_error("Unsupported WAV sample bit depth: " + path);
      }
      sum += sample;
    }
    result.samples[frame] = sum / static_cast<float>(numChannels);
  }

  return result;
}

} // namespace ampsim
