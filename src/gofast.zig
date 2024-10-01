const std = @import("std");
const assert = std.debug.assert;
const SString = @import("smallstring.zig").ShortString;
const SIMDArray = @import("simdarray.zig").SIMDSentinelArray;

const Allocator = std.mem.Allocator;

const log = std.log.scoped(.Gofast);

/// Gofast project system
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
///
/// TODO:
///     Specify precise error sets.
pub const Gofast = struct {
    /// RwLock to allow multiple readers, but only one writer.
    lock: std.Thread.RwLock = .{},
    /// Allocator stored for convenience.
    alloc: Allocator = undefined,
    /// Where do we save the data. Null - in-memory storage only.
    persistance: ?std.fs.File = null,

    /// Storage of keys and other one-to-one things.
    ///
    /// Always kept sorted by .key. (Implcit)
    tickets: Tickets = .{},
    time_spent: std.MultiArrayList(TicketTime) = .{},
    // PERF: Convert to a hashmap with a linked list.
    graph_children: GraphChildren = .{},
    names: struct {
        types: StringMap = .{},
        priorities: StringMap = .{},
        statuses: StringMap = .{},
        people: StringMap = .{},
    } = .{},

    /// Store the tickets in the system.
    history: History,

    /// = largest_ticket_number_ever.
    max_ticket_key: u32 = 0,

    const Self = @This();

    pub const TicketIndex = usize;
    pub const Tickets = std.MultiArrayList(Ticket);
    pub const Timestamp = i64;
    pub const Person = u32;
    pub const Ticket = struct {
        key: Key,
        parent: ?Key = null,
        title: SString,
        description: SString,

        details: Details,
        creator: Person,
        created_on: i64,
        last_updated_by: Person,
        last_updated_on: i64,

        pub const Key = u32;
        pub const Order = f32;
        pub const Type = u8;
        pub const Priority = u8;
        pub const Status = u8;
        pub const Details = packed struct {
            /// Padding, TODO: Find something else to put here.
            _padding: u8 = 0,
            /// Bug, Task, etc.
            type: Type = 0,
            /// ToDo, InProgress, Done, etc.
            status: Status = 0,
            /// High, Normal, Low, etc.
            priority: Priority = 0,
            /// Sub-priority
            order: Order,
        };

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

            pub fn init(from: Key) FatLink {
                return FatLink{
                    .from = from,
                    .to = To.init(),
                };
            }
        };
    };
    //PERF:
    //  There's probably a better way to arrange this,
    //  such that we can easily find stuff.
    /// Use a MAL to store these.
    pub const TicketTime = struct {
        ticket: Ticket.Key,
        person: Person,
        time: packed struct {
            estimate: Seconds = 0,
            spent: Seconds = 0,
        } = .{},

        pub const Seconds = u32; // Can fit ~500years of full workdays
    };
    pub const StringMap = std.ArrayListUnmanaged(SString);
    pub const GraphChildren = std.MultiArrayList(Ticket.FatLink);
    const Error = error{
        NotFound,
        Corrupted,
    };

    /// Init the whole system, with `persistence` as a relative
    /// path for storing/loading data from.
    pub fn init(alloc: Allocator, persitence: ?[]const u8) !Gofast {
        const INITIAL_CAPACITY = 16;

        var g = Gofast{
            .alloc = alloc,
            .history = .{
                .arena_string = std.heap.ArenaAllocator.init(alloc),
            },
        };
        // Reserve plenty of space for type_names.
        try g.names.types.ensureTotalCapacity(alloc, 8);
        // Reserve plenty of space for priority_names.
        try g.names.priorities.ensureTotalCapacity(alloc, 8);
        // Reserve plenty of space for status_names.
        try g.names.statuses.ensureTotalCapacity(alloc, 16);
        try g.tickets.ensureTotalCapacity(alloc, INITIAL_CAPACITY);

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
                break :blk f;
            };

            if (load) {
                log.info("Loading data from persistance {s}", .{p});
                try g.loadFromFile(file.reader());
            } else {
                g.persistance = file;
                // Save it so it's not empty the next time.
                try g.save();
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
        const alloc = self.alloc;
        self.graph_children.deinit(alloc);
        const tickets_slice = self.tickets.slice();
        const titles = tickets_slice.items(.title);
        const descriptions = tickets_slice.items(.description);
        for (0..tickets_slice.len) |i| {
            titles[i].deinit(alloc);
            descriptions[i].deinit(alloc);
        }
        self.time_spent.deinit(alloc);
        Gofast.deinit_stringmap(alloc, &self.names.statuses);
        Gofast.deinit_stringmap(alloc, &self.names.types);
        Gofast.deinit_stringmap(alloc, &self.names.priorities);
        Gofast.deinit_stringmap(alloc, &self.names.people);
        self.history.deinit(alloc);
        self.tickets.deinit(alloc);
    }

    /// Save the state of Gofast to the persistence file, if any.
    pub fn save(self: *Self) !void {
        if (self.persistance) |p| {
            log.info(".save", .{});
            try p.seekTo(0);
            try self.saveV0(p.writer());
        } else {
            return error.NoPersistance;
        }
    }
    /// Generate a "now" timestamp, in the units expected by Gofast (ms).
    pub fn timestamp() Timestamp {
        return std.time.milliTimestamp();
    }

    /// Create a new ticket
    ///
    /// now = Gofast.timestamp()
    pub fn createTicket(
        self: *Self,
        craetor: Person,
        now: Timestamp,
        action: History.Event.Action.CreateTicket,
    ) !Ticket.Key {
        const alloc = self.alloc;

        const ticket = try self.addTicketNoHistory(.{
            .title = try SString.fromSlice(alloc, action.title),
            .description = try SString.fromSlice(alloc, action.description),
            .parent = action.parent,
            .priority = action.priority,
            .type_ = action.type_,
            .status = action.status,
            .creator = craetor,
            .created_on = now,
            .last_updated_by = craetor,
            .last_updated_on = now,
        });

        try self.history.addEvent(self.alloc, .{
            .timestamp = now,
            .ticket = ticket,
            .user = craetor,
            .action = .{ .create_ticket = action },
        });

        return ticket;
    }

    /// Delete an existing ticket.
    ///
    /// TODO:
    ///     Remove this function, as we'd like to keep an
    ///     "infinite" history of tickets.
    pub fn deleteTicket(self: *Self, key: Ticket.Key) !void {
        try self.removeTicket(key);
    }

    /// Change some data about a ticket.
    ///
    /// The ticket must exist.
    pub fn updateTicket(
        self: *Self,
        key: Ticket.Key,
        updater: Person,
        u: struct {
            title: ?[]const u8 = null,
            description: ?[]const u8 = null,
            parent: ??Ticket.Key = null,
            type: ?Ticket.Type = null,
            status: ?Ticket.Status = null,
            priority: ?Ticket.Priority = null,
            order: ?Ticket.Order = null,
        },
    ) !void {
        const alloc = self.alloc;

        var tickets = self.tickets.slice();

        // Find the ticket's index in the MAL.
        //PERF:
        //  We can take advantage of the fact that the whole ticket_store
        //  is ordered by key and that keys are sequential and non-repeating.
        //  Thus, starting at the index `ticket_key-1`, we guarantee that we're
        //  as close to the actual ticket as possible.
        const index = try self.findTicketIndex(key);

        //TODO:
        //  Record the changes in some history structure.

        log.debug("updateTicket: #{}.last_updated_by = {}", .{ key, updater });
        if (u.type) |p| {
            tickets.items(.details)[index].type = p;
            log.debug("updateTicket: #{}.type = {}", .{ key, p });
        }
        if (u.status) |p| {
            tickets.items(.details)[index].status = p;
            log.debug("updateTicket: #{}.status = {}", .{ key, p });
        }
        if (u.priority) |p| {
            tickets.items(.details)[index].priority = p;
            log.debug("updateTicket: #{}.priority = {}", .{ key, p });
        }
        if (u.order) |p| {
            tickets.items(.details)[index].order = p;
            log.debug("updateTicket: #{}.order = {}", .{ key, p });
        }
        if (u.parent) |p| {
            //PERF:
            // Can optimize this by reusing the index we already found in the code above.
            try self.setParent(key, p);
            log.debug("updateTicket: #{}.parent = {?}", .{ key, p });
        }
        if (u.title) |p| {
            const titles = tickets.items(.title);
            var old = titles[index];
            old.deinit(alloc);
            titles[index] = try SString.fromSlice(alloc, p);
            log.debug("updateTicket: #{}.title = {s}", .{ key, p[0..@min(p.len, 16)] });
        }
        if (u.description) |p| {
            const descriptions = tickets.items(.description);
            var old = descriptions[index];
            old.deinit(alloc);
            descriptions[index] = try SString.fromSlice(alloc, p);
            log.debug("updateTicket: #{}.description = {s}", .{ key, p[0..@min(p.len, 16)] });
        }

        // PERF: Maybe put these together?
        tickets.items(.last_updated_by)[index] = updater;
        tickets.items(.last_updated_on)[index] = timestamp();
    }

    /// Create a new Priority
    pub fn createPriority(self: *Self, data: struct {
        name: []const u8,
    }) !Ticket.Priority {
        const alloc = self.alloc;
        const id = self.names.priorities.items.len;
        try self.names.priorities.append(
            alloc,
            try SString.fromSlice(alloc, data.name),
        );
        return @intCast(id);
    }

    /// Create a new Status
    pub fn createStatus(self: *Self, data: struct {
        name: []const u8,
    }) !Ticket.Status {
        const alloc = self.alloc;
        const id = self.names.statuses.items.len;
        try self.names.statuses.append(
            alloc,
            try SString.fromSlice(alloc, data.name),
        );
        return @intCast(id);
    }

    /// Create a new Type
    pub fn createType(self: *Self, data: struct {
        name: []const u8,
    }) !Ticket.Type {
        const alloc = self.alloc;
        const id = self.names.types.items.len;
        try self.names.types.append(
            alloc,
            try SString.fromSlice(alloc, data.name),
        );
        return @intCast(id);
    }

    /// Create a new Person
    pub fn createPerson(self: *Self, data: struct { name: []const u8 }) !Person {
        const alloc = self.alloc;
        const id = self.names.people.items.len;
        try self.names.people.append(
            alloc,
            try SString.fromSlice(alloc, data.name),
        );
        return @intCast(id);
    }

    pub fn priorityName(self: *Self, p: Ticket.Priority) []const u8 {
        return self.names.priorities.items[@intCast(p)].s;
    }
    pub fn statusName(self: *Self, p: Ticket.Status) []const u8 {
        return self.names.statuses.items[@intCast(p)].s;
    }
    pub fn typeName(self: *Self, p: Ticket.Type) []const u8 {
        return self.names.types.items[@intCast(p)].s;
    }
    pub fn personName(self: *Self, p: Person) []const u8 {
        return self.names.people.items[@intCast(p)].s;
    }

    pub fn loadFromFile(self: *Self, reader: std.fs.File.Reader) !void {
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
        log.info("Loading took {}us", .{@divTrunc(took, @as(i128, std.time.ns_per_us))});
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
            // std.debug.print("loadSStringSliceV0: allocating {}\n", .{len});
            ss.s = try alloc.alloc(u8, len);
            errdefer ss.deinit(alloc);
            try reader.readNoEof(ss.s[0..len]);
            // std.debug.print("loadSStringSliceV0: [{}] len={}, content={s}>\n", .{ i, len, ss.s });
            std.debug.print("loadSStringSliceV0: [{}] len={}\n", .{ i, len });
        }
    }
    fn loadFromV0(self: *Self, reader: std.fs.File.Reader) !void {
        try Self.loadStringMapV0(self.alloc, reader, &self.names.types);
        log.info("loadFromV0: Loaded {} types", .{self.names.types.items.len});

        try Self.loadStringMapV0(self.alloc, reader, &self.names.priorities);
        log.info("loadFromV0: Loaded {} priorities", .{self.names.priorities.items.len});

        try Self.loadStringMapV0(self.alloc, reader, &self.names.statuses);
        log.info("loadFromV0: Loaded {} statuses", .{self.names.statuses.items.len});

        try Self.loadStringMapV0(self.alloc, reader, &self.names.people);
        log.info("loadFromV0: Loaded {} people", .{self.names.people.items.len});

        const max_key = try reader.readInt(u32, .little);
        log.info("loadFromV0: max_key={}", .{max_key});
        const n_tickets = try reader.readInt(u32, .little);
        log.info("loadFromV0: n_tickets={}", .{n_tickets});

        self.max_ticket_key = max_key;

        // Early break
        if (n_tickets == 0) {
            return;
        }

        // Now load the MultiArrayList slice-by-slice.
        try self.tickets.resize(self.alloc, n_tickets);
        var allslice = self.tickets.slice();

        for (allslice.items(.key)) |*i| i.* = try reader.readInt(u32, .little);
        for (allslice.items(.details)) |*i| {
            i.type = try reader.readInt(u8, .little);
            i.status = try reader.readInt(u8, .little);
            i.priority = try reader.readInt(u8, .little);
            comptime assert(@sizeOf(u32) == @sizeOf(Ticket.Order));
            i.order = @bitCast(try reader.readInt(u32, .little));
        }
        for (allslice.items(.creator)) |*i| i.* = try reader.readInt(u32, .little);
        for (allslice.items(.created_on)) |*i| i.* = try reader.readInt(i64, .little);
        for (allslice.items(.last_updated_by)) |*i| i.* = try reader.readInt(u32, .little);
        for (allslice.items(.last_updated_on)) |*i| i.* = try reader.readInt(i64, .little);

        // title: SString,
        // description: SString,
        try loadSStringSliceV0(self.alloc, reader, allslice.items(.title));
        try loadSStringSliceV0(self.alloc, reader, allslice.items(.description));

        // parent: ?Key = null,
        const parents = allslice.items(.parent);
        for (0..n_tickets) |i| {
            parents[i] = null;
        }
        const n_graphs = try reader.readInt(usize, .little);
        log.info("loadFromV0: n_graphs={}", .{n_graphs});
        for (0..n_graphs) |i_graph| {
            // Unused for now
            _ = i_graph;

            switch (try reader.readInt(u8, .little)) {
                // Child Graph
                0 => {
                    log.info("loadFromV0: loading graph 0", .{});
                    const n_graph_len = try reader.readInt(usize, .little);

                    log.info("loadFromV0: n_graph_len={}", .{n_graph_len});
                    try self.graph_children.resize(self.alloc, n_graph_len);
                    for (self.graph_children.items(.from)) |*from| {
                        from.* = try reader.readInt(u32, .little);
                    }
                    for (self.graph_children.items(.from), self.graph_children.items(.to)) |from, *to| {
                        for (0..Ticket.FatLink.To.capacity) |i| {
                            const parent_key = from;
                            const child_key = try reader.readInt(u32, .little);
                            to.*.items[i] = child_key;
                            log.info("loadFromV0: link: {} -> {}", .{ from, child_key });
                            if (child_key != 0) {
                                // Actually set the .parent field.
                                const child_index = try self.findTicketIndex(child_key);
                                parents[child_index] = parent_key;
                            }
                        }
                    }
                    self.compact_children_graph();
                },
                else => return error.UnknownGraphType,
            }
        }

        // Read ticket_time_spent
        {
            const n_time_spent = try reader.readInt(usize, .little);
            try self.time_spent.resize(self.alloc, n_time_spent);
            const time_spent_slice = self.time_spent.slice();

            const ts_people = time_spent_slice.items(.person);
            const ts_time = time_spent_slice.items(.time);
            for (time_spent_slice.items(.ticket)) |*ticket| ticket.* = try reader.readInt(u32, .little);
            for (0..n_time_spent) |i| ts_people[i] = try reader.readInt(u32, .little);
            for (0..n_time_spent) |i| ts_time[i] = .{
                .estimate = try reader.readInt(u32, .little),
                .spent = try reader.readInt(u32, .little),
            };
        }
    }
    /// Remove holes and combine split parents into tight(er) buckets.
    fn compact_children_graph(self: *Self) void {
        var i: usize = 0;
        const slice = self.graph_children.slice();
        const tos = slice.items(.to);
        const froms = slice.items(.from);

        const t_start_comapct = std.time.nanoTimestamp();
        while (true) {
            // Important! Do not for(..) loop this, as it will fuck up when we
            // try to delete thing WHILE iterating.
            if (i >= self.graph_children.len) {
                // We're done.
                break;
            }

            const from = froms[i];
            const to = tos[i];

            // Check for empty buckets
            if (to.items[0] == 0) {
                // If the first one is 0, the all of the other should be, right?
                assert(Ticket.FatLink.To.capacity == std.simd.countTrues(
                    to.items == @as(Ticket.FatLink.To.Vector, @splat(0)),
                ));

                std.log.info("compact_children_graph: Removing [{}] {} -> 16x0s", .{ i, from });

                // We don't care about the order, so we swap-remove.
                self.graph_children.swapRemove(i);
                // Important! "Repeat" the current iteration, don't i+1.
                continue;
            }

            i += 1;
        }
        const t_end_compact = std.time.nanoTimestamp();

        const Compare = struct {
            from: []Ticket.Key,
            pub fn lessThan(s: *const @This(), a: usize, b: usize) bool {
                return s.from[a] < s.from[b];
            }
        };

        self.graph_children.sort(Compare{ .from = froms });
        const t_end_sort = std.time.nanoTimestamp();

        std.log.info("compact_children_graph: compacting took {}us", .{@divTrunc((t_start_comapct - t_end_compact), std.time.ns_per_us)});
        std.log.info("compact_children_graph: sorting took {}us", .{@divTrunc((t_end_sort - t_end_compact), std.time.ns_per_us)});
    }
    // fn lessThan_GraphChildren(self: [] const , a: usize, b: usize) bool {}
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
        try saveV0StringMap(writer, &self.names.types);
        //name_priorities
        try saveV0StringMap(writer, &self.names.priorities);
        //name_statuses
        try saveV0StringMap(writer, &self.names.statuses);
        //name_people
        try saveV0StringMap(writer, &self.names.people);

        //max_key
        try writer.writeInt(u32, self.max_ticket_key, .little);

        const allslice = self.tickets.slice();

        //ntickets
        try writer.writeInt(u32, @intCast(allslice.len), .little);

        //-tickets
        //--key
        //--type
        //--priority
        //--status
        for (allslice.items(.key)) |e| try writer.writeInt(u32, e, .little);
        for (allslice.items(.details)) |e| {
            try writer.writeInt(u8, e.type, .little);
            try writer.writeInt(u8, e.status, .little);
            try writer.writeInt(u8, e.priority, .little);
            comptime assert(@sizeOf(u32) == @sizeOf(Ticket.Order));
            try writer.writeInt(u32, @bitCast(e.order), .little);
        }
        for (allslice.items(.creator)) |e| try writer.writeInt(u32, e, .little);
        for (allslice.items(.created_on)) |e| try writer.writeInt(i64, e, .little);
        for (allslice.items(.last_updated_by)) |e| try writer.writeInt(u32, e, .little);
        for (allslice.items(.last_updated_on)) |e| try writer.writeInt(i64, e, .little);

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

        {
            //n_graphs
            try writer.writeInt(usize, 1, .little);

            //linktype=child
            const child = 0; // Ticket.LinkType.child
            try writer.writeInt(u8, child, .little);

            const children = self.graph_children.slice();

            //n_graph_nodes
            try writer.writeInt(usize, children.len, .little);

            for (children.items(.from)) |from| try writer.writeInt(u32, from, .little);
            for (children.items(.to)) |*to| {
                for (&to.array()) |to_child| {
                    try writer.writeInt(u32, to_child, .little);
                }
            }
        }

        // ticket_time_spent
        {
            const ticket_time_slice = self.time_spent.slice();
            try writer.writeInt(usize, ticket_time_slice.len, .little);
            for (ticket_time_slice.items(.ticket)) |ticket| {
                try writer.writeInt(u32, ticket, .little);
            }
            for (ticket_time_slice.items(.person)) |person| {
                try writer.writeInt(u32, person, .little);
            }
            for (ticket_time_slice.items(.time)) |time| {
                try writer.writeInt(u32, time.estimate, .little);
                try writer.writeInt(u32, time.spent, .little);
            }
        }
    }

    /// Add a new ticket.
    ///
    /// It's key will be auto-assigned.
    fn addTicketNoHistory(
        self: *Self,
        c: struct {
            title: SString,
            description: SString,
            parent: ?Ticket.Key,
            type_: Ticket.Type,
            priority: Ticket.Priority,
            status: Ticket.Status,
            creator: Person,
            created_on: i64,
            last_updated_by: Person,
            last_updated_on: i64,
        },
    ) !Ticket.Key {
        self.max_ticket_key += 1;
        const key = self.max_ticket_key;
        try self.tickets.append(self.alloc, .{
            .key = key,
            .title = c.title,
            .description = c.description,
            .parent = null,
            .details = .{
                .type = c.type_,
                .status = c.status,
                .priority = c.priority,
                .order = @floatFromInt(key),
            },
            .creator = c.creator,
            .created_on = c.created_on,
            .last_updated_by = c.last_updated_by,
            .last_updated_on = c.last_updated_on,
        });

        if (c.parent != null) {
            // We need to connect the child as well.
            try self.setParent(key, c.parent);
        }

        return key;
    }

    pub fn findParent(self: *const Self, key: Ticket.Key) Error!?Ticket.Key {
        const index = try self.findTicketIndex(key);
        return self.tickets.items(.parent)[index];
    }

    pub fn removeTicket(self: *Self, key: Ticket.Key) Error!void {
        const index = try self.findTicketIndex(key);
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
        const index = try self.findTicketIndex(ticket);
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
        const index = try self.findTicketIndex(ticket);

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

    pub fn findTicketIndex(self: *const Self, key: Ticket.Key) Error!TicketIndex {
        const max_index = @min(key, self.tickets.len);
        return std.mem.indexOfScalar(
            Ticket.Key,
            self.tickets.items(.key)[0..max_index],
            key,
        ) orelse error.NotFound;
    }

    /// Collect all children from a given ticket to any other ticket.
    pub fn ticketChildrenAlloc(
        self: *const Self,
        from: Ticket.Key,
        alloc: Allocator,
        guess_count: ?usize,
    ) ![]Ticket.Key {
        const initial_capacity: usize = guess_count orelse 8;

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

    /// Log work by a single person on a single
    pub fn logWork(
        self: *Self,
        ticket: Ticket.Key,
        person: Person,
        timestamp_started: i64,
        timestamp_ended: i64,
    ) !void {
        const worked_seconds_i64 = timestamp_ended - timestamp_started;
        if (worked_seconds_i64 < 0) {
            return error.NegativeWorktime;
        }

        const spent: Gofast.TicketTime.Seconds = @intCast(worked_seconds_i64);

        // TODO: Check if ticket actually exists.
        // TODO(histroy): Save the start/end times in a separate structure.

        var allslice = self.time_spent.slice();

        for (allslice.items(.ticket), allslice.items(.person), 0..) |t, p, i| {
            if (t == ticket and p == person) {
                var time = &allslice.items(.time)[i];
                log.debug("logWork: found entry for t={}, p={}. oldSeconds={}, newSeconds={}", .{
                    ticket, person, time.spent, time.spent + spent,
                });
                time.spent += spent;
                break;
            }
        } else {
            // We didn't find an entry matching the ticket-person.
            try self.time_spent.append(self.alloc, .{
                .ticket = ticket,
                .person = person,
                .time = .{ .spent = spent },
            });
            log.debug("logWork: added new entry for t={}, p={}, seconds={}", .{ ticket, person, spent });
        }
    }
    /// Give estimate
    pub fn setEstimate(
        self: *Self,
        ticket: Gofast.Ticket.Key,
        person: Person,
        estimate: Gofast.TicketTime.Seconds,
    ) !void {
        // TODO: Check if ticket actually exists.
        // TODO(histroy): Save the start/end times in a separate structure.

        var allslice = self.time_spent.slice();

        for (allslice.items(.ticket), allslice.items(.person), 0..) |t, p, i| {
            if (t == ticket and p == person) {
                var time = &allslice.items(.time)[i];
                log.debug("setEstimate: found entry for t={}, p={}. e={}, new_e={}", .{
                    ticket, person, time.estimate, time.estimate + estimate,
                });
                time.estimate += estimate;
                break;
            }
        } else {
            // We didn't find an entry matchin the ticket-person.
            try self.time_spent.append(self.alloc, .{
                .ticket = ticket,
                .person = person,
                .time = .{ .estimate = estimate },
            });
            log.debug("setEstimate: added new entry for t={}, p={}, e={}", .{
                ticket,
                person,
                estimate,
            });
        }
    }
};

/// Record a history of all actions that happen with the Gofast system.
pub const History = struct {
    events: std.MultiArrayList(Event) = .{},
    arena_string: std.heap.ArenaAllocator,

    pub const Event = struct {
        timestamp: Timestamp,
        user: Gofast.Person,
        /// Which ticket was affected by the action.
        ///
        /// For CreateTicket, it is the ID of the created ticket.
        ticket: Gofast.Ticket.Key,
        action: Action,

        pub const Timestamp = i64; // std.time.timestamp()
        pub const Action = union(enum) {
            create_ticket: CreateTicket,
            update_ticket: UpdateTicket,
            update_time: UpdateTime,

            pub const CreateTicket = struct {
                // TODO: Think of how to store these strings...
                title: []const u8,
                description: []const u8,
                parent: ?Gofast.Ticket.Key = null,
                type_: Gofast.Ticket.Type = 0,
                priority: Gofast.Ticket.Priority = 0,
                status: Gofast.Ticket.Status = 0,
            };
            pub const UpdateTicket = struct {
                title: ?[]const u8 = null,
                description: ?[]const u8 = null,
                parent: ??Gofast.Ticket.Key = null,
                type_: ?Gofast.Ticket.Type = null,
                priority: ?Gofast.Ticket.Priority = null,
                status: Gofast.Ticket.Status = null,
                order: ?Gofast.Ticket.Order = null,
            };
            pub const UpdateTime = struct {
                estimate: Gofast.TicketTime.Seconds,
                spent: Gofast.TicketTime.Seconds,
            };
        };
    };
    const Self = @This();

    pub fn addEvent(self: *Self, alloc: Allocator, event: Event) !void {
        const arena = self.arena_string.allocator();
        var mut_event = event;

        // Allocate these separately, as they go to history and will never be changed.
        switch (mut_event.action) {
            .create_ticket => |*a| {
                a.title = try arena.dupe(u8, a.title);
                a.description = try arena.dupe(u8, a.description);
            },
            .update_ticket => |*a| {
                if (a.title) |*title| title.* = try arena.dupe(u8, title.*);
                if (a.description) |*description| description.* = try arena.dupe(u8, description.*);
            },
            .update_time => {},
        }

        try self.events.append(alloc, mut_event);
    }

    pub fn deinit(self: *Self, alloc: Allocator) void {
        self.arena_string.deinit();
        self.events.deinit(alloc);
    }
};

test Gofast {
    const TEST = std.testing;
    const alloc = TEST.allocator;

    var gf = try Gofast.init(alloc, null);
    defer gf.deinit();

    try TEST.expect(gf.max_ticket_key == 0);

    const ticket1 = try gf.createTicket(0, Gofast.timestamp(), .{ .title = "t", .description = "d" });
    try TEST.expectEqual(1, ticket1);
    try TEST.expectEqual(1, gf.tickets.len);
    try TEST.expectEqual(1, gf.tickets.items(.key)[0]);

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
    defer std.fs.cwd().deleteFile(filepath) catch unreachable;

    // Create the persistance file with some known data.
    var ticket_create_date = [3]i64{ 0, 0, 0 };
    {
        var gofast = try Gofast.init(alloc, filepath);
        defer gofast.deinit();

        // Sanity check, Gofast starts with nothing predefined.
        try TEST.expectEqual(0, gofast.names.priorities.items.len);
        try TEST.expectEqual(0, gofast.names.statuses.items.len);
        try TEST.expectEqual(0, gofast.names.types.items.len);
        try TEST.expectEqual(0, gofast.tickets.len);
        try TEST.expectEqual(0, gofast.time_spent.len);

        // Are we even going to attempt saving?
        try TEST.expect(gofast.persistance != null);

        // Statuses
        try TEST.expectEqual(0, try gofast.createStatus(.{ .name = "status0" }));
        try TEST.expectEqual(1, gofast.names.statuses.items.len);

        // Priorities
        try TEST.expectEqual(0, try gofast.createPriority(.{ .name = "priority0" }));
        try TEST.expectEqual(1, try gofast.createPriority(.{ .name = "priority1" }));
        try TEST.expectEqual(2, gofast.names.priorities.items.len);

        // Types
        try TEST.expectEqual(0, try gofast.createType(.{ .name = "type0" }));
        try TEST.expectEqual(1, try gofast.createType(.{ .name = "type1" }));
        try TEST.expectEqual(2, try gofast.createType(.{ .name = "type2" }));
        try TEST.expectEqual(3, gofast.names.types.items.len);

        // People
        const person1 = try gofast.createPerson(.{ .name = "Bozhidar" });
        const person2 = try gofast.createPerson(.{ .name = "Stoyanov" });

        const ticket1 = try gofast.createTicket(person1, Gofast.timestamp(), .{
            .title = "Test ticket 1",
            .description = "Test description 1",
        });

        const ticket2 = try gofast.createTicket(person2, Gofast.timestamp(), .{
            .title = "Test ticket 2",
            .description = "Test description 2",
        });

        const ticket3 = try gofast.createTicket(person1, Gofast.timestamp(), .{
            .title = "Test ticket 3",
            .description = "Test description 3",
            .parent = ticket1,
        });

        ticket_create_date[0] = gofast.tickets.items(.created_on)[0];
        ticket_create_date[1] = gofast.tickets.items(.created_on)[1];
        ticket_create_date[2] = gofast.tickets.items(.created_on)[2];

        try gofast.setEstimate(ticket1, person1, 300);
        try gofast.setEstimate(ticket1, person2, 350);

        try gofast.setEstimate(ticket3, person2, 1200);

        try gofast.logWork(ticket2, person2, 0, 600);
        try gofast.logWork(ticket3, person1, 0, 120);
        try gofast.logWork(ticket1, person1, 0, 6000);
        try gofast.save();

        // try TEST.expectEqual(3, gofast.history.events.len);
    }

    // Load the persistance data and check if everything got loaded correctly.
    {
        var gofast = try Gofast.init(alloc, filepath);
        defer gofast.deinit();

        try TEST.expectEqual(1, gofast.names.statuses.items.len);
        try TEST.expectEqualStrings("status0", gofast.statusName(0));

        try TEST.expectEqualStrings("priority0", gofast.priorityName(0));
        try TEST.expectEqualStrings("priority1", gofast.priorityName(1));
        try TEST.expectEqual(2, gofast.names.priorities.items.len);

        try TEST.expectEqual(3, gofast.names.types.items.len);
        try TEST.expectEqualStrings("type0", gofast.typeName(0));
        try TEST.expectEqualStrings("type1", gofast.typeName(1));
        try TEST.expectEqualStrings("type2", gofast.typeName(2));

        try TEST.expectEqual(2, gofast.names.people.items.len);
        try TEST.expectEqualStrings("Bozhidar", gofast.personName(0));
        try TEST.expectEqualStrings("Stoyanov", gofast.personName(1));

        try TEST.expectEqual(3, gofast.tickets.len);
        try TEST.expectEqual(5, gofast.time_spent.len);

        const person1 = 0;
        const person2 = 1;

        const ticket1 = gofast.tickets.items(.key)[0];
        const ticket2 = gofast.tickets.items(.key)[1];
        const ticket3 = gofast.tickets.items(.key)[2];
        {
            // ticket - title
            try TEST.expectEqualStrings("Test ticket 1", gofast.tickets.items(.title)[0].s);
            try TEST.expectEqualStrings("Test ticket 2", gofast.tickets.items(.title)[1].s);
            try TEST.expectEqualStrings("Test ticket 3", gofast.tickets.items(.title)[2].s);
            // ticket - description
            try TEST.expectEqualStrings("Test description 1", gofast.tickets.items(.description)[0].s);
            try TEST.expectEqualStrings("Test description 2", gofast.tickets.items(.description)[1].s);
            try TEST.expectEqualStrings("Test description 3", gofast.tickets.items(.description)[2].s);
            // ticket - parent
            try TEST.expectEqual(null, gofast.tickets.items(.parent)[0]);
            try TEST.expectEqual(null, gofast.tickets.items(.parent)[1]);
            try TEST.expectEqual(ticket1, gofast.tickets.items(.parent)[2]);
            // ticket - creator
            try TEST.expectEqual(person1, gofast.tickets.items(.creator)[0]);
            try TEST.expectEqual(person2, gofast.tickets.items(.creator)[1]);
            try TEST.expectEqual(person1, gofast.tickets.items(.creator)[2]);
            // ticket - created_on
            try TEST.expectEqual(ticket_create_date[0], gofast.tickets.items(.created_on)[0]);
            try TEST.expectEqual(ticket_create_date[1], gofast.tickets.items(.created_on)[1]);
            try TEST.expectEqual(ticket_create_date[2], gofast.tickets.items(.created_on)[2]);
            // ticket - last_updated_on
            try TEST.expectEqual(ticket_create_date[0], gofast.tickets.items(.last_updated_on)[0]);
            try TEST.expectEqual(ticket_create_date[1], gofast.tickets.items(.last_updated_on)[1]);
            try TEST.expectEqual(ticket_create_date[2], gofast.tickets.items(.last_updated_on)[2]);
            // ticket - last_updated_by
            try TEST.expectEqual(person1, gofast.tickets.items(.last_updated_by)[0]);
            try TEST.expectEqual(person2, gofast.tickets.items(.last_updated_by)[1]);
            try TEST.expectEqual(person1, gofast.tickets.items(.last_updated_by)[2]);
        }
        // time spent
        {
            const time_spent0 = gofast.time_spent.get(0);
            try TEST.expectEqual(person1, time_spent0.person);
            try TEST.expectEqual(ticket1, time_spent0.ticket);
            try TEST.expectEqual(300, time_spent0.time.estimate);
            try TEST.expectEqual(6000, time_spent0.time.spent);
            const time_spent1 = gofast.time_spent.get(1);
            try TEST.expectEqual(person2, time_spent1.person);
            try TEST.expectEqual(ticket1, time_spent1.ticket);
            try TEST.expectEqual(350, time_spent1.time.estimate);
            try TEST.expectEqual(0, time_spent1.time.spent);
            const time_spent2 = gofast.time_spent.get(2);
            try TEST.expectEqual(person2, time_spent2.person);
            try TEST.expectEqual(ticket3, time_spent2.ticket);
            try TEST.expectEqual(1200, time_spent2.time.estimate);
            try TEST.expectEqual(0, time_spent2.time.spent);
            const time_spent3 = gofast.time_spent.get(3);
            try TEST.expectEqual(person2, time_spent3.person);
            try TEST.expectEqual(ticket2, time_spent3.ticket);
            try TEST.expectEqual(0, time_spent3.time.estimate);
            try TEST.expectEqual(600, time_spent3.time.spent);
            const time_spent4 = gofast.time_spent.get(4);
            try TEST.expectEqual(person1, time_spent4.person);
            try TEST.expectEqual(ticket3, time_spent4.ticket);
            try TEST.expectEqual(0, time_spent4.time.estimate);
            try TEST.expectEqual(120, time_spent4.time.spent);
        }

        // history
        // try TEST.expectEqual(3, gofast.history.events.len);
    }
}
test "Gofast.update.order" {
    const TEST = std.testing;
    const alloc = TEST.allocator;
    var gofast = try Gofast.init(alloc, null);
    defer gofast.deinit();

    // People
    const person1 = try gofast.createPerson(.{ .name = "Bozhidar" });
    const person2 = try gofast.createPerson(.{ .name = "Stoyanov" });

    const ticket1 = try gofast.createTicket(person1, Gofast.timestamp(), .{
        .title = "Test ticket 1",
        .description = "Test description 1",
    });
    const index: usize = @intCast(ticket1 - 1);

    try TEST.expectEqual(person1, gofast.tickets.items(.last_updated_by)[index]);
    try TEST.expectEqual(@as(f32, @floatFromInt(ticket1)), gofast.tickets.items(.details)[index].order);

    try gofast.updateTicket(
        ticket1,
        person2,
        .{
            .order = 200,
        },
    );
    try TEST.expectEqual(person2, gofast.tickets.items(.last_updated_by)[index]);
    try TEST.expectEqual(200, gofast.tickets.items(.details)[index].order);
}

test "Ticket.Link" {
    try std.testing.expectEqual(@sizeOf(Gofast.Ticket.Link), @sizeOf(usize));
}

test "Gofast.ticketstore" {
    const TEST = std.testing;
    const alloc = TEST.allocator;

    var store = try Gofast.init(alloc, null);
    defer store.deinit();

    const person1 = try store.createPerson(.{ .name = "p0" });
    const now = Gofast.timestamp();

    const k1 = try store.createTicket(person1, now, .{
        .title = "T1",
        .description = "D1",
        .parent = null,
        .status = 0,
        .type_ = 0,
        .priority = 0,
    });
    const k2 = try store.createTicket(person1, now, .{
        .title = "T2",
        .description = "D2",
        .parent = null,
        .status = 0,
        .type_ = 0,
        .priority = 0,
    });
    const k3 = try store.createTicket(person1, now, .{
        .title = "T3",
        .description = "D3",
        .parent = null,
        .status = 0,
        .type_ = 0,
        .priority = 0,
    });
    const k4 = try store.createTicket(person1, now, .{
        .title = "T4",
        .description = "D4",
        .parent = null,
        .status = 0,
        .type_ = 0,
        .priority = 0,
    });
    const k5 = try store.createTicket(person1, now, .{
        .title = "T5",
        .description = "D5",
        .parent = null,
        .status = 0,
        .type_ = 0,
        .priority = 0,
    });
    try TEST.expect(k1 == 1);
    try TEST.expect(k2 == 2);
    try TEST.expect(k3 == 3);
    try TEST.expect(k4 == 4);
    try TEST.expect(k5 == 5);

    // Setting a parent directly.
    const k6 = try store.createTicket(person1, now, .{
        .title = "T6",
        .description = "D6",
        .parent = k1,
        .status = 0,
        .type_ = 0,
        .priority = 0,
    });
    try TEST.expect(k6 != 0);
    {
        const k1children = try store.ticketChildrenAlloc(k1, alloc, 1);
        defer alloc.free(k1children);

        try TEST.expectEqual(1, k1children.len);
        try TEST.expectEqual(k6, k1children[0]);
    }

    // Removing some child
    {
        try store.removeTicket(k6);
        const k1children = try store.ticketChildrenAlloc(k1, alloc, 1);
        // defer alloc.free(k1children);
        try TEST.expectEqual(0, k1children.len);
    }

    // Add one child
    try store.connectFromTo(k1, k2);

    // Add another child and remove the parent
    const k7 = try store.createTicket(person1, now, .{
        .title = "T7",
        .description = "D7",
        .parent = k1,
        .status = 0,
        .type_ = 0,
        .priority = 0,
    });
    try TEST.expect(k7 != 0);
    {
        const k1children = try store.ticketChildrenAlloc(k1, alloc, 1);
        defer alloc.free(k1children);

        printChildrenGraph(&store, alloc);

        try TEST.expectEqual(2, k1children.len);
        try TEST.expectEqual(k2, k1children[0]);
        try TEST.expectEqual(k7, k1children[1]);
    }
    try store.removeTicket(k1);
    try TEST.expectEqual(null, store.findParent(k2));
    try TEST.expectEqual(null, store.findParent(k7));

    printChildrenGraph(&store, alloc);
}

test "TicketStore.sizes" {
    std.debug.print("@sizeOf(Ticket.Key) = {}\n", .{@sizeOf(Gofast.Ticket.Key)});
    std.debug.print("@sizeOf(Ticket.Link) = {}\n", .{@sizeOf(Gofast.Ticket.Link)});
    std.debug.print("@sizeOf(Ticket.FatLink) = {}\n", .{@sizeOf(Gofast.Ticket.FatLink)});
}

pub fn printChildrenGraph(ticket_store: *const Gofast, alloc: Allocator) void {
    // ticket_store.
    std.debug.print("Graph: Parent -> Children\n", .{});

    for (ticket_store.tickets.items(.key)) |key_parent| {
        std.debug.print("{} -> ", .{key_parent});
        const children = ticket_store.ticketChildrenAlloc(key_parent, alloc, null) catch unreachable;
        defer alloc.free(children);

        for (children) |c| {
            std.debug.print("{} ", .{c});
        }
        std.debug.print("\n", .{});
    }
}
