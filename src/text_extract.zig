//! Text for the meaning index: what a file says, not just its name.
//!
//! Plain text and Markdown are read as they are. HTML is stripped of tags,
//! scripts and styles: good enough for search, not for display. PDFs are
//! read on the Mac with PDFKit (a separate file, since it needs objc).
//! Office files and scans are not read yet.
//!
//! Long text is cut into overlapping pieces so one file can answer several
//! different questions: the model's input is limited, and a single vector
//! for a whole book would blur everything in it together.
const std = @import("std");

/// A piece of a file, ready to be framed as a document and embedded.
pub const Chunk = struct {
    text: []const u8,
    /// Which piece of the file, from 0. Only the first few go in at first.
    index: usize,
};

/// The extensions read as text, lowercase without the dot.
pub const text_extensions = [_][]const u8{
    "txt", "md", "markdown", "text", "log", "csv", "json", "xml",
    "yaml", "yml", "toml", "ini", "cfg", "conf", "py", "js", "ts",
    "zig", "rs", "go", "c", "h", "cpp", "java", "rb", "sh", "sql",
    "html", "htm", "css", "rtf",
};

/// Whether this file's words can be read here.
pub fn readable(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return false;
    const e = ext[1..];
    if (std.ascii.eqlIgnoreCase(e, "pdf")) return @import("pdf_extract.zig").available();
    if (@import("office_extract.zig").readable(path)) return true;
    for (text_extensions) |known| {
        if (std.ascii.eqlIgnoreCase(e, known)) return true;
    }
    return false;
}

/// Read a file's text, cleaned up. The caller owns the result.
pub fn extract(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const ext = std.fs.path.extension(path);
    if (@import("office_extract.zig").readable(path)) {
        const raw = try @import("office_extract.zig").extract(gpa, io, path);
        const clean = try tidy(gpa, raw);
        gpa.free(raw);
        return clean;
    }
    if (ext.len >= 2 and std.ascii.eqlIgnoreCase(ext[1..], "pdf")) {
        const pdf = try @import("pdf_extract.zig").extract(gpa, path);
        // The same cleanup as any other text: collapse whitespace, keep
        // paragraph breaks, so the model sees one shape for every file.
        const clean = try tidy(gpa, pdf);
        gpa.free(pdf);
        return clean;
    }
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const st = try file.stat(io);
    // A file past this is not worth reading whole: the index keeps only so
    // much of any one file, and a giant generated file would crowd it out.
    if (st.size > max_bytes) return error.TooLarge;
    const raw = try gpa.alloc(u8, @intCast(st.size));
    errdefer gpa.free(raw);
    const n = try file.readPositionalAll(io, raw, 0);
    if (n != raw.len) return error.Truncated;

    if (ext.len >= 2 and (std.ascii.eqlIgnoreCase(ext[1..], "html") or std.ascii.eqlIgnoreCase(ext[1..], "htm"))) {
        const plain = try stripHtml(gpa, raw);
        gpa.free(raw);
        return plain;
    }
    // `tidy` returns a new buffer; the raw one is ours no longer needed.
    const clean = try tidy(gpa, raw);
    gpa.free(raw);
    return clean;
}

pub const max_bytes = 8 << 20;
/// How much of one file goes in, and the size of each piece.
pub const max_chars = 32_000;
pub const chunk_chars = 1400;
pub const chunk_overlap = 160;
/// Enough pieces to cover `max_chars` at `chunk_chars` each, with the
/// overlap: ceil(32000 / (1400 - 160)) = 26. A long document is indexed to
/// its end, not just its first pages.
pub const max_chunks = 26;

/// Collapses runs of spaces, keeps line breaks, trims the ends. The model
/// does not care about exact whitespace, and tidy text embeds more evenly.
pub fn tidy(gpa: std.mem.Allocator, raw: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = 0;
    var spaces: usize = 0;
    var lines: usize = 0;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\r' or c == '\n') {
            // At most two line breaks in a row.
            if (lines < 2 and out.items.len > 0) {
                try out.append(gpa, '\n');
                lines += 1;
            }
            spaces = 0;
            continue;
        }
        if (c == ' ' or c == '\t' or c == 0) {
            spaces += 1;
            continue;
        }
        if (spaces > 0 and out.items.len > 0 and out.items[out.items.len - 1] != '\n') try out.append(gpa, ' ');
        spaces = 0;
        lines = 0;
        try out.append(gpa, c);
    }
    return out.toOwnedSlice(gpa);
}

