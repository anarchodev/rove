/*
 * arenajs trace emitter — fires structural events during JS execution so
 * the browser host can build a navigable timeline. See ARENA_PLAN.md
 * (or the design notes in qjs-arena-trace.c) for the why; this header
 * is just the public surface the patched QJS interpreter calls into.
 *
 * Modes:
 *   ARENA_TRACE_OFF   — every hook is a single nullable-check branch
 *   ARENA_TRACE_SCAN  — FUNC_ENTER / FUNC_EXIT / THROW events only
 *   ARENA_TRACE_DRILL — also LINE events on every source-line transition
 *
 * Stop semantics: the host's host_trace callback returns truthy to halt
 * execution. The C side raises a sentinel exception (message exactly
 * ARENA_TRACE_STOP_MSG) which arena_run_module recognises and converts
 * to a clean rc=0 return — the host knows it stopped on purpose.
 */
#ifndef QJS_ARENA_TRACE_H
#define QJS_ARENA_TRACE_H

#include <stdint.h>
#include "quickjs.h"

#ifdef __cplusplus
extern "C" {
#endif

#define ARENA_TRACE_OFF   0
#define ARENA_TRACE_SCAN  1
#define ARENA_TRACE_DRILL 2

/* Compile-time gate. Default 0 — the trace machinery is invisible to
   the native worker build (zero code, zero per-opcode cost). The
   browser-targeted qjs_arena_wasm CMake target sets this to 1 to wire
   up the real implementation. */
#ifndef ARENA_TRACE_ENABLED
#define ARENA_TRACE_ENABLED 0
#endif

struct JSFunctionBytecode;

#if ARENA_TRACE_ENABLED

/* Trace mode global, read by the interpreter hooks. Set via
   arena_trace_set_mode(). Default 0 so when tracing is built in but
   not enabled at runtime, every hook is one predictable-not-taken
   branch on this global and nothing else. */
extern int arena_trace_mode;

/* Sentinel exception message used to signal a clean host-requested
   stop. arena_run_module compares the thrown error's message against
   this string and returns 0 if it matches. */
extern const char ARENA_TRACE_STOP_MSG[];

void arena_trace_set_mode(int mode);
void arena_trace_reset(void);             /* clear name-table between runs */

/* Walk the live stack and ship the same JSON snapshot host_trace=2
   emits, via _arena_host_state. Unlike host_trace=2, does NOT raise
   the stop sentinel — execution continues. Must be called
   synchronously from inside a host_trace callback. Returns 0 on
   success, -1 if called outside an active trace event. */
int arena_trace_snapshot_here(void);

/* True when raise_stop has been called this run — host_trace returned
   truthy and we tried to throw the sentinel. arena_run_module checks
   this so it can distinguish "stop sentinel was requested but its
   allocation OOM-d" (treat as clean stop) from "unrelated exception". */
int arena_trace_stop_armed(void);

void arena_trace_func_enter(JSContext *ctx, struct JSFunctionBytecode *b);
void arena_trace_func_exit(JSContext *ctx);
void arena_trace_check_line(JSContext *ctx,
                            struct JSFunctionBytecode *b,
                            const uint8_t *pc);
void arena_trace_op_throw(JSContext *ctx,
                          struct JSFunctionBytecode *b,
                          const uint8_t *pc,
                          JSValueConst thrown);

JSAtom         js_arena_trace_bc_filename(struct JSFunctionBytecode *b);
JSAtom         js_arena_trace_bc_func_name(struct JSFunctionBytecode *b);
int            js_arena_trace_bc_resolve_line(JSContext *ctx,
                                              struct JSFunctionBytecode *b,
                                              const uint8_t *pc);

/* Stack-walker accessors. The trace module calls these to enumerate
   live frames + locals when host_trace returns 2 (stop-and-inspect).
   JSStackFrame is forward-declared so the header doesn't have to
   include quickjs.c internals. */
struct JSStackFrame;

struct JSStackFrame *js_arena_trace_top_frame(JSContext *ctx);
struct JSStackFrame *js_arena_trace_prev_frame(struct JSStackFrame *sf);
struct JSFunctionBytecode *js_arena_trace_frame_bytecode(struct JSStackFrame *sf);
const uint8_t *js_arena_trace_frame_pc(struct JSStackFrame *sf);
/* Total names enumerable on this frame = arg_count + var_count.
   Args come first (indices 0..arg_count-1), then locals. */
int  js_arena_trace_frame_var_count(struct JSStackFrame *sf,
                                    struct JSFunctionBytecode *b);
JSAtom js_arena_trace_frame_var_name(struct JSStackFrame *sf,
                                     struct JSFunctionBytecode *b,
                                     int idx);
JSValueConst js_arena_trace_frame_var_value(struct JSStackFrame *sf,
                                            struct JSFunctionBytecode *b,
                                            int idx);

/* Closure variables this function references from enclosing scopes.
   For a module body the closure_var list typically contains the
   module's own top-level `let`/`const` names too (the module body is
   itself a function and inner scopes need to capture those). */
int  js_arena_trace_frame_closure_count(struct JSFunctionBytecode *b);
JSAtom js_arena_trace_frame_closure_name(struct JSFunctionBytecode *b, int idx);
JSValueConst js_arena_trace_frame_closure_value(struct JSStackFrame *sf,
                                                struct JSFunctionBytecode *b,
                                                int idx);

#else  /* !ARENA_TRACE_ENABLED — native worker build path */

/* Compile-time constant 0. Every `if (arena_trace_mode != ARENA_TRACE_OFF)`
   in quickjs.c folds to a constant-false branch the compiler removes
   at any optimization level, so the per-opcode dispatch hook is
   physically not emitted. */
#define arena_trace_mode 0

/* Empty inline stubs so unfolded calls (if any) compile to no-ops
   without needing a linker symbol. Belt and braces — the macro above
   should keep these calls from being emitted in the first place. */
static inline void arena_trace_func_enter(JSContext *ctx, struct JSFunctionBytecode *b)
    { (void)ctx; (void)b; }
static inline void arena_trace_func_exit(JSContext *ctx) { (void)ctx; }
static inline void arena_trace_check_line(JSContext *ctx, struct JSFunctionBytecode *b,
                                          const uint8_t *pc)
    { (void)ctx; (void)b; (void)pc; }
static inline void arena_trace_op_throw(JSContext *ctx, struct JSFunctionBytecode *b,
                                        const uint8_t *pc, JSValueConst thrown)
    { (void)ctx; (void)b; (void)pc; (void)thrown; }

#endif

#ifdef __cplusplus
}
#endif

#endif
