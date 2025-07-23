/// Parse data from a .gfs
///
///
///
const std = @import("std");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.Gofast_loadV0);

const Gofast = @import("gofast.zig").Gofast;
const SString = @import("SmallString.zig");
const StringMap = Gofast.StringMap;
const Reader = std.fs.File.Reader;

pub fn load(gofast: *Gofast, reader: Reader) !void {
    try readNames(gofast, reader);

    const max_key = try reader.readInt(u32, .little);
    log.info("max_key={}", .{max_key});
    const n_tickets = try reader.readInt(u32, .little);
    log.info("n_tickets={}", .{n_tickets});

    gofast.max_ticket_key = max_key;

    // Early break
    if (n_tickets == 0) {
        return;
    }

    // Now load the MultiArrayList slice-by-slice.
    try gofast.tickets.resize(gofast.alloc, n_tickets);
    var tickets = gofast.tickets.slice();

    for (tickets.items(.key)) |*i| i.* = try reader.readInt(u32, .little);
    for (tickets.items(.details)) |*i| {
        i.type = try reader.readInt(u8, .little);
        i.status = try reader.readInt(u8, .little);
        i.priority = try reader.readInt(u8, .little);
        i.order = @bitCast(try reader.readInt(u32, .little));
    }
    for (tickets.items(.creator)) |*i| i.* = try reader.readInt(u32, .little);
    for (tickets.items(.created_on)) |*i| i.* = try reader.readInt(i64, .little);
    for (tickets.items(.last_updated_by)) |*i| i.* = try reader.readInt(u32, .little);
    for (tickets.items(.last_updated_on)) |*i| i.* = try reader.readInt(i64, .little);

    // title: SString,
    // description: SString,
    try readStringSlice(gofast.alloc, reader, tickets.items(.title));
    try readStringSlice(gofast.alloc, reader, tickets.items(.description));

    // parent: ?Key = null,
    const parents = tickets.items(.parent);
    for (0..n_tickets) |i| {
        parents[i] = null;
    }
    try readGraphs(gofast, reader);

    // Read ticket_time_spent
    try readTicketTimeSpent(gofast, reader);
}

fn readNames(gofast: *Gofast, reader: Reader) !void {
    try readStringMapAlloc(gofast.alloc, reader, &gofast.names.types);
    log.info("Loaded {} types", .{gofast.names.types.items.len});

    try readStringMapAlloc(gofast.alloc, reader, &gofast.names.priorities);
    log.info("Loaded {} priorities", .{gofast.names.priorities.items.len});

    try readStringMapAlloc(gofast.alloc, reader, &gofast.names.statuses);
    log.info("Loaded {} statuses", .{gofast.names.statuses.items.len});

    try readStringMapAlloc(gofast.alloc, reader, &gofast.names.people);
    log.info("Loaded {} people", .{gofast.names.people.items.len});
}
fn readGraphs(gofast: *Gofast, reader: Reader) !void {
    const n_graphs: usize = @intCast(try reader.readInt(u64, .little));
    log.info("n_graphs={}", .{n_graphs});

    var parents = gofast.tickets.items(.parent);
    for (0..n_graphs) |i_graph| {
        // Unused for now
        _ = i_graph;

        switch (try reader.readInt(u8, .little)) {
            // Child Graph
            0 => {
                log.info("Loading Children Graph", .{});
                const n_graph_len: usize = @intCast(try reader.readInt(u64, .little));

                log.info("n_graph_len={}", .{n_graph_len});
                try gofast.graph_children.resize(gofast.alloc, n_graph_len);
                for (gofast.graph_children.items(.from)) |*from| {
                    from.* = try reader.readInt(u32, .little);
                }
                for (gofast.graph_children.items(.from), gofast.graph_children.items(.to)) |from, *to| {
                    // In case this changes, update this code
                    comptime assert(Gofast.Ticket.FatLink.To.capacity == 16);

                    for (0..Gofast.Ticket.FatLink.To.capacity) |i| {
                        const parent_key = from;
                        const child_key = try reader.readInt(u32, .little);
                        to.*.items[i] = child_key;
                        log.info("loadFromV0: link: {} -> {}", .{ from, child_key });
                        if (child_key != 0) {
                            // Actually set the .parent field.
                            const child_index = try gofast.findTicketIndex(child_key);
                            parents[child_index] = parent_key;
                        }
                    }
                }
            },
            else => return error.UnknownGraphType,
        }
    }
}

