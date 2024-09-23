const std = @import("std");
const Tickets = @import("tickets.zig");
const Ticket = Tickets.Ticket;
const TicketStore = Tickets.TicketStore;
const SString = @import("smallstring.zig").ShortString;

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.Gofast);

/// Gofast project system
pub const Gofast = struct {
    /// Store the tickets in the system.
    lock: std.Thread.RwLock = .{},
    tickets: TicketStore,
    persistance: ?std.fs.File = null,
    const Self = @This();

    /// Init the whole system, with `persistence` as a relative
    /// path for storing/loading data from.
    pub fn init(alloc: Allocator, persitence: ?[]const u8) !Gofast {
        var g = Gofast{
            .tickets = try TicketStore.init(alloc),
        };

        const cwd = std.fs.cwd();
        if (persitence) |p| {
            var load = true;
            const file = cwd.openFile(p, .{ .mode = .read_write }) catch |e| blk: {
                log.info("Failed to open {s} ({}), creating...", .{ p, e });
                const f = try cwd.createFile(p, .{
                    .truncate = true,
                    .exclusive = true,
                    .read = true,
                });
                load = false;
                // Save it so it's not empty the next time.
                try g.tickets.save(f.writer());
                break :blk f;
            };

            if (load) {
                log.info("Loading data from persistance {s}", .{p});
                try g.tickets.loadFromFile(file.reader());
            }

            g.persistance = file;
        }

        return g;
    }
    pub fn deinit(self: *Self) void {
        if (self.persistance) |p| {
            self.save() catch |e| {
                log.err("Failed to save on deinit(). error: {}", .{e});
            };
            p.close();
        }
        self.tickets.deinit();
    }

    pub fn save(self: *Self) !void {
        if (self.persistance) |p| {
            log.info(".save", .{});
            try p.seekTo(0);
            try self.tickets.save(p.writer());
        } else {
            return error.NoPersistance;
        }
    }

    const CreateTicket = struct {
        title: []const u8,
        desc: []const u8,
        parent: ?Ticket.Key = null,
        priority: Ticket.Priority = 0,
        type_: Ticket.Type = 0,
        status: Ticket.Status = 0,
    };

    /// Create a new ticket, withthe provided parameters
    pub fn createTicket(self: *Self, c: CreateTicket) !Ticket.Key {
        const alloc = self.tickets.alloc;
        return try self.tickets.addOne(
            try SString.fromSlice(c.title, alloc),
            try SString.fromSlice(c.desc, alloc),
            c.parent,
            c.priority,
            c.type_,
            c.status,
        );
    }

    pub fn deleteTicket(self: *Self, key: Ticket.Key) !void {
        try self.tickets.removeOne(key);
    }

    const UpdateTicket = struct {
        title: ?[]const u8 = null,
        description: ?[]const u8 = null,
        parent: ??Ticket.Key = null,
        status: ?Ticket.Status = null,
        priority: ?Ticket.Priority = null,
        type: ?Ticket.Type = null,
    };
    pub fn updateTicket(self: *Self, key: Ticket.Key, u: UpdateTicket) !void {
        const alloc = self.tickets.alloc;

        var slice = self.tickets.tickets.slice();

        // Find the ticket's index in the MAL.
        const index = std.mem.indexOfScalar(Ticket.Key, slice.items(.key), key) orelse return error.NotFound;

        //TODO:
        //  Record the changes in some history structure.
        //

        if (u.type) |p| slice.items(.type)[index] = p;
        if (u.priority) |p| slice.items(.priority)[index] = p;
        if (u.status) |p| slice.items(.status)[index] = p;
        if (u.parent) |p| {
            //PERF:
            // Can optimize this by reusing the index we already found in the code above.
            try self.tickets.setParent(key, p);
        }
        if (u.title) |p| {
            const titles = slice.items(.title);
            var old = titles[index];
            old.deinit(alloc);
            titles[index] = try SString.fromSlice(p, alloc);
        }
        if (u.description) |p| {
            const descriptions = slice.items(.description);
            var old = descriptions[index];
            old.deinit(alloc);
            descriptions[index] = try SString.fromSlice(p, alloc);
        }
    }
    pub fn setEstimate(self: *Self, ticket: Ticket.Key, person: Ticket.Person, estimate: Ticket.TimeSpent.Seconds) !void {
        try self.tickets.setEstimate(ticket, person, estimate);
    }
    pub fn logWork(self: *Self, ticket: Ticket.Key, person: Ticket.Person, t_start: i64, t_end: i64) !void {
        try self.tickets.logWork(ticket, person, t_start, t_end);
    }
};

/// Recorder/Replayer of actions performed.
const Replay = struct {
    // TODO: This can aid testing greatly if we can record/replay actions.
    const Action = union(enum) {
        create_ticket: struct {
            outcome: anyerror!Ticket.Key,
            title: SString,
            desc: SString,
            parent: ?Ticket.Key = null,
        },
        delete_ticket: struct {
            outcome: anyerror!void,
            ticket: Ticket.Key,
        },
        set_parent: struct {
            outcome: anyerror!void,
            ticket: Ticket.Key,
            parent: ?Ticket.Key = null,
        },
    };
};

test Gofast {
    const TEST = std.testing;
    const alloc = TEST.allocator;

    var gf = try Gofast.init(alloc, null);
    defer gf.deinit();

    try TEST.expect(gf.tickets.max_key == 0);

    const ticket1 = try gf.createTicket(.{ .title = "t", .desc = "d" });
    try TEST.expect(ticket1 == 1);

    try gf.deleteTicket(ticket1);
}
test "Gofast.gibberish" {
    const TEST = std.testing;
    const alloc = TEST.allocator;
    var gf = try Gofast.init(alloc, null);
    defer gf.deinit();
}
test "Gofast.persistance" {
    const TEST = std.testing;
    const alloc = TEST.allocator;
    const filepath = "persist.test.gfs";

    std.fs.cwd().deleteFile(filepath) catch |e| switch (e) {
        error.FileNotFound => {},
        else => {
            return e;
        },
    };

    //Create the persistance file.
    {
        var gofast = try Gofast.init(alloc, "persist.test.gfs");
        defer gofast.deinit();
        try TEST.expect(gofast.persistance != null);
        try TEST.expectEqual(0, gofast.tickets.name_priorities.items.len);
        try TEST.expectEqual(0, gofast.tickets.name_statuses.items.len);
        try TEST.expectEqual(0, gofast.tickets.name_types.items.len);
        try gofast.tickets.name_priorities.append(alloc, try SString.fromSlice("Prio0", alloc));

        try TEST.expectEqual(1, gofast.tickets.name_priorities.items.len);
        try TEST.expectEqual(0, gofast.tickets.name_statuses.items.len);
        try TEST.expectEqual(0, gofast.tickets.name_types.items.len);
        try TEST.expectEqualStrings("Prio0", gofast.tickets.name_priorities.items[0].s);
        try gofast.save();
    }

    {
        var gofast = try Gofast.init(alloc, "persist.test.gfs");
        defer gofast.deinit();

        try TEST.expectEqual(1, gofast.tickets.name_priorities.items.len);
        try TEST.expectEqual(0, gofast.tickets.name_statuses.items.len);
        try TEST.expectEqual(0, gofast.tickets.name_types.items.len);
        try TEST.expectEqualStrings("Prio0", gofast.tickets.name_priorities.items[0].s);
    }
}
test Replay {}
