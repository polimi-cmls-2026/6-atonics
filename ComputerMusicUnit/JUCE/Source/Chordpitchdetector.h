#pragma once
#include <vector>
#include <complex>
#include <cmath>
#include <numeric>
#include <algorithm>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

//  ChordPitchDetector — HPS + FFT optimized for live guitar playing
// It's a monophonic algorithm but we optimized it in order to detect the root note even when playing full chords. It doesn't work with chord inversions (it will detect the lowest note)
// For the best results, play the bass note first and strum/pluck the rest of the chord after.


class ChordPitchDetector
{
public:
	// fftSize different from windowSize: we apply the window to the first 2048 samples, then zero-pad to 8192 for better frequency resolution.
    ChordPitchDetector(int windowSize = 2048, int fftSize = 8192, double sampleRate = 44100.0)
        : windowSize(windowSize), fftSize(fftSize), sampleRate(sampleRate)
    {
        hannWindow.resize(windowSize);
		// Window applied only on real samples, zero-padding will be applied after
        for (int i = 0; i < windowSize; ++i)
            hannWindow[i] = 0.5f * (1.0f - std::cos(2.0f * (float)M_PI * i / (windowSize - 1)));

        fftBuffer.resize(fftSize);
        magnitudes.resize(fftSize / 2 + 1);
        hpsSpectrum.resize(fftSize / 2 + 1);

		//Initialize median history with zeros
        medianHistory.assign(medianFrames, 0.0f);
        prevRms = 0.0f;
    }

	// Main processing function: takes a frame of audio samples and returns the detected chord root frequency in Hz (or 0.0f if no chord detected)
    float detectChordRoot(const float* frame, int frameSize)
    {
        if (frameSize != windowSize)
            return 0.0f;

        // Compute RMS
        float energy = 0.0f;
        for (int i = 0; i < windowSize; ++i)
            energy += frame[i] * frame[i];
        float rms = std::sqrt(energy / windowSize);

		// If RMS is below threshold, consider it silence and reset median history. Otherwise, check for attack transients.
        if (rms < rmsThreshold) {
            prevRms = rms;
            return 0.0f;
        }

		// Compute RMS ratio to detect attack transients.
        float rmsRatio = (prevRms > 1e-6f) ? (rms / prevRms) : 999.0f;

        if (rmsRatio > attackRatioThreshold) {
            //If it's a transient, ignore the next 3 frames to prevent random values
            transientHoldFrames = 3;
        }
        prevRms = rms;

		// If we're in the transient hold period, return the median of the last few frames to avoid erratic pitch detections. If we don't have enough history, return 0.
        if (transientHoldFrames > 0) {
            transientHoldFrames--;
            if (!medianHistory.empty()) {
                std::vector<float> sorted = medianHistory;
                std::sort(sorted.begin(), sorted.end());
                return sorted[sorted.size() / 2];
            }
            return 0.0f;
        }

		// Apply Hann window to the input frame and prepare the FFT buffer with zero-padding
        for (int i = 0; i < windowSize; ++i)
            fftBuffer[i] = { frame[i] * hannWindow[i], 0.0f };

        // Zero-pad
        for (int i = windowSize; i < fftSize; ++i)
            fftBuffer[i] = { 0.0f, 0.0f };

		// Compute FFT in-place
        computeFFT(fftBuffer);

		// Magnitude calculation for positive frequencies only (0 to Nyquist)
        for (int i = 0; i <= fftSize / 2; ++i)
            magnitudes[i] = std::abs(fftBuffer[i]);

        // HPS (Harmonic Product Spectrum)
        const int numHarmonics = 4;
        const int minBin = std::max(1, static_cast<int>(minFreqHz * fftSize / sampleRate));
        const int maxBin = static_cast<int>(maxFreqHz * fftSize / sampleRate);

        for (int i = 0; i <= fftSize / 2; ++i)
            hpsSpectrum[i] = magnitudes[i];

        for (int h = 2; h <= numHarmonics; ++h)
        {
            for (int i = minBin; i <= maxBin; ++i)
            {
                int srcBin = i * h;
                if (srcBin <= fftSize / 2)
                    hpsSpectrum[i] *= magnitudes[srcBin];
            }
        }

        // Spectral Bass Weighting
        // We favour the lower frequencies to help detect the chord root
        float fadeStartHz = 120.0f; // Fade begins above B2
        float fadeEndHz = 220.0f; // Pretty steep curve (nothing above A3)

        for (int i = minBin; i <= maxBin; ++i)
        {
            float freq = i * sampleRate / fftSize;
            float weight = 1.0f;

            if (freq > fadeStartHz)
            {
                if (freq < fadeEndHz)
                    // Exponential curve
                    weight = std::pow(1.0f - ((freq - fadeStartHz) / (fadeEndHz - fadeStartHz)), 2.0f);
                else
                    weight = 0.01f;
            }
            hpsSpectrum[i] *= weight;
        }

		// Search for the peak in the HPS spectrum
        int peakBin = minBin;
        float peakVal = hpsSpectrum[minBin];
        for (int i = minBin + 1; i <= maxBin; ++i)
        {
            if (hpsSpectrum[i] > peakVal)
            {
                peakVal = hpsSpectrum[i];
                peakBin = i;
            }
        }

		// Parabolic Interpolation for better frequency estimation
        float refinedBin = static_cast<float>(peakBin);
        if (peakBin > minBin && peakBin < maxBin)
        {
            float left   = hpsSpectrum[peakBin - 1];
            float center = hpsSpectrum[peakBin];
            float right  = hpsSpectrum[peakBin + 1];
            float denom  = 2.0f * (2.0f * center - left - right);
            if (std::abs(denom) > 1e-6f)
                refinedBin += (right - left) / denom;
        }

        float rawPitch = static_cast<float>(refinedBin * sampleRate / fftSize);

        // Median filter (3 samples) to stabilize the pitch detection
        medianHistory.erase(medianHistory.begin());
        medianHistory.push_back(rawPitch);

        std::vector<float> sorted = medianHistory;
        std::sort(sorted.begin(), sorted.end());
        return sorted[sorted.size() / 2];
    }