/// Drops HTML's script, style and head blocks, then its tags, and decodes
/// the entities that actually show up in prose. Not a parser: a search
/// index needs the words, not the document tree.
pub fn stripHtml(gpa: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    var i: usize = 0;
    var skip: ?[]const u8 = null;
    while (i < html.len) {
        if (skip) |tag| {
            // HTML5 lets `</head>` be omitted: `<body>` ends it implicitly.
            // Without this, a common HTML5 page loses its whole body.
            if (std.ascii.eqlIgnoreCase(tag, "head")) {
                if (std.mem.indexOfPos(u8, html, i, "<body")) |body_at| {
                    const after = html[body_at + 5];
                    if (after == '>' or after == ' ' or after == '\t' or after == '\r' or after == '\n') {
                        i = body_at;
                        skip = null;
                        continue;
                    }
                }
            }
            if (std.mem.indexOfPos(u8, html, i, "</")) |at| {
                const name_end = std.mem.indexOfScalarPos(u8, html, at + 2, '>') orelse break;
                const name = std.mem.trim(u8, html[at + 2 .. name_end], " \t/");
                if (std.ascii.eqlIgnoreCase(name, tag)) {
                    i = name_end + 1;
                    skip = null;
                    continue;
                }
                i = name_end + 1;
                continue;
            }
            break;
        }
        if (html[i] == '<') {
            // A bare `<` in prose ("5 < 10") is not a tag. Only treat it as
            // one when a letter, `/`, `!` or `?` follows, as in real markup.
            if (i + 1 >= html.len) {
                try out.append(gpa, '<');
                i += 1;
                continue;
            }
            const next = html[i + 1];
            if (!(std.ascii.isAlphabetic(next) or next == '/' or next == '!' or next == '?')) {
                try out.append(gpa, '<');
                i += 1;
                continue;
            }
            const end = std.mem.indexOfScalarPos(u8, html, i + 1, '>') orelse {
                // An unterminated construct: keep the `<` and move on rather
                // than dropping everything after it.
                try out.append(gpa, '<');
                i += 1;
                continue;
            };
            const inside = std.mem.trim(u8, html[i + 1 .. end], " \t\r\n/");
            const name = blk: {
                var j: usize = 0;
                while (j < inside.len and inside[j] != ' ' and inside[j] != '\t' and inside[j] != '/') : (j += 1) {}
                break :blk inside[0..j];
            };
            if (std.ascii.eqlIgnoreCase(name, "script") or std.ascii.eqlIgnoreCase(name, "style") or std.ascii.eqlIgnoreCase(name, "head")) {
                skip = if (std.ascii.eqlIgnoreCase(name, "head")) "head" else name;
            } else if (isBlockEnd(name)) {
                try out.append(gpa, '\n');
            } else {
                try out.append(gpa, ' ');
            }
            i = end + 1;
            continue;
        }
        if (html[i] == '&') {
            if (entity(html[i..])) |found| {
                try out.appendSlice(gpa, found.text);
                i += found.len;
                continue;
            }
        }
        try out.append(gpa, html[i]);
        i += 1;
    }
    return tidy(gpa, out.items);
}

fn isBlockEnd(name: []const u8) bool {
    if (name.len < 2 or name[0] != '/') return false;
    const n = name[1..];
    for ([_][]const u8{ "p", "div", "li", "br", "tr", "section", "article", "h1", "h2", "h3", "h4", "h5", "h6" }) |b| {
        if (std.ascii.eqlIgnoreCase(n, b)) return true;
    }
    return false;
}

const Entity = struct { text: []const u8, len: usize };
fn entity(s: []const u8) ?Entity {
    const named = [_]struct { key: []const u8, value: []const u8 }{
        .{ .key = "&nbsp;", .value = " " },
        .{ .key = "&amp;", .value = "&" },
        .{ .key = "&lt;", .value = "<" },
        .{ .key = "&gt;", .value = ">" },
        .{ .key = "&quot;", .value = "\"" },
        .{ .key = "&#39;", .value = "'" },
        .{ .key = "&apos;", .value = "'" },
        .{ .key = "&mdash;", .value = "—" },
        .{ .key = "&ndash;", .value = "–" },
        .{ .key = "&hellip;", .value = "…" },
    };
    for (named) |e| if (std.mem.startsWith(u8, s, e.key)) return .{ .text = e.value, .len = e.key.len };
    return null;
}

/// Cuts cleaned text into overlapping pieces on word boundaries. Returns
/// slices into `text`, so nothing is copied; the caller owns `text`.
///
/// `max_chunks` is sized so the pieces reach the end of the `max_chars`
/// window: a long document's last page is as searchable as its first. Only
/// a file longer than `max_chars` is cut short, and that is deliberate.
pub fn chunks(text: []const u8, out: *[max_chunks][]const u8) usize {
    if (text.len == 0) return 0;
    const limit = @min(text.len, max_chars);
    var body = text[0..limit];
    while (body.len > 0 and body[body.len - 1] == '\n') body = body[0 .. body.len - 1];
    if (body.len == 0) return 0;

    var n: usize = 0;
    var start: usize = 0;
    while (start < body.len and n < out.len) {
        var end = @min(start + chunk_chars, body.len);
        if (end < body.len) {
            // Back up to a word boundary, but never past the midpoint.
            var at = end;
            while (at > start + chunk_chars / 2 and body[at - 1] != ' ' and body[at - 1] != '\n') : (at -= 1) {}
            if (at > start + chunk_chars / 2) end = at;
        }
        const piece = std.mem.trim(u8, body[start..end], " \t\r\n");
        if (piece.len > 0) {
            out[n] = piece;
            n += 1;
        }
        if (end == body.len) break;
        // The next piece starts a little before this one ended, so a phrase
        // split across the boundary still appears whole in one of them.
        start = if (end > chunk_overlap) end - chunk_overlap else end;
        while (start < end and body[start] != ' ' and body[start] != '\n') : (start += 1) {}
        if (start >= end) start = end;
    }
    return n;
}

