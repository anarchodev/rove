/*
 * QuickJS dual bump-arena allocator implementation.
 *
 * Each arena owns a single contiguous buffer of fixed capacity. Allocations
 * never spill across arenas and never grow the buffer; an alloc beyond
 * capacity returns NULL (which propagates as JS OOM).
 *
 * Buffer layout:
 *   bytes  0..8  : bump cursor (size_t)
 *   bytes  8..16 : padding, keeps payload 16-byte aligned
 *   bytes 16..   : allocations, each [ 8B size ][ 8B pad ][ payload ... ]
 *
 * The cursor lives INSIDE the buffer (not in JSArena) so that a future
 * snapshot/restore step can memcpy the buffer and have the cursor relocate
 * automatically — same trick as ~/src/rove/src/qjs/snap.zig. Reset is one
 * store: write ARENA_PREFIX_LEN to the first 8 bytes.
 */
#include "qjs-arena.h"

#include <assert.h>
#include <execinfo.h>
#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define ARENA_ALIGN          16
#define ARENA_HEADER_SIZE    16   /* 8B size + 8B pad, keeps payload 16B-aligned */
#define ARENA_PREFIX_LEN     16   /* 8B cursor + 8B pad at the start of each buffer */
#define ARENA_DEFAULT_SIZE   (16u << 20)  /* 16 MiB */

typedef struct JSArena {
    uint8_t *buf;                /* owned, 16-byte aligned, capacity bytes */
    size_t capacity;
    void *last_alloc_ptr;        /* in-place realloc fast path */
    size_t last_alloc_aligned;
} JSArena;

typedef enum {
    JS_ARENA_MODE_BASE = 0,
    JS_ARENA_MODE_REQUEST = 1,
} JSArenaMode;

struct JSDualArena {
    JSArena base;
    JSArena request;
    JSArenaMode mode;
};

/* Per-thread list of registered arena base ranges; see qjs-arena.h. */
__thread struct js_arena_range js_arena_ranges[JS_ARENA_RANGES_MAX];
__thread int                   js_arena_range_count = 0;

int js_arena_register_base(const uint8_t *lo, const uint8_t *hi)
{
    if (js_arena_range_count >= JS_ARENA_RANGES_MAX)
        return -1;
    js_arena_ranges[js_arena_range_count].lo = lo;
    js_arena_ranges[js_arena_range_count].hi = hi;
    js_arena_range_count++;
    return 0;
}

void js_arena_unregister_base(const uint8_t *lo, const uint8_t *hi)
{
    for (int i = 0; i < js_arena_range_count; i++) {
        if (js_arena_ranges[i].lo == lo && js_arena_ranges[i].hi == hi) {
            /* Compact: move the last entry into this slot. */
            js_arena_range_count--;
            js_arena_ranges[i] = js_arena_ranges[js_arena_range_count];
            js_arena_ranges[js_arena_range_count].lo = NULL;
            js_arena_ranges[js_arena_range_count].hi = NULL;
            return;
        }
    }
}

/* ----- low-level arena ops ----- */

static inline size_t arena_cursor(const JSArena *a)
{
    return *(const size_t *)a->buf;
}

static inline void arena_set_cursor(JSArena *a, size_t v)
{
    *(size_t *)a->buf = v;
}

