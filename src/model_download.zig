//! Getting the model onto this computer: the two GGUF files from Hugging
//! Face, the text part first, each into `<name>.partial` and only named
//! when its size and SHA-256 match what `embed_model.zig` says.
//!
//! Resumable: an interrupted download carries on from where it stopped, an
//! HTTP range, which survives Hugging Face's redirect to its CDN. Checked:
//! a file under its real name is always whole, so being there is enough.
//!
//! Nothing here touches the UI. `Progress` is what a caller shows, and
//! `run` is called on a thread of its own.
const std = @import("std");
const model = @import("embed_model.zig");

pub const Phase = enum { needed, downloading, verifying, failed, ready };

pub const Progress = struct {
    phase: Phase = .needed,
    /// Bytes on disk across both files, what an earlier run left included.
    received: u64 = 0,
    total: u64 = model.totalBytes(),
    /// The file being fetched, for the row's own words.
    file: []const u8 = "",
    /// Why it stopped, when it did: the words live in `problem_buf`, so a
    /// Progress can be copied and kept.
    problem_buf: [96]u8 = @splat(0),
    problem_len: usize = 0,

    pub fn problem(p: *const Progress) []const u8 {
        return p.problem_buf[0..p.problem_len];
    }

    pub fn fraction(p: *const Progress) f64 {
        if (p.total == 0) return 0;
        return @min(1, @as(f64, @floatFromInt(p.received)) / @as(f64, @floatFromInt(p.total)));
    }
};

/// Where the files live: beside the app's own values, in a folder of their
/// own so they can be found, moved or deleted without touching anything
/// else.
pub fn folder(buf: []u8) []const u8 {
    const home = @import("files_scope.zig").home();
    if (home.len == 0) return "";
    return std.fmt.bufPrint(buf, "{s}/.nanolight/models", .{home}) catch "";
}

/// The files that aren't there yet, in download order.
pub fn missing(io: std.Io, dir: []const u8, out: *[model.all.len]model.File) usize {
    var n: usize = 0;
    var buf: [model.max_path]u8 = undefined;
    for (model.all) |f| {
        const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, f.name }) catch continue;
        const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch {
            out[n] = f;
            n += 1;
            continue;
        };
        // A file of the wrong size is not the file: it is fetched again.
        if (st.size != f.bytes) {
            out[n] = f;
            n += 1;
        }
    }
    return n;
}

/// Whether both files are there, at their right sizes. Cheap: no hashing,
/// no network. The SHA-256 was checked when each was named.
pub fn ready(io: std.Io, dir: []const u8) bool {
    var out: [model.all.len]model.File = undefined;
    return missing(io, dir, &out) == 0;
}

/// Whether the text model is there: enough to search by words, and by the
/// meaning of text. The media encoders are a second, optional download.
pub fn textReady(io: std.Io, dir: []const u8) bool {
    var buf: [model.max_path]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ dir, model.text.name }) catch return false;
    const st = std.Io.Dir.cwd().statFile(io, path, .{}) catch return false;
    return st.size == model.text.bytes;
}

/// The SHA-256 of a file as lowercase hex, read in pieces so a 555 MB file
/// does not have to fit in memory.
pub fn sha256(io: std.Io, path: []const u8, out: *[64]u8) !void {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var buf: [1 << 20]u8 = undefined;
    var offset: u64 = 0;
    while (true) {
        const n = try file.readPositionalAll(io, &buf, offset);
        if (n == 0) break;
        hasher.update(buf[0..n]);
        offset += n;
    }
    var digest: [32]u8 = undefined;
    hasher.final(&digest);
    _ = std.fmt.bufPrint(out, "{x}", .{&digest}) catch unreachable;
}

/// One file, fetched into `<dir>/<name>.partial` and named when it checks
/// out. Returns false when it could not be finished, with `problem` set.
pub fn fetchOne(
    io: std.Io,
    gpa: std.mem.Allocator,
    dir: []const u8,
    f: model.File,
    prog: *Progress,
    problem: []u8,
) bool {
    var url_buf: [512]u8 = undefined;
    const url = model.url(&url_buf, f) orelse {
        @memcpy(problem[0.."bad url".len], "bad url");
        return false;
    };
    var path_buf: [model.max_path]u8 = undefined;
    const final = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, f.name }) catch return false;
    var partial_buf: [model.max_path]u8 = undefined;
    const partial = std.fmt.bufPrint(&partial_buf, "{s}/{s}.partial", .{ dir, f.name }) catch return false;

    // What an earlier run already wrote, to resume from.
    var have: u64 = 0;
    if (std.Io.Dir.cwd().statFile(io, partial, .{})) |st| {
        have = st.size;
        if (have > f.bytes) {
            std.Io.Dir.cwd().deleteFile(io, partial) catch {};
            have = 0;
        }
    } else |_| {}

    if (have < f.bytes) {
        prog.phase = .downloading;
        prog.file = f.name;
        if (!download(io, gpa, url, partial, have, f.bytes, prog, problem)) return false;
    }

    // Named only when it is whole: a file under its real name is trusted.
    prog.phase = .verifying;
    var hex: [64]u8 = undefined;
    sha256(io, partial, &hex) catch {
        @memcpy(problem[0.."cannot read the download".len], "cannot read the download");
        return false;
    };
    if (!std.mem.eql(u8, &hex, f.sha256)) {
        // A damaged file is thrown away: the next try starts clean.
        std.Io.Dir.cwd().deleteFile(io, partial) catch {};
        @memcpy(problem[0.."the download was damaged".len], "the download was damaged");
        return false;
    }
    std.Io.Dir.renameAbsolute(partial, final, io) catch {
        @memcpy(problem[0.."cannot keep the download".len], "cannot keep the download");
        return false;
    };
    return true;
}

