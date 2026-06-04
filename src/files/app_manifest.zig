//! App-manifest seam (`docs/handler-shape.md` §8). A bundle-root
//! `manifest.json` declares an app's identity, install-time config
//! schema, declared/derived effects, and listing metadata — so apps
//! written today are born-distributable on the self-hosters
//! marketplace (a community-installable app = a tenant; see the
//! marketplace plan).
//!
//! **RESERVED + INERT.** The deploy path validates this structurally
//! (author feedback) and it ships content-addressed in the deployment
//! bundle like any static file, so it travels with the app for free.
//! Nothing *consumes* it yet: no install-time capability grants, no
//! registry, no runtime `_deploy/manifest` pointer. The shape is
//! deliberately permissive — required `name` + `version`, everything
//! else optional, unknown top-level fields accepted — while it is
//! still wet. Retrofitting later would mean re-authoring every app, so
//! the seam is reserved now even though the consumer is post-launch.

const std = @import("std");

/// The reserved bundle-root path. An app opts in by shipping this file.
pub const FILE_NAME = "manifest.json";

pub const Error = error{
    /// Top-level JSON is not an object.
    NotObject,
    /// `name` absent.
    MissingName,
    /// `name` present but not a non-empty string.
    BadName,
    /// `version` absent.
    MissingVersion,
    /// `version` present but not a non-empty string.
    BadVersion,
    /// `config` present but not an object.
    BadConfig,
    /// `effects` present but not an object.
    BadEffects,
    /// `metadata` present but not an object.
    BadMetadata,
    /// Not valid JSON.
    ParseFailed,
    OutOfMemory,
};

/// Structurally validate a bundle-root `manifest.json`.
///
/// Required: `name` (non-empty string), `version` (non-empty string).
/// Optional: `config` / `effects` / `metadata` (each an object when
/// present). Unknown top-level fields are accepted — forward-compatible
/// while the schema is still being designed.
///
/// Returns `void` on success; a specific `Error` otherwise. Nothing is
/// stored — callers use this for deploy-time author feedback only.
pub fn validate(allocator: std.mem.Allocator, json_bytes: []const u8) Error!void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_bytes, .{}) catch
        return Error.ParseFailed;
    defer parsed.deinit();

    if (parsed.value != .object) return Error.NotObject;
    const obj = parsed.value.object;

    const name = obj.get("name") orelse return Error.MissingName;
    if (name != .string or name.string.len == 0) return Error.BadName;

    const version = obj.get("version") orelse return Error.MissingVersion;
    if (version != .string or version.string.len == 0) return Error.BadVersion;

    if (obj.get("config")) |v| {
        if (v != .object) return Error.BadConfig;
    }
    if (obj.get("effects")) |v| {
        if (v != .object) return Error.BadEffects;
    }
    if (obj.get("metadata")) |v| {
        if (v != .object) return Error.BadMetadata;
    }
}

test "validate: minimal valid manifest" {
    try validate(std.testing.allocator,
        \\{"name":"link-shortener","version":"1.0.0"}
    );
}

test "validate: full valid manifest with optional objects + unknown field" {
    try validate(std.testing.allocator,
        \\{
        \\  "name": "notes",
        \\  "version": "2.3.1",
        \\  "config": { "schema": { "API_KEY": { "type": "string" } } },
        \\  "effects": { "declared": ["kv", "on.fetch"] },
        \\  "metadata": { "description": "A notes app" },
        \\  "futureField": true
        \\}
    );
}

test "validate: rejects non-object root" {
    try std.testing.expectError(Error.NotObject, validate(std.testing.allocator,
        \\["not", "an", "object"]
    ));
}

test "validate: rejects missing name" {
    try std.testing.expectError(Error.MissingName, validate(std.testing.allocator,
        \\{"version":"1.0.0"}
    ));
}

test "validate: rejects empty name" {
    try std.testing.expectError(Error.BadName, validate(std.testing.allocator,
        \\{"name":"","version":"1.0.0"}
    ));
}

test "validate: rejects non-string name" {
    try std.testing.expectError(Error.BadName, validate(std.testing.allocator,
        \\{"name":42,"version":"1.0.0"}
    ));
}

test "validate: rejects missing version" {
    try std.testing.expectError(Error.MissingVersion, validate(std.testing.allocator,
        \\{"name":"x"}
    ));
}

test "validate: rejects non-object config" {
    try std.testing.expectError(Error.BadConfig, validate(std.testing.allocator,
        \\{"name":"x","version":"1","config":"nope"}
    ));
}

test "validate: rejects non-object effects" {
    try std.testing.expectError(Error.BadEffects, validate(std.testing.allocator,
        \\{"name":"x","version":"1","effects":["kv"]}
    ));
}

test "validate: rejects malformed json" {
    try std.testing.expectError(Error.ParseFailed, validate(std.testing.allocator,
        \\{"name": "x", "version":
    ));
}
