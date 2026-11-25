//! PDF text, on the Mac, through PDFKit. Scans have no text layer and are
//! left out: reading them needs rendering and OCR, which is a later step.
//!
//! PDFKit is Apple's own framework, already on every Mac this app runs on.
//! Nanolight does not link a PDF library of its own; it asks the system to
//! open the document and read each page's text, then tidies that text the
//! same way as any other file.
const std = @import("std");
const builtin = @import("builtin");

const mac = builtin.os.tag == .macos;
const objc = if (mac) @import("nanoui").objc else struct {};

/// The most pages read from one PDF. A longer one would crowd out the rest
/// of the index; the first pages are where people look first.
pub const max_pages = 50;

/// Whether PDFs can be read here: only on the Mac, where PDFKit lives.
pub fn available() bool {
    return mac;
}

/// A PDF's text, page by page, joined with line breaks. The caller owns the
/// result. On a non-Mac this returns `error.Unsupported`.
pub fn extract(gpa: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!mac) return error.Unsupported;
    const pool = objc.Pool.push();
    defer pool.pop();

    const url = objc.msg(?objc.Object, objc.class("NSURL"), "fileURLWithPath:", .{objc.nsString(path)}) orelse
        return error.Unreadable;
    // `initWithURL:` is an instance method: alloc first, then init. Swift's
    // `PDFDocument(url:)` convenience init does the same.
    const allocated = objc.alloc("PDFDocument");
    const doc = objc.msg(?objc.Object, allocated, "initWithURL:", .{url}) orelse
        return error.Unreadable;
    // A locked PDF has no text to read without a password.
    if (objc.msg(objc.BOOL, doc, "isLocked", .{}) != objc.NO) return error.Locked;

    const count = objc.msg(objc.NSInteger, doc, "pageCount", .{});
    if (count <= 0) return error.Unreadable;
    const pages = @min(count, max_pages);

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: objc.NSInteger = 0;
    while (i < pages) : (i += 1) {
        const page = objc.msg(?objc.Object, doc, "pageAtIndex:", .{i}) orelse continue;
        const text = objc.msg(?objc.Object, page, "string", .{}) orelse continue;
        const utf8 = objc.fromNSString(text);
        if (utf8.len == 0) continue;
        if (out.items.len > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, utf8);
    }
    if (out.items.len == 0) return error.NoText;
    return out.toOwnedSlice(gpa);
}

test "PDFs are read only where PDFKit is" {
    const t = std.testing;
    // The answer follows the platform: true on the Mac, false elsewhere.
    try t.expectEqual(mac, available());
    if (!mac) try t.expectError(error.Unsupported, extract(t.allocator, "/none.pdf"));
}
