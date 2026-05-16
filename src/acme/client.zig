//! ACME RFC 8555 client — the HTTP-01 order→finalize state machine.
//!
//! One issuance = `Client.issue(host)`: directory → nonce → account
//! (cached via the persisted account key) → newOrder → fetch authz →
//! publish the http-01 key authorization to the :80 `Responder` →
//! tell the CA we're ready → poll → finalize with a CSR → poll →
//! download the chain. Returns the leaf+chain PEM and the freshly
//! generated cert key PEM (the caller persists/replicates them).
//!
//! JWS is ES256 throughout (account key). `jwk` in the protected
//! header for newAccount, `kid` (the account URL) thereafter.
//! POST-as-GET is a JWS over an empty payload, per §6.3.

const std = @import("std");
const blob = @import("rove-blob");
const curl = blob.curl;
const acme_crypto = @import("crypto.zig");
const Responder = @import("responder.zig").Responder;

const Json = std.json;

pub const Error = error{
    Http,
    BadResponse,
    OrderFailed,
    AuthzFailed,
    Timeout,
} || acme_crypto.Error || std.mem.Allocator.Error;

pub const Issued = struct {
    cert_pem: []u8,
    key_pem: []u8,

    pub fn deinit(self: *Issued, a: std.mem.Allocator) void {
        a.free(self.cert_pem);
        a.free(self.key_pem);
        self.* = undefined;
    }
};

