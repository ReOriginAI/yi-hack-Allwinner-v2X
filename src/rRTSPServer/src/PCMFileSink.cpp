/*
 * Copyright (c) 2025 roleo.
 *
 * This program is free software: you can redistribute it and/or modify
 * it under the terms of the GNU General Public License as published by
 * the Free Software Foundation, version 3.
 *
 * This program is distributed in the hope that it will be useful, but
 * WITHOUT ANY WARRANTY; without even the implied warranty of
 * MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU
 * General Public License for more details.
 *
 * You should have received a copy of the GNU General Public License
 * along with this program. If not, see <http://www.gnu.org/licenses/>.
 */

/*
 * PCM File Sink
 */

#include "PCMFileSink.hh"
#include "GroupsockHelper.hh"
#include "OutputFile.hh"
#include "uLawAudioFilter.hh"
#include "aLawAudioFilter.hh"
#include "Speaker.hh"
#include "rRTSPServer.h"
#include <fcntl.h>
#include <unistd.h>
#include <errno.h>

////////// PCMFileSink //////////

extern int debug;

// ulaw and alaw functions
static int16_t linear16FromuLaw(unsigned char uLawByte) {
    static int const exp_lut[8] = {0,132,396,924,1980,4092,8316,16764};
    uLawByte = ~uLawByte;

    int sign = (uLawByte & 0x80) != 0;
    unsigned char exponent = (uLawByte >> 4) & 0x07;
    unsigned char mantissa = uLawByte & 0x0F;

    int16_t result = exp_lut[exponent] + (mantissa << (exponent + 3));
    if (sign) result = -result;
    return result;
}

static int16_t alaw_decode[256] = {
    -5504, -5248, -6016, -5760, -4480, -4224, -4992, -4736,
     -7552, -7296, -8064, -7808, -6528, -6272, -7040, -6784,
    -2752, -2624, -3008, -2880, -2240, -2112, -2496, -2368,
    -3776, -3648, -4032, -3904, -3264, -3136, -3520, -3392,
    -22016, -20992, -24064, -23040, -17920, -16896, -19968, -18944,
    -30208, -29184, -32256, -31232, -26112, -25088, -28160, -27136,
    -11008, -10496, -12032, -11520, -8960, -8448, -9984, -9472,
    -15104, -14592, -16128, -15616, -13056, -12544, -14080, -13568,
    -344, -328, -376, -360, -280, -264, -312, -296,
    -472, -456, -504, -488, -408, -392, -440, -424,
    -88, -72, -120, -104, -24, -8, -56, -40,
    -216, -200, -248, -232, -152, -136, -184, -168,
    -1376, -1312, -1504, -1440, -1120, -1056, -1248, -1184,
    -1888, -1824, -2016, -1952, -1632, -1568, -1760, -1696,
    -688, -656, -752, -720, -560, -528, -624, -592,
    -944, -912, -1008, -976, -816, -784, -880, -848,
    5504, 5248, 6016, 5760, 4480, 4224, 4992, 4736,
    7552, 7296, 8064, 7808, 6528, 6272, 7040, 6784,
    2752, 2624, 3008, 2880, 2240, 2112, 2496, 2368,
    3776, 3648, 4032, 3904, 3264, 3136, 3520, 3392,
    22016, 20992, 24064, 23040, 17920, 16896, 19968, 18944,
    30208, 29184, 32256, 31232, 26112, 25088, 28160, 27136,
    11008, 10496, 12032, 11520, 8960, 8448, 9984, 9472,
    15104, 14592, 16128, 15616, 13056, 12544, 14080, 13568,
    344, 328, 376, 360, 280, 264, 312, 296,
    472, 456, 504, 488, 408, 392, 440, 424,
    88, 72, 120, 104, 24, 8, 56, 40,
    216, 200, 248, 232, 152, 136, 184, 168,
    1376, 1312, 1504, 1440, 1120, 1056, 1248, 1184,
    1888, 1824, 2016, 1952, 1632, 1568, 1760, 1696,
    688, 656, 752, 720, 560, 528, 624, 592,
    944, 912, 1008, 976, 816, 784, 880, 848
};

static u_int16_t linear16FromaLaw(unsigned char aLawByte) {
    return alaw_decode[aLawByte];
}

