# rove-kv quickjs-ng patch: deterministic context construction

Applied against: quickjs-ng v0.13.0 (commit 71a3c54).

## Why

rove-qjs uses the shift-js memcpy-snapshot trick: create a JS runtime +
context once, snapshot the arena bytes, then restore N times per request
via memcpy + pointer relocation. This requires context construction to
be **byte-for-byte deterministic** — two back-to-back calls to the same
init function must produce identical arena contents (modulo base-address-
dependent pointer slots).

Stock quickjs-ng violates this in three places, all inside
`JS_NewContext`'s implicit intrinsics setup:

1. `js_random_init(ctx)` seeds `ctx->random_state = js__gettimeofday_us()`,
   giving a fresh u64 each time.
2. `JS_AddPerformance(ctx)` sets `ctx->time_origin = js__now_ms()`, giving
   a fresh double each time.
3. The same `JS_AddPerformance` also stores a snapshot of `time_origin`
   as the `performance.timeOrigin` property value — a second copy of (2)
   somewhere inside the global object's property table.

Without this patch, the snapshot diff sees three "volatile" u64 slots
whose values differ between passes for reasons other than pointer
relocation, and the restore path has to classify and re-seed them with
semantic-type-aware heuristics. With this patch, all three collapse:
`random_state` and `time_origin` default to 0, and
`performance.timeOrigin` becomes a getter that reads `ctx->time_origin`
live — so after restore, writing `ctx->time_origin` updates both the
JS-visible property and the anchor for `performance.now()` through a
single write. There are zero volatile slots in the snapshot; the host
calls `JS_SetRandomSeed` and `JS_SetTimeOrigin` after restore to inject
fresh wall-clock values.

## Changes

All in `quickjs.c` + `quickjs.h`.

### 1. `quickjs.c`: `js_random_init`

Replace:
```c
static void js_random_init(JSContext *ctx)
{
    ctx->random_state = js__gettimeofday_us();
    /* the state must be non zero */
    if (ctx->random_state == 0)
        ctx->random_state = 1;
}
```
With:
```c
static void js_random_init(JSContext *ctx)
{
    /* rove-kv patch */
    ctx->random_state = 0;
}

void JS_SetRandomSeed(JSContext *ctx, uint64_t seed)
{
    ctx->random_state = seed != 0 ? seed : 1;
}
```

### 2. `quickjs.c`: `JS_AddPerformance` + `js_perf_proto_funcs`

Add a getter function above `js_perf_proto_funcs`:
```c
static JSValue js_perf_time_origin_get(JSContext *ctx, JSValueConst this_val)
{
    return js_float64(ctx->time_origin);
}
```

Add a getter entry to the proto funcs list:
```c
static const JSCFunctionListEntry js_perf_proto_funcs[] = {
    JS_CFUNC_DEF2("now", 0, js_perf_now, JS_PROP_ENUMERABLE),
    JS_CGETSET_DEF("timeOrigin", js_perf_time_origin_get, NULL),   // new
};
```

Replace `JS_AddPerformance` body with:
```c
int JS_AddPerformance(JSContext *ctx)
{
    ctx->time_origin = 0;   /* rove-kv patch: was js__now_ms() */
    JSValue performance = JS_NewObject(ctx);
    JS_SetPropertyFunctionList(ctx, performance, js_perf_proto_funcs, countof(js_perf_proto_funcs));
    /* timeOrigin is a getter in js_perf_proto_funcs; no direct definition */
    JS_DefinePropertyValueStr(ctx, ctx->global_obj, "performance",
                           js_dup(performance),
                           JS_PROP_WRITABLE | JS_PROP_ENUMERABLE | JS_PROP_CONFIGURABLE);
    JS_FreeValue(ctx, performance);
    return 0;
}

void JS_SetTimeOrigin(JSContext *ctx, double time_origin_ms)
{
    ctx->time_origin = time_origin_ms;
}
```

### 3. `quickjs.h`: declarations

Below the existing `JS_AddPerformance` declaration, add:
```c
JS_EXTERN void JS_SetRandomSeed(JSContext *ctx, uint64_t seed);
JS_EXTERN void JS_SetTimeOrigin(JSContext *ctx, double time_origin_ms);
```

## Audit on quickjs-ng upgrade

When bumping quickjs-ng:

1. Reapply this patch (search for `rove-kv patch` comments as landmarks).
2. Re-run `zig build test` — the snapshot tests will FAIL if any new
   non-deterministic slot has been introduced (volatile count > 0).
   That's the signal to investigate what new state the upgrade added and
   either patch it similarly or (if unavoidable) reintroduce a minimal
   classification step for just that one slot.
3. Compare the new `JS_AddPerformance` implementation against this
   patch — if upstream introduced more `performance.*` properties that
   cache values, those need getters too.
