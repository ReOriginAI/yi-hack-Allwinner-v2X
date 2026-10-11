// SPDX-License-Identifier: GPL-3.0-only
// Fixed-address extension for the two hash-audited vendor recorder ELFs.
// Read encoded packet headers under the recorder's existing lock. The cached
// latest timestamp freezes after a backwards NTP step in these RMM builds.
#include <stdint.h>
#if defined(PREROLL_Y623)
#define RING_POINTER 0x28904U
#define RING_CAPACITY 0xe0000U
#define READ_LOCK 0x13f48U
#define READ_UNLOCK 0x13f9cU
#define COPY_HEADER 0x13fecU
#elif defined(PREROLL_Y28GA)
#define RING_POINTER 0x27734U
#define RING_CAPACITY 0x100000U
#define READ_LOCK 0x13508U
#define READ_UNLOCK 0x1355cU
#define COPY_HEADER 0x135acU
#else
#error An audited recorder model is required
#endif

#ifdef PREROLL_TEST
extern const uint32_t *test_ring;
extern void test_lock(void), test_unlock(void);
extern void test_copy(const void *, void *, unsigned);
#undef RING_POINTER
#undef READ_LOCK
#undef READ_UNLOCK
#undef COPY_HEADER
#define RING_POINTER ((uintptr_t)&test_ring)
#define READ_LOCK ((uintptr_t)test_lock)
#define READ_UNLOCK ((uintptr_t)test_unlock)
#define COPY_HEADER ((uintptr_t)test_copy)
#endif

__attribute__((section(".text.duration")))
uint32_t record_ring_duration(void) {
    void (*lock)(void) = (void (*)(void))READ_LOCK;
    void (*unlock)(void) = (void (*)(void))READ_UNLOCK;
    void (*copy)(const void *, void *, unsigned) =
        (void (*)(const void *, void *, unsigned))COPY_HEADER;
    lock();
    const uint32_t *base = *(const uint32_t *volatile *)RING_POINTER;
    uint32_t remaining = base[1], position = base[4];
    uint32_t first = 0, last = 0, count = 0, header[7];
    if (remaining <= RING_CAPACITY && position < RING_CAPACITY) {
        while (remaining >= sizeof(header)) {
            copy((const unsigned char *)base + 368 + position,
                 header, sizeof(header));
            if (header[0] > remaining - sizeof(header)) break;
            if (!count++) first = header[4];
            last = header[4];
            uint32_t size = header[0] + sizeof(header);
            remaining -= size;
            position += size;
            if (position >= RING_CAPACITY) position -= RING_CAPACITY;
        }
    }
    unlock();
    // Unsigned subtraction also handles the 32-bit millisecond clock wrapping.
    uint32_t span = last - first;
    return count && !remaining && span <= 120000U ? span : 0;
}