fn readTicketTimeSpent(gofast: *Gofast, reader: Reader) !void {
    const n_time_spent = try reader.readInt(usize, .little);
    try gofast.time_spent.resize(gofast.alloc, n_time_spent);
    const time_spent_slice = gofast.time_spent.slice();

    const ts_people = time_spent_slice.items(.person);
    const ts_time = time_spent_slice.items(.time);
    for (time_spent_slice.items(.ticket)) |*ticket| ticket.* = try reader.readInt(u32, .little);
    for (0..n_time_spent) |i| ts_people[i] = try reader.readInt(u32, .little);
    for (0..n_time_spent) |i| ts_time[i] = .{
        .estimate = try reader.readInt(u32, .little),
        .spent = try reader.readInt(u32, .little),
    };
}

fn readStringMapAlloc(alloc: Allocator, reader: std.fs.File.Reader, into: *StringMap) !void {
    const n: usize = @intCast(try reader.readInt(u64, .little));
    try into.ensureUnusedCapacity(alloc, n);

    for (0..n) |_| {
        const len = try reader.readInt(u32, .little);
        var ss = into.addOneAssumeCapacity();
        ss.s = try alloc.alloc(u8, len);
        errdefer ss.deinit(alloc);
        try reader.readNoEof(ss.s);
    }
}
fn readStringSlice(alloc: Allocator, reader: std.fs.File.Reader, slice: []SString) !void {
    for (0..slice.len) |i| {
        var ss = &slice[i];
        const len = try reader.readInt(u32, .little);
        ss.s = try alloc.alloc(u8, len);
        errdefer ss.deinit(alloc);
        try reader.readNoEof(ss.s[0..len]);
        log.info("readStringSlice: [{}] len={}", .{ i, len });
    }
}

fn prepareTestFile(src: []const u8) ![]const u8 {
    const test_file_name = ".test.gfs";
    var data_dir = try std.fs.cwd().openDir("test_data", .{});
    defer data_dir.close();
    try data_dir.copyFile(src, data_dir, test_file_name, .{});
    return "test_data/" ++ test_file_name;
}
fn cleanupTestFile() void {
    const test_file_name = ".test.gfs";
    var data_dir = std.fs.cwd().openDir("test_data", .{}) catch unreachable;
    defer data_dir.close();

    data_dir.deleteFile(test_file_name) catch unreachable;
}

test "load test_data/v0.gfs" {
    const TEST = std.testing;
    const alloc = TEST.allocator;

    var g = try Gofast.init(alloc, try prepareTestFile("v0.gfs"));
    defer cleanupTestFile();
    defer g.deinit();

    try TEST.expectEqual(100, g.max_ticket_key);
    try TEST.expectEqual(100, g.tickets.len);
    try TEST.expectEqual(4, g.names.types.items.len);
    try TEST.expectEqual(3, g.names.statuses.items.len);
    try TEST.expectEqual(8, g.names.priorities.items.len);
    try TEST.expectEqual(3, g.names.people.items.len);
    try TEST.expectEqual(49, g.graph_children.len);

    // For example
    const item44 = g.graph_children.get(44);
    try TEST.expectEqual(92, item44.from);
    try TEST.expectEqual(23, item44.to.items[0]);
    try TEST.expectEqual(62, item44.to.items[1]);
    for (3..16) |i| {
        try TEST.expectEqual(0, item44.to.items[i]);
    }
}
