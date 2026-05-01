//! Dev-mode TLS bootstrap: discovers/issues a mkcert-signed leaf cert
//! for `*.loop46.localhost` so `loop46 dev` can speak h2-over-TLS
//! without any external setup. No-op for production paths — explicit
//! `--tls-cert` / `--tls-key` flags always win.

const std = @import("std");
const cli = @import("cli.zig");

const MKCERT_NOT_FOUND_HINT =
    \\error: mkcert is not installed (required for --dev TLS).
    \\
    \\Install instructions:
    \\  Linux (Debian/Ubuntu):  sudo apt install libnss3-tools && \
    \\                          curl -L https://github.com/FiloSottile/mkcert/releases/latest/download/mkcert-v1.4.4-linux-amd64 -o /usr/local/bin/mkcert && \
    \\                          sudo chmod +x /usr/local/bin/mkcert
    \\  Linux (Fedora):         sudo dnf install nss-tools mkcert
    \\  macOS:                  brew install mkcert nss
    \\  Windows / other:        https://github.com/FiloSottile/mkcert#installation
    \\
    \\Then re-run `js-worker --dev`.
    \\
;

/// Default TLS cert + key paths used by `--dev` mode. Files are
/// produced by `scripts/rove-dev-setup.sh` via mkcert. Caller frees
/// all three slices.
pub fn defaultDevTlsPaths(allocator: std.mem.Allocator) !struct { cert: []u8, key: []u8, dir: []u8 } {
    const dir = try cli.defaultLoop46DataDir(allocator);
    errdefer allocator.free(dir);
    const cert = try std.fmt.allocPrint(allocator, "{s}/dev-cert.pem", .{dir});
    errdefer allocator.free(cert);
    const key = try std.fmt.allocPrint(allocator, "{s}/dev-key.pem", .{dir});
    return .{ .cert = cert, .key = key, .dir = dir };
}

/// Both files exist + are readable?
pub fn devTlsPathsExist(cert: []const u8, key: []const u8) bool {
    std.fs.cwd().access(cert, .{}) catch return false;
    std.fs.cwd().access(key, .{}) catch return false;
    return true;
}