static int arena_init(JSArena *a, size_t capacity)
{
    if (capacity == 0)
        capacity = ARENA_DEFAULT_SIZE;
    /* round capacity up to page size — we use mmap for page-aligned starts
       so the thermometer can mprotect this buffer without affecting any
       neighbouring allocation. */
    long pagesz = sysconf(_SC_PAGESIZE);
    if (pagesz <= 0)
        pagesz = 4096;
    capacity = (capacity + (size_t)pagesz - 1) & ~(size_t)(pagesz - 1);
    if (capacity < ARENA_PREFIX_LEN + ARENA_HEADER_SIZE + ARENA_ALIGN)
        return -1;

    void *buf = mmap(NULL, capacity, PROT_READ | PROT_WRITE,
                     MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
    if (buf == MAP_FAILED)
        return -1;
    a->buf = buf;
    a->capacity = capacity;
    a->last_alloc_ptr = NULL;
    a->last_alloc_aligned = 0;
    arena_set_cursor(a, ARENA_PREFIX_LEN);
    return 0;
}

static void arena_destroy(JSArena *a)
{
    if (a->buf)
        munmap(a->buf, a->capacity);
    memset(a, 0, sizeof(*a));
}

static void arena_reset(JSArena *a)
{
    arena_set_cursor(a, ARENA_PREFIX_LEN);
    a->last_alloc_ptr = NULL;
    a->last_alloc_aligned = 0;
}

static void *arena_alloc(JSArena *a, size_t size)
{
    if (size == 0)
        return NULL;

    size_t aligned = (size + ARENA_ALIGN - 1) & ~(size_t)(ARENA_ALIGN - 1);
    size_t total = ARENA_HEADER_SIZE + aligned;
    size_t cursor = arena_cursor(a);
    if (cursor + total > a->capacity)
        return NULL;

    uint8_t *header = a->buf + cursor;
    *(uint64_t *)header = (uint64_t)size;
    /* second 8 bytes are padding, intentionally untouched */
    void *user_ptr = header + ARENA_HEADER_SIZE;
    arena_set_cursor(a, cursor + total);
    a->last_alloc_ptr = user_ptr;
    a->last_alloc_aligned = aligned;
    return user_ptr;
}

static inline uint64_t arena_user_size(const void *ptr)
{
    return *((const uint64_t *)ptr - 2);
}

static inline void arena_set_user_size(void *ptr, size_t size)
{
    *((uint64_t *)ptr - 2) = (uint64_t)size;
}

static void *arena_realloc(JSArena *a, void *ptr, size_t size)
{
    if (!ptr)
        return arena_alloc(a, size);
    if (size == 0)
        return NULL;

    size_t aligned = (size + ARENA_ALIGN - 1) & ~(size_t)(ARENA_ALIGN - 1);
    size_t old_size = (size_t)arena_user_size(ptr);

    if (ptr == a->last_alloc_ptr) {
        size_t old_aligned = a->last_alloc_aligned;
        size_t cursor = arena_cursor(a);
        if (aligned <= old_aligned) {
            /* shrink in place; return the freed tail to the bump region */
            arena_set_cursor(a, cursor - (old_aligned - aligned));
            a->last_alloc_aligned = aligned;
            arena_set_user_size(ptr, size);
            return ptr;
        }
        size_t delta = aligned - old_aligned;
        if (cursor + delta <= a->capacity) {
            arena_set_cursor(a, cursor + delta);
            a->last_alloc_aligned = aligned;
            arena_set_user_size(ptr, size);
            return ptr;
        }
        /* can't extend in place; fall through to copy */
    }

    void *np = arena_alloc(a, size);
    if (!np)
        return NULL;
    memcpy(np, ptr, size < old_size ? size : old_size);
    return np;
}

static bool arena_contains(const JSArena *a, const void *ptr)
{
    const uint8_t *p = ptr;
    return a->buf && p >= a->buf && p < a->buf + a->capacity;
}

/* ----- dual arena ----- */

JSDualArena *js_dual_arena_new(size_t base_size, size_t request_size)
{
    JSDualArena *da = calloc(1, sizeof(*da));
    if (!da)
        return NULL;
    if (arena_init(&da->base, base_size) < 0) {
        free(da);
        return NULL;
    }
    if (arena_init(&da->request, request_size) < 0) {
        arena_destroy(&da->base);
        free(da);
        return NULL;
    }
    da->mode = JS_ARENA_MODE_BASE;
    return da;
}

void js_dual_arena_free(JSDualArena *da)
{
    if (!da)
        return;
    const uint8_t *lo = da->base.buf;
    const uint8_t *hi = da->base.buf + da->base.capacity;
    /* If the thermometer is still active on this arena, disable it before
       tearing down — otherwise the SIGSEGV handler stays installed pointing
       into munmap'd memory. */
    js_arena_thermometer_disable_range(lo, hi);
    /* Drop this arena's range from the per-thread list so a stale
       check after teardown doesn't read freed memory. */
    js_arena_unregister_base(lo, hi);
    arena_destroy(&da->base);
    arena_destroy(&da->request);
    free(da);
}

void js_dual_arena_freeze(JSDualArena *da)
{
    da->mode = JS_ARENA_MODE_REQUEST;
    js_arena_register_base(da->base.buf, da->base.buf + da->base.capacity);
}

void js_dual_arena_reset_request(JSDualArena *da)
{
    arena_reset(&da->request);
}

bool js_dual_arena_is_frozen(const JSDualArena *da)
{
    return da->mode == JS_ARENA_MODE_REQUEST;
}

bool js_dual_arena_in_base(const JSDualArena *da, const void *ptr)
{
    return arena_contains(&da->base, ptr);
}

bool js_dual_arena_in_request(const JSDualArena *da, const void *ptr)
{
    return arena_contains(&da->request, ptr);
}

size_t js_dual_arena_base_used(const JSDualArena *da)
{
    return arena_cursor(&da->base) - ARENA_PREFIX_LEN;
}

size_t js_dual_arena_request_used(const JSDualArena *da)
{
    return arena_cursor(&da->request) - ARENA_PREFIX_LEN;
}

/* ----- JSMallocFunctions glue ----- */

static inline JSArena *active_arena(JSDualArena *da)
{
    return (da->mode == JS_ARENA_MODE_BASE) ? &da->base : &da->request;
}

static void *jda_calloc(void *opaque, size_t count, size_t size)
{
    if (count == 0 || size == 0)
        return NULL;
    if (count > (size_t)-1 / size)
        return NULL;
    size_t total = count * size;
    void *p = arena_alloc(active_arena(opaque), total);
    if (p)
        memset(p, 0, total);
    return p;
}

static void *jda_malloc(void *opaque, size_t size)
{
    return arena_alloc(active_arena(opaque), size);
}

static void jda_free(void *opaque, void *ptr)
{
    (void)opaque;
    (void)ptr;
}

static void *jda_realloc(void *opaque, void *ptr, size_t size)
{
    return arena_realloc(active_arena(opaque), ptr, size);
}

static size_t jda_usable_size(const void *ptr)
{
    if (!ptr)
        return 0;
    return (size_t)arena_user_size(ptr);
}

const JSMallocFunctions js_dual_arena_malloc_funcs = {
    jda_calloc,
    jda_malloc,
    jda_free,
    jda_realloc,
    jda_usable_size,
};

/* ----- convenience wrappers ----- */

JSRuntime *JS_NewRuntimeArena(size_t base_size, size_t request_size)
{
    JSDualArena *da = js_dual_arena_new(base_size, request_size);
    if (!da)
        return NULL;
    JSRuntime *rt = JS_NewRuntime2(&js_dual_arena_malloc_funcs, da);
    if (!rt) {
        js_dual_arena_free(da);
        return NULL;
    }
    /* Mark the runtime as arena-backed only at freeze time — pre-freeze
       it must behave as vanilla (allocate into base, use base shape_hash,
       no overlays), since request-arena machinery doesn't exist yet. */
    return rt;
}

JSDualArena *JS_GetDualArena(JSRuntime *rt)
{
    return (JSDualArena *)JS_GetMallocOpaque(rt);
}

void JS_FreezeRuntime(JSRuntime *rt)
{
    /* Order matters:
       1. Pre-force every autoinit property while we're still in BASE mode
          so the resulting writes land in base normally and no lazy init
          remains. Eliminates the prototype-method-after-reset hole.
       2. Pre-mark every base prototype's is_prototype flag so user-code
          uses of those objects as `__proto__` don't trigger a same-value
          write into snapshot memory.
       3. Flip the dual arena to request mode.
       4. Relocate JSRequestState into the request arena. */
    JS_ForceAllAutoinit(rt);
    JS_MarkAllPrototypes(rt);
    js_dual_arena_freeze(JS_GetDualArena(rt));
    /* Flip rt->is_arena now: from this point on every chokepoint takes
       the arena code path. Done AFTER js_dual_arena_freeze because the
       dual arena registers its base range in the same step, so
       js_arena_ptr_is_base() works in concert with rt->is_arena. */
    js_runtime_mark_arena(rt);
    JS_RelocateReqState(rt);
}

void JS_ResetRequestArena(JSRuntime *rt)
{
    /* Cursor → PREFIX_LEN, then re-allocate JSRequestState as the very
       first post-reset allocation. Since the cursor is rewound, the
       allocation lands at the same address it had after the initial
       JS_RelocateReqState, so rt->req (a one-time base write at freeze)
       remains valid without further base writes. JS_RelocateReqState
       is the canonical re-init path; call it here too. */
    js_dual_arena_reset_request(JS_GetDualArena(rt));
    JS_RelocateReqState(rt);
}

/* ----- thermometer -----
 *
 * Counts writes to a base-arena range via mprotect+SIGSEGV. Supports
 * multiple ranges concurrently: each enabled arena gets its own
 * (bitmap, baseline, counters) entry; the SIGSEGV handler walks the
 * list to find which entry contains si_addr, and chains to the
 * previous handler if no entry matches.
 *
 * The signal handler is process-singleton (sigaction is process-wide).
 * Two threads frobbing the same arena's counters race; that's an
 * embedder error since arena ownership is per-thread.
 */

struct therm_state {
    const uint8_t *lo;
    const uint8_t *hi;
    size_t        base_pages;
    uint8_t      *dirty_bitmap;   /* one bit per page */
    uint8_t      *baseline;       /* copy of base buffer at enable time */
    size_t        writes;
    size_t        pages_dirty;
};

#define THERM_MAX 8
static struct therm_state therm_states[THERM_MAX];
static int therm_state_count = 0;
static volatile sig_atomic_t therm_handler_installed = 0;
static struct sigaction therm_prev_sa;
static long therm_page_size = 0;

/* Diagnostic: print a backtrace for faults whose address falls in
   [therm_trace_lo, therm_trace_hi). Off by default. */
static uintptr_t therm_trace_lo = 0;
static uintptr_t therm_trace_hi = 0;

static struct therm_state *therm_find_for(uintptr_t addr)
{
    for (int i = 0; i < therm_state_count; i++) {
        struct therm_state *s = &therm_states[i];
        if (addr >= (uintptr_t)s->lo && addr < (uintptr_t)s->hi)
            return s;
    }
    return NULL;
}

static struct therm_state *therm_find_by_lo(const uint8_t *lo)
{
    for (int i = 0; i < therm_state_count; i++) {
        if (therm_states[i].lo == lo)
            return &therm_states[i];
    }
    return NULL;
}

static void therm_chain(int sig, siginfo_t *info, void *ctx)
{
    if (therm_prev_sa.sa_flags & SA_SIGINFO) {
        if (therm_prev_sa.sa_sigaction)
            therm_prev_sa.sa_sigaction(sig, info, ctx);
    } else if (therm_prev_sa.sa_handler == SIG_DFL) {
        struct sigaction dfl = {0};
        dfl.sa_handler = SIG_DFL;
        sigemptyset(&dfl.sa_mask);
        sigaction(sig, &dfl, NULL);
        raise(sig);
    } else if (therm_prev_sa.sa_handler != SIG_IGN
            && therm_prev_sa.sa_handler != NULL) {
        therm_prev_sa.sa_handler(sig);
    }
}

static void therm_sigsegv(int sig, siginfo_t *info, void *ctx)
{
    uintptr_t addr = (uintptr_t)info->si_addr;
    struct therm_state *s = therm_find_for(addr);
    if (!s) {
        therm_chain(sig, info, ctx);
        return;
    }

    s->writes++;
    size_t page_idx = (addr - (uintptr_t)s->lo) / (size_t)therm_page_size;
    size_t byte_idx = page_idx >> 3;
    uint8_t bit = (uint8_t)(1u << (page_idx & 7));
    if (!(s->dirty_bitmap[byte_idx] & bit)) {
        s->dirty_bitmap[byte_idx] |= bit;
        s->pages_dirty++;
    }

    if (therm_trace_lo && addr >= therm_trace_lo && addr < therm_trace_hi) {
        void *frames[16];
        int nframes = backtrace(frames, 16);
        char header[128];
        int hlen = snprintf(header, sizeof(header),
                            "[therm] fault at base+%zu (addr=%p)\n",
                            addr - (uintptr_t)s->lo, (void *)addr);
        write(2, header, (size_t)hlen);
        backtrace_symbols_fd(frames, nframes, 2);
    }

    void *page_addr = (void *)((uintptr_t)s->lo + page_idx * (size_t)therm_page_size);
    mprotect(page_addr, (size_t)therm_page_size, PROT_READ | PROT_WRITE);
}

static int therm_install_handler(void)
{
    if (therm_handler_installed)
        return 0;
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_flags = SA_SIGINFO;
    sa.sa_sigaction = therm_sigsegv;
    sigemptyset(&sa.sa_mask);
    if (sigaction(SIGSEGV, &sa, &therm_prev_sa) < 0)
        return -1;
    therm_handler_installed = 1;
    return 0;
}

static void therm_uninstall_handler_if_idle(void)
{
    if (!therm_handler_installed || therm_state_count > 0)
        return;
    sigaction(SIGSEGV, &therm_prev_sa, NULL);
    therm_handler_installed = 0;
}

int js_arena_thermometer_enable_range(const uint8_t *lo, const uint8_t *hi)
{
    if (!lo || !hi || lo >= hi)
        return -1;
    if (therm_find_by_lo(lo))
        return 0; /* already enabled for this range */
    if (therm_state_count >= THERM_MAX)
        return -1;

    if (therm_page_size == 0) {
        therm_page_size = sysconf(_SC_PAGESIZE);
        if (therm_page_size <= 0)
            return -1;
    }
    if ((uintptr_t)lo & (uintptr_t)(therm_page_size - 1))
        return -1; /* mmap'd ranges are page-aligned */

    size_t base_size = (size_t)(hi - lo);
    size_t base_pages = base_size / (size_t)therm_page_size;
    size_t bitmap_bytes = (base_pages + 7) / 8;
    uint8_t *bitmap = calloc(1, bitmap_bytes ? bitmap_bytes : 1);
    if (!bitmap)
        return -1;
    uint8_t *baseline = malloc(base_size);
    if (!baseline) { free(bitmap); return -1; }
    memcpy(baseline, lo, base_size);

    if (therm_install_handler() < 0) {
        free(baseline); free(bitmap); return -1;
    }
    if (mprotect((void *)lo, base_size, PROT_READ) < 0) {
        free(baseline); free(bitmap);
        therm_uninstall_handler_if_idle();
        return -1;
    }

    struct therm_state *s = &therm_states[therm_state_count++];
    s->lo = lo; s->hi = hi;
    s->base_pages = base_pages;
    s->dirty_bitmap = bitmap;
    s->baseline = baseline;
    s->writes = 0;
    s->pages_dirty = 0;
    return 0;
}

void js_arena_thermometer_disable_range(const uint8_t *lo, const uint8_t *hi)
{
    (void)hi;
    struct therm_state *s = therm_find_by_lo(lo);
    if (!s)
        return;
    size_t base_size = (size_t)(s->hi - s->lo);
    mprotect((void *)s->lo, base_size, PROT_READ | PROT_WRITE);
    free(s->dirty_bitmap);
    free(s->baseline);
    /* compact: move the last entry into this slot */
    int idx = (int)(s - therm_states);
    therm_state_count--;
    if (idx != therm_state_count)
        therm_states[idx] = therm_states[therm_state_count];
    memset(&therm_states[therm_state_count], 0, sizeof(therm_states[0]));
    therm_uninstall_handler_if_idle();
}

/* No-arg API: operate on the most-recently-enabled state. Convenient
   for the typical single-runtime test harness; for multi-runtime
   debugging, call the _range variants explicitly. */
static struct therm_state *therm_current(void)
{
    return therm_state_count > 0 ? &therm_states[therm_state_count - 1] : NULL;
}

int js_arena_thermometer_enable(void)
{
    if (js_arena_range_count == 0)
        return -1; /* freeze hasn't published any range yet */
    /* Default to the most recently registered arena. */
    struct js_arena_range *r =
        &js_arena_ranges[js_arena_range_count - 1];
    return js_arena_thermometer_enable_range(r->lo, r->hi);
}

void js_arena_thermometer_disable(void)
{
    /* Disable everything the thermometer is tracking. Used by tests
       that toggle the thermometer once at end of run. */
    while (therm_state_count > 0) {
        struct therm_state *s = &therm_states[therm_state_count - 1];
        js_arena_thermometer_disable_range(s->lo, s->hi);
    }
}

void js_arena_thermometer_reset(void)
{
    struct therm_state *s = therm_current();
    if (!s)
        return;
    size_t base_size = (size_t)(s->hi - s->lo);
    mprotect((void *)s->lo, base_size, PROT_READ);
    if (s->baseline)
        memcpy(s->baseline, s->lo, base_size);
    size_t bitmap_bytes = (s->base_pages + 7) / 8;
    memset(s->dirty_bitmap, 0, bitmap_bytes);
    s->writes = 0;
    s->pages_dirty = 0;
}

size_t js_arena_thermometer_pages(void)
{
    struct therm_state *s = therm_current();
    return s ? s->pages_dirty : 0;
}

size_t js_arena_thermometer_writes(void)
{
    struct therm_state *s = therm_current();
    return s ? s->writes : 0;
}

void js_arena_thermometer_trace_range(size_t lo_off, size_t hi_off)
{
    if (lo_off == 0 && hi_off == 0) {
        therm_trace_lo = 0;
        therm_trace_hi = 0;
        return;
    }
    struct therm_state *s = therm_current();
    if (!s)
        return;
    therm_trace_lo = (uintptr_t)s->lo + lo_off;
    therm_trace_hi = (uintptr_t)s->lo + hi_off;
}

size_t js_arena_thermometer_page_size(void)
{
    return therm_state_count > 0 ? (size_t)therm_page_size : 0;
}

size_t js_arena_thermometer_dirty_offsets(size_t *out, size_t cap)
{
    struct therm_state *s = therm_current();
    if (!s)
        return 0;
    size_t found = 0;
    for (size_t i = 0; i < s->base_pages; i++) {
        if (s->dirty_bitmap[i >> 3] & (1u << (i & 7))) {
            if (found < cap)
                out[found] = i * (size_t)therm_page_size;
            found++;
        }
    }
    return found;
}

size_t js_arena_thermometer_changed_in_page(size_t page_offset)
{
    struct therm_state *s = therm_current();
    if (!s || !s->baseline)
        return 0;
    size_t base_size = (size_t)(s->hi - s->lo);
    if (page_offset >= base_size)
        return 0;
    size_t end = page_offset + (size_t)therm_page_size;
    if (end > base_size)
        end = base_size;
    const uint8_t *live = s->lo + page_offset;
    const uint8_t *base = s->baseline + page_offset;
    size_t n = 0;
    for (size_t i = 0, len = end - page_offset; i < len; i++)
        if (live[i] != base[i])
            n++;
    return n;
}

size_t js_arena_thermometer_changed_bytes(void)
{
    struct therm_state *s = therm_current();
    if (!s)
        return 0;
    size_t total = 0;
    for (size_t i = 0; i < s->base_pages; i++) {
        if (s->dirty_bitmap[i >> 3] & (1u << (i & 7)))
            total += js_arena_thermometer_changed_in_page(i * (size_t)therm_page_size);
    }
    return total;
}

const void *js_arena_thermometer_baseline_at(size_t offset)
{
    struct therm_state *s = therm_current();
    if (!s || !s->baseline)
        return NULL;
    size_t base_size = (size_t)(s->hi - s->lo);
    if (offset >= base_size)
        return NULL;
    return s->baseline + offset;
}

size_t js_arena_thermometer_changed_byte_offsets(
    size_t page_offset, size_t *out, size_t cap)
{
    struct therm_state *s = therm_current();
    if (!s || !s->baseline)
        return 0;
    size_t base_size = (size_t)(s->hi - s->lo);
    if (page_offset >= base_size)
        return 0;
    size_t end = page_offset + (size_t)therm_page_size;
    if (end > base_size)
        end = base_size;
    const uint8_t *live = s->lo;
    const uint8_t *base = s->baseline;
    size_t found = 0;
    for (size_t i = page_offset; i < end; i++) {
        if (live[i] != base[i]) {
            if (found < cap)
                out[found] = i;
            found++;
        }
    }
    return found;
}
