/*
 * QuickJS dual bump-arena allocator
 *
 * Two-arena model for request-scoped JS execution:
 *   - base arena: holds the snapshot (runtime, prelude, prototypes); never reset.
 *   - request arena: holds per-request allocations; reset between requests.
 *
 * Each arena owns a single contiguous buffer of fixed capacity, sized at
 * js_dual_arena_new() time. Allocations beyond capacity return NULL (which
 * propagates as JS OOM); the buffer never grows.
 *
 * The active arena is selected by a mode flag flipped via js_dual_arena_freeze().
 * Allocations are bump-pointer; js_free is a no-op; js_realloc extends in place
 * when the buffer is the most recent allocation, otherwise copies. Reset of
 * the request arena is one store: the bump cursor lives at offset 0 inside
 * the buffer.
 */
#ifndef QUICKJS_ARENA_H
#define QUICKJS_ARENA_H

#include <stddef.h>
#include <stdbool.h>
#include <stdint.h>

#include "quickjs.h"

#ifdef __cplusplus
extern "C" {
#endif

typedef struct JSDualArena JSDualArena;

/* Fixed capacities for the two arenas. Pass 0 for a 16 MiB default. */
JS_EXTERN JSDualArena *js_dual_arena_new(size_t base_size,
                                         size_t request_size);
JS_EXTERN void js_dual_arena_free(JSDualArena *da);

JS_EXTERN void js_dual_arena_freeze(JSDualArena *da);
JS_EXTERN void js_dual_arena_reset_request(JSDualArena *da);
JS_EXTERN bool js_dual_arena_is_frozen(const JSDualArena *da);

JS_EXTERN bool js_dual_arena_in_base(const JSDualArena *da, const void *ptr);
JS_EXTERN bool js_dual_arena_in_request(const JSDualArena *da, const void *ptr);

JS_EXTERN size_t js_dual_arena_base_used(const JSDualArena *da);
JS_EXTERN size_t js_dual_arena_request_used(const JSDualArena *da);

/* Request-arena exhaustion record. The bump allocator is the only
 * component that knows for certain we hit the ceiling — by the time
 * the resulting OOM propagates, QJS may have mangled it into a bare
 * `null` exception (it can't allocate the Error object). So we record
 * the FIRST refused request-mode allocation at the source. Cleared by
 * js_dual_arena_reset_request, so it is strictly per-request.
 *
 * Embedders use this to distinguish "the JS code threw" (user error)
 * from "we ran out of arena" (capacity — resize / retry / 503) and to
 * surface an actionable message with real numbers. */
JS_EXTERN bool js_dual_arena_oom_hit(const JSDualArena *da);
/* Bytes the refused allocation asked for (0 if no OOM this request). */
JS_EXTERN size_t js_dual_arena_oom_requested(const JSDualArena *da);
/* Request-arena bytes in use at the moment of refusal. */
JS_EXTERN size_t js_dual_arena_oom_used(const JSDualArena *da);
/* Request-arena total capacity. */
JS_EXTERN size_t js_dual_arena_oom_limit(const JSDualArena *da);

/* Thread-local list of registered base-arena address ranges. One entry
 * per arena-backed runtime that has been frozen on this thread. Used by
 * the refcount chokepoints (and a few other per-pointer checks) to
 * recognise base-arena allocations.
 *
 * Multiple arena runtimes can coexist in the same thread, and arena
 * runtimes can coexist with vanilla (non-arena) runtimes. Vanilla
 * heap pointers fall in no registered range, so js_arena_ptr_is_base()
 * returns false for them automatically.
 *
 * The runtime must stay on its creating thread — a second thread calling
 * into it sees an unset TLS list and js_arena_ptr_is_base() reports
 * false for objects that ARE in base, which corrupts refcount semantics.
 */
#define JS_ARENA_RANGES_MAX 16
struct js_arena_range { const uint8_t *lo, *hi; };
extern __thread struct js_arena_range js_arena_ranges[JS_ARENA_RANGES_MAX];
extern __thread int                   js_arena_range_count;

static inline bool js_arena_ptr_is_base(const void *p)
{
    const uint8_t *b = (const uint8_t *)p;
    for (int i = 0; i < js_arena_range_count; i++) {
        if (b >= js_arena_ranges[i].lo && b < js_arena_ranges[i].hi)
            return true;
    }
    return false;
}

/* Internal: register/deregister an arena's base range. Called by
 * js_dual_arena_freeze and js_dual_arena_free. Returns 0 on success,
 * -1 if the per-thread range table is full (raise JS_ARENA_RANGES_MAX). */
JS_EXTERN int  js_arena_register_base(const uint8_t *lo, const uint8_t *hi);
JS_EXTERN void js_arena_unregister_base(const uint8_t *lo, const uint8_t *hi);

/* JSMallocFunctions table; pass &js_dual_arena_malloc_funcs to JS_NewRuntime2
   together with a JSDualArena* as the opaque parameter. */
extern const JSMallocFunctions js_dual_arena_malloc_funcs;

/* Convenience wrappers around the above + JS_NewRuntime2 / JS_GetMallocOpaque. */
JS_EXTERN JSRuntime *JS_NewRuntimeArena(size_t base_size,
                                        size_t request_size);
JS_EXTERN void JS_FreezeRuntime(JSRuntime *rt);
JS_EXTERN void JS_ResetRequestArena(JSRuntime *rt);
JS_EXTERN JSDualArena *JS_GetDualArena(JSRuntime *rt);

/* Internal: marks a runtime as arena-backed. Set by JS_NewRuntimeArena;
   defined in quickjs.c so it can reach the JSRuntime struct. */
JS_EXTERN void js_runtime_mark_arena(JSRuntime *rt);

/* Internal coordination — relocates the per-request mutable runtime state
   (current_exception, current_stack_frame, in_*, parent_promise) from its
   embedded backing on JSRuntime to a freshly allocated JSRequestState in
   the request arena. Called by JS_FreezeRuntime after the dual arena
   has flipped to request mode. Returns 0 on success, -1 on OOM. */
JS_EXTERN int JS_RelocateReqState(JSRuntime *rt);

/* arena: pre-force every JS_PROP_AUTOINIT property on every base JSObject
   so no lazy initialization remains by freeze time. Called by
   JS_FreezeRuntime BEFORE js_dual_arena_freeze (writes still land in
   base normally). Returns the number of autoinit properties forced.
   Eliminates the "first read of a base prototype method writes to base"
   class of post-freeze base mutations. */
JS_EXTERN int JS_ForceAllAutoinit(JSRuntime *rt);

/* arena: pre-mark every base prototype object's is_prototype flag so the
   first user code to use it as `__proto__` doesn't trigger a same-value
   write into base. Called by JS_FreezeRuntime; returns count marked. */
JS_EXTERN int JS_MarkAllPrototypes(JSRuntime *rt);

/* Page-fault-based base-arena write detector — the "CoW thermometer" in
 * ARENA_PLAN.md. After enabling, the base arena buffer is mprotect'd
 * read-only and a SIGSEGV handler counts every write that touches it.
 * The handler marks the offending page in a bitmap, makes the page
 * writable, and returns so the faulting instruction succeeds.
 *
 * Workflow:
 *   js_dual_arena_freeze(da);
 *   js_arena_thermometer_enable();
 *   for each request:
 *     js_arena_thermometer_reset();
 *     ... run request ...
 *     printf("%zu pages, %zu writes\n",
 *            js_arena_thermometer_pages(),
 *            js_arena_thermometer_writes());
 *   js_arena_thermometer_disable();
 *
 * Returns 0 on success, -1 if base hasn't been frozen yet or if installing
 * the SIGSEGV handler / mprotect failed.
 *
 * Multiple ranges supported (cap: 8) — the handler dispatches by si_addr
 * to the entry that contains the faulting address. Each range gets its
 * own bitmap / baseline / counters. Two threads frobbing the same
 * arena's counters race; arena ownership is per-thread so this is an
 * embedder error.
 *
 * The handler uses mprotect, which is not strictly async-signal-safe per
 * POSIX but works on Linux/glibc in practice — same pattern as incremental
 * GCs. The previous SIGSEGV handler is chained for faults outside any
 * registered base range.
 */
JS_EXTERN int    js_arena_thermometer_enable(void);
JS_EXTERN void   js_arena_thermometer_disable(void);
JS_EXTERN void   js_arena_thermometer_reset(void);

/* Multi-runtime variants. The thermometer can track up to 8 ranges
 * concurrently; the SIGSEGV handler dispatches to the entry whose
 * (lo, hi) contains the faulting address. The no-arg API above
 * operates on the most recently enabled range. */
JS_EXTERN int    js_arena_thermometer_enable_range(const uint8_t *lo,
                                                   const uint8_t *hi);
JS_EXTERN void   js_arena_thermometer_disable_range(const uint8_t *lo,
                                                    const uint8_t *hi);
JS_EXTERN size_t js_arena_thermometer_pages(void);
JS_EXTERN size_t js_arena_thermometer_writes(void);
/* Fills `out` (capacity `cap`) with the byte offsets within the base
 * arena buffer of each dirtied page (multiples of the system page size).
 * Returns the total number of dirty pages, which may exceed cap (in
 * which case only the first cap entries were written). */
JS_EXTERN size_t js_arena_thermometer_dirty_offsets(size_t *out, size_t cap);
/* System page size at the time enable was called, or 0 if not enabled. */
JS_EXTERN size_t js_arena_thermometer_page_size(void);

/* Byte-level signal: enable mallocs a baseline copy of the entire base
 * buffer; these helpers memcmp the live base against the baseline to
 * count distinct mutated bytes. Useful to attribute residual writes
 * inside a single dirty page to specific structures.
 *   _changed_bytes()       — total across all dirty pages
 *   _changed_in_page(off)  — within the page starting at byte `off`
 */
JS_EXTERN size_t js_arena_thermometer_changed_bytes(void);
JS_EXTERN size_t js_arena_thermometer_changed_in_page(size_t page_offset);
/* Fills `out` with the byte offsets within the base buffer (NOT within the
 * page) of distinct changed bytes inside a single dirty page. Up to `cap`.
 * Returns the total number of changed bytes (which may exceed cap). */
JS_EXTERN size_t js_arena_thermometer_changed_byte_offsets(
    size_t page_offset, size_t *out, size_t cap);

/* Reads `len` bytes starting at `offset` in the baseline snapshot
 * (state at the most recent reset). Returns NULL if not enabled or
 * out of range. */
JS_EXTERN const void *js_arena_thermometer_baseline_at(size_t offset);

/* Diagnostic: when the SIGSEGV handler faults on an address inside
 * [base+lo_off, base+hi_off), prints a backtrace. Pass (0, 0) to disable.
 * Useful to identify which call paths still mutate base. */
JS_EXTERN void js_arena_thermometer_trace_range(size_t lo_off, size_t hi_off);

/* Diagnostic: prints JSRuntime field offsets to `out` so the thermometer's
 * dirty-page offsets can be cross-referenced with which mutable field is
 * being written. Layout is process-stable. */
JS_EXTERN void JS_DumpRuntimeOffsets(JSRuntime *rt, void *out_FILE);

#ifdef __cplusplus
}
#endif

#endif /* QUICKJS_ARENA_H */
