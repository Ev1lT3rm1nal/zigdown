const std = @import("std");
const cons = @import("console.zig");
const zd = struct {
    usingnamespace @import("parser.zig");
    usingnamespace @import("render.zig");
    usingnamespace @import("render_html.zig");
    usingnamespace @import("utils.zig");
};

pub const HtmlRenderer = zd.HtmlRenderer;
pub const htmlRenderer = zd.htmlRenderer;

pub const ConsoleRenderer = zd.ConsoleRenderer;
pub const consoleRenderer = zd.consoleRenderer;

pub fn main() !void {
    const text1: []const u8 =
        \\# Heading 1
        \\## Heading 2
        \\### Heading 3
        \\#### Heading 4
        \\
        \\Foo **Bar _baz_**. ~Hi!~
        \\> > Double-nested ~Quote~
        \\> > ...which supports multiple lines, which will be wrapped to the appropriate width by the renderer.
        \\> Note that lazy continuation lines allow this to be included in the previous child.
        \\>
        \\> This should work, too...
        \\> - And so should this!
        \\>
        \\> foo
        \\
        \\Image: ![Some Image](../test/zig-zero.png)
        \\
        \\Link: [Click Me!](https://google.com)
        \\
        \\1. Numlist
        \\2. Foobar
        \\   - With child list
        \\   - this should work?
        \\      1. and this?
        \\      2. Wohooo!!!
        \\1. 2nd item
        \\
        \\- Another list
        \\- more items
        \\```c++
        \\  Some raw code here...
        \\And some more here.
        \\```
        \\para
    ;
    const text2: []const u8 =
        \\# Heading 1
        \\
        \\Link: [Click Me!](https://google.com)
        \\
        \\1. Numlist
        \\ 2. Foobar
        \\    - With child list
        \\    - this should work?
        \\     1. and this?
        \\      2. Wohooo!!!
        \\     3. > Quote block
        \\1. 2nd item
    ;
    _ = text2;
    const text = text1;

    const stdout = std.io.getStdOut().writer();
    var style: zd.TextStyle = zd.TextStyle{ .fg_color = .Green, .bold = true };
    cons.printStyled(stdout, style, "\n────────────────── Test Document ──────────────────\n", .{});
    try stdout.print("{s}\n", .{text});
    cons.printStyled(stdout, style, "───────────────────────────────────────────────────\n", .{});

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var p: zd.Parser = zd.Parser.init(alloc, .{ .copy_input = false, .verbose = true });
    defer p.deinit();
    try p.parseMarkdown(text);

    style.fg_color = .Blue;
    cons.printStyled(stdout, style, "─────────────────── Parsed AST ────────────────────\n", .{});
    p.document.print(0);
    cons.printStyled(stdout, style, "───────────────────────────────────────────────────\n", .{});

    var hrenderer = htmlRenderer(stdout, alloc);
    defer hrenderer.deinit();

    style.fg_color = .Cyan;
    cons.printStyled(stdout, style, "────────────────── Rendered HTML ──────────────────\n", .{});
    try hrenderer.renderBlock(p.document);
    cons.printStyled(stdout, style, "───────────────────────────────────────────────────\n", .{});

    var crenderer = consoleRenderer(stdout, alloc, .{ .width = 70 });
    defer crenderer.deinit();

    style.fg_color = .Red;
    cons.printStyled(stdout, style, "─────────────────────── Rendered Text ───────────────────────\n", .{});
    try crenderer.renderBlock(p.document);
    cons.printStyled(stdout, style, "─────────────────────────────────────────────────────────────\n", .{});
}
