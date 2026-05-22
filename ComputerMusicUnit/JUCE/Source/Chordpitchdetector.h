#pragma once
#include <vector>
#include <complex>
#include <cmath>
#include <numeric>
#include <algorithm>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

// =============================================================================
//  ChordPitchDetector — HPS + FFT optimisé pour usage live
//
//  Latence totale visée : ~75 ms (FFT 2048, médian 3 frames, hop = FFT/2)
//
//  Optimisations clés :
//   1. Filtre médian réduit à 3 frames (au lieu de 5)
//   2. Reset dynamique du filtre sur détection d'attaque (transitoire RMS)
//   3. Deadband en cents pour éviter les micro-envois OSC inutiles
//   4. Fenêtre de Hann pré-calculée à l'init (pas de malloc dans l'audio thread)
//   5. FFT Cooley-Tukey in-place — aucune dépendance externe
// =============================================================================

class ChordPitchDetector
{
public:
    // Aggiungiamo windowSize (2048 per il live) e fftSize (8192 per la risoluzione)
    ChordPitchDetector(int windowSize = 2048, int fftSize = 8192, double sampleRate = 44100.0)
        : windowSize(windowSize), fftSize(fftSize), sampleRate(sampleRate)
    {
        hannWindow.resize(windowSize);
        // La finestra si applica solo ai campioni reali
        for (int i = 0; i < windowSize; ++i)
            hannWindow[i] = 0.5f * (1.0f - std::cos(2.0f * (float)M_PI * i / (windowSize - 1)));

        fftBuffer.resize(fftSize); // Ora è 8192
        magnitudes.resize(fftSize / 2 + 1);
        hpsSpectrum.resize(fftSize / 2 + 1);

        medianHistory.assign(medianFrames, 0.0f);
        prevRms = 0.0f;
    }

    float detectChordRoot(const float* frame, int frameSize)
    {
        if (frameSize != windowSize)
            return 0.0f;

        // --- 1. Calcul RMS (rimane invariato) ---
        float energy = 0.0f;
        for (int i = 0; i < windowSize; ++i)
            energy += frame[i] * frame[i];
        float rms = std::sqrt(energy / windowSize);

        if (rms < rmsThreshold) {
            prevRms = rms;
            return 0.0f;
        }

        float rmsRatio = (prevRms > 1e-6f) ? (rms / prevRms) : 999.0f;
        if (rmsRatio > attackRatioThreshold)
            resetMedianHistory();
        prevRms = rms;

        // --- 3. Fenêtrage de Hann e ZERO-PADDING ---
        // Copia i campioni reali
        for (int i = 0; i < windowSize; ++i)
            fftBuffer[i] = { frame[i] * hannWindow[i], 0.0f };

        // Riempi di zeri la parte rimanente (zero-padding)
        for (int i = windowSize; i < fftSize; ++i)
            fftBuffer[i] = { 0.0f, 0.0f };

        // --- 4. FFT in-place (calcolata su 8192 punti) ---
        computeFFT(fftBuffer);

        // --- 5. Spectre de magnitudes ---
        for (int i = 0; i <= fftSize / 2; ++i)
            magnitudes[i] = std::abs(fftBuffer[i]);

        // --- 6. HPS (Harmonic Product Spectrum) ---
        //    Plage cible : 60–800 Hz (cordes basses + aigu guitare standard)
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

        // ==========================================================
        // --- 6.5 SPECTRAL BASS WEIGHTING (LA NOSTRA MODIFICA) ---
        // Forziamo matematicamente l'HPS a preferire le frequenze gravi.
        // Fino a 160Hz (circa un Mi/Re3) il peso è 1.0. 
        // Da 160Hz a 400Hz sfuma fino a 0.1, penalizzando i cantini.
        // ==========================================================
        float fadeStartHz = 160.0f;
        float fadeEndHz = 400.0f;

        for (int i = minBin; i <= maxBin; ++i)
        {
            float freq = i * sampleRate / fftSize;
            float weight = 1.0f;

            if (freq > fadeStartHz)
            {
                if (freq < fadeEndHz)
                    weight = 1.0f - 0.9f * ((freq - fadeStartHz) / (fadeEndHz - fadeStartHz));
                else
                    weight = 0.1f;
            }
            hpsSpectrum[i] *= weight;
        }

        // --- 7. Recherche du pic dans la plage cible ---
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

        // --- 8. Interpolation parabolique (précision sub-bin) ---
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

        // --- 9. Filtre médian 3 frames ---
        medianHistory.erase(medianHistory.begin());
        medianHistory.push_back(rawPitch);

        std::vector<float> sorted = medianHistory;
        std::sort(sorted.begin(), sorted.end());
        return sorted[sorted.size() / 2];
    }

    // -------------------------------------------------------------------------
    //  Paramètres ajustables publiquement avant / pendant l'usage
    // -------------------------------------------------------------------------
    float rmsThreshold      = 0.008f;   // Seuil silence (ajuste selon ton préamp)
    float attackRatioThreshold = 2.5f;  // Ratio RMS déclenchant un reset médian
    float minFreqHz         = 80.0f;    // Mi grave guitare basse : 41 Hz / guitare : 82 Hz
    float maxFreqHz         = 800.0f;   // Limite haute (harmoniques jusqu'à 800 Hz)

private:
    int    windowSize;
    int    fftSize;
    double sampleRate;
    int    medianFrames = 3;            // 3 frames = ~70 ms de latence médian à 44100/hop1024

    std::vector<float>               hannWindow;
    std::vector<std::complex<float>> fftBuffer;
    std::vector<float>               magnitudes;
    std::vector<float>               hpsSpectrum;
    std::vector<float>               medianHistory;

    float prevRms;

    // Vide le filtre médian — appelé sur détection d'attaque
    void resetMedianHistory()
    {
        std::fill(medianHistory.begin(), medianHistory.end(), 0.0f);
    }

    // -------------------------------------------------------------------------
    //  FFT Cooley-Tukey radix-2 in-place — pas d'allocation dans l'audio thread
    // -------------------------------------------------------------------------
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