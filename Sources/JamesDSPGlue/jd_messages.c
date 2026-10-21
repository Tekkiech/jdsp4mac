#include "jd_messages.h"

#include <stdarg.h>
#include <stdatomic.h>
#include <string.h>

#include "Effects/eel2/stb_sprintf.h"  // implementation lives in nseel-compiler.c

#define SLOTS 64
#define SLOT_BYTES 256

typedef struct {
    _Atomic uint32_t sequence;  // == ticket + 1 when the slot holds the message for that ticket
    char text[SLOT_BYTES];
} Slot;

static Slot ring[SLOTS];
static _Atomic uint32_t head;     // next ticket to hand to a producer
static _Atomic uint32_t tail;     // next ticket the consumer reads
static _Atomic uint32_t dropped;

static void push(const char *text, size_t len)
{
    uint32_t ticket = atomic_load_explicit(&head, memory_order_relaxed);
    for (;;) {
        if (ticket - atomic_load_explicit(&tail, memory_order_acquire) >= SLOTS) {
            atomic_fetch_add_explicit(&dropped, 1, memory_order_relaxed);
            return;
        }
        if (atomic_compare_exchange_weak_explicit(&head, &ticket, ticket + 1, memory_order_acq_rel, memory_order_relaxed))
            break;
    }
    Slot *slot = &ring[ticket % SLOTS];
    if (len >= SLOT_BYTES)
        len = SLOT_BYTES - 1;
    memcpy(slot->text, text, len);
    slot->text[len] = 0;
    atomic_store_explicit(&slot->sequence, ticket + 1, memory_order_release);
}

uint32_t jd_messages_drain(jd_message_sink sink, void *context)
{
    uint32_t t = atomic_load_explicit(&tail, memory_order_relaxed);
    for (;;) {
        Slot *slot = &ring[t % SLOTS];
        if (atomic_load_explicit(&slot->sequence, memory_order_acquire) != t + 1)
            break;  // not written yet (or nothing pending)
        sink(slot->text, context);
        atomic_store_explicit(&tail, t + 1, memory_order_release);
        t++;
    }
    return atomic_exchange_explicit(&dropped, 0, memory_order_relaxed);
}

// libjamesdsp's own printf calls (built with -Dprintf=jd_lib_printf).
int jd_lib_printf(const char *format, ...)
{
    char buffer[SLOT_BYTES];
    va_list ap;
    va_start(ap, format);
    int n = stbsp_vsnprintf(buffer, sizeof buffer, format, ap);
    va_end(ap);
    if (n > 0)
        push(buffer, strlen(buffer));
    return n;
}

// EEL printf output (ns-eel.h EEL_STRING_STDOUT_WRITE with CUSTOM_CMD).
void writeCircularStringBuf(char *text)
{
    push(text, strlen(text));
}
