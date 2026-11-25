//! Text inside Office files: docx, xlsx and pptx are ZIP archives of XML.
//!
//! Zig 0.17 has `std.zip`, so no archive dependency is needed. The XML is
//! simple enough for a small pull tokenizer: element names, attributes and
//! text, with namespace prefixes stripped. We only need the words, not a
//! validating parser, DTDs or entity tables beyond the common few.
//!
//! - docx: `word/document.xml`, every `w:t` in a `w:p` is one line.
//! - xlsx: `xl/sharedStrings.xml` plus each `xl/worksheets/sheet*.xml`;
//!   cells with `t="s"` index into the shared strings.
//! - pptx: `ppt/slides/slide*.xml`, every `a:t` is text on a slide.
const std = @import("std");

/// The extensions read here, lowercase without the dot.
pub const extensions = [_][]const u8{ "docx", "xlsx", "pptx" };

pub fn readable(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    if (ext.len < 2) return false;
    for (extensions) |e| if (std.ascii.eqlIgnoreCase(ext[1..], e)) return true;
    return false;
}

/// A ZIP entry's uncompressed bytes, or null when the entry is absent.
/// Bounded so a poisoned size cannot allocate the whole address space.
fn part(gpa: std.mem.Allocator, io: std.Io, file: std.Io.File, name: []const u8) ?[]u8 {
    var read_buf: [64 << 10]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var iter = std.zip.Iterator.init(&reader) catch return null;
    while (iter.next() catch null) |entry| {
        var name_buf: [512]u8 = undefined;
        const got = entry.getFilename(&reader, &name_buf, .{}) catch continue;
        if (!std.mem.eql(u8, got, name)) continue;
        if (entry.uncompressed_size > max_part) return null;
        var out: std.Io.Writer.Allocating = .init(gpa);
        errdefer out.deinit();
        entry.extractTo(&reader, &out.writer) catch {
            out.deinit();
            return null;
        };
        return out.toOwnedSlice() catch null;
    }
    return null;
}

/// All ZIP entries whose names start with `prefix`, in archive order.
fn partsWithPrefix(
    gpa: std.mem.Allocator,
    io: std.Io,
    file: std.Io.File,
    prefix: []const u8,
    out: *std.ArrayList([]u8),
) void {
    var read_buf: [64 << 10]u8 = undefined;
    var reader = file.reader(io, &read_buf);
    var iter = std.zip.Iterator.init(&reader) catch return;
    while (iter.next() catch null) |entry| {
        var name_buf: [512]u8 = undefined;
        const got = entry.getFilename(&reader, &name_buf, .{}) catch continue;
        if (!std.mem.startsWith(u8, got, prefix)) continue;
        if (entry.uncompressed_size > max_part) continue;
        var data: std.Io.Writer.Allocating = .init(gpa);
        errdefer data.deinit();
        entry.extractTo(&reader, &data.writer) catch {
            data.deinit();
            continue;
        };
        out.append(gpa, data.toOwnedSlice() catch {
            data.deinit();
            continue;
        }) catch {
            data.deinit();
            break;
        };
    }
}

pub const max_part = 16 << 20;

/// An XML event, with the namespace prefix removed from names.
pub const Event = union(enum) {
    /// The element name, with namespace stripped. Attributes are read with
    /// `attribute()` on the raw tag kept alongside in `Xml.last_tag`.
    open: []const u8,
    close: []const u8,
    /// A self-closing tag: `<w:p/>`.
    empty: []const u8,
    text: []const u8,
};

