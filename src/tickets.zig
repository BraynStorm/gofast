const std = @import("std");
const Allocator = std.mem.Allocator;

const SString = @import("smallstring.zig").ShortString;
const SIMDArray = @import("simdarray.zig").SIMDSentinelArray;
const sqlite3 = @import("sqlite3.zig").lib;

pub const Ticket = struct {
    key: Key,
    title: SString,
    description: SString,
    parent: ?Key = null,

    /// Bug, Task, etc.
    type: Type = 0,
    /// High, Normal, Low, etc.
    priority: Priority = 0,
    /// ToDo, InProgress, Done, etc.
    status: Status = 0,

    pub const Key = u32;
    pub const Type = i8;
    pub const Priority = i8;
    pub const Status = i8;

    // const Index = usize;
    pub const LinkType = enum(u8) {
        child = 0,
        blocks = 1,
        duplicates = 2,
    };
    /// Use an ArrayList to store these.
    pub const Link = packed struct {
        from: Key,
        to: Key,
    };
    /// Use a MultiArrayList to store these.
    pub const FatLink = struct {
        to: To = undefined,
        from: Key,

        const To = SIMDArray(Key, null, 0);

        const Self = @This();
        pub fn init(from: Key) Self {
            return FatLink{
                .from = from,
                .to = To.init(),
            };
        }
    };
};

test "Ticket.Link" {
    try std.testing.expectEqual(@sizeOf(Ticket.Link), @sizeOf(usize));
}