/// Run `mkcert` once at the loop46 data dir to provision a dev TLS
/// cert + key. Idempotent — re-running over an existing setup just
/// rewrites the files. Errors with install hints if mkcert isn't on
/// PATH (a stake-in-the-ground "dev = TLS or fail" — no plaintext
/// fallback, see PLAN §1.5).
///
/// Subprocess steps (matching the legacy scripts/rove-dev-setup.sh
/// the binary now subsumes):
///   1. mkcert -CAROOT  → confirm mkcert is installed AND get the
///                        rootCA path for the symlink later.
///   2. mkcert -install → register the local CA into system + browser
///                        trust stores. Inherits stdio so sudo /
///                        Keychain prompts are visible to the user.
///   3. mkcert -cert-file <cert> -key-file <key> <SANs>
///                      → generate the actual leaf cert covering
///                        every domain our smoke + dev workflows use.
///   4. symlink mkcert-CAROOT/rootCA.pem → <data-dir>/ca-root.pem so
///                        tools that need an explicit --cacert path
///                        (the upcoming loop46 CLI in non-system-
///                        trust setups) have a stable location.
pub fn initDevTls(allocator: std.mem.Allocator, paths: anytype) !void {
    std.log.info("--dev: no TLS cert at {s} — bootstrapping via mkcert...", .{paths.dir});

    // ── 1. mkcert installed? Capture rootCA path while we're at it.
    const caroot = caroot: {
        const result = std.process.Child.run(.{
            .allocator = allocator,
            .argv = &.{ "mkcert", "-CAROOT" },
        }) catch |err| switch (err) {
            error.FileNotFound => {
                std.debug.print(MKCERT_NOT_FOUND_HINT, .{});
                std.process.exit(2);
            },
            else => return err,
        };
        defer allocator.free(result.stdout);
        defer allocator.free(result.stderr);
        if (result.term != .Exited or result.term.Exited != 0) {
            std.debug.print(
                "error: mkcert -CAROOT exited with {any}: {s}\n",
                .{ result.term, result.stderr },
            );
            std.process.exit(2);
        }
        // Strip trailing whitespace/newline.
        const trimmed = std.mem.trimRight(u8, result.stdout, " \t\r\n");
        break :caroot try allocator.dupe(u8, trimmed);
    };
    defer allocator.free(caroot);

    // ── 2. mkdir the data dir.
    std.fs.cwd().makePath(paths.dir) catch |err| {
        std.debug.print("error: cannot create {s}: {s}\n", .{ paths.dir, @errorName(err) });
        std.process.exit(2);
    };

    // ── 3. mkcert -install (idempotent; may prompt for sudo on Linux
    //       or pop a Keychain dialog on macOS — inherited stdio so the
    //       user sees the prompts).
    {
        var child = std.process.Child.init(&.{ "mkcert", "-install" }, allocator);
        const term = child.spawnAndWait() catch |err| {
            std.debug.print("error: mkcert -install failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        if (term != .Exited or term.Exited != 0) {
            std.debug.print("error: mkcert -install exited with {any}\n", .{term});
            std.process.exit(2);
        }
    }

    // ── 4. mkcert -cert-file <cert> -key-file <key> <SANs>
    //
    // SAN list covers the dev + smoke domains.
    //
    // The dev wildcard `*.loop46.localhost` mirrors production's
    // `*.loop46.me` exactly — admin lives at `app.loop46.localhost`,
    // customer instances at `{id}.loop46.localhost`, both matched by
    // the single 3-label wildcard. Subdomains of `localhost` resolve
    // to loopback per RFC 6761 so no /etc/hosts edits are needed.
    //
    // Wildcard depth caveat: OpenSSL 3.x rejects wildcards whose
    // wildcard sits directly under a TLD-like label, so `*.localhost`
    // and `*.test` would NOT validate. Our 3-label dev wildcard
    // sidesteps that; the smoke domains keep their existing 2-label
    // wildcards but smokes don't actually verify the cert
    // (they're h2c).
    {
        const argv = [_][]const u8{
            "mkcert",
            "-cert-file", paths.cert,
            "-key-file",  paths.key,
            // Dev workflow + smoke tests both use this single
            // wildcard (mirrors prod's *.loop46.me layout). Smokes
            // get isolation via separate ports + separate data
            // dirs, not via hostnames — keeping one wildcard means
            // smoke URLs read like real dev usage.
            "*.loop46.localhost",
            // Plain localhost for direct-to-IP loopback URLs.
            "localhost",
            "127.0.0.1",
            "::1",
        };
        var child = std.process.Child.init(&argv, allocator);
        const term = child.spawnAndWait() catch |err| {
            std.debug.print("error: mkcert (cert generation) failed: {s}\n", .{@errorName(err)});
            std.process.exit(2);
        };
        if (term != .Exited or term.Exited != 0) {
            std.debug.print("error: mkcert (cert generation) exited with {any}\n", .{term});
            std.process.exit(2);
        }
    }

    // ── 5. Symlink the mkcert root CA → <data-dir>/ca-root.pem.
    //       Best-effort: if the source is missing or the symlink can't
    //       be made (pre-existing regular file, FS permissions), log
    //       a warning but don't fail the launch.
    {
        const source = try std.fmt.allocPrint(allocator, "{s}/rootCA.pem", .{caroot});
        defer allocator.free(source);
        const dest = try std.fmt.allocPrint(allocator, "{s}/ca-root.pem", .{paths.dir});
        defer allocator.free(dest);

        // Remove any pre-existing file/symlink so the operation is idempotent.
        std.fs.cwd().deleteFile(dest) catch {};
        std.fs.cwd().symLink(source, dest, .{}) catch |err| {
            std.log.warn("--dev: ca-root.pem symlink ({s} → {s}) failed: {s}", .{ dest, source, @errorName(err) });
        };
    }

    std.log.info("--dev: TLS cert + key written to {s}", .{paths.dir});
}
