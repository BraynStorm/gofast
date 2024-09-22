const std = @import("std");
const Tickets = @import("tickets.zig");
const Ticket = Tickets.Ticket;
const TicketStore = Tickets.TicketStore;
const SString = @import("smallstring.zig").ShortString;

const Allocator = std.mem.Allocator;

/// Gofast project system
///
pub const Gofast = struct {
    /// Store the tickets in the system.
    lock: std.Thread.RwLock = .{},
    tickets: TicketStore,
    const Self = @This();

    pub fn init(alloc: Allocator) !Gofast {
        return Gofast{ .tickets = try TicketStore.init(alloc) };
    }
    pub fn deinit(self: *Self) void {
        //TODO(bozho2):
        //  At some point, I should move this to Gofast, instead of the TicketStore.
        //  For now, just steal it.
        self.tickets.deinit();
    }

    /// Create a new ticket.
    ///
    /// This get's called from the REST API
    pub fn createTicket(
        self: *Self,
        title: []const u8,
        desc: []const u8,
        parent: ?Ticket.Key,
        priority: Ticket.Priority,
        type_: Ticket.Type,
        status: Ticket.Status,
    ) !Ticket.Key {
        const alloc = self.tickets.alloc;
        return try self.tickets.addOne(
            try SString.fromSlice(title, alloc),
            try SString.fromSlice(desc, alloc),
            parent,
            priority,
            type_,
            status,
        );
    }

    pub fn deleteTicket(self: *Self, key: Ticket.Key) !void {
        try self.tickets.removeOne(key);
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

    var gf = try Gofast.init(alloc);
    defer gf.deinit();

    try TEST.expect(gf.tickets.max_key == 0);

    const ticket1 = try gf.createTicket("t", "d", null, 0, 0, 0);
    try TEST.expect(ticket1 == 1);

    try gf.deleteTicket(ticket1);
}
test "Gofast.gibberish" {
    const TEST = std.testing;
    const alloc = TEST.allocator;
    var gf = try Gofast.init(alloc);
    defer gf.deinit();
}
test Replay {}