pub const Client = struct {
    allocator: std.mem.Allocator,
    easy: *curl.Easy,
    account_key: *const acme_crypto.Key,
    responder: *Responder,
    /// ACME directory URL — Pebble in tests, LE staging/prod in
    /// production. Everything else is discovered from it.
    directory_url: []const u8,
    contact_email: ?[]const u8 = null,
    /// Pebble uses its own throwaway root; the smoke sets this so
    /// libcurl doesn't reject the CA's API TLS. Never set in prod.
    insecure_tls: bool = false,
    /// Bounded poll: ~30 × 1s. Pebble validates near-instantly; real
    /// CAs take a few seconds.
    poll_max: u32 = 30,

    // Discovered / cached across calls.
    dir_new_nonce: []u8 = &.{},
    dir_new_account: []u8 = &.{},
    dir_new_order: []u8 = &.{},
    nonce: []u8 = &.{},
    kid: []u8 = &.{},

    pub fn deinit(self: *Client) void {
        const a = self.allocator;
        a.free(self.dir_new_nonce);
        a.free(self.dir_new_account);
        a.free(self.dir_new_order);
        a.free(self.nonce);
        a.free(self.kid);
        self.* = undefined;
    }

    pub fn issue(self: *Client, host: []const u8) Error!Issued {
        try self.loadDirectory();
        try self.freshNonce();
        try self.ensureAccount();

        // newOrder
        var order = try self.postJson(self.dir_new_order, try std.fmt.allocPrint(
            self.allocator,
            "{{\"identifiers\":[{{\"type\":\"dns\",\"value\":\"{s}\"}}]}}",
            .{host},
        ), .free_payload);
        defer order.deinit();
        const order_url = (order.header("location")) orelse return Error.BadResponse;
        const order_url_owned = try self.allocator.dupe(u8, order_url);
        defer self.allocator.free(order_url_owned);

        const authz_url = try self.firstString(order.json, &.{ "authorizations", "0" });
        defer self.allocator.free(authz_url);
        const finalize_url = try self.jsonStr(order.json, "finalize");
        defer self.allocator.free(finalize_url);

        // Fetch the authz, find the http-01 challenge.
        var authz = try self.postAsGet(authz_url);
        defer authz.deinit();
        const chal = try self.findHttp01(authz.json);
        defer self.allocator.free(chal.url);
        defer self.allocator.free(chal.token);

        // keyauth = token "." base64url(SHA256(account JWK))
        const tp = try self.account_key.thumbprint(self.allocator);
        defer self.allocator.free(tp);
        const keyauth = try std.fmt.allocPrint(self.allocator, "{s}.{s}", .{ chal.token, tp });
        defer self.allocator.free(keyauth);
        std.log.info("acme: publish challenge token={s} keyauth={s}", .{ chal.token, keyauth });
        try self.responder.put(chal.token, keyauth);
        defer self.responder.remove(chal.token);

        // Tell the CA we're ready (empty JSON object payload).
        var rdy = try self.postJson(chal.url, try self.allocator.dupe(u8, "{}"), .free_payload);
        rdy.deinit();

        // Poll the authz until "valid".
        try self.pollUntilValid(authz_url, "authz");

        // Finalize with the CSR (fresh per-host cert key).
        var cert_key = try acme_crypto.Key.generate();
        defer cert_key.deinit();
        const csr_der = try acme_crypto.buildCsrDer(self.allocator, &cert_key, host);
        defer self.allocator.free(csr_der);
        const csr_b64 = try acme_crypto.b64urlAlloc(self.allocator, csr_der);
        defer self.allocator.free(csr_b64);
        var fin = try self.postJson(finalize_url, try std.fmt.allocPrint(
            self.allocator,
            "{{\"csr\":\"{s}\"}}",
            .{csr_b64},
        ), .free_payload);
        fin.deinit();

        // Poll the order until "valid"; grab the certificate URL.
        const cert_url = try self.pollOrderForCert(order_url_owned);
        defer self.allocator.free(cert_url);

        // Download the chain (PEM, POST-as-GET).
        var certresp = try self.postAsGetRaw(cert_url);
        defer certresp.resp.deinit(self.allocator);
        const cert_pem = try self.allocator.dupe(u8, certresp.resp.body orelse return Error.BadResponse);
        errdefer self.allocator.free(cert_pem);
        const key_pem = try cert_key.privatePem(self.allocator);
        return .{ .cert_pem = cert_pem, .key_pem = key_pem };
    }

    // ── directory / nonce / account ───────────────────────────────

    fn loadDirectory(self: *Client) Error!void {
        if (self.dir_new_order.len != 0) return; // cached
        var resp = try self.get(self.directory_url);
        defer resp.deinit(self.allocator);
        if (resp.status != 200) return rejectHttp("directory", self.directory_url, &resp);
        var p = Json.parseFromSlice(Json.Value, self.allocator, resp.body orelse return Error.BadResponse, .{}) catch
            return Error.BadResponse;
        defer p.deinit();
        const o = p.value.object;
        self.dir_new_nonce = try self.allocator.dupe(u8, (o.get("newNonce") orelse return Error.BadResponse).string);
        self.dir_new_account = try self.allocator.dupe(u8, (o.get("newAccount") orelse return Error.BadResponse).string);
        self.dir_new_order = try self.allocator.dupe(u8, (o.get("newOrder") orelse return Error.BadResponse).string);
    }

    fn freshNonce(self: *Client) Error!void {
        var resp = try self.head(self.dir_new_nonce);
        defer resp.deinit(self.allocator);
        try self.takeNonce(&resp);
    }

    fn takeNonce(self: *Client, resp: *curl.Response) Error!void {
        const n = resp.header("replay-nonce") orelse return;
        self.allocator.free(self.nonce);
        self.nonce = try self.allocator.dupe(u8, n);
    }

    fn ensureAccount(self: *Client) Error!void {
        if (self.kid.len != 0) return;
        const payload = if (self.contact_email) |e|
            try std.fmt.allocPrint(self.allocator,
                "{{\"termsOfServiceAgreed\":true,\"contact\":[\"mailto:{s}\"]}}", .{e})
        else
            try self.allocator.dupe(u8, "{\"termsOfServiceAgreed\":true}");
        var resp = try self.jwsRetry(self.dir_new_account, payload, true);
        self.allocator.free(payload);
        defer resp.deinit(self.allocator);
        if (resp.status != 200 and resp.status != 201)
            return rejectHttp("newAccount", self.dir_new_account, &resp);
        const loc = resp.header("location") orelse return Error.BadResponse;
        self.kid = try self.allocator.dupe(u8, loc);
    }

    // ── JWS POST helpers ──────────────────────────────────────────

    const Parsed = struct {
        resp: curl.Response,
        json: Json.Value,
        _p: Json.Parsed(Json.Value),
        client: *Client,
        fn header(self: *Parsed, name: []const u8) ?[]const u8 {
            return self.resp.header(name);
        }
        fn deinit(self: *Parsed) void {
            self._p.deinit();
            self.resp.deinit(self.client.allocator);
        }
    };

    const PayloadOwn = enum { free_payload, keep_payload };

    /// Send a JWS, always refreshing the nonce from the response
    /// (every ACME reply carries a fresh `Replay-Nonce`), and retry
    /// on `badNonce` — RFC 8555 §6.5. Real CAs (and Pebble, which
    /// rejects ~5% of nonces deliberately) require this; without it a
    /// single rejected nonce fails the whole issuance and can poison
    /// retries via authz reuse. Caller owns the returned response and
    /// the payload.
    fn jwsRetry(self: *Client, url: []const u8, payload: []const u8, use_jwk: bool) Error!curl.Response {
        var attempt: u32 = 0;
        while (true) : (attempt += 1) {
            if (self.nonce.len == 0) try self.freshNonce();
            var resp = try self.jws(url, payload, use_jwk);
            self.takeNonce(&resp) catch {}; // best-effort; freshNonce recovers
            if (resp.status == 400 and attempt < 5) {
                const b = resp.body orelse "";
                if (std.mem.indexOf(u8, b, "badNonce") != null) {
                    std.log.info("acme: badNonce on {s}, retrying ({d})", .{ url, attempt + 1 });
                    resp.deinit(self.allocator); // fresh nonce already taken above
                    continue;
                }
            }
            return resp;
        }
    }

    /// JWS POST with a JSON body, then parse the JSON response.
    fn postJson(self: *Client, url: []const u8, payload: []u8, own: PayloadOwn) Error!Parsed {
        var resp = try self.jwsRetry(url, payload, false);
        if (own == .free_payload) self.allocator.free(payload);
        errdefer resp.deinit(self.allocator);
        if (resp.status >= 400) return rejectHttp("acme-post", url, &resp);
        const p = Json.parseFromSlice(Json.Value, self.allocator, resp.body orelse "{}", .{}) catch
            return Error.BadResponse;
        return .{ .resp = resp, .json = p.value, ._p = p, .client = self };
    }

    /// POST-as-GET (empty payload) + parse JSON.
    fn postAsGet(self: *Client, url: []const u8) Error!Parsed {
        var resp = try self.jwsRetry(url, "", false);
        errdefer resp.deinit(self.allocator);
        if (resp.status >= 400) return rejectHttp("acme-post", url, &resp);
        const p = Json.parseFromSlice(Json.Value, self.allocator, resp.body orelse "{}", .{}) catch
            return Error.BadResponse;
        return .{ .resp = resp, .json = p.value, ._p = p, .client = self };
    }

    const Raw = struct { resp: curl.Response };
    /// POST-as-GET returning the raw body (the cert chain is PEM,
    /// not JSON).
    fn postAsGetRaw(self: *Client, url: []const u8) Error!Raw {
        var resp = try self.jwsRetry(url, "", false);
        errdefer resp.deinit(self.allocator);
        if (resp.status >= 400) return rejectHttp("acme-post", url, &resp);
        return .{ .resp = resp };
    }

    /// Build + send a flattened JWS. `use_jwk` embeds the account
    /// public JWK (newAccount); otherwise `kid` (every other call).
    fn jws(self: *Client, url: []const u8, payload: []const u8, use_jwk: bool) Error!curl.Response {
        const a = self.allocator;
        const header = if (use_jwk) blk: {
            const jwk = try self.account_key.jwkJson(a);
            defer a.free(jwk);
            break :blk try std.fmt.allocPrint(a,
                "{{\"alg\":\"ES256\",\"nonce\":\"{s}\",\"url\":\"{s}\",\"jwk\":{s}}}",
                .{ self.nonce, url, jwk });
        } else try std.fmt.allocPrint(a,
            "{{\"alg\":\"ES256\",\"nonce\":\"{s}\",\"url\":\"{s}\",\"kid\":\"{s}\"}}",
            .{ self.nonce, url, self.kid });
        defer a.free(header);

        const ph = try acme_crypto.b64urlAlloc(a, header);
        defer a.free(ph);
        const pp = try acme_crypto.b64urlAlloc(a, payload);
        defer a.free(pp);
        const signing_input = try std.fmt.allocPrint(a, "{s}.{s}", .{ ph, pp });
        defer a.free(signing_input);
        const sig = try self.account_key.signEs256(a, signing_input);
        const sigb = try acme_crypto.b64urlAlloc(a, &sig);
        defer a.free(sigb);

        const body = try std.fmt.allocPrint(a,
            "{{\"protected\":\"{s}\",\"payload\":\"{s}\",\"signature\":\"{s}\"}}",
            .{ ph, pp, sigb });
        defer a.free(body);

        return self.easy.request(a, .{
            .method = .POST,
            .url = url,
            .headers = &[_]curl.Header{.{ .name = "Content-Type", .value = "application/jose+json" }},
            .body = body,
            .verify_tls = !self.insecure_tls,
        }) catch |e| {
            std.log.warn("acme: POST {s} transport error: {s}", .{ url, @errorName(e) });
            return Error.Http;
        };
    }

    fn get(self: *Client, url: []const u8) Error!curl.Response {
        return self.easy.request(self.allocator, .{
            .method = .GET, .url = url, .verify_tls = !self.insecure_tls,
        }) catch |e| {
            std.log.warn("acme: GET {s} transport error: {s}", .{ url, @errorName(e) });
            return Error.Http;
        };
    }
    fn head(self: *Client, url: []const u8) Error!curl.Response {
        return self.easy.request(self.allocator, .{
            .method = .HEAD, .url = url, .verify_tls = !self.insecure_tls,
        }) catch |e| {
            std.log.warn("acme: HEAD {s} transport error: {s}", .{ url, @errorName(e) });
            return Error.Http;
        };
    }

    /// Diagnostic: an ACME error that only says "Http" is undebuggable
    /// in production too — always log status + a body snippet at the
    /// point we reject a response.
    fn rejectHttp(what: []const u8, url: []const u8, resp: *const curl.Response) Error {
        const b = resp.body orelse "";
        std.log.warn("acme: {s} {s} → HTTP {d}: {s}", .{
            what, url, resp.status, b[0..@min(b.len, 400)],
        });
        return Error.Http;
    }

    // ── polling + JSON helpers ────────────────────────────────────

    fn pollUntilValid(self: *Client, url: []const u8, what: []const u8) Error!void {
        var i: u32 = 0;
        while (i < self.poll_max) : (i += 1) {
            var r = try self.postAsGet(url);
            defer r.deinit();
            const st = (r.json.object.get("status") orelse return Error.BadResponse).string;
            if (std.mem.eql(u8, st, "valid")) return;
            if (std.mem.eql(u8, st, "invalid")) {
                std.log.warn("acme: {s} {s} → invalid", .{ what, url });
                return Error.AuthzFailed;
            }
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
        return Error.Timeout;
    }

    /// Poll the order until valid, then return its certificate URL.
    fn pollOrderForCert(self: *Client, order_url: []const u8) Error![]u8 {
        var i: u32 = 0;
        while (i < self.poll_max) : (i += 1) {
            var r = try self.postAsGet(order_url);
            defer r.deinit();
            const st = (r.json.object.get("status") orelse return Error.BadResponse).string;
            if (std.mem.eql(u8, st, "valid")) {
                const cu = (r.json.object.get("certificate") orelse return Error.BadResponse).string;
                return self.allocator.dupe(u8, cu);
            }
            if (std.mem.eql(u8, st, "invalid")) return Error.OrderFailed;
            std.Thread.sleep(1 * std.time.ns_per_s);
        }
        return Error.Timeout;
    }

    fn jsonStr(self: *Client, v: Json.Value, key: []const u8) Error![]u8 {
        const s = (v.object.get(key) orelse return Error.BadResponse).string;
        return self.allocator.dupe(u8, s);
    }

    /// `v[path[0]][path[1]]...` as a string; path elements that are
    /// digits index an array. Only the shapes we need (authz[0]).
    fn firstString(self: *Client, v: Json.Value, path: []const []const u8) Error![]u8 {
        var cur = v;
        for (path) |seg| {
            cur = switch (cur) {
                .object => |o| o.get(seg) orelse return Error.BadResponse,
                .array => |arr| blk: {
                    const idx = std.fmt.parseInt(usize, seg, 10) catch return Error.BadResponse;
                    if (idx >= arr.items.len) return Error.BadResponse;
                    break :blk arr.items[idx];
                },
                else => return Error.BadResponse,
            };
        }
        return self.allocator.dupe(u8, cur.string);
    }

    const Challenge = struct { url: []u8, token: []u8 };
    fn findHttp01(self: *Client, authz: Json.Value) Error!Challenge {
        const chals = (authz.object.get("challenges") orelse return Error.BadResponse).array;
        for (chals.items) |ch| {
            const o = ch.object;
            const ty = (o.get("type") orelse continue).string;
            if (!std.mem.eql(u8, ty, "http-01")) continue;
            return .{
                .url = try self.allocator.dupe(u8, (o.get("url") orelse return Error.BadResponse).string),
                .token = try self.allocator.dupe(u8, (o.get("token") orelse return Error.BadResponse).string),
            };
        }
        return Error.AuthzFailed;
    }
};
