//! Building the meaning index: walk the folders the user chose, read the
//! text files in them, ask the model for each piece's vector, and write one
//! index file.
//!
//! It runs on a thread of its own, in bounded batches: a folder with a
//! million files must not fill memory, and a search must keep working while
//! the index is being built. The finished index replaces the old one only
//! when it is complete, so a failed run leaves the last good one in place.
const std = @import("std");
const nanoui = @import("nanoui");
const scope = @import("files_scope.zig");
const files = @import("files.zig");
const extract = @import("text_extract.zig");
const model = @import("embed_model.zig");
const download = @import("model_download.zig");
const runtime = @import("embed_runtime.zig");
const vectors = @import("vector_index.zig");
const Kind = vectors.Kind;
const semantic = @import("semantic_live.zig");
const Live = @import("main.zig").Live;

/// How far a build got, for the Settings row.
pub const Progress = struct {
    running: bool = false,
    files_seen: usize = 0,
    files_indexed: usize = 0,
    /// How many kept their vector from the last build, never re-embedded.
    files_reused: usize = 0,
    /// Why it stopped, when it did.
    problem: []const u8 = "",
};

/// A file's path and the pieces of it that went in.
const Found = struct {
    path: []const u8,
    /// Null for a file whose stamp matched the last build: its vector is
    /// already in `stored`, so the text is never read or embedded again.
    text: ?[]u8 = null,
    mtime: i64,
    size: u64,
    chunks: [extract.max_chunks][]const u8 = undefined,
    n: usize = 0,
    /// The float16 vector from the previous index, when unchanged.
    stored: ?[]const u8 = null,
    stored_kind: Kind = .text,

    fn free(f: *Found, gpa: std.mem.Allocator) void {
        gpa.free(f.path);
        if (f.text) |t| gpa.free(t);
    }
};

/// One piece in a batch, with the file it came from.
const Piece = struct {
    framed: []const u8,
    owner: []u8,
    file: *const Found,
};

