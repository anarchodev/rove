#ifndef RUST_FFI_SMOKE_H
#define RUST_FFI_SMOKE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

uint64_t rust_ffi_smoke_add(uint64_t a, uint64_t b);

const char *rust_ffi_smoke_version(void);

typedef int32_t (*rust_ffi_smoke_cb)(void *ctx, uint32_t value);

int32_t rust_ffi_smoke_fire(uint32_t times, void *ctx, rust_ffi_smoke_cb cb);

#ifdef __cplusplus
}
#endif

#endif