test "plain text is recognized, and a binary is not" {
    const t = std.testing;
    try t.expect(readable("/notes/lease.md"));
    try t.expect(readable("/notes/REPORT.HTML"));
    try t.expect(readable("/src/main.zig"));
    try t.expect(!readable("/photos/dog.jpg"));
    try t.expect(!readable("/no-extension"));
}

test "tidy collapses whitespace and keeps paragraph breaks" {
    const t = std.testing;
    const gpa = t.allocator;
    const got = try tidy(gpa, "  hello \t  world\n\n\n  again  ");
    defer gpa.free(got);
    try t.expectEqualStrings("hello world\n\nagain", got);
}

test "HTML loses its tags, scripts and entities" {
    const t = std.testing;
    const gpa = t.allocator;
    const html = "<html><head><title>Hidden</title></head><body><h1>Lease</h1>" ++
        "<script>var secret = 1;</script><p>The tenant may keep a &quot;dog&quot;.</p></body></html>";
    const got = try stripHtml(gpa, html);
    defer gpa.free(got);
    try t.expect(std.mem.indexOf(u8, got, "Lease") != null);
    try t.expect(std.mem.indexOf(u8, got, "tenant may keep a \"dog\"") != null);
    // Neither the title in head nor the script's body is searchable text.
    try t.expect(std.mem.indexOf(u8, got, "Hidden") == null);
    try t.expect(std.mem.indexOf(u8, got, "secret") == null);
    try t.expect(std.mem.indexOf(u8, got, "<") == null);
}

test "chunks overlap on word boundaries and cover the text" {
    const t = std.testing;
    var buf: [8192]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    for (0..400) |i| {
        try w.print("w{d} ", .{i});
    }
    const text = std.mem.trim(u8, w.buffered(), " ");
    var out: [max_chunks][]const u8 = undefined;
    const n = chunks(text, &out);
    try t.expect(n > 1);
    try t.expect(n <= max_chunks);
    // Every piece is a real slice of the text, and the first starts at it.
    try t.expectEqualStrings(text[0..out[0].len], out[0]);
    for (out[0..n]) |piece| {
        try t.expect(piece.len > 0);
        try t.expect(piece.len <= chunk_chars);
    }
    // The pieces advance: none repeats the one before it.
    try t.expect(!std.mem.eql(u8, out[0], out[1]));
}

test "a short file is one chunk" {
    const t = std.testing;
    var out: [max_chunks][]const u8 = undefined;
    const n = chunks("a short note about the dog", &out);
    try t.expectEqual(@as(usize, 1), n);
    try t.expectEqualStrings("a short note about the dog", out[0]);
}

test "HTML5 without a closing head still keeps the body" {
    const t = std.testing;
    const gpa = t.allocator;
    // Legal HTML5: `</head>` is omitted, `<body>` ends the head implicitly.
    const got = try stripHtml(gpa, "<html><head><title>Hidden</title><body>Body text here</body></html>");
    defer gpa.free(got);
    try t.expect(std.mem.indexOf(u8, got, "Body text here") != null);
    try t.expect(std.mem.indexOf(u8, got, "Hidden") == null);
}

test "a bare less-than in prose is not a tag" {
    const t = std.testing;
    const gpa = t.allocator;
    const got = try stripHtml(gpa, "<p>5 < 10 and 20 > 15</p>");
    defer gpa.free(got);
    try t.expect(std.mem.indexOf(u8, got, "10 and 20") != null);
    // An unterminated `<` keeps the text after it.
    const got2 = try stripHtml(gpa, "<p>a</p> 3 < 4");
    defer gpa.free(got2);
    try t.expect(std.mem.indexOf(u8, got2, "3 < 4") != null);
}

test "chunks cover the whole window, not just the first few" {
    const t = std.testing;
    const gpa = t.allocator;
    // 32,000 characters of words, the full `max_chars` window.
    var text: std.Io.Writer.Allocating = .init(gpa);
    defer text.deinit();
    var i: usize = 0;
    while (text.written().len < max_chars) : (i += 1) {
        try text.writer.print("word{d} ", .{i});
    }
    const body = text.written()[0..max_chars];
    var out: [max_chunks][]const u8 = undefined;
    const n = chunks(body, &out);
    try t.expect(n > 1);
    // The last piece must reach near the end of the window: a document's
    // final page has to be as searchable as its first.
    const last = out[n - 1];
    const last_end = @intFromPtr(last.ptr) + last.len - @intFromPtr(body.ptr);
    try t.expect(last_end > max_chars - chunk_chars);
}
