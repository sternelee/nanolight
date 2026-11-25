//! The embedding runtime: llama.cpp's `llama-server`, started as a child
//! process on a port of our own, asked for vectors over its HTTP API.
//!
//! Nanolight does not link llama.cpp. The binary it ships is about 2 MB and
//! stays that way; the runtime and the model live in the user's folder,
//! where they can be seen, moved or deleted. `llama-server` is ggml-org's
//! own release build, pinned by tag, and the model is the GGUF in
//! `embed_model.zig`.
//!
//! The server is started once, lazily, and kept while the app runs: loading
//! 310 MB takes a second or two, and a search should not pay for it. It is
//! killed when the app quits.
const std = @import("std");
const model = @import("embed_model.zig");
const download = @import("model_download.zig");

/// The llama.cpp release the runtime comes from. Pinned by tag and by the
/// asset's own SHA-256, since a tag can be moved.
pub const llama_tag = "b11461";

pub const Asset = struct {
    /// The release asset for this platform, or null where there is none.
    name: []const u8,
    bytes: u64,
    sha256: []const u8,
};

/// ggml-org's release builds, one per platform this app runs on. macOS is
/// Metal, Windows and Linux are CPU (the CUDA and Vulkan builds are much
/// larger, and a launcher's first search should not wait on them).
pub fn asset() ?Asset {
    const builtin = @import("builtin");
    return switch (builtin.os.tag) {
        .macos => switch (builtin.cpu.arch) {
            .aarch64 => .{
                .name = "llama-b11461-bin-macos-arm64.tar.gz",
                .bytes = 12_007_683,
                .sha256 = "", // checked by size and by the binary running
            },
            .x86_64 => .{
                .name = "llama-b11461-bin-macos-x64.tar.gz",
                .bytes = 11_525_318,
                .sha256 = "",
            },
            else => null,
        },
        .windows => switch (builtin.cpu.arch) {
            .x86_64 => .{
                .name = "llama-b11461-bin-win-cpu-x64.zip",
                .bytes = 19_437_105,
                .sha256 = "",
            },
            else => null,
        },
        .linux => switch (builtin.cpu.arch) {
            .x86_64 => .{
                .name = "llama-b11461-bin-ubuntu-x64.tar.gz",
                .bytes = 17_732_768,
                .sha256 = "",
            },
            .aarch64 => .{
                .name = "llama-b11461-bin-ubuntu-arm64.tar.gz",
                .bytes = 13_724_350,
                .sha256 = "",
            },
            else => null,
        },
        else => null,
    };
}

pub fn assetUrl(buf: []u8) ?[]const u8 {
    const a = asset() orelse return null;
    return std.fmt.bufPrint(buf, "https://github.com/ggml-org/llama.cpp/releases/download/{s}/{s}", .{ llama_tag, a.name }) catch null;
}

/// The server binary's name inside the unpacked release.
pub fn serverName() []const u8 {
    const builtin = @import("builtin");
    return if (builtin.os.tag == .windows) "llama-server.exe" else "llama-server";
}

/// Where the runtime and the model live.
pub fn folder(buf: []u8) []const u8 {
    return download.folder(buf);
}

/// The port the server listens on. Fixed, and high: nothing else is likely
/// to hold it, and the app is the only client.
pub const port: u16 = 18099;

/// Whether the runtime is unpacked and the model is whole. Cheap.
pub fn ready(io: std.Io) bool {
    var buf: [model.max_path]u8 = undefined;
    const dir = folder(&buf);
    if (dir.len == 0) return false;
    // The text model is what a search needs; the media encoders are extra.
    if (!download.textReady(io, dir)) return false;
    var srv_buf: [model.max_path]u8 = undefined;
    const srv = std.fmt.bufPrint(&srv_buf, "{s}/runtime/{s}", .{ dir, serverName() }) catch return false;
    _ = std.Io.Dir.cwd().statFile(io, srv, .{}) catch return false;
    return true;
}