/// A small pull tokenizer over one XML part. Names and text borrow from
/// `xml`; they are valid until `next()` is called again.
pub const Xml = struct {
    xml: []const u8,
    i: usize = 0,
    /// The raw content of the most recent open tag, including attributes.
    last_tag: []const u8 = "",

    pub fn init(xml: []const u8) Xml {
        return .{ .xml = xml };
    }

    pub fn next(self: *Xml) ?Event {
        while (self.i < self.xml.len) {
            const c = self.xml[self.i];
            if (c == '<') {
                const end = std.mem.indexOfScalarPos(u8, self.xml, self.i + 1, '>') orelse return null;
                const inside = std.mem.trim(u8, self.xml[self.i + 1 .. end], " \t\r\n");
                self.i = end + 1;
                if (inside.len == 0) continue;
                // Declarations, comments, CDATA and processing instructions
                // carry no words we want.
                if (inside[0] == '?' or inside[0] == '!') continue;
                if (inside[0] == '/') return .{ .close = localName(inside[1..]) };
                const self_closing = inside[inside.len - 1] == '/';
                const body = if (self_closing) inside[0 .. inside.len - 1] else inside;
                const name_end = std.mem.indexOfAny(u8, body, " \t\r\n") orelse body.len;
                const name = localName(body[0..name_end]);
                self.last_tag = body;
                return if (self_closing) .{ .empty = name } else .{ .open = name };
            }
            const end = std.mem.indexOfScalarPos(u8, self.xml, self.i, '<') orelse self.xml.len;
            const raw = self.xml[self.i..end];
            self.i = end;
            if (std.mem.trim(u8, raw, " \t\r\n").len == 0) continue;
            return .{ .text = raw };
        }
        return null;
    }
};

/// `w:t` → `t`, `a:t` → `t`: Office puts its namespace in the prefix.
fn localName(name: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, name, ':')) |at| return name[at + 1 ..];
    return name;
}

/// The value of attribute `wanted` on the last open tag, or null. Handles
/// both `name="value"` and `name='value'`.
pub fn attribute(x: *const Xml, wanted: []const u8) ?[]const u8 {
    const tag = x.last_tag;
    var i: usize = 0;
    while (i < tag.len) {
        // Skip whitespace and any leading slash.
        while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t' or tag[i] == '/')) : (i += 1) {}
        if (i >= tag.len) break;
        // The element name itself is not an attribute: skip it.
        if (i == 0) {
            while (i < tag.len and tag[i] != ' ' and tag[i] != '\t' and tag[i] != '/') : (i += 1) {}
            continue;
        }
        const name_start = i;
        while (i < tag.len and tag[i] != '=' and tag[i] != ' ' and tag[i] != '\t') : (i += 1) {}
        const name = localName(tag[name_start..i]);
        while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t')) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') break;
        i += 1;
        while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t')) : (i += 1) {}
        if (i >= tag.len or (tag[i] != '"' and tag[i] != '\'')) break;
        const quote = tag[i];
        i += 1;
        const value_start = i;
        while (i < tag.len and tag[i] != quote) : (i += 1) {}
        const value = tag[value_start..@min(i, tag.len)];
        if (i < tag.len) i += 1;
        if (std.mem.eql(u8, name, wanted)) return value;
    }
    return null;
}

/// The five entities Office writes in text. Numeric ones are rare in these
/// parts; the caller's `tidy` later collapses the whitespace they produce.
fn appendDecoded(out: *std.ArrayList(u8), gpa: std.mem.Allocator, raw: []const u8) !void {
    var i: usize = 0;
    while (i < raw.len) {
        if (raw[i] == '&') {
            if (std.mem.indexOfScalarPos(u8, raw, i + 1, ';')) |semi| {
                const ent = raw[i + 1 .. semi];
                const decoded: ?[]const u8 = if (std.mem.eql(u8, ent, "amp")) "&" else if (std.mem.eql(u8, ent, "lt")) "<" else if (std.mem.eql(u8, ent, "gt")) ">" else if (std.mem.eql(u8, ent, "quot")) "\"" else if (std.mem.eql(u8, ent, "apos")) "'" else null;
                if (decoded) |d| {
                    try out.appendSlice(gpa, d);
                    i = semi + 1;
                    continue;
                }
            }
        }
        try out.append(gpa, raw[i]);
        i += 1;
    }
}