/// Where a response's bytes go, from its status. A 206 continues at
/// `have`; a 200 starts over at 0; anything else writes nothing. Kept as a
/// pure function so the resume decision can be tested without a network.
pub const Placement = union(enum) {
    append: u64,
    restart,
    refuse,
};

pub fn placement(status: std.http.Status, have: u64) Placement {
    return switch (status) {
        .partial_content => .{ .append = have },
        .ok => .restart,
        else => .refuse,
    };
}

/// The bytes themselves, appended to `partial` from `have` on. A range
/// request, so an interrupted download costs only what it had not reached.
///
/// The response head is read before any body is written, so a resumed
/// download (206) appends at `have` while a full response (200, the server
/// ignored the range) starts the file over. An error response writes
/// nothing at all. `fetch` cannot do this: it streams the body into the
/// writer before returning the status.
fn download(
    io: std.Io,
    gpa: std.mem.Allocator,
    url: []const u8,
    partial: []const u8,
    have: u64,
    want: u64,
    prog: *Progress,
    problem: []u8,
) bool {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    var range_buf: [64]u8 = undefined;
    const range = std.fmt.bufPrint(&range_buf, "bytes={d}-", .{have}) catch return false;
    var headers = [_]std.http.Header{
        .{ .name = "Range", .value = range },
        .{ .name = "Accept", .value = "application/octet-stream" },
    };

    const uri = std.Uri.parse(url) catch {
        @memcpy(problem[0.."bad model address".len], "bad model address");
        return false;
    };
    var req = client.request(.GET, uri, .{
        // Range is an extra header: kept across Hugging Face's redirect to
        // its CDN, which is what makes a resumed download possible.
        .extra_headers = &headers,
        // Never ask for gzip: a compressed range would land on disk as
        // decoded bytes and fail the size and SHA-256 checks.
        .headers = .{ .accept_encoding = .omit },
    }) catch {
        @memcpy(problem[0.."the network did not answer".len], "the network did not answer");
        return false;
    };
    defer req.deinit();
    req.sendBodiless() catch {
        @memcpy(problem[0.."the network did not answer".len], "the network did not answer");
        return false;
    };

    var redirect_buf: [8 * 1024]u8 = undefined;
    var response = req.receiveHead(&redirect_buf) catch {
        @memcpy(problem[0.."the network did not answer".len], "the network did not answer");
        return false;
    };

    // Decide where the bytes go from the status, before writing any.
    const where = placement(response.head.status, have);
    const offset: u64 = switch (where) {
        .append => |at| at, // 206: keep what an earlier run wrote
        .restart => 0,      // 200: the server ignored the range
        .refuse => {
            @memcpy(problem[0.."the server refused the download".len], "the server refused the download");
            return false;
        },
    };

    const file = std.Io.Dir.cwd().createFile(io, partial, .{ .truncate = offset == 0 }) catch {
        @memcpy(problem[0.."cannot write the download".len], "cannot write the download");
        return false;
    };
    defer file.close(io);
    // FileSink writes positionally at `offset`, so no separate seek is
    // needed: a 206 appends after the bytes an earlier run left, a 200
    // overwrites from the start.
    var sink = FileSink.init(io, file, offset, prog, prog.received -| offset);
    var transfer_buf: [64]u8 = undefined;
    var decompress: std.http.Decompress = undefined;
    var decompress_buf: [std.compress.flate.max_window_len]u8 = undefined;
    const reader = response.readerDecompressing(&transfer_buf, &decompress, &decompress_buf);
    _ = reader.streamRemaining(&sink.writer) catch {
        // What arrived stays on disk; the next try resumes from it.
        @memcpy(problem[0.."the network did not answer".len], "the network did not answer");
        return false;
    };

    if (sink.offset != want) {
        @memcpy(problem[0.."the download stopped short".len], "the download stopped short");
        return false;
    }
    return true;
}

