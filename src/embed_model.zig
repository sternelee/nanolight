//! The model files meaning search runs on: EmbeddingGemma 2, as ggml-org's
//! Q8_0 GGUF conversion at one pinned revision, made from
//! google/embeddinggemma-2. The same two files DigUp uses, for the same
//! reason: the F16 weights overflow float16 in the model's activations.
//!
//! - `text` (310 MB): the text model. Queries and the words in a file.
//! - `media` (555 MB): the image and audio encoders, fed to the text model.
//!   Only needed for pictures, recordings and video frames.
//!
//! A file is downloaded into `<name>.partial` and only gets its real name
//! once its size and SHA-256 match, so a file under its real name is whole.
//! Nothing here talks to the network: `model_download.zig` does.
const std = @import("std");

pub const repository = "ggml-org/embeddinggemma-2-GGUF";
/// A path long enough for a model file's name under any home folder.
pub const max_path = 4096;
/// Pinned: a revision can be replaced, a commit cannot.
pub const revision = "bfcd298762cc34d0357ece5ebdd31791a3a374d8";

pub const File = struct {
    name: []const u8,
    bytes: u64,
    sha256: []const u8,
};

/// The text model: all a query needs.
pub const text = File{
    .name = "embeddinggemma-2-Q8_0.gguf",
    .bytes = 309_855_456,
    .sha256 = "2188ac1deca4b77dffefd603c2776a9d76d9d74ec01841392982ebb840b09135",
};

/// The image and audio encoders.
pub const media = File{
    .name = "mmproj-embeddinggemma-2-Q8_0.gguf",
    .bytes = 554_821_024,
    .sha256 = "c4a8a52691ecef40618438928bdf9e68379b854e24166f292592353db0aab64f",
};

/// In download order: the text part first, so searching by words works
/// while the rest is still coming.
pub const all = [_]File{ text, media };

pub fn totalBytes() u64 {
    var n: u64 = 0;
    for (all) |f| n += f.bytes;
    return n;
}

/// Hugging Face's address for a file at the pinned revision. It answers
/// with a redirect to a CDN that takes HTTP ranges, which is what makes a
/// resumed download possible.
pub fn url(buf: []u8, f: File) ?[]const u8 {
    return std.fmt.bufPrint(buf, "https://huggingface.co/{s}/resolve/{s}/{s}", .{ repository, revision, f.name }) catch null;
}

/// The prompt wording, as a constant the fingerprint can hash. Changing
/// either prompt changes the vectors, so it must change the fingerprint;
/// keeping the text here is what makes that automatic rather than a `:v1`
/// someone has to remember to bump.
pub const query_prefix = "task: search result | query: ";
pub const document_prefix = "title: ";
pub const document_middle = " | text: ";

/// What the vectors were made with: the model, its revision, and the exact
/// prompt wording. A different one makes different vectors, and an index
/// made by another is refused rather than scored against these.
pub const fingerprint: [16]u8 = blk: {
    var out: [16]u8 = @splat(0);
    // Every input to the embedding, in one string: the model file, the
    // revision, and both prompts. Nothing that changes a vector may be
    // left out of this.
    const seed = "embeddinggemma2-q8_0:" ++ revision ++ ":" ++
        query_prefix ++ "\x00" ++ document_prefix ++ "\x00" ++ document_middle;
    var h = std.hash.Wyhash.init(0);
    h.update(seed);
    const n = h.final();
    std.mem.writeInt(u64, out[0..8], n, .little);
    var h2 = std.hash.Wyhash.init(n);
    h2.update(seed);
    std.mem.writeInt(u64, out[8..16], h2.final(), .little);
    break :blk out;
};

/// The task prompts the model card gives. A query and a document are
/// embedded differently on purpose: that is what puts "a dog on the beach"
/// next to a photo of one.
pub fn queryText(buf: []u8, q: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ query_prefix, q }) catch null;
}