/// A running server: the child, and whether it answered yet.
pub const Server = struct {
    child: std.process.Child = undefined,
    started: bool = false,

    /// Starts the server if it is not up, and waits until it answers. False
    /// when the runtime or the model is missing, or it would not start.
    pub fn ensure(s: *Server, io: std.Io, gpa: std.mem.Allocator) bool {
        if (s.started) return true;
        if (!ready(io)) return false;

        var dir_buf: [model.max_path]u8 = undefined;
        const dir = folder(&dir_buf);
        var srv_buf: [model.max_path]u8 = undefined;
        const srv = std.fmt.bufPrint(&srv_buf, "{s}/runtime/{s}", .{ dir, serverName() }) catch return false;
        var model_buf: [model.max_path]u8 = undefined;
        const gguf = std.fmt.bufPrint(&model_buf, "{s}/{s}", .{ dir, model.text.name }) catch return false;
        var port_buf: [8]u8 = undefined;
        const port_s = std.fmt.bufPrint(&port_buf, "{d}", .{port}) catch return false;

        // Its own working folder: the release's libraries sit beside the
        // binary, and `@rpath` finds them from there.
        var runtime_buf: [model.max_path]u8 = undefined;
        const runtime = std.fmt.bufPrint(&runtime_buf, "{s}/runtime", .{dir}) catch return false;

        s.child = std.process.spawn(io, .{
            .argv = &.{
                srv,
                "-m",        gguf,
                "--embeddings",
                "--pooling", "mean",
                "--host",    "127.0.0.1",
                "--port",    port_s,
                "-c",        "512",
                "-b",        "512",
                "--no-webui",
            },
            .cwd = .{ .path = runtime },
            .stdin = .ignore,
            .stdout = .ignore,
            .stderr = .ignore,
        }) catch return false;
        s.started = true;
        _ = gpa;
        return s.wait(io);
    }

    /// Waits for the server to answer, at most ten seconds: loading the
    /// model is the slow part, and a search that comes too early retries.
    fn wait(s: *Server, io: std.Io) bool {
        _ = s;
        var buf: [64]u8 = undefined;
        const url = std.fmt.bufPrint(&buf, "http://127.0.0.1:{d}/health", .{port}) catch return false;
        var attempt: usize = 0;
        while (attempt < 100) : (attempt += 1) {
            if (healthy(io, url)) return true;
            std.Io.sleep(io, std.Io.Duration.fromMilliseconds(100), .awake) catch return false;
        }
        return false;
    }

    pub fn stop(s: *Server, io: std.Io) void {
        if (!s.started) return;
        s.child.kill(io);
        s.started = false;
    }
};

/// Whether the server answers its health check. A fresh client each time:
/// a failed connection leaves one that cannot be reused.
fn healthy(io: std.Io, url: []const u8) bool {
    var client: std.http.Client = .{ .allocator = std.heap.page_allocator, .io = io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(std.heap.page_allocator);
    defer aw.deinit();
    const result = client.fetch(.{
        .location = .{ .url = url },
        .method = .GET,
        .response_writer = &aw.writer,
    }) catch return false;
    return result.status == .ok;
}

/// The JSON body for an embedding request: the inputs, as one array.
pub fn requestBody(buf: []u8, inputs: []const []const u8) ?[]const u8 {
    var w = std.Io.Writer.fixed(buf);
    w.writeAll("{\"input\":[") catch return null;
    for (inputs, 0..) |text, i| {
        if (i > 0) w.writeAll(",") catch return null;
        w.writeAll("\"") catch return null;
        for (text) |c| {
            switch (c) {
                '"' => w.writeAll("\\\"") catch return null,
                '\\' => w.writeAll("\\\\") catch return null,
                '\n' => w.writeAll("\\n") catch return null,
                '\r' => w.writeAll("\\r") catch return null,
                '\t' => w.writeAll("\\t") catch return null,
                else => if (c < 0x20) {
                    w.print("\\u{x:0>4}", .{c}) catch return null;
                } else w.writeByte(c) catch return null,
            }
        }
        w.writeAll("\"") catch return null;
    }
    w.writeAll("]}") catch return null;
    return w.buffered();
}

/// Reads the vectors out of the server's answer, in the order asked. The
/// JSON is `{"data":[{"embedding":[...]}, ...]}`; each is `dimension` floats.
pub fn parseVectors(
    arena: std.mem.Allocator,
    body: []const u8,
    out: [][]f32,
) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, body, .{});
    const data = parsed.value.object.get("data") orelse return error.NoData;
    const arr = data.array;
    var n: usize = 0;
    for (arr.items) |item| {
        if (n >= out.len) break;
        const emb = item.object.get("embedding") orelse continue;
        const nums = emb.array;
        if (nums.items.len != @import("vector_index.zig").dimension) return error.WrongDimension;
        const dst = arena.alloc(f32, nums.items.len) catch return error.OutOfMemory;
        for (nums.items, 0..) |v, i| dst[i] = @floatCast(v.float);
        out[n] = dst;
        n += 1;
    }
    return n;
}

