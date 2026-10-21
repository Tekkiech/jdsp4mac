#ifndef JD_MESSAGES_H
#define JD_MESSAGES_H

// Text output from libjamesdsp (its printf calls) and from liveprog scripts (EEL printf) lands in
// a fixed-size, lock-free ring instead of stdout. Producers may be any thread, including the
// IOProc: pushing never allocates, locks or blocks; when the ring is full the message is dropped
// and counted. One consumer (the control plane) drains it.

#include <stddef.h>
#include <stdint.h>

typedef void (*jd_message_sink)(const char *text, void *context);

// Calls `sink` for each pending message, oldest first. Returns how many were dropped since the
// previous drain because the ring was full. Single consumer only.
uint32_t jd_messages_drain(jd_message_sink sink, void *context);

#endif
