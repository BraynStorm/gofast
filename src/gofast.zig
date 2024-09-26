const std = @import("std");
const Tickets = @import("tickets.zig");
const Ticket = Tickets.Ticket;
const TicketStore = Tickets.TicketStore;
const SString = @import("smallstring.zig").ShortString;

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.Gofast);

/// Gofast project system
///
/// TODO:
///     Specify precise error sets.
pub const Gofast = struct {
    /// RwLock to allow multiple readers, but only one writer.
    lock: std.Thread.RwLock = .{},

    /// Store the tickets in the system.
    tickets: TicketStore,

    /// If this is notnull, the data has been loaded from this file,
    /// and all changes are saved in said file.
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

    /// Save the state of Gofast to the persistence file, if any.
    pub fn save(self: *Self) !void {
        if (self.persistance) |p| {
            log.info(".save", .{});
            try p.seekTo(0);
            try self.tickets.save(p.writer());
        } else {
            return error.NoPersistance;
        }
    }

    /// Generate a "now" timestamp, in the units expected by Gofast (ms).
    pub fn timestamp() i64 {
        return std.time.milliTimestamp();
    }

    /// Create a new ticket, withthe provided parameters
    pub fn createTicket(self: *Self, c: struct {
        title: []const u8,
        description: []const u8,
        parent: ?Ticket.Key = null,
        priority: Ticket.Priority = 0,
        type_: Ticket.Type = 0,
        status: Ticket.Status = 0,
        creator: Ticket.Person,
    }) !Ticket.Key {
        const now = timestamp();
        const alloc = self.tickets.alloc;
        return try self.tickets.addTicket(.{
            .title = try SString.fromSlice(alloc, c.title),
            .description = try SString.fromSlice(alloc, c.description),
            .parent = c.parent,
            .priority = c.priority,
            .type_ = c.type_,
            .status = c.status,
            .creator = c.creator,
            .created_on = now,
            .last_updated_by = c.creator,
            .last_updated_on = now,
        });
    }

    /// Delete an existing ticket.
    ///
    /// TODO:
    ///     Remove this function, as we'd like to keep an
    ///     "infinite" history of tickets.
    pub fn deleteTicket(self: *Self, key: Ticket.Key) !void {
        try self.tickets.removeOne(key);
    }

    /// Change some data about a ticket.
    ///
    /// The ticket must exist.
    pub fn updateTicket(self: *Self, key: Ticket.Key, u: struct {
        title: ?[]const u8 = null,
        description: ?[]const u8 = null,
        parent: ??Ticket.Key = null,
        status: ?Ticket.Status = null,
        priority: ?Ticket.Priority = null,
        type: ?Ticket.Type = null,
    }) !void {
        const alloc = self.tickets.alloc;

        var slice = self.tickets.tickets.slice();

        // Find the ticket's index in the MAL.
        const index = std.mem.indexOfScalar(Ticket.Key, slice.items(.key), key) orelse return error.NotFound;

        //TODO:
        //  Record the changes in some history structure.

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
            titles[index] = try SString.fromSlice(alloc, p);
        }
        if (u.description) |p| {
            const descriptions = slice.items(.description);
            var old = descriptions[index];
            old.deinit(alloc);
            descriptions[index] = try SString.fromSlice(alloc, p);
        }
    }

    /// Set this ticket's estimate from the given person.
    pub fn giveEstimate(
        self: *Self,
        ticket: Ticket.Key,
        person: Ticket.Person,
        estimate: Ticket.TimeSpent.Seconds,
    ) !void {
        try self.tickets.setEstimate(ticket, person, estimate);
    }

    /// Log work-hours on a ticket from a given person.
    pub fn logWork(
        self: *Self,
        ticket: Ticket.Key,
        person: Ticket.Person,
        t_start: i64,
        t_end: i64,
    ) !void {
        try self.tickets.logWork(ticket, person, t_start, t_end);
    }

    /// Create a new Priority
    pub fn createPriority(self: *Self, data: struct {
        name: []const u8,
    }) !Ticket.Priority {
        const alloc = self.tickets.alloc;
        const id = self.tickets.name_priorities.items.len;
        try self.tickets.name_priorities.append(
            alloc,
            try SString.fromSlice(alloc, data.name),
        );
        return @intCast(id);
    }

    /// Create a new Status
    pub fn createStatus(self: *Self, data: struct {
        name: []const u8,
    }) !Ticket.Status {
        const alloc = self.tickets.alloc;
        const id = self.tickets.name_statuses.items.len;
        try self.tickets.name_statuses.append(
            alloc,
            try SString.fromSlice(alloc, data.name),
        );
        return @intCast(id);
    }

    /// Create a new Type
    pub fn createType(self: *Self, data: struct {
        name: []const u8,
    }) !Ticket.Type {
        const alloc = self.tickets.alloc;
        const id = self.tickets.name_types.items.len;
        try self.tickets.name_types.append(
            alloc,
            try SString.fromSlice(alloc, data.name),
        );
        return @intCast(id);
    }

    /// Create a new Person
    pub fn createPerson(self: *Self, data: struct { name: []const u8 }) !Ticket.Person {
        const alloc = self.tickets.alloc;
        const id = self.tickets.name_people.items.len;
        try self.tickets.name_people.append(
            alloc,
            try SString.fromSlice(alloc, data.name),
        );
        return @intCast(id);
    }

    pub fn priorityName(self: *Self, p: Ticket.Priority) []const u8 {
        return self.tickets.name_priorities.items[@intCast(p)].s;
    }
    pub fn statusName(self: *Self, p: Ticket.Status) []const u8 {
        return self.tickets.name_statuses.items[@intCast(p)].s;
    }
    pub fn typeName(self: *Self, p: Ticket.Type) []const u8 {
        return self.tickets.name_types.items[@intCast(p)].s;
    }
    pub fn personName(self: *Self, p: Ticket.Person) []const u8 {
        return self.tickets.name_people.items[@intCast(p)].s;
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

    const ticket1 = try gf.createTicket(.{ .title = "t", .description = "d", .creator = 0 });
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

    // Create the persistance file with some known data.
    {
        var gofast = try Gofast.init(alloc, filepath);
        defer gofast.deinit();
        const tickets = &gofast.tickets;

        // Sanity check, Gofast starts with nothing predefined.
        try TEST.expectEqual(0, tickets.name_priorities.items.len);
        try TEST.expectEqual(0, tickets.name_statuses.items.len);
        try TEST.expectEqual(0, tickets.name_types.items.len);
        try TEST.expectEqual(0, tickets.tickets.len);
        try TEST.expectEqual(0, tickets.ticket_time_spent.len);

        // Are we even going to attempt saving?
        try TEST.expect(gofast.persistance != null);

        // Statuses
        try TEST.expectEqual(0, try gofast.createStatus(.{ .name = "status0" }));
        try TEST.expectEqual(1, tickets.name_statuses.items.len);

        // Priorities
        try TEST.expectEqual(0, try gofast.createPriority(.{ .name = "priority0" }));
        try TEST.expectEqual(1, try gofast.createPriority(.{ .name = "priority1" }));
        try TEST.expectEqual(2, tickets.name_priorities.items.len);

        // Types
        try TEST.expectEqual(0, try gofast.createType(.{ .name = "type0" }));
        try TEST.expectEqual(1, try gofast.createType(.{ .name = "type1" }));
        try TEST.expectEqual(2, try gofast.createType(.{ .name = "type2" }));
        try TEST.expectEqual(3, tickets.name_types.items.len);

        // People
        const person0 = try gofast.createPerson(.{ .name = "Bozhidar" });
        const person1 = try gofast.createPerson(.{ .name = "Stoyanov" });

        const ticket0 = try gofast.createTicket(.{
            .title = "Test ticket zero",
            .description = "Test description zero",
            .creator = person1,
        });

        const ticket1 = try gofast.createTicket(.{
            .title = "Test ticket one",
            .description = "Test description one",
            .creator = person0,
        });

        try gofast.giveEstimate(ticket0, person0, 300);
        try gofast.logWork(ticket1, person1, 0, 600);
        try gofast.save();
    }

    // Load the persistance data and check if everything got loaded correctly.
    {
        var gofast = try Gofast.init(alloc, filepath);
        defer gofast.deinit();
        const tickets = &gofast.tickets;

        try TEST.expectEqual(1, tickets.name_statuses.items.len);
        try TEST.expectEqualStrings("status0", gofast.statusName(0));

        try TEST.expectEqualStrings("priority0", gofast.priorityName(0));
        try TEST.expectEqualStrings("priority1", gofast.priorityName(1));
        try TEST.expectEqual(2, tickets.name_priorities.items.len);

        try TEST.expectEqual(3, tickets.name_types.items.len);
        try TEST.expectEqualStrings("type0", gofast.typeName(0));
        try TEST.expectEqualStrings("type1", gofast.typeName(1));
        try TEST.expectEqualStrings("type2", gofast.typeName(2));

        try TEST.expectEqual(2, tickets.name_people.items.len);
        try TEST.expectEqualStrings("Bozhidar", gofast.personName(0));
        try TEST.expectEqualStrings("Stoyanov", gofast.personName(1));

        try TEST.expectEqual(2, tickets.tickets.len);
        try TEST.expectEqual(0, tickets.ticket_time_spent.len);
    }
}
test Replay {}