/// Writes what arrives straight to the file, and says how far it got. The
/// bytes never sit in memory as a whole.
const FileSink = struct {
    writer: std.Io.Writer,
    io: std.Io,
    file: std.Io.File,
    offset: u64,
    prog: *Progress,
    base: u64,

    const Writer = std.Io.Writer;

    fn init(io: std.Io, file: std.Io.File, offset: u64, prog: *Progress, base: u64) FileSink {
        return .{
            .writer = .{ .vtable = &vtable, .buffer = &.{} },
            .io = io,
            .file = file,
            .offset = offset,
            .prog = prog,
            .base = base,
        };
    }

    // Only `drain` is ours: `flush`, `rebase` and `sendFile` keep their
    // defaults, since the bytes arrive as they are and never from a file.
    const vtable: Writer.VTable = .{ .drain = drain };

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const s: *FileSink = @alignCast(@fieldParentPtr("writer", w));
        // What was buffered goes first; it is not counted in what is
        // returned, which is the bytes consumed from `data`.
        const buffered = w.buffered();
        if (buffered.len > 0) {
            s.file.writePositionalAll(s.io, buffered, s.offset) catch return error.WriteFailed;
            s.offset += buffered.len;
            w.end = 0;
        }
        if (data.len == 0) {
            s.prog.received = s.base + s.offset;
            return 0;
        }
        // The last slice is written `splat` times in all, not once more:
        // the contract's "repeated as necessary so that it is written
        // `splat` number of times".
        var written: usize = 0;
        for (data[0 .. data.len - 1]) |chunk| {
            if (chunk.len == 0) continue;
            s.file.writePositionalAll(s.io, chunk, s.offset) catch return error.WriteFailed;
            s.offset += chunk.len;
            written += chunk.len;
        }
        const last = data[data.len - 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            if (last.len == 0) continue;
            s.file.writePositionalAll(s.io, last, s.offset) catch return error.WriteFailed;
            s.offset += last.len;
            written += last.len;
        }
        s.prog.received = s.base + s.offset;
        return written;
    }
};

test "a file that is there at its size is not fetched again" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const dir = std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
    // Nothing there yet: both files are missing.
    var out: [model.all.len]model.File = undefined;
    try t.expectEqual(@as(usize, 2), missing(t.io, dir, &out));
    try t.expect(!ready(t.io, dir));
    // A file of the right name but the wrong size is not the file.
    try tmp.dir.writeFile(t.io, .{ .sub_path = model.text.name, .data = "short" });
    try t.expectEqual(@as(usize, 2), missing(t.io, dir, &out));
}

test "the sha256 of a file is its hex digest" {
    const t = std.testing;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, ".zig-cache/tmp/{s}/abc.txt", .{tmp.sub_path}) catch unreachable;
    try tmp.dir.writeFile(t.io, .{ .sub_path = "abc.txt", .data = "abc" });
    var hex: [64]u8 = undefined;
    try sha256(t.io, path, &hex);
    // The SHA-256 of "abc", from the standard's own test vector.
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &hex);
}

test "progress is a share of both files" {
    const t = std.testing;
    var p: Progress = .{};
    try t.expectEqual(@as(f64, 0), p.fraction());
    p.received = p.total / 2;
    try t.expectApproxEqAbs(@as(f64, 0.5), p.fraction(), 1e-9);
    p.received = p.total;
    try t.expectEqual(@as(f64, 1), p.fraction());
    // Never past the end, whatever a server says.
    p.received = p.total * 2;
    try t.expectEqual(@as(f64, 1), p.fraction());
}

test "a 206 appends at the bytes already on disk, a 200 starts over" {
    const t = std.testing;
    // The bug this catches: the old code always truncated and wrote at 0,
    // so a resumed download (206) overwrote the head with the tail.
    switch (placement(.partial_content, 1000)) {
        .append => |at| try t.expectEqual(@as(u64, 1000), at),
        else => return error.WrongPlacement,
    }
    switch (placement(.ok, 1000)) {
        .restart => {},
        else => return error.WrongPlacement,
    }
    // A zero-byte partial resumes from zero, which is the same as starting.
    switch (placement(.partial_content, 0)) {
        .append => |at| try t.expectEqual(@as(u64, 0), at),
        else => return error.WrongPlacement,
    }
}

test "an error response refuses the body, so it cannot poison the partial" {
    inline for ([_]std.http.Status{ .not_found, .forbidden, .too_many_requests, .internal_server_error }) |status| {
        switch (placement(status, 1000)) {
            .refuse => {},
            else => return error.WrongPlacement,
        }
    }
}