/// One build, off the main thread.
pub const Job = struct {
    live: *Live,
    /// Filled by `start`, then owned by the job.
    dirs: [scope.max_folders][scope.max_path]u8 = undefined,
    dir_lens: [scope.max_folders]usize = @splat(0),
    dir_count: usize = 0,
    found: std.ArrayList(Found) = .empty,

    pub fn start(ctx: *anyopaque) bool {
        const l: *Live = @ptrCast(@alignCast(ctx));
        if (l.meaning_indexing.running) return false;
        if (!l.meaning.ready) return false;
        const job = l.app.gpa.create(Job) catch return false;
        job.* = .{ .live = l };
        // The folders as they are now: a change mid-build asks for another
        // run once this one is done.
        var it = l.s.files_scope.lines();
        while (it.next()) |line| {
            if (job.dir_count >= scope.max_folders) break;
            // `expand` returns the line unchanged for an absolute path, so
            // the bytes must be copied into the job's own buffer: the line
            // is a slice of the scope, which can change under us.
            const path = scope.expand(&job.dirs[job.dir_count], line) orelse continue;
            if (path.ptr != &job.dirs[job.dir_count]) {
                if (path.len > scope.max_path) continue;
                @memcpy(job.dirs[job.dir_count][0..path.len], path);
            }
            job.dir_lens[job.dir_count] = @min(path.len, scope.max_path);
            job.dir_count += 1;
        }
        if (job.dir_count == 0) {
            l.app.gpa.destroy(job);
            return false;
        }
        l.meaning_indexing = .{ .running = true };
        const thread = std.Thread.spawn(.{}, Job.run, .{job}) catch {
            l.meaning_indexing = .{};
            l.app.gpa.destroy(job);
            return false;
        };
        thread.detach();
        return true;
    }

    fn run(job: *Job) void {
        const l = job.live;
        const io = l.app.io;
        const gpa = l.app.gpa;
        defer {
            l.meaning_indexing.running = false;
            for (job.found.items) |*f| f.free(gpa);
            job.found.deinit(gpa);
            gpa.destroy(job);
            if (l.window) |w| w.redraw();
        }

        // 1. Walk the folders, keeping only readable text files. A file
        // whose stamp matches the last build keeps its vector and is not
        // read or embedded again: only changed and new files cost work.
        var previous = vectors.Index.loadFor(io, gpa, indexPathOf(), model.fingerprint) catch vectors.Index{ .gpa = gpa };
        defer previous.deinit();
        var seen: usize = 0;
        for (job.dirs[0..job.dir_count], job.dir_lens[0..job.dir_count]) |dir, dir_len| {
            if (seen >= max_files) break;
            var root = std.Io.Dir.cwd().openDir(io, dir[0..dir_len], .{ .iterate = true }) catch continue;
            defer root.close(io);
            var walker = root.walk(gpa) catch continue;
            defer walker.deinit();
            while (seen < max_files) {
                const entry = (walker.next(io) catch null) orelse break;
                if (entry.kind != .file) continue;
                seen += 1;
                l.meaning_indexing.files_seen = seen;
                if (!extract.readable(entry.basename)) continue;
                const full = std.fmt.bufPrint(&job_path_buf, "{s}/{s}", .{ dir[0..dir_len], entry.path }) catch continue;
                if (files.excluded(full, "")) continue;
                const st = std.Io.Dir.cwd().statFile(io, full, .{}) catch continue;
                if (st.size > extract.max_bytes or st.size == 0) continue;
                const stamp: vectors.Stamp = .{
                    .mtime = @intCast(@divFloor(st.mtime.nanoseconds, std.time.ns_per_s)),
                    .size = st.size,
                };
                // Unchanged since the last build: reuse its vector as is.
                if (previous.recordFor(full, stamp)) |i| {
                    const f: Found = .{
                        .path = gpa.dupe(u8, full) catch continue,
                        .mtime = stamp.mtime,
                        .size = stamp.size,
                        .stored = previous.vector(i),
                        .stored_kind = previous.kind(i),
                    };
                    job.found.append(gpa, f) catch {
                        gpa.free(f.path);
                        break;
                    };
                    continue;
                }
                const text = extract.extract(gpa, io, full) catch continue;
                var f: Found = .{ .path = gpa.dupe(u8, full) catch {
                    gpa.free(text);
                    continue;
                }, .text = text, .mtime = stamp.mtime, .size = stamp.size };
                f.n = extract.chunks(text, &f.chunks);
                if (f.n == 0) {
                    f.free(gpa);
                    continue;
                }
                job.found.append(gpa, f) catch {
                    f.free(gpa);
                    break;
                };
            }
        }
        if (job.found.items.len == 0) return;

        // 2. Embed every piece, in batches the model can take at once.
        // Share the app's server with queries: starting a second one on
        // the same port used to make both fight over it.
        const srv = &l.meaning.server;
        if (!srv.ensure(io, gpa)) {
            l.meaning_indexing.problem = "The model did not start";
            return;
        }
        var b = vectors.Builder.init(gpa, model.fingerprint) catch {
            l.meaning_indexing.problem = "Out of memory";
            return;
        };
        defer b.deinit();
        // Each piece carries the stamp of the file it came from, so a
        // batch may span files without mixing their records.
        var batch: [batch_size]Piece = undefined;
        var count: usize = 0;
        var reused: usize = 0;
        for (job.found.items) |*f| {
            // Unchanged: its vector is already right, so it goes in as is
            // and never reaches the model.
            if (f.stored) |stored| {
                b.addStored(f.path, f.stored_kind, .{ .mtime = f.mtime, .size = f.size }, stored) catch continue;
                reused += 1;
                continue;
            }
            for (f.chunks[0..f.n]) |piece| {
                var framed_buf: [extract.chunk_chars + 256]u8 = undefined;
                const framed = model.documentText(&framed_buf, std.fs.path.basename(f.path), piece) orelse continue;
                const owned = gpa.dupe(u8, framed) catch continue;
                batch[count] = .{ .framed = owned, .owner = owned, .file = f };
                count += 1;
                if (count < batch_size) continue;
                if (!flush(l, &b, &batch, &count)) return;
            }
        }
        if (count > 0) if (!flush(l, &b, &batch, &count)) return;

        // 3. Name the new index only when it is whole.
        var path_buf: [model.max_path]u8 = undefined;
        const path = semantic.indexPath(&path_buf);
        if (path.len == 0) return;
        b.save(io, path) catch {
            l.meaning_indexing.problem = "Could not save the index";
            return;
        };
        // The next search reads it.
        l.meaning.index.deinit();
        l.meaning.index = vectors.Index.loadFor(io, gpa, path, model.fingerprint) catch .{ .gpa = gpa };
        l.meaning.index_loaded = true;
        l.meaning_indexing.files_indexed = job.found.items.len;
        l.meaning_indexing.files_reused = reused;
    }
};

