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
 * Class to handle GPIOS to activate speaker
 */

#ifndef _SPEAKER_HH
#define _SPEAKER_HH

#include "UsageEnvironment.hh"
#include <semaphore.h>

#define SPEAKER_OFF 0
#define SPEAKER_ON  1

#define SPEAKER_MAX_VALUE 1000 // ms

#define DEVICE_NUM 0x70
#define CPLD_DEV "/dev/cpld_periph"
#define SEM_FILE "audio_in_fifo.lock"

class Speaker {

public:
    static Speaker* createNew(UsageEnvironment& env);
    virtual ~Speaker();
    int switchSpeaker(int on);
    Boolean isActive();

protected:
    Speaker(UsageEnvironment& env, sem_t *semSpeaker);

private:
    int openCpld();
    void closeCpld(int fd);
    void runIO(int fd, int n);
    static void releaseSpeaker(void* data);

private:
    UsageEnvironment& fEnv;
    sem_t *fSemSpeaker;
    Boolean fIsActive;
    TaskToken fReleaseTask;
};

#endif