/// Reads a docx's paragraphs: each `w:p` is one line of `w:t` text.
fn docx(gpa: std.mem.Allocator, file: std.Io.File, io: std.Io) ![]u8 {
    const xml = part(gpa, io, file, "word/document.xml") orelse return error.NoText;
    defer gpa.free(xml);
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var x = Xml.init(xml);
    var in_para = false;
    var began_line = false;
    while (x.next()) |ev| switch (ev) {
        .open => |name| if (std.mem.eql(u8, name, "p")) {
            in_para = true;
        },
        .empty => |name| if (std.mem.eql(u8, name, "p") and began_line) {
            try out.append(gpa, '\n');
            began_line = false;
        },
        .close => |name| if (std.mem.eql(u8, name, "p")) {
            if (began_line) try out.append(gpa, '\n');
            in_para = false;
            began_line = false;
        },
        .text => |text| if (in_para) {
            if (out.items.len > 0 and !std.mem.endsWith(u8, out.items, "\n")) {
                // Text between runs is whitespace: keep one space.
                try out.append(gpa, ' ');
            }
            try appendDecoded(&out, gpa, text);
            began_line = true;
        },
    };
    if (out.items.len == 0) return error.NoText;
    return out.toOwnedSlice(gpa);
}

/// Reads a pptx's slides: each `a:t` is text, slides separated by a line.
fn pptx(gpa: std.mem.Allocator, file: std.Io.File, io: std.Io) ![]u8 {
    var slides: std.ArrayList([]u8) = .empty;
    defer {
        for (slides.items) |s| gpa.free(s);
        slides.deinit(gpa);
    }
    partsWithPrefix(gpa, io, file, "ppt/slides/slide", &slides);
    // Only `slideN.xml`, not `slideN.xml.rels` or layouts.
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var n_slides: usize = 0;
    for (slides.items) |xml| {
        if (!std.mem.endsWith(u8, xml, "")) {} // keep the slice alive
        var x = Xml.init(xml);
        var slide: std.ArrayList(u8) = .empty;
        defer slide.deinit(gpa);
        while (x.next()) |ev| switch (ev) {
            .text => |text| {
                try appendDecoded(&slide, gpa, text);
                try slide.append(gpa, ' ');
            },
            .open, .close, .empty => {},
        };
        if (std.mem.trim(u8, slide.items, " \t\r\n").len == 0) continue;
        if (n_slides > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, slide.items);
        n_slides += 1;
    }
    if (out.items.len == 0) return error.NoText;
    return out.toOwnedSlice(gpa);
}

/// Reads an xlsx: shared strings first, then each sheet's cells. A cell with
/// `t="s"` holds an index into the shared strings; other cells hold their
/// value directly. Rows become lines, cells separated by a tab.
fn xlsx(gpa: std.mem.Allocator, file: std.Io.File, io: std.Io) ![]u8 {
    var strings: std.ArrayList([]u8) = .empty;
    defer {
        for (strings.items) |s| gpa.free(s);
        strings.deinit(gpa);
    }
    if (part(gpa, io, file, "xl/sharedStrings.xml")) |xml| {
        defer gpa.free(xml);
        var x = Xml.init(xml);
        var in_si = false;
        var current: std.ArrayList(u8) = .empty;
        defer current.deinit(gpa);
        while (x.next()) |ev| switch (ev) {
            .open => |name| if (std.mem.eql(u8, name, "si")) {
                in_si = true;
                current.clearRetainingCapacity();
            },
            .close => |name| if (std.mem.eql(u8, name, "si") and in_si) {
                in_si = false;
                try strings.append(gpa, try current.toOwnedSlice(gpa));
                current = .empty;
            },
            .text => |text| if (in_si) try appendDecoded(&current, gpa, text),
            else => {},
        };
    }

    var sheets: std.ArrayList([]u8) = .empty;
    defer {
        for (sheets.items) |s| gpa.free(s);
        sheets.deinit(gpa);
    }
    partsWithPrefix(gpa, io, file, "xl/worksheets/sheet", &sheets);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    for (sheets.items) |xml| {
        var x = Xml.init(xml);
        var in_row = false;
        var in_cell = false;
        var shared = false;
        var value: std.ArrayList(u8) = .empty;
        defer value.deinit(gpa);
        var row_started = false;
        while (x.next()) |ev| switch (ev) {
            .open => |name| {
                if (std.mem.eql(u8, name, "row")) {
                    in_row = true;
                    row_started = false;
                } else if (std.mem.eql(u8, name, "c")) {
                    in_cell = true;
                    // `t="s"` means the value is an index into the shared
                    // strings. Without it the number is the cell's value.
                    const kind = attribute(&x, "t") orelse "";
                    shared = std.mem.eql(u8, kind, "s");
                    value.clearRetainingCapacity();
                }
            },
            .empty => |name| if (std.mem.eql(u8, name, "row")) {
                try out.append(gpa, '\n');
            },
            .close => |name| {
                if (std.mem.eql(u8, name, "c") and in_cell) {
                    in_cell = false;
                    const v = std.mem.trim(u8, value.items, " \t\r\n");
                    if (v.len > 0) {
                        if (row_started) try out.append(gpa, '\t');
                        if (shared) {
                            if (std.fmt.parseInt(usize, v, 10)) |idx| {
                                if (idx < strings.items.len) try out.appendSlice(gpa, strings.items[idx]);
                            } else |_| try out.appendSlice(gpa, v);
                        } else try out.appendSlice(gpa, v);
                        row_started = true;
                    }
                } else if (std.mem.eql(u8, name, "row") and in_row) {
                    try out.append(gpa, '\n');
                    in_row = false;
                }
            },
            .text => |text| if (in_cell) try appendDecoded(&value, gpa, text),
        };
    }
    if (out.items.len == 0) return error.NoText;
    return out.toOwnedSlice(gpa);
}