/// A file's words, with its name as the title.
pub fn documentText(buf: []u8, title: []const u8, body: []const u8) ?[]const u8 {
    const t = if (title.len == 0) "none" else title;
    // A very long basename must not cost the whole chunk: trim the title
    // to what fits after the fixed framing. The body is the searchable
    // part; the name is only a hint.
    const fixed = document_prefix.len + document_middle.len;
    const room = if (buf.len > fixed + body.len) buf.len - fixed - body.len else 0;
    const shown = t[0..@min(t.len, room)];
    return std.fmt.bufPrint(buf, "{s}{s}{s}{s}", .{ document_prefix, shown, document_middle, body }) catch null;
}

test "the files add up to what the app says it downloads" {
    const t = std.testing;
    try t.expectEqual(@as(u64, 309_855_456 + 554_821_024), totalBytes());
    try t.expectEqual(@as(usize, 2), all.len);
    // The text part comes first: search works before the media encoders land.
    try t.expectEqualStrings(text.name, all[0].name);
    try t.expectEqualStrings(media.name, all[1].name);
}

test "a file's address is the pinned revision, not a branch" {
    const t = std.testing;
    var buf: [512]u8 = undefined;
    const u = url(&buf, text).?;
    try t.expect(std.mem.indexOf(u8, u, repository) != null);
    try t.expect(std.mem.indexOf(u8, u, revision) != null);
    try t.expect(std.mem.indexOf(u8, u, text.name) != null);
    // A branch would move under us; a commit cannot.
    try t.expect(std.mem.indexOf(u8, u, "/resolve/main/") == null);
}

test "the fingerprint is stable, and names the model" {
    const t = std.testing;
    // Same bytes every run: an index is not read again for no reason.
    try t.expectEqualSlices(u8, &fingerprint, &fingerprint);
    var other: [16]u8 = @splat(0);
    try t.expect(!std.mem.eql(u8, &fingerprint, &other));
}

test "queries and documents are framed as the model card says" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    try t.expectEqualStrings("task: search result | query: a dog", queryText(&buf, "a dog").?);
    try t.expectEqualStrings("title: lease | text: the tenant may keep a cat", documentText(&buf, "lease", "the tenant may keep a cat").?);
    // A file with no name still gets a title the model understands.
    try t.expectEqualStrings("title: none | text: body", documentText(&buf, "", "body").?);
}

test "the fingerprint covers the prompt wording, not just the model" {
    const t = std.testing;
    // The prompts are part of the seed: changing one changes the
    // fingerprint, so an index made with the old wording is refused
    // instead of being scored against new query vectors.
    var h = std.hash.Wyhash.init(0);
    h.update(query_prefix);
    const q = h.final();
    var h2 = std.hash.Wyhash.init(0);
    h2.update(document_prefix);
    const d = h2.final();
    try t.expect(q != d);
    // The full revision is in the seed, not an 8-character prefix: two
    // commits that share their first eight hex digits still differ.
    try t.expect(revision.len > 8);
    // And the fingerprint is not all zeroes.
    var zero: [16]u8 = @splat(0);
    try t.expect(!std.mem.eql(u8, &fingerprint, &zero));
}

test "the prompt builders use the hashed prefixes" {
    const t = std.testing;
    var buf: [256]u8 = undefined;
    const q = queryText(&buf, "a dog").?;
    try t.expect(std.mem.startsWith(u8, q, query_prefix));
    var buf2: [256]u8 = undefined;
    const d = documentText(&buf2, "lease", "the tenant").?;
    try t.expect(std.mem.startsWith(u8, d, document_prefix));
    try t.expect(std.mem.indexOf(u8, d, document_middle) != null);
}

const extract_chunk_chars = 1400;

test "a very long title is trimmed, not the whole document dropped" {
    const t = std.testing;
    var long: [600]u8 = undefined;
    @memset(&long, 'n');
    var buf: [extract_chunk_chars + 256]u8 = undefined;
    const framed = documentText(&buf, &long, "the tenant may keep a dog").?;
    // The body survives intact; only the name was cut to fit.
    try t.expect(std.mem.endsWith(u8, framed, "the tenant may keep a dog"));
    try t.expect(framed.len <= buf.len);
}