///
/// Visual data structure:
/// ```
///                                  U = u32
///                                  LL = usize = u64
///                                  PP = *u8 = usize = u64
///
///                                  One character represents 4 bytes.
/// tickets:                         -----------------------------------------
///     Array(key,   Key     (u32)): |U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|...
///     Array(title, Slice(fatptr)): |LLPP|LLPP|LLPP|LLPP|LLPP|LLPP|LLPP|LLPP|...
///     Array(desc., Slice(fatptr)): |LLPP|LLPP|LLPP|LLPP|LLPP|LLPP|LLPP|LLPP|...
/// graph_children (fat): ---------------------------------------------------
///     Array(from, Key): |U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|U|...
///     Array(to,   Key): |UUUUUUUUUUUUUUUU|UUUUUUUUUUUUUUUU|UUUUUUUUUUUUUUUU|...
///         (uses 0 key as a sentinel to signal "no more keys")
///                       ---------------------------------------------------
/// ```
///
pub const TicketStore = struct {
    /// Storage of keys and other one-to-one things.
    ///
    /// Always kept sorted by .key. (Implcit)
    tickets: std.MultiArrayList(Ticket) = .{},

    // PERF: Convert to a hashmap with a linked list.
    graph_children: std.MultiArrayList(Ticket.FatLink) = .{},

    name_types: StringMap = .{},
    name_priorities: StringMap = .{},
    name_statuses: StringMap = .{},

    /// Allocator stored for convenience.
    alloc: Allocator = undefined,
    /// = largest_ticket_number_ever.
    max_key: u32 = 0,

    const Self = @This();
    const MalIndex = usize;
    const StringMap = std.ArrayListUnmanaged(SString);

    const Error = error{
        NotFound,
        Corrupted,
    };

    pub fn init(alloc: Allocator) !TicketStore {
        const INITIAL_CAPACITY = 16;
        var ts = TicketStore{ .alloc = alloc };
        // Reserve plenty of space for type_names.
        try ts.name_types.ensureTotalCapacity(alloc, 8);
        // Reserve plenty of space for priority_names.
        try ts.name_priorities.ensureTotalCapacity(alloc, 8);
        // Reserve plenty of space for status_names.
        try ts.name_statuses.ensureTotalCapacity(alloc, 16);
        try ts.tickets.ensureTotalCapacity(alloc, INITIAL_CAPACITY);

        return ts;
    }
    pub fn loadFromFile(self: *TicketStore, reader: std.fs.File.Reader) !void {
        const t_start = std.time.nanoTimestamp();
        // Read the MAGIC.
        {
            const gofast_magic = "GOFAST\x00";
            var magic = [_]u8{0} ** 7;
            try reader.readNoEof(&magic);
            if (!std.mem.eql(u8, &magic, gofast_magic)) {
                return error.UnknownFileType;
            }
        }

        // Read the version
        const version = try reader.readInt(u32, .little);
        switch (version) {
            0 => try self.loadFromV0(reader),
            else => return error.UnkownVersion,
        }
        const t_end = std.time.nanoTimestamp();
        const took = t_end - t_start;
        std.log.info("loadFromFile took {}us", .{@divTrunc(took, @as(i128, std.time.ns_per_us))});
    }
    fn loadStringMapV0(alloc: Allocator, reader: std.fs.File.Reader, into: *StringMap) !void {
        const n = try reader.readInt(usize, .little);
        try into.ensureUnusedCapacity(alloc, n);

        for (0..n) |_| {
            const len = try reader.readInt(u32, .little);
            var ss = into.addOneAssumeCapacity();
            ss.s = try alloc.alloc(u8, len);
            errdefer ss.deinit(alloc);
            try reader.readNoEof(ss.s);
        }
    }
    fn loadSStringSliceV0(alloc: Allocator, reader: std.fs.File.Reader, slice: []SString) !void {
        for (0..slice.len) |i| {
            var ss = &slice[i];
            const len = try reader.readInt(u32, .little);
            ss.s = try alloc.alloc(u8, len);
            errdefer ss.deinit(alloc);
            try reader.readNoEof(ss.s);
            // std.log.debug("loadSStringSliceV0: [{}] len={}, content={s}>", .{ i, len, ss.s });
        }
    }
    fn loadFromV0(self: *Self, reader: std.fs.File.Reader) !void {
        try Self.loadStringMapV0(self.alloc, reader, &self.name_types);
        std.log.debug("loadFromV0: Loaded {} name_types", .{self.name_types.items.len});

        try Self.loadStringMapV0(self.alloc, reader, &self.name_priorities);
        std.log.debug("loadFromV0: Loaded {} name_priorities", .{self.name_priorities.items.len});

        try Self.loadStringMapV0(self.alloc, reader, &self.name_statuses);
        std.log.debug("loadFromV0: Loaded {} name_statuses", .{self.name_statuses.items.len});

        const max_key = try reader.readInt(u32, .little);
        std.log.debug("loadFromV0: max_key={}", .{max_key});
        const n_tickets = try reader.readInt(u32, .little);
        std.log.debug("loadFromV0: n_tickets={}", .{n_tickets});

        self.max_key = max_key;

        // Early break
        if (n_tickets == 0) {
            return;
        }

        // Now load the MultiArrayList slice-by-slice.
        try self.tickets.resize(self.alloc, n_tickets);
        var allslice = self.tickets.slice();

        // key: Key,
        // type: Type = 0,
        // priority: Priority = 0,
        // status: Status = 0,
        const keys = allslice.items(.key);
        const types = allslice.items(.type);
        const priorities = allslice.items(.priority);
        const statuses = allslice.items(.status);

        for (0..n_tickets) |i| keys[i] = try reader.readInt(u32, .little);

        for (0..n_tickets) |i| types[i] = try reader.readInt(i8, .little);
        for (0..n_tickets) |i| priorities[i] = try reader.readInt(i8, .little);
        for (0..n_tickets) |i| statuses[i] = try reader.readInt(i8, .little);

        // title: SString,
        // description: SString,
        try loadSStringSliceV0(self.alloc, reader, allslice.items(.title));
        try loadSStringSliceV0(self.alloc, reader, allslice.items(.description));

        // parent: ?Key = null,
        const parents = allslice.items(.parent);
        for (0..n_tickets) |i| {
            parents[i] = null;
        }
        const n_graphs = try reader.readInt(u32, .little);
        if (n_graphs != 1) return error.CorruptedGraph;

        const link_type = try reader.readInt(u8, .little);
        if (link_type != 0)
            return error.CorruptedChildGraph;

        const n_graph_len = try reader.readInt(usize, .little);
        try self.graph_children.ensureTotalCapacity(self.alloc, n_graph_len);
        std.log.debug("loadFromV0: n_graph_len={}", .{n_graph_len});

        // Proceed to read only the parent->children graph.
        for (0..n_graph_len) |_| {
            const parent = try reader.readInt(u32, .little);
            const n_children = @sizeOf(Ticket.FatLink.To) / @sizeOf(u32);
            for (0..n_children) |_| {
                const child = try reader.readInt(u32, .little);
                if (child != 0) {
                    std.log.debug("loadFromV0: setParent({}, {})", .{ child, parent });
                    try self.setParent(child, parent);
                }
            }
        }
    }
    pub fn deinit(self: *Self) void {
        const alloc = self.alloc;
        self.graph_children.deinit(alloc);
        const tickets_slice = self.tickets.slice();
        const titles = tickets_slice.items(.title);
        const descriptions = tickets_slice.items(.description);
        for (0..tickets_slice.len) |i| {
            titles[i].deinit(alloc);
            descriptions[i].deinit(alloc);
        }
        self.tickets.deinit(alloc);
        TicketStore.deinit_stringmap(alloc, &self.name_statuses);
        TicketStore.deinit_stringmap(alloc, &self.name_types);
        TicketStore.deinit_stringmap(alloc, &self.name_priorities);
    }
    fn deinit_stringmap(alloc: Allocator, stringmap: *StringMap) void {
        var i = stringmap.items.len;
        while (i > 0) {
            i -= 1;
            stringmap.items[i].deinit(alloc);
        }
        stringmap.deinit(alloc);
    }

    fn saveV0StringMap(writer: std.fs.File.Writer, map: *const StringMap) !void {
        // Length
        try writer.writeInt(usize, map.items.len, .little);

        // Characters
        for (map.items) |ss| {
            try writer.writeInt(u32, @intCast(ss.s.len), .little);
            try writer.writeAll(ss.s);
        }
    }

    fn saveV0(self: *const Self, writer: std.fs.File.Writer) !void {
        // Magic
        try writer.writeAll("GOFAST\x00");
        // Version
        try writer.writeInt(u32, 0, .little);

        //name_types
        try saveV0StringMap(writer, &self.name_types);
        //name_priorities
        try saveV0StringMap(writer, &self.name_priorities);
        //name_statuses
        try saveV0StringMap(writer, &self.name_statuses);

        //max_key
        try writer.writeInt(u32, self.max_key, .little);

        const allslice = self.tickets.slice();

        //ntickets
        try writer.writeInt(u32, @intCast(allslice.len), .little);

        //-tickets
        //--key
        //--type
        //--priority
        //--status
        for (allslice.items(.key)) |e| try writer.writeInt(u32, e, .little);
        for (allslice.items(.type)) |e| try writer.writeInt(i8, e, .little);
        for (allslice.items(.priority)) |e| try writer.writeInt(i8, e, .little);
        for (allslice.items(.status)) |e| try writer.writeInt(i8, e, .little);

        //--title
        //--description
        for (allslice.items(.title)) |e| {
            try writer.writeInt(u32, @intCast(e.s.len), .little);
            try writer.writeAll(e.s);
        }
        for (allslice.items(.description)) |e| {
            try writer.writeInt(u32, @intCast(e.s.len), .little);
            try writer.writeAll(e.s);
        }

        //n_children_graph
        try writer.writeInt(u32, 1, .little);

        //linktype=child
        const child = 0; // Ticket.LinkType.child
        try writer.writeInt(u8, child, .little);

        const children = self.graph_children.slice();

        //n_graph_nodes
        try writer.writeInt(usize, children.len, .little);

        //-graph
        //--from
        //--to
        for (children.items(.from), children.items(.to)) |f, t| {
            try writer.writeInt(u32, f, .little);
            for (t.array()) |c| {
                try writer.writeInt(u32, c, .little);
            }
        }
    }
    pub fn save(self: *const Self, writer: std.fs.File.Writer) !void {
        std.log.debug("Saving", .{});
        try self.saveV0(writer);
    }

    /// Add a new ticket.
    ///
    /// It's key will be auto-assigned.
    /// TODO:
    ///     Just take a Ticket-like struct instead of this parameter mess,
    ///     It's not even type-safe!
    pub fn addOne(
        self: *Self,
        title: SString,
        description: SString,
        parent: ?Ticket.Key,
        type_: Ticket.Type,
        priority: Ticket.Priority,
        status: Ticket.Status,
    ) !Ticket.Key {
        self.max_key += 1;
        const key = self.max_key;
        try self.tickets.append(self.alloc, .{
            .key = key,
            .title = title,
            .description = description,
            .parent = parent,
            .type = type_,
            .priority = priority,
            .status = status,
        });

        if (parent != null) {
            // We need to connect the child as well.
            try self.setParent(key, parent);
        }

        return key;
    }

    pub fn findParent(self: *const Self, key: Ticket.Key) Error!?Ticket.Key {
        const index = try self.findIndex(key);
        return self.tickets.items(.parent)[index];
    }

    pub fn removeOne(self: *Self, key: Ticket.Key) Error!void {
        const index = self.findIndex(key) catch {
            return error.NotFound;
        };

        const parent = self.tickets.items(.parent)[index];

        if (parent) |par| {
            //PERF:
            //  Merge these two functions.
            self.clearParentFromGraphWithIndex(key, par);
            self.clearChildrenFromGraphWithIndex(key);
        } else {
            self.clearChildrenFromGraphWithIndex(key);
        }

        const tickets_slice = self.tickets.slice();
        tickets_slice.items(.title)[index].deinit(self.alloc);
        tickets_slice.items(.description)[index].deinit(self.alloc);
        self.tickets.orderedRemove(index);
    }

    pub fn clearParent(self: *Self, ticket: Ticket.Key) Error!void {
        const index = try self.findIndex(ticket);
        return self.clearParent(ticket, index);
    }

    fn clearChildrenFromGraphWithIndex(self: *Self, ticket: Ticket.Key) void {
        const froms = self.graph_children.items(.from);
        const tos = self.graph_children.items(.to);
        const ticket_keys = self.tickets.items(.key);
        const ticket_parents = self.tickets.items(.parent);

        // Loop over the whole chidren graph, looking for the parent's entries.
        var i: usize = self.graph_children.len;

        while (i > 0) {
            i -= 1;
            const from = froms[i];
            if (from == ticket) {
                // Make sure to clear each child's .parent to null.
                const children: Ticket.FatLink.To = tos[i];

                // PERF:
                //  There are many ways to optimize this.
                //    - Keep a key-index pair of the last child, reducing the
                //      search space "in half", something like findIndexBounded()...
                //    - We can also implement binary serach here.
                //    - We can also also implement SIMD searching for multiple children
                //    at the same time.
                for (children.array()) |child_key| {
                    for (ticket_keys, 0..) |maybe_child_key, child_index| {
                        if (child_key == maybe_child_key) {
                            // Found a child, clear it's parent.
                            ticket_parents[child_index] = null;
                        }
                    }
                }

                self.graph_children.orderedRemove(i);
            }
        }
    }

    fn clearParentFromGraphWithIndex(self: *Self, ticket: Ticket.Key, parent: Ticket.Key) void {
        const froms = self.graph_children.items(.from);
        const tos = self.graph_children.items(.to);

        // Loop over the whole chidren graph, looking for the parent's entries.
        for (froms, 0..) |from, i| {
            if (from == parent) {
                // Okay, tos[i] has children of old_p.
                if (tos[i].maybeRemoveOne(ticket)) {
                    // We're done.
                    break;
                } else {
                    // Keep digging, we have to find the joke (child).
                    continue;
                }
            }
        }
    }
    fn clearParentWithIndex(self: *Self, ticket: Ticket.Key, index: Ticket.Index) void {
        const parent_ptr = &self.tickets.items(.parent)[index];
        const old_parent: ?u32 = parent_ptr.*;
        parent_ptr.* = null;

        if (old_parent) |old_p| {
            // We need to disconnect the parent's children graph.
            const froms = self.graph_children.items(.from);
            const tos = self.graph_children.items(.to);

            // Loop over the whole chidren graph, looking for the parent's entries.
            for (froms, 0..) |from, i| {
                if (from == old_p) {
                    // Okay, tos[i] has children of old_p.
                    if (tos[i].maybeRemoveOne(ticket)) {
                        // We're done.
                        break;
                    } else {
                        // Keep digging, we have to find the joke (child).
                        continue;
                    }
                }
            }
        }
    }
    pub fn connectFromTo(self: *Self, from: Ticket.Key, to: Ticket.Key) !void {
        return self.setParent(to, from);
    }
    pub fn setParent(self: *Self, ticket: Ticket.Key, new_parent: ?Ticket.Key) !void {
        const index = try self.findIndex(ticket);

        const parent_ptr = &self.tickets.items(.parent)[index];
        const old_parent: ?u32 = parent_ptr.*;
        parent_ptr.* = new_parent;

        if (old_parent) |old_p| {
            // We need to disconnect the parent's children graph.
            const froms = self.graph_children.items(.from);
            const tos = self.graph_children.items(.to);

            // Loop over the whole chidren graph, looking for the parent's entries.
            for (froms, 0..) |from, i| {
                if (from == old_p) {
                    // Okay, tos[i] has children of old_p.
                    if (tos[i].maybeRemoveOne(ticket)) {
                        // We're done.
                        break;
                    } else {
                        // Keep digging, we have to find the joke (child).
                        continue;
                    }
                }
            }
        }

        if (new_parent) |new_p| {
            // We need to connect the new_parent's children graph.
            const froms = self.graph_children.items(.from);
            const tos = self.graph_children.items(.to);

            // Loop over the whole chidren graph, looking for the parent's entries.
            for (froms, 0..) |from, i| {
                if (from == new_p) {
                    // Okay, tos[i] has children of new_p.
                    if (tos[i].maybeAddOne(ticket)) {
                        // We're done.
                        break;
                    } else {
                        // Keep searching for a speot
                        continue;
                    }
                }
            } else {
                // We didn't find anywhere to put it, allocate a new FatLink slot.
                var fat_link = Ticket.FatLink.init(new_p);
                if (!fat_link.to.maybeAddOne(ticket)) {
                    // It is always possible to insert after creating a FatLink.
                    unreachable;
                }

                try self.graph_children.append(self.alloc, fat_link);
            }
        }
    }

    /// Find the key of a given ticket index.
    fn findKey(self: *const Self, index: MalIndex) Ticket.Key {
        return self.tickets.items(.ticket)[index];
    }

    fn findIndex(self: *const Self, key: Ticket.Key) Error!MalIndex {
        for (self.tickets.items(.key), 0..) |k, i| {
            if (k == key)
                return i;
        }

        return error.NotFound;
    }
    fn findIndexBounded(self: *const Self, key: Ticket.Key, min: MalIndex, max: MalIndex) Error!MalIndex {
        for (self.tickets.items(.key)[min..max], min..max) |k, i| {
            if (k == key)
                return i;
        }

        return error.NotFound;
    }

    /// Collect all children from a given ticket to any other ticket.
    pub fn childrenAlloc(
        self: *const Self,
        from: Ticket.Key,
        alloc: Allocator,
        guess_count: ?usize,
    ) ![]Ticket.Key {
        const initial_capacity: usize = if (guess_count) |g| g else 8;

        // Hold the links here.
        var our_children = try std.ArrayListUnmanaged(Ticket.Key).initCapacity(self.alloc, initial_capacity);

        const fat_links = self.graph_children.items(.to);
        for (self.graph_children.items(.from), 0..) |graph_from, i| {
            if (graph_from != from) continue;

            // We found a FatLink from us to ... somethings.
            var links_to = fat_links[i];

            // Push them to our buffer.
            const links_to_array = links_to.array();
            try our_children.appendSlice(alloc, links_to_array[0..links_to.len()]);

            // unreachable;
        }

        our_children.shrinkAndFree(alloc, our_children.items.len);
        return our_children.items;
    }
};