/// Reads an Office file's text. The caller owns the result.
pub fn extract(gpa: std.mem.Allocator, io: std.Io, path: []const u8) ![]u8 {
    const file = try std.Io.Dir.cwd().openFile(io, path, .{});
    defer file.close(io);
    const ext = std.fs.path.extension(path);
    if (ext.len >= 2 and std.ascii.eqlIgnoreCase(ext[1..], "docx")) return docx(gpa, file, io);
    if (ext.len >= 2 and std.ascii.eqlIgnoreCase(ext[1..], "xlsx")) return xlsx(gpa, file, io);
    if (ext.len >= 2 and std.ascii.eqlIgnoreCase(ext[1..], "pptx")) return pptx(gpa, file, io);
    return error.Unsupported;
}

test "the XML tokenizer strips namespace prefixes and reads text" {
    const t = std.testing;
    var x = Xml.init("<w:p><w:r><w:t>hello &amp; bye</w:t></w:r></w:p>");
    try t.expectEqualStrings("p", (x.next().?).open);
    try t.expectEqualStrings("r", (x.next().?).open);
    try t.expectEqualStrings("t", (x.next().?).open);
    try t.expectEqualStrings("hello &amp; bye", (x.next().?).text);
    try t.expectEqualStrings("t", (x.next().?).close);
    try t.expectEqualStrings("r", (x.next().?).close);
    try t.expectEqualStrings("p", (x.next().?).close);
    try t.expect(x.next() == null);
}

test "a self-closing tag is one event" {
    const t = std.testing;
    var x = Xml.init("<a/><b x=\"1\">text</b>");
    try t.expectEqualStrings("a", (x.next().?).empty);
    try t.expectEqualStrings("b", (x.next().?).open);
    try t.expectEqualStrings("text", (x.next().?).text);
    try t.expectEqualStrings("b", (x.next().?).close);
}

test "office extensions are recognized" {
    const t = std.testing;
    try t.expect(readable("/docs/report.DOCX"));
    try t.expect(readable("/docs/budget.xlsx"));
    try t.expect(readable("/docs/slides.pptx"));
    try t.expect(!readable("/docs/notes.txt"));
    try t.expect(!readable("/docs/old.doc"));
}

test "the attribute reader handles the first and later attributes" {
    const t = std.testing;
    var x = Xml.init("<c r=\"A1\" t=\"s\"><v>0</v></c>");
    try t.expectEqualStrings("c", (x.next().?).open);
    try t.expectEqualStrings("A1", attribute(&x, "r").?);
    try t.expectEqualStrings("s", attribute(&x, "t").?);
    try t.expect(attribute(&x, "missing") == null);
    // Single quotes work too.
    var y = Xml.init("<c t='inlineStr'/>");
    try t.expectEqualStrings("c", (y.next().?).empty);
    try t.expectEqualStrings("inlineStr", attribute(&y, "t").?);
}