// PCMFileSink class implementation
PCMFileSink::PCMFileSink(UsageEnvironment& env, char const* fileName,
                         int destSampleRate, int srcLaw,
                         Boolean enableSpeaker, unsigned bufferSize)
    : FileSink(env, NULL, bufferSize, NULL), fDestSampleRate(destSampleRate),
      fSrcLaw(srcLaw), fFileName(strDup(fileName)), fEnableSpeaker(enableSpeaker) {

    if (debug & 16) fprintf(stderr, "%lld: PCMFileSink - Starting sink\n", current_timestamp());

    if (enableSpeaker) {
        fSpeaker = Speaker::createNew(env);
    } else {
        fSpeaker = NULL;
    }
    fPCMBuffer = new int16_t[bufferSize * (destSampleRate / 8000)];
}

PCMFileSink::~PCMFileSink() {
    delete[] fPCMBuffer;
    delete[] fFileName;
    if (fSpeaker != NULL)
        delete fSpeaker;
}

PCMFileSink* PCMFileSink::createNew(UsageEnvironment& env,
                                    char const* fileName, int destSampleRate,
                                    int srcLaw, Boolean enableSpeaker,
                                    unsigned bufferSize) {

    if ((destSampleRate != 8000) && (destSampleRate != 16000)) {
        fprintf(stderr, "PCMFileSink::createNew(): The sample rate is not supported\n");
        return NULL;
    }

    // DESCRIBE/SETUP must not open a FIFO or activate the camera speaker.
    return new PCMFileSink(env, fileName, destSampleRate, srcLaw, enableSpeaker, bufferSize);
}

Boolean PCMFileSink::continuePlaying() {
    // Call parent
    return FileSink::continuePlaying();
}

void PCMFileSink::addData(unsigned char* data, unsigned dataSize,
                          struct timeval presentationTime) {
    if (data == NULL || dataSize == 0 || dataSize > fBufferSize) return;
    // A failed lock must drop the packet, never mix it with TTS or local clips.
    if (fEnableSpeaker && (fSpeaker == NULL || fSpeaker->switchSpeaker(SPEAKER_ON) < 0)) return;
    if (fOutFid == NULL) {
        int fd = open(fFileName, O_WRONLY | O_NONBLOCK);
        if (fd >= 0) {
            fOutFid = fdopen(fd, "wb");
            if (fOutFid == NULL) ::close(fd);
        }
        if (fOutFid == NULL) {
            if (fSpeaker != NULL) fSpeaker->switchSpeaker(SPEAKER_OFF);
            return;
        }
    }

    unsigned factor = fDestSampleRate / 8000;
    for (unsigned i = 0; i < dataSize; ++i) {
        int16_t sample = fSrcLaw == ULAW ? linear16FromuLaw(data[i]) : linear16FromaLaw(data[i]);
        for (unsigned j = 0; j < factor; ++j) fPCMBuffer[i * factor + j] = sample;
    }
    unsigned char* bytes = (unsigned char*)fPCMBuffer;
    size_t left = dataSize * factor * sizeof(int16_t);
    while (left > 0) {
        ssize_t written = write(fileno(fOutFid), bytes, left);
        if (written > 0) {
            bytes += written;
            left -= written;
        } else if (written < 0 && errno == EINTR) {
            continue;
        } else {
            // A full/missing FIFO reader must never stall every RTSP client.
            if (written < 0 && errno != EAGAIN && errno != EWOULDBLOCK) {
                fclose(fOutFid);
                fOutFid = NULL;
                if (fSpeaker != NULL) fSpeaker->switchSpeaker(SPEAKER_OFF);
            }
            break;
        }
    }
}

void PCMFileSink::afterGettingFrame(unsigned frameSize,
                                         unsigned numTruncatedBytes,
                                         struct timeval presentationTime) {

    if (debug & 16) fprintf(stderr, "%lld: PCMFileSink - afterGettingFrame\n", current_timestamp());

    if (numTruncatedBytes > 0) {
        fprintf(stderr, "PCMFileSink::afterGettingFrame(): The input frame data was too large for our buffer size (%d).\n", fBufferSize);
        fprintf(stderr, "%d bytes of trailing data was dropped! Correct this by increasing the \"bufferSize\" parameter in the \"createNew()\" call to at least %d\n",
                numTruncatedBytes, fBufferSize + numTruncatedBytes);
    }
    addData(fBuffer, frameSize, presentationTime);

    // Then try getting the next frame:
    continuePlaying();
}
