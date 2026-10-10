// SPDX-License-Identifier: GPL-3.0-only
// Copyright (c) 2025 roleo.
#include "Speaker.hh"

#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>

Speaker::Speaker(UsageEnvironment& env, sem_t* semSpeaker)
    : fEnv(env), fSemSpeaker(semSpeaker), fIsActive(False), fReleaseTask(NULL) {}

Speaker* Speaker::createNew(UsageEnvironment& env) {
    sem_t* semaphore = sem_open(SEM_FILE, O_CREAT, 0644, 1);
    if (semaphore == SEM_FAILED) {
        env << "Error opening speaker semaphore\n";
        return NULL;
    }
    return new Speaker(env, semaphore);
}

Speaker::~Speaker() {
    switchSpeaker(SPEAKER_OFF);
    sem_close(fSemSpeaker);
}

int Speaker::openCpld() { return open(CPLD_DEV, O_RDWR); }
void Speaker::closeCpld(int fd) { close(fd); }
void Speaker::runIO(int fd, int n) { ioctl(fd, _IOC(0, DEVICE_NUM, n, 0x00), 0); }
Boolean Speaker::isActive() { return fIsActive; }

void Speaker::releaseSpeaker(void* data) {
    Speaker* speaker = (Speaker*)data;
    speaker->fReleaseTask = NULL;
    speaker->switchSpeaker(SPEAKER_OFF);
}

int Speaker::switchSpeaker(int on) {
    if (on != SPEAKER_ON && on != SPEAKER_OFF) return -2;
    if (on == SPEAKER_OFF) {
        fEnv.taskScheduler().unscheduleDelayedTask(fReleaseTask);
        if (!fIsActive) return 0;
        int fd = openCpld();
        if (fd >= 0) {
            runIO(fd, 17);
            closeCpld(fd);
        }
        fIsActive = False;
        sem_post(fSemSpeaker);
        return 0;
    }
    if (!fIsActive) {
        if (sem_trywait(fSemSpeaker) < 0) return -1;
        int fd = openCpld();
        if (fd < 0) {
            sem_post(fSemSpeaker);
            return -3;
        }
        runIO(fd, 16);
        closeCpld(fd);
        fIsActive = True;
    }
    // No speaker thread or polling while idle. This runs in the RTSP event loop.
    fEnv.taskScheduler().rescheduleDelayedTask(fReleaseTask,
                           SPEAKER_MAX_VALUE * 1000, releaseSpeaker, this);
    return 0;
}
