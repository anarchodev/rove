// SPDX-FileCopyrightText: 2026 Loop46, Inc.
// SPDX-License-Identifier: AGPL-3.0-or-later
//! The one `@cImport` of arenajs's quickjs C surface for the replay/sim
//! engine — kept in a single file so every replay module that needs a qjs
//! type shares the SAME import instance (a second `@cImport` of the same
//! header mints incompatible opaque types). The include path is wired by
//! `linkReplayEngine` in build.zig (`addIncludePath(arenajs.path("."))`).
//!
//! Most of the sim externalizes through the arenajs host vtable in plain
//! bytes (see host.zig) and needs none of this; only the package-resolving
//! module normalizer (mod_loader.zig) touches quickjs directly, to allocate
//! its resolved-specifier result with the interpreter's allocator.

pub const c = @cImport({
    @cInclude("quickjs.h");
});