pub fn printChildrenGraph(ticket_store: *const TicketStore, alloc: Allocator) void {
    // ticket_store.
    std.debug.print("Graph: Parent -> Children\n", .{});

    for (ticket_store.tickets.items(.key)) |key_parent| {
        std.debug.print("{} -> ", .{key_parent});
        const children = ticket_store.childrenAlloc(key_parent, alloc, 8) catch unreachable;
        defer alloc.free(children);

        for (children) |c| {
            std.debug.print("{} ", .{c});
        }
        std.debug.print("\n", .{});
    }
}

test TicketStore {
    const TEST = std.testing;
    const alloc = TEST.allocator;

    var store = try TicketStore.init(alloc);
    defer store.deinit();

    const k1 = try store.addOne(try SString.fromSlice("T1", alloc), try SString.fromSlice("D1", alloc), null, 0, 0, 0);
    try TEST.expect(k1 != 0);
    const k2 = try store.addOne(try SString.fromSlice("T2", alloc), try SString.fromSlice("D2", alloc), null, 0, 0, 0);
    try TEST.expect(k2 != 0);
    const k3 = try store.addOne(try SString.fromSlice("T3", alloc), try SString.fromSlice("D3", alloc), null, 0, 0, 0);
    try TEST.expect(k3 != 0);
    const k4 = try store.addOne(try SString.fromSlice("T4", alloc), try SString.fromSlice("D4", alloc), null, 0, 0, 0);
    try TEST.expect(k4 != 0);
    const k5 = try store.addOne(try SString.fromSlice("T5", alloc), try SString.fromSlice("D5", alloc), null, 0, 0, 0);
    try TEST.expect(k5 != 0);

    // Setting a parent directly.
    const k6 = try store.addOne(try SString.fromSlice("T6", alloc), try SString.fromSlice("D6", alloc), k1, 0, 0, 0);
    try TEST.expect(k6 != 0);
    {
        const k1children = try store.childrenAlloc(k1, alloc, 1);
        defer alloc.free(k1children);

        try TEST.expectEqual(1, k1children.len);
        try TEST.expectEqual(k6, k1children[0]);
    }

    // Removing some child
    {
        try store.removeOne(k6);
        const k1children = try store.childrenAlloc(k1, alloc, 1);
        // defer alloc.free(k1children);
        try TEST.expectEqual(0, k1children.len);
    }

    // Add one child
    try store.connectFromTo(k1, k2);

    // Add another child and remove the parent
    const k7 = try store.addOne(try SString.fromSlice("T7", alloc), try SString.fromSlice("D7", alloc), k1, 0, 0, 0);
    try TEST.expect(k7 != 0);
    {
        const k1children = try store.childrenAlloc(k1, alloc, 1);
        defer alloc.free(k1children);

        printChildrenGraph(&store, alloc);

        try TEST.expectEqual(2, k1children.len);
        try TEST.expectEqual(k2, k1children[0]);
        try TEST.expectEqual(k7, k1children[1]);
    }
    try store.removeOne(k1);
    try TEST.expectEqual(null, store.findParent(k2));
    try TEST.expectEqual(null, store.findParent(k7));

    printChildrenGraph(&store, alloc);
}

test "TicketStore.sizes" {
    std.debug.print("@sizeOf(Ticket.Key) = {}\n", .{@sizeOf(Ticket.Key)});
    std.debug.print("@sizeOf(Ticket.Link) = {}\n", .{@sizeOf(Ticket.Link)});
    std.debug.print("@sizeOf(Ticket.FatLink) = {}\n", .{@sizeOf(Ticket.FatLink)});
}
