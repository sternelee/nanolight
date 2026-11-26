//! The vectors file search keeps: one record per indexed file, its path and
//! the model's 768 numbers for it. A search by meaning reads this file and
//! scores it; only the query itself needs the model.
//!
//! One file, no database: the same promise the rest of file search makes
//! (docs/file-search.md). A record is its path, what the file was when it
//! was read, and the vector, in that order, so a scan reads them together.
//! Vectors are float16 and L2-normalized: half the bytes of float32, and a
//! dot product is the cosine.
const std = @import("std");

/// EmbeddingGemma 2's output width.
pub const dimension = 768;
pub const max_path = 4096;
/// "NLVEC1", then two bytes of room for a format that needs them.
pub const magic = [_]u8{ 'N', 'L', 'V', 'E', 'C', '1', 0, 0 };
/// The header: magic, dimension, count, the model's fingerprint, reserved.
pub const header_bytes = 8 + 4 + 4 + 16 + 4;

/// What a record is, for grouping and for the row's own label.
pub const Kind = enum(u8) {
    file = 0,
    folder = 1,
    image = 2,
    audio = 3,
    video = 4,
    text = 5,
};

/// A file as it was when it was read: a changed one is read again.
pub const Stamp = struct {
    mtime: i64 = 0,
    size: u64 = 0,
};

pub const Hit = struct {
    /// Into the index's own bytes: valid only while the index is. A caller
    /// that keeps a hit past the next `Index.deinit` must copy the path.
    path: []const u8,
    kind: Kind,
    /// The cosine, from -1 to 1 (the vectors are normalized).
    score: f32,
};

pub const Error = error{
    NotAnIndex,
    /// Made by another model or another prompt wording: its vectors are
    /// not comparable with these.
    WrongModel,
    WrongDimension,
    Truncated,
    OutOfMemory,
};

/// A vectors file, read into memory once. `bytes` owns every path `Hit`
/// points into, so an index must not move while its hits are used.
pub const Index = struct {
    bytes: []u8 = &.{},
    count: usize = 0,
    /// Where each record starts, in `bytes`.
    at: []usize = &.{},
    /// The model and prompts that made these vectors: a different one
    /// makes different vectors, and the index is read again.
    model: [16]u8 = @splat(0),
    gpa: std.mem.Allocator = std.heap.page_allocator,

    pub fn deinit(ix: *Index) void {
        if (ix.bytes.len > 0) ix.gpa.free(ix.bytes);
        if (ix.at.len > 0) ix.gpa.free(ix.at);
        ix.* = .{ .gpa = ix.gpa };
    }

    /// Reads a vectors file. A missing one is an empty index, not an error:
    /// nothing is indexed yet.
    pub fn load(io: std.Io, gpa: std.mem.Allocator, path: []const u8) !Index {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |e| switch (e) {
            error.FileNotFound => return .{ .gpa = gpa },
            else => return e,
        };
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.size < magic.len) return error.Truncated;
        const bytes = try gpa.alloc(u8, @intCast(stat.size));
        // From here the index owns `bytes`: `deinit` frees it, and the
        // error paths go through it, so nothing is freed twice.
        var ix: Index = .{ .bytes = bytes, .gpa = gpa };
        errdefer ix.deinit();
        const read = try file.readPositionalAll(io, bytes, 0);
        if (read != bytes.len) return error.Truncated;
        // Ours or not, before anything else is believed about it.
        if (!std.mem.eql(u8, bytes[0..magic.len], &magic)) return error.NotAnIndex;
        if (bytes.len < header_bytes) return error.Truncated;
        try ix.parse();
        return ix;
    }

    /// Reads a vectors file only when it was made by the same model and
    /// prompts. An index from another fingerprint is not scored against
    /// these vectors: its numbers mean something else. A missing file is
    /// still an empty index.
    pub fn loadFor(io: std.Io, gpa: std.mem.Allocator, path: []const u8, want: [16]u8) !Index {
        var ix = try load(io, gpa, path);
        errdefer ix.deinit();
        if (ix.count > 0 and !std.mem.eql(u8, &ix.model, &want)) return error.WrongModel;
        return ix;
    }

    /// The header and the record offsets, checked against the bytes.
    fn parse(ix: *Index) !void {
        const b = ix.bytes;
        if (!std.mem.eql(u8, b[0..8], &magic)) return error.NotAnIndex;
        const dim = std.mem.readInt(u32, b[8..12], .little);
        if (dim != dimension) return error.WrongDimension;
        const count = std.mem.readInt(u32, b[12..16], .little);
        @memcpy(&ix.model, b[16..32]);
        // Every record has at least its 19-byte fixed part. Check the
        // claimed count against the bytes before allocating: a 36-byte
        // file saying 0xFFFFFFFF records must not ask for 34 GB.
        if (@as(u64, count) * 19 > b.len - header_bytes) return error.Truncated;
        var at = try ix.gpa.alloc(usize, count);
        errdefer ix.gpa.free(at);
        var i: usize = 0;
        var pos: usize = header_bytes;
        while (i < count) : (i += 1) {
            at[i] = pos;
            pos += recordBytes(b, pos) orelse return error.Truncated;
        }
        ix.at = at;
        ix.count = count;
    }

    /// How long the record at `pos` is, or null when it runs past the bytes.
    fn recordBytes(b: []const u8, pos: usize) ?usize {
        if (pos + 2 > b.len) return null;
        const path_len = std.mem.readInt(u16, b[pos..][0..2], .little);
        const fixed = 2 + 1 + 8 + 8;
        const total = fixed + @as(usize, path_len) + dimension * 2;
        if (pos + total > b.len) return null;
        return total;
    }

    pub fn pathAt(ix: *const Index, i: usize) []const u8 {
        const pos = ix.at[i];
        const path_len = std.mem.readInt(u16, ix.bytes[pos..][0..2], .little);
        return ix.bytes[pos + 19 ..][0..path_len];
    }

    pub fn kind(ix: *const Index, i: usize) Kind {
        const pos = ix.at[i];
        return @enumFromInt(ix.bytes[pos + 2]);
    }

    pub fn stamp(ix: *const Index, i: usize) Stamp {
        const pos = ix.at[i];
        return .{
            .mtime = std.mem.readInt(i64, ix.bytes[pos + 3 ..][0..8], .little),
            .size = std.mem.readInt(u64, ix.bytes[pos + 11 ..][0..8], .little),
        };
    }

    /// The record's vector, as stored: `dimension` float16s.
    pub fn vector(ix: *const Index, i: usize) []const u8 {
        const pos = ix.at[i];
        const path_len = std.mem.readInt(u16, ix.bytes[pos..][0..2], .little);
        return ix.bytes[pos + 19 + path_len ..][0 .. dimension * 2];
    }

    /// The `limit` best files for a query vector, best first. The vectors
    /// are normalized, so each score is a dot product; every record is
    /// scored, which is what makes an honest "nothing close" possible.
    pub fn search(ix: *const Index, query: []const f32, out: []Hit) usize {
        // No room to keep a hit: nothing to score for. Without this the
        // `out[n - 1]` comparison below underflows on the first record.
        if (out.len == 0 or query.len != dimension) return 0;
        var n: usize = 0;
        for (0..ix.count) |i| {
            const score = dot(query, ix.vector(i));
            if (n == out.len and score <= out[n - 1].score) continue;
            var at: usize = if (n < out.len) n else out.len - 1;
            while (at > 0 and out[at - 1].score < score) : (at -= 1) out[at] = out[at - 1];
            out[at] = .{ .path = ix.pathAt(i), .kind = ix.kind(i), .score = score };
            if (n < out.len) n += 1;
        }
        return n;
    }

    /// The record for `path` when it was read at exactly `stamp`, or null.
    /// A file whose stamp moved is read again rather than trusted.
    pub fn recordFor(ix: *const Index, path: []const u8, stamp_v: Stamp) ?usize {
        for (0..ix.count) |i| {
            if (!std.mem.eql(u8, ix.pathAt(i), path)) continue;
            const s = ix.stamp(i);
            if (s.mtime == stamp_v.mtime and s.size == stamp_v.size) return i;
            return null; // the path is there but the file changed
        }
        return null;
    }

    /// The cosine of a record against a query vector, for a caller that
    /// wants one file's score rather than a ranking.
    pub fn scoreOf(ix: *const Index, i: usize, query: []const f32) f32 {
        if (query.len != dimension) return 0;
        return dot(query, ix.vector(i));
    }
};

/// A query vector against a stored one: float16 read as float32, multiplied
/// and added in one pass.
fn dot(query: []const f32, stored: []const u8) f32 {
    var sum: f32 = 0;
    var i: usize = 0;
    while (i < dimension) : (i += 1) {
        const h: f16 = @bitCast(std.mem.readInt(u16, stored[i * 2 ..][0..2], .little));
        sum += query[i] * @as(f32, @floatCast(h));
    }
    return sum;
}

/// Writes a vectors file: the header, then each record as it is added.
pub const Builder = struct {
    gpa: std.mem.Allocator,
    buf: std.ArrayList(u8) = .empty,
    count: u32 = 0,
    model: [16]u8 = @splat(0),

    pub fn init(gpa: std.mem.Allocator, model: [16]u8) !Builder {
        var b: Builder = .{ .gpa = gpa, .model = model };
        errdefer b.deinit();
        try b.buf.appendSlice(gpa, &magic);
        try b.appendInt(u32, dimension);
        try b.appendInt(u32, 0); // the count, written again by save
        try b.buf.appendSlice(gpa, &model);
        try b.appendInt(u32, 0);
        return b;
    }

    pub fn deinit(b: *Builder) void {
        b.buf.deinit(b.gpa);
        b.* = .{ .gpa = b.gpa };
    }

    fn appendInt(b: *Builder, comptime T: type, v: T) !void {
        var tmp: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &tmp, v, .little);
        try b.buf.appendSlice(b.gpa, &tmp);
    }

    /// Adds a file's vector. `vector` is `dimension` floats, normalized.
    pub fn add(b: *Builder, path: []const u8, kind: Kind, stamp_v: Stamp, vector: []const f32) !void {
        if (path.len > max_path or vector.len != dimension) return error.Truncated;
        try b.appendInt(u16, @intCast(path.len));
        try b.buf.append(b.gpa, @intFromEnum(kind));
        try b.appendInt(i64, stamp_v.mtime);
        try b.appendInt(u64, stamp_v.size);
        try b.buf.appendSlice(b.gpa, path);
        for (vector) |v| {
            const h: f16 = @floatCast(v);
            try b.appendInt(u16, @bitCast(h));
        }
        b.count += 1;
    }

    /// Adds a record whose vector is already stored as float16 bytes, as
    /// an unchanged file's is: no round trip through f32, so the numbers
    /// are exactly what the last build wrote.
    pub fn addStored(b: *Builder, path: []const u8, kind: Kind, stamp_v: Stamp, stored: []const u8) !void {
        if (path.len > max_path or stored.len != dimension * 2) return error.Truncated;
        try b.appendInt(u16, @intCast(path.len));
        try b.buf.append(b.gpa, @intFromEnum(kind));
        try b.appendInt(i64, stamp_v.mtime);
        try b.appendInt(u64, stamp_v.size);
        try b.buf.appendSlice(b.gpa, path);
        try b.buf.appendSlice(b.gpa, stored);
        b.count += 1;
    }

    /// Writes it where `path` names, atomically: the bytes go to
    /// `<path>.tmp` first and the real name only appears when they are all
    /// there. A failed or interrupted write leaves the previous index
    /// untouched, so a half index is never read.
    pub fn save(b: *Builder, io: std.Io, path: []const u8) !void {
        std.mem.writeInt(u32, b.buf.items[12..16], b.count, .little);
        var tmp_buf: [max_path + 8]u8 = undefined;
        const tmp = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{path}) catch return error.PathTooLong;
        {
            const file = try std.Io.Dir.cwd().createFile(io, tmp, .{ .truncate = true });
            defer file.close(io);
            try file.writeStreamingAll(io, b.buf.items);
        }
        // Same directory, so the rename is atomic on every platform.
        std.Io.Dir.rename(std.Io.Dir.cwd(), tmp, std.Io.Dir.cwd(), path, io) catch |e| {
            // Do not leave the half file behind for the next run to find.
            std.Io.Dir.cwd().deleteFile(io, tmp) catch {};
            return e;
        };
    }
};

/// A vector as the model gives it, made safe to store: L2-normalized, so a
/// dot product is the cosine whatever the model's own scale was.
pub fn normalize(v: []f32) void {
    var sum: f32 = 0;
    for (v) |x| sum += x * x;
    if (sum <= 0) return;
    const len = @sqrt(sum);
    for (v) |*x| x.* /= len;
}

/// A temp folder's path, as a file path the index can open.
fn tmpPath(t: *std.testing.TmpDir, buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ t.sub_path, name }) catch unreachable;
}

test "an index keeps what it was given, and finds it again" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const file = tmpPath(&tmp, &buf, "v.idx");

    var vec: [dimension]f32 = undefined;
    @memset(&vec, 0);
    vec[0] = 1;
    var b = try Builder.init(gpa, @splat('m'));
    defer b.deinit();
    try b.add("/notes/lease.pdf", .file, .{ .mtime = 1700, .size = 4096 }, &vec);
    vec[0] = 0;
    vec[1] = 1;
    try b.add("/notes/budget.xlsx", .file, .{ .mtime = 1800, .size = 8192 }, &vec);
    try b.save(t.io, file);

    var ix = try Index.load(t.io, gpa, file);
    defer ix.deinit();
    try t.expectEqual(@as(usize, 2), ix.count);
    try t.expectEqualStrings("/notes/lease.pdf", ix.pathAt(0));
    try t.expectEqualStrings("/notes/budget.xlsx", ix.pathAt(1));
    try t.expectEqual(Kind.file, ix.kind(0));
    try t.expectEqual(@as(i64, 1800), ix.stamp(1).mtime);
    try t.expectEqual(@as(u64, 8192), ix.stamp(1).size);

    // A query on the first axis finds the lease first, and only it is close.
    var q: [dimension]f32 = undefined;
    @memset(&q, 0);
    q[0] = 1;
    var hits: [4]Hit = undefined;
    const n = ix.search(&q, &hits);
    try t.expectEqual(@as(usize, 2), n);
    try t.expectEqualStrings("/notes/lease.pdf", hits[0].path);
    try t.expectApproxEqAbs(@as(f32, 1), hits[0].score, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 0), hits[1].score, 1e-3);
}

test "a missing index is empty, not an error" {
    const t = std.testing;
    var ix = try Index.load(t.io, t.allocator, "/nonexistent/nanolight/vectors.idx");
    defer ix.deinit();
    try t.expectEqual(@as(usize, 0), ix.count);
    var q: [dimension]f32 = undefined;
    @memset(&q, 0);
    var hits: [4]Hit = undefined;
    try t.expectEqual(@as(usize, 0), ix.search(&q, &hits));
}

test "a truncated or foreign file is refused, never half-read" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const file = tmpPath(&tmp, &buf, "bad.idx");

    // Not ours at all.
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bad.idx", .data = "hello, this is not an index" });
    try t.expectError(error.NotAnIndex, Index.load(t.io, gpa, file));

    // Ours, but the last record is cut short.
    var vec: [dimension]f32 = undefined;
    @memset(&vec, 0);
    vec[0] = 1;
    var b = try Builder.init(gpa, @splat('m'));
    defer b.deinit();
    try b.add("/a/very/long/path/that/will/be/cut.pdf", .file, .{}, &vec);
    try b.save(t.io, file);
    const whole = try tmp.dir.readFileAlloc(t.io, "bad.idx", gpa, .limited(1 << 20));
    defer gpa.free(whole);
    try tmp.dir.writeFile(t.io, .{ .sub_path = "bad.idx", .data = whole[0 .. whole.len - 100] });
    try t.expectError(error.Truncated, Index.load(t.io, gpa, file));
}

test "normalize makes a dot product a cosine" {
    const t = std.testing;
    var a: [dimension]f32 = undefined;
    var b: [dimension]f32 = undefined;
    @memset(&a, 0);
    @memset(&b, 0);
    a[0] = 3;
    a[1] = 4; // length 5
    b[0] = 6; // twice a: the same direction, twice the length
    b[1] = 8;
    normalize(&a);
    normalize(&b);
    // Same direction, so the cosine is 1 whatever their lengths were.
    var sum: f32 = 0;
    for (a, b) |x, y| sum += x * y;
    try t.expectApproxEqAbs(@as(f32, 1), sum, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0.6), a[0], 1e-5);
    try t.expectApproxEqAbs(@as(f32, 0.8), a[1], 1e-5);
}

test "a search keeps the best few, in order, from many" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const file = tmpPath(&tmp, &buf, "many.idx");

    var b = try Builder.init(gpa, @splat('m'));
    defer b.deinit();
    var path: [64]u8 = undefined;
    // 50 files, each on its own axis: the query on axis 0 matches the first
    // exactly and the rest not at all.
    for (0..50) |i| {
        var v: [dimension]f32 = undefined;
        @memset(&v, 0);
        v[i] = 1;
        try b.add(try std.fmt.bufPrint(&path, "/f/{d}.txt", .{i}), .file, .{}, &v);
    }
    try b.save(t.io, file);
    var ix = try Index.load(t.io, gpa, file);
    defer ix.deinit();

    var q: [dimension]f32 = undefined;
    @memset(&q, 0);
    q[0] = 1;
    var hits: [3]Hit = undefined;
    const n = ix.search(&q, &hits);
    try t.expectEqual(@as(usize, 3), n);
    try t.expectEqualStrings("/f/0.txt", hits[0].path);
    try t.expectApproxEqAbs(@as(f32, 1), hits[0].score, 1e-3);
    // The rest tie at zero, and the order among equals is stable enough.
    try t.expectApproxEqAbs(@as(f32, 0), hits[1].score, 1e-3);
}

test "save leaves no temp file and replaces an existing index" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const file = tmpPath(&tmp, &buf, "atomic.idx");
    var vec: [dimension]f32 = undefined;
    @memset(&vec, 0);
    vec[0] = 1;

    // First save: one record.
    var b = try Builder.init(gpa, @splat('m'));
    defer b.deinit();
    try b.add("/one.txt", .text, .{}, &vec);
    try b.save(t.io, file);
    {
        var ix = try Index.load(t.io, gpa, file);
        defer ix.deinit();
        try t.expectEqual(@as(usize, 1), ix.count);
    }
    // The temp name is gone once the real one appears.
    var tmp_buf: [300]u8 = undefined;
    const tmp_name = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{file}) catch unreachable;
    try t.expectError(error.FileNotFound, std.Io.Dir.cwd().statFile(t.io, tmp_name, .{}));

    // A second save replaces it with two records, still atomically.
    var b2 = try Builder.init(gpa, @splat('m'));
    defer b2.deinit();
    try b2.add("/one.txt", .text, .{}, &vec);
    try b2.add("/two.txt", .text, .{}, &vec);
    try b2.save(t.io, file);
    var ix2 = try Index.load(t.io, gpa, file);
    defer ix2.deinit();
    try t.expectEqual(@as(usize, 2), ix2.count);
    try t.expectEqualStrings("/two.txt", ix2.pathAt(1));
}

test "search with no room for a hit returns zero, not an underflow" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const file = tmpPath(&tmp, &buf, "empty-out.idx");
    var vec: [dimension]f32 = undefined;
    @memset(&vec, 0);
    vec[0] = 1;
    var b = try Builder.init(gpa, @splat('m'));
    defer b.deinit();
    try b.add("/a.txt", .text, .{}, &vec);
    try b.save(t.io, file);
    var ix = try Index.load(t.io, gpa, file);
    defer ix.deinit();
    var q: [dimension]f32 = undefined;
    @memset(&q, 0);
    q[0] = 1;
    // An empty out slice used to hit `out[n - 1]` with n == 0.
    try t.expectEqual(@as(usize, 0), ix.search(&q, &.{}));
}

test "a lying record count is refused before allocating" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    // A header-sized file claiming 0xFFFFFFFF records. The old code tried
    // to allocate ~34 GB before noticing the records were not there.
    var raw: [header_bytes]u8 = undefined;
    @memcpy(raw[0..8], &magic);
    std.mem.writeInt(u32, raw[8..12], dimension, .little);
    std.mem.writeInt(u32, raw[12..16], 0xFFFFFFFF, .little);
    @memset(raw[16..32], 0);
    std.mem.writeInt(u32, raw[32..36], 0, .little);
    var buf: [256]u8 = undefined;
    const file = tmpPath(&tmp, &buf, "lying.idx");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "lying.idx", .data = &raw });
    try t.expectError(error.Truncated, Index.load(t.io, gpa, file));
}

test "an index from another model or prompt is refused, not scored" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const file = tmpPath(&tmp, &buf, "foreign.idx");
    var vec: [dimension]f32 = undefined;
    @memset(&vec, 0);
    vec[0] = 1;
    // Built with one fingerprint...
    var b = try Builder.init(gpa, @splat('a'));
    defer b.deinit();
    try b.add("/a.txt", .text, .{}, &vec);
    try b.save(t.io, file);
    // ...and read with another: its vectors mean something else.
    try t.expectError(error.WrongModel, Index.loadFor(t.io, gpa, file, @splat('b')));
    // The matching fingerprint is accepted.
    var ix = try Index.loadFor(t.io, gpa, file, @splat('a'));
    defer ix.deinit();
    try t.expectEqual(@as(usize, 1), ix.count);
    // An empty index has no vectors to misread, so any fingerprint loads.
    var empty = try Index.loadFor(t.io, gpa, "/nonexistent/nanolight/none.idx", @splat('z'));
    defer empty.deinit();
    try t.expectEqual(@as(usize, 0), empty.count);
}

test "recordFor finds an unchanged file and refuses a changed one" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const file = tmpPath(&tmp, &buf, "stamps.idx");
    var vec: [dimension]f32 = undefined;
    @memset(&vec, 0);
    vec[0] = 1;
    var b = try Builder.init(gpa, @splat('m'));
    defer b.deinit();
    try b.add("/notes/lease.md", .text, .{ .mtime = 1700, .size = 4096 }, &vec);
    try b.save(t.io, file);
    var ix = try Index.load(t.io, gpa, file);
    defer ix.deinit();

    // Same path, same stamp: the record is reused.
    try t.expectEqual(@as(?usize, 0), ix.recordFor("/notes/lease.md", .{ .mtime = 1700, .size = 4096 }));
    // Same path, a newer mtime: the file changed, so it must be read again.
    try t.expectEqual(@as(?usize, null), ix.recordFor("/notes/lease.md", .{ .mtime = 1800, .size = 4096 }));
    // Same path, a different size: also changed.
    try t.expectEqual(@as(?usize, null), ix.recordFor("/notes/lease.md", .{ .mtime = 1700, .size = 5000 }));
    // A path that was never indexed.
    try t.expectEqual(@as(?usize, null), ix.recordFor("/notes/other.md", .{ .mtime = 1700, .size = 4096 }));
}

test "addStored moves a vector without rounding it again" {
    const t = std.testing;
    const gpa = t.allocator;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [256]u8 = undefined;
    const first = tmpPath(&tmp, &buf, "one.idx");
    var vec: [dimension]f32 = undefined;
    @memset(&vec, 0);
    vec[0] = 0.5;
    vec[1] = 0.25;
    var b = try Builder.init(gpa, @splat('m'));
    defer b.deinit();
    try b.add("/a.txt", .text, .{ .mtime = 100, .size = 10 }, &vec);
    try b.save(t.io, first);
    var ix = try Index.load(t.io, gpa, first);
    defer ix.deinit();

    // Copy the stored bytes into a new index: the numbers must be identical.
    var b2 = try Builder.init(gpa, @splat('m'));
    defer b2.deinit();
    try b2.addStored(ix.pathAt(0), ix.kind(0), ix.stamp(0), ix.vector(0));
    var buf2: [256]u8 = undefined;
    const second = tmpPath(&tmp, &buf2, "two.idx");
    try b2.save(t.io, second);
    var ix2 = try Index.load(t.io, gpa, second);
    defer ix2.deinit();
    try t.expectEqual(@as(usize, 1), ix2.count);
    try t.expectEqualSlices(u8, ix.vector(0), ix2.vector(0));
    try t.expectEqualStrings("/a.txt", ix2.pathAt(0));
    try t.expectEqual(@as(i64, 100), ix2.stamp(0).mtime);
}