var job_path_buf: [scope.max_path + 256]u8 = undefined;

/// The index's path, as `semantic_live` names it. Kept here so the builder
/// can read the previous index before writing a new one.
var index_path_buf: [model.max_path]u8 = undefined;
fn indexPathOf() []const u8 {
    return semantic.indexPath(&index_path_buf);
}

pub const max_files = 20_000;
pub const batch_size = 16;

/// Embeds one batch and adds its vectors to the builder. `owners` keeps the
/// framed strings alive while the server answers.
fn flush(
    l: *Live,
    b: *vectors.Builder,
    batch: *[batch_size]Piece,
    count: *usize,
) bool {
    const gpa = l.app.gpa;
    // `count` is set to 0 on success, and a defer evaluates at scope exit:
    // capture the number to free now, not then.
    const to_free = count.*;
    defer for (batch[0..to_free]) |p| gpa.free(p.owner);
    var texts: [batch_size][]const u8 = undefined;
    for (batch[0..count.*], 0..) |p, i| texts[i] = p.framed;
    // Worst case: every byte of every framed input is a control character
    // escaped to six bytes. The old bound assumed plain text and aborted
    // the whole build on a batch full of quotes or control bytes.
    var body_buf: [runtime.jsonBound(extract.chunk_chars + 256, batch_size)]u8 = undefined;
    const body = runtime.requestBody(&body_buf, texts[0..count.*]) orelse return fail(l, "The request was too large");
    var client: std.http.Client = .{ .allocator = gpa, .io = l.app.io };
    defer client.deinit();
    var aw: std.Io.Writer.Allocating = .init(gpa);
    defer aw.deinit();
    var url_buf: [64]u8 = undefined;
    const url = std.fmt.bufPrint(&url_buf, "http://127.0.0.1:{d}/v1/embeddings", .{runtime.port}) catch return false;
    const res = client.fetch(.{
        .location = .{ .url = url },
        .method = .POST,
        .payload = body,
        .extra_headers = &.{.{ .name = "Content-Type", .value = "application/json" }},
        .response_writer = &aw.writer,
    }) catch return fail(l, "The model did not answer");
    if (res.status != .ok) return fail(l, "The model refused the request");

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    var got: [batch_size][]f32 = undefined;
    const n = runtime.parseVectors(arena.allocator(), aw.written(), &got) catch return fail(l, "A vector came back wrong");
    if (n != count.*) return fail(l, "The model answered too few vectors");
    for (got[0..n], 0..) |v, i| {
        var norm: [vectors.dimension]f32 = undefined;
        @memcpy(&norm, v[0..vectors.dimension]);
        vectors.normalize(&norm);
        const f = batch[i].file;
        b.add(f.path, .text, .{ .mtime = f.mtime, .size = f.size }, &norm) catch return fail(l, "Out of memory");
    }
    l.meaning_indexing.files_indexed += count.*;
    count.* = 0;
    return true;
}

fn fail(l: *Live, why: []const u8) bool {
    l.meaning_indexing.problem = why;
    return false;
}

test "the batch size fits one request" {
    const t = std.testing;
    try t.expect(batch_size > 1);
    try t.expect(batch_size <= 32);
    // A batch of full chunks plus framing stays under a megabyte.
    try t.expect(batch_size * (extract.chunk_chars + 256) < 1 << 20);
    try t.expect(max_files > 1000);
}