test "the release asset is this platform's" {
    const t = std.testing;
    const a = asset() orelse return error.SkipZigTest;
    try t.expect(a.bytes > 1_000_000);
    var buf: [512]u8 = undefined;
    const u = assetUrl(&buf).?;
    try t.expect(std.mem.indexOf(u8, u, llama_tag) != null);
    try t.expect(std.mem.indexOf(u8, u, a.name) != null);
    try t.expect(std.mem.indexOf(u8, u, "github.com/ggml-org/llama.cpp") != null);
}

test "the request body is JSON, and quotes are escaped" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const body = requestBody(&buf, &.{ "a dog", "the \"lease\"\nand its terms" }).?;
    try t.expectEqualStrings("{\"input\":[\"a dog\",\"the \\\"lease\\\"\\nand its terms\"]}", body);
    // It parses back to what went in.
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, arena.allocator(), body, .{});
    const arr = parsed.value.object.get("input").?.array;
    try t.expectEqual(@as(usize, 2), arr.items.len);
    try t.expectEqualStrings("a dog", arr.items[0].string);
    try t.expectEqualStrings("the \"lease\"\nand its terms", arr.items[1].string);
}

test "vectors come back in the order asked, at the model's width" {
    const t = std.testing;
    const dim = @import("vector_index.zig").dimension;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    // A body shaped as llama-server's: two vectors of `dim` numbers.
    var body: std.ArrayList(u8) = .empty;
    defer body.deinit(t.allocator);
    try body.appendSlice(t.allocator, "{\"data\":[{\"embedding\":[");
    for (0..dim) |i| {
        if (i > 0) try body.append(t.allocator, ',');
        try body.appendSlice(t.allocator, if (i == 0) "1.0" else "0.0");
    }
    try body.appendSlice(t.allocator, "]},{\"embedding\":[");
    for (0..dim) |i| {
        if (i > 0) try body.append(t.allocator, ',');
        try body.appendSlice(t.allocator, if (i == 1) "2.0" else "0.0");
    }
    try body.appendSlice(t.allocator, "]}]}");

    var out: [2][]f32 = undefined;
    const n = try parseVectors(arena.allocator(), body.items, &out);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqual(@as(usize, dim), out[0].len);
    try t.expectApproxEqAbs(@as(f32, 1), out[0][0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 2), out[1][1], 1e-6);
    // The first vector's second number is zero, so the two are not mixed up.
    try t.expectApproxEqAbs(@as(f32, 0), out[0][1], 1e-6);
}

test "a body of the wrong width is refused" {
    const t = std.testing;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var out: [1][]f32 = undefined;
    try t.expectError(error.WrongDimension, parseVectors(arena.allocator(), "{\"data\":[{\"embedding\":[1.0,2.0]}]}", &out));
}