	// Parameters (adjust these according to your setup and preferences)
	float rmsThreshold = 0.008f;   // Minimum RMS to consider as a valid chord (adjust based on your input level)
	float attackRatioThreshold = 2.5f;  // RMS Ratio threshold
	float minFreqHz = 80.0f;    // Just below E2, the lowest note on a standard guitar.
    float maxFreqHz = 300.0f;   // Just above D4, the highest note we want to consider

private:
    int    windowSize;
    int    fftSize;
    double sampleRate;
    int    medianFrames = 3;
    int transientHoldFrames = 0;

    std::vector<float>               hannWindow;
    std::vector<std::complex<float>> fftBuffer;
    std::vector<float>               magnitudes;
    std::vector<float>               hpsSpectrum;
    std::vector<float>               medianHistory;

    float prevRms;

	// Reset the median history (useful when we detect silence to avoid old values affecting the next detection)
    void resetMedianHistory()
    {
        std::fill(medianHistory.begin(), medianHistory.end(), 0.0f);
    }

	//FFT implementation (Cooley-Tukey in-place radix-2)
    void computeFFT(std::vector<std::complex<float>>& x)
    {
        int N = static_cast<int>(x.size());

        // Bit-reversal permutation
        for (int i = 1, j = 0; i < N; ++i)
        {
            int bit = N >> 1;
            for (; j & bit; bit >>= 1)
                j ^= bit;
            j ^= bit;
            if (i < j) std::swap(x[i], x[j]);
        }

        // Butterfly stages
        for (int len = 2; len <= N; len <<= 1)
        {
            float angle = -(float)M_PI * 2.0f / len;
            std::complex<float> wlen(std::cos(angle), std::sin(angle));
            for (int i = 0; i < N; i += len)
            {
                std::complex<float> w(1.0f, 0.0f);
                for (int j = 0; j < len / 2; ++j)
                {
                    std::complex<float> u = x[i + j];
                    std::complex<float> v = x[i + j + len / 2] * w;
                    x[i + j]             = u + v;
                    x[i + j + len / 2]   = u - v;
                    w *= wlen;
                }
            }
        }
    }
};