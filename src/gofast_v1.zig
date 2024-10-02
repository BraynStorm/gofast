const std = @import("std");
const builtin = @import("builtin");
const Allocator = std.mem.Allocator;
const assert = std.debug.assert;
const log = std.log.scoped(.Gofast_loadV1);

const Gofast = @import("gofast.zig").Gofast;
const SString = @import("smallstring.zig").ShortString;
const StringMap = Gofast.StringMap;
const Reader = std.fs.File.Reader;
const Writer = std.fs.File.Writer;

pub const GofastV1 = struct {
    pub const Key = u32;
    pub const Type = u8;
    pub const Status = u8;
    pub const Priority = u8;
    pub const Order = f32;
    pub const Person = u32;
};
pub const Prelude = extern struct {
    file_created: TimestampAbsoulte,
    offset_first_map_block: u64,
    _reserved0: u64 = undefined,
    _reserved1: u64 = undefined,
    pub const TimestampAbsoulte = i64;
};

pub const Block = extern union {
    history: History,
    map: Map,

    pub const target_size = 256;

    /// Think about the best way to store strings in the history.
    /// Do we want them like this? Where they are bascially a pointer?
    ///     Slower string-search
    ///     A bit faster iteration
    /// Or do we want to integrate, for example the length here?
    ///     A bit faster serach
    ///     Slower iteration
    ///
    /// Maybe instead, we can have each event have an ID and a StringMap
    /// can be stored like this
    ///     event_id u32
    ///     len      u32
    ///     data     [*]u8
    pub const StringRef = packed struct(u32) {
        id: u32,
    };

    pub const Map = extern struct {
        /// What type of block and where to find it.
        blocks: [capacity]BlockPtr = [_]BlockPtr{.{}} ** capacity,
        /// Block metadata, depends on block type.
        metas: [capacity]Meta = undefined,

        pub const element_size = @sizeOf(BlockPtr) + @sizeOf(Meta);
        pub const capacity = @divFloor(target_size, element_size);
        pub const waste = target_size - @sizeOf(@This());

        pub const BlockPtr = packed struct(u64) {
            /// Offset from the start of the file.
            offset: u48 = undefined,
            /// TWhat kind of block it is.
            type: BlockType = .empty,
        };
        pub const BlockType = enum(u16) {
            empty = 0,
            map = 1,
            strings = 2,
            history = 3,
        };
        pub const Meta = packed union {
            map: void,
            strings: packed struct(u64) {
                min: StringRef,
                max: StringRef,
            },
            history: packed struct(u64) {
                start: TimestampRelative,
                end: TimestampRelative,

                pub const TimestampRelative = u32;
            },
        };
    };
    pub const History = extern struct {
        pub const element_size = @sizeOf(Event);
        pub const capacity = @divFloor(target_size, element_size);
        pub const waste = target_size - @sizeOf(@This());
        _reserved: u64,
        count: u16,
        events: [capacity]Event,

        pub const Event = extern struct {
            stamp: Stamp,
            data: Data,

            pub const Stamp = packed struct(u64) {
                timestamp: TimestampRelative,
                event: Type,
            };
            pub const TimestampRelative = u48;
            pub const Type = enum(u16) {
                // Empty event, can be overwritten.
                create_type = 1,
                create_status,
                create_priority,
                create_person,
                create_ticket,
                // create_comment,
                // edit_ticket_strings,
                // edit_ticket_time,
                // edit_ticket_type,
                // edit_ticket_status,
                // edit_ticket_priority,
                // edit_ticket_order,
                // edit_ticket_time_estimate,
                // edit_ticket_time_spent,
            };
            pub const Data = extern union {
                create_type: CreateType,
                create_status: CreateStatus,
                create_priority: CreatePriority,
                create_person: CreatePerson,
                create_ticket: CreateTicket,
                // create_comment: CreateComment,
                // edit_comment: EditComment,

                pub const CreateType = extern struct {
                    created_by: GofastV1.Person,
                    name: StringRef,
                };
                pub const CreateStatus = extern struct {
                    created_by: GofastV1.Person,
                    name: StringRef,
                };
                pub const CreatePriority = extern struct {
                    created_by: GofastV1.Person,
                    name: StringRef,
                };
                pub const CreatePerson = extern struct {
                    created_by: GofastV1.Person,
                    name: StringRef,
                };
                pub const CreateTicket = extern struct {
                    created_by: GofastV1.Person,
                    type: GofastV1.Type,
                    status: GofastV1.Status,
                    priority: GofastV1.Priority,
                    title: StringRef,
                    description: StringRef,
                };
                // pub const CreateComment = extern struct {
                //     created_by: GofastV1.Person,
                //     comment: StringRef,
                // };
                // pub const EditComment = extern struct {
                //     comment_id: Comment,
                //     comment: StringRef,
                // };
            };
        };
    };

    pub const Strings = extern struct {
        pub const waste = target_size - @sizeOf(@This());

        bytes: [target_size]u8,
    };
};

const V1 = struct {
    file: std.fs.File,
    prelude: Prelude = undefined,
    /// Store the offset of the last block of each type
    block_index: BlockIndex = undefined,
    // Writer - how many events are in the current History block.
    w_history_count: u16 = 0,
    // Writer - how many bytes of the current Strings block are taken.
    w_string_byte_index: u64 = 0,
    w_last_string_index: u32 = 0,

    const magic = "GOFAST\x00";
    const version: u32 = 1;
    /// prelude is just after the magic and the version
    const prelude_location = magic.len + @sizeOf(@TypeOf(version));
    const BlockIndex = std.enums.EnumArray(Block.Map.BlockType, u64);
    const Self = @This();
    /// StringRef len type
    const Len = u32;

    pub fn init(file: std.fs.File) !V1 {
        // Check that we can seek this file
        _ = try file.seekTo(0);
        _ = try file.getPos();

        var me = V1{ .file = file };

        const stat = try file.stat();
        if (stat.size == 0) {
            // Brand new file. Write the necessary things
            try me.writeInitialFile();
            try me.seek(0);
        }

        // Load the prelude
        me.prelude = try me.readPrelude();

        // Load the block index.
        me.block_index = try me.computeBlockIndex();

        // Load the w_count.
        try me.seek(me.block_index.get(.history) + @offsetOf(Block.History, "count"));
        me.w_history_count = try me.reader().readInt(u16, .little);
        assert(me.w_history_count < Block.History.capacity);

        return me;
    }

    pub fn addString(self: *Self, string: []const u8) !Block.StringRef {
        var block_pos = self.block_index.get(.strings);
        if (string.len >= std.math.maxInt(Len)) {
            return error.StringTooLong;
        }

        if (block_pos == 0) {
            // No string blocks, just add a new one.
            block_pos = try self.newBlock(.strings);
            self.w_string_byte_index = 0;
        }

        // Okay we have a strings block. Can it fit the current string?
        const bytes_needed_min = @sizeOf(Len);
        const bytes_needed_total = bytes_needed_min + string.len;
        const block_bytes_left = @sizeOf(Block.Strings) - self.w_string_byte_index;

        const w = self.writer();
        if (block_bytes_left >= bytes_needed_total) {
            // Easy, the whole string + length fit in the block.
            try self.seek(block_pos + self.w_string_byte_index);
            try w.writeInt(Len, @intCast(string.len), .little);
            try w.writeAll(string);
            self.w_string_byte_index += bytes_needed_total;
        } else if (block_bytes_left < bytes_needed_min) {
            // A little different, we need to create a new block,
            // because the current block cannot fit the 'length' field of
            // the string.
            block_pos = try self.newBlock(.strings);
            try self.seek(block_pos + self.w_string_byte_index);
            try w.writeInt(Len, @intCast(string.len), .little);
            try w.writeAll(string);
            self.w_string_byte_index = bytes_needed_total;
        } else {
            // Fuck. We need to slice the string into multiple blocks.
            return error.NotImplemented;
        }

        const r = Block.StringRef{ .id = self.w_last_string_index };
        self.w_last_string_index += 1;
        return r;
    }
    pub fn addHistoryEvent(self: *Self, event: Block.History.Event) !void {
        assert(self.w_history_count < Block.History.capacity);

        // Try to allocate a new event in the current block
        self.w_history_count += 1;
        const block_pos = blk: {
            if (self.w_history_count >= Block.History.capacity) {
                // Sadly, the current block is full. Allocate a new block.
                self.w_history_count = 0;
                break :blk try self.newBlock(.history);
            } else {
                break :blk self.block_index.get(.history);
            }
        };

        const block_count_pos = block_pos + @offsetOf(Block.History, "count");
        const first_event_pos = block_pos + @offsetOf(Block.History, "events");
        const new_event_pos = first_event_pos + (self.w_history_count) * @sizeOf(Block.History.Event);

        if (builtin.mode == .Debug) {
            // Ensure the cache is correct.
            try self.seek(block_count_pos);
            assert(try self.reader().readInt(u16, .little) == self.w_history_count - 1);
        }

        try self.seek(new_event_pos);
        try self.writer().writeStruct(event);
    }

    fn newBlock(self: *Self, new_block_type: Block.Map.BlockType) !u64 {
        const map_pos = self.block_index.get(.map);
        assert(map_pos != 0);
        assert(new_block_type != .map);

        try self.seek(map_pos);
        var map = (try self.readBlock()).map;

        for (map.blocks, 0..) |b, i| {
            // Find an empty slot.
            if (b.type == .empty) {
                var end_of_file = try self.file.getEndPos();
                if (i == Block.Map.capacity - 1) {
                    // Last block of this map
                    // Need to put a reference to the next map block.

                    // Seek to the spot in this file.
                    const new_map_pos = end_of_file;
                    try self.seek(map_pos + i * @sizeOf(Block.Map.BlockPtr));
                    try self.writer().writeStruct(Block.Map.BlockPtr{
                        .offset = @intCast(new_map_pos),
                        .type = .map,
                    });
                    // Leave the meta untouched.
                    // try self.seek(current_map_loc + i * @sizeOf(Block.Map.Meta));

                    // Now create the actual map-block.
                    map = .{};
                    self.block_index.set(.map, new_map_pos);
                    try self.seek(new_map_pos);
                    try self.writer().writeByteNTimes(0, @sizeOf(Block));
                    end_of_file += @sizeOf(Block);
                }
                // Now go actually create the block
                const new_block_pos = end_of_file;
                try self.seek(new_block_pos);
                try self.writer().writeByteNTimes(0, @sizeOf(Block));
                self.block_index.set(new_block_type, end_of_file);
                return new_block_pos;
            }
        }
        return error.NotFound;
    }

    /// On initial opening, read the index of map blocks.
    inline fn computeBlockIndex(self: *Self) !BlockIndex {
        var start = self.prelude.offset_first_map_block;
        var index = BlockIndex{
            .values = [_]u64{0} ** std.meta.fields(Block.Map.BlockType).len,
        };
        index.set(.map, start);

        while (true) {
            try self.seek(start);
            const block = try self.readBlock();

            for (block.map.blocks) |b| {
                index.set(b.type, b.offset);
                if (b.type == .empty) break;
            }

            const last_block = Block.Map.capacity - 1;
            // No more blocks left, just stop.
            if (block.map.blocks[last_block].type == .empty) break;

            // Go to the next map.
            assert(block.map.blocks[last_block].type == .map);
            start = block.map.blocks[last_block].offset;
        }

        return index;
    }

    inline fn readPrelude(self: *Self) !Prelude {
        try self.seek(V1.prelude_location);
        return try self.reader().readStruct(Prelude);
    }
    inline fn seek(self: *Self, pos: usize) !void {
        try self.file.seekTo(pos);
    }
    inline fn position(self: *const Self) u64 {
        return self.file.getPos() catch unreachable;
    }
    inline fn readBlock(self: *Self) !Block {
        return (try self.reader().readStruct(extern struct { b: Block })).b;
    }
    inline fn writeInitialFile(self: *Self) !void {
        // We're at the start of the file.
        assert(self.position() == 0);

        const w = self.writer();

        // Magic.
        try w.writeAll(magic);
        // Version
        try w.writeInt(u32, version, .little);
        // Prelude
        try w.writeStruct(Prelude{
            .file_created = std.time.timestamp(),
            // Just after Prelude, we find the first Map block.
            .offset_first_map_block = prelude_location + @sizeOf(Prelude),
        });
        // An empty map block.
        try w.writeStruct(extern struct { b: Block }{
            .b = .{ .map = .{} },
        });
    }

    pub fn getString(self: *Self, string_ref: Block.StringRef) ![]const u8 {
        var map_ptr = self.prelude.offset_first_map_block;
        var start_block_index: u64 = undefined;
        var start_block_ptr: u64 = undefined;
        var bytes_to_eat: u64 = undefined;
        // Which string are we looking at now.
        var string_ref_counter: u64 = 0;

        while (true) {
            try self.seek(map_ptr);
            const map = (try self.readBlock()).map;
            for (map.blocks, 0..) |b, i| {
                if (i == Block.Map.capacity - 1) {
                    // sanity check, last block is always a map
                    assert(b.type == .map);
                }

                switch (b.type) {
                    .empty => {
                        break;
                    },
                    .strings => {
                        // Strings block!
                        if (bytes_to_eat > @sizeOf(Block)) {
                            // We have to eat more than a block. Wow, a long string!.
                            // Skip reading whatever is in the block and just go straight
                            // to looking for the next one.
                            bytes_to_eat -= @sizeOf(Block);
                            continue;
                        }

                        // Okay the string either starts in this block or
                        // is not at all contained in this block.
                        start_block_index = i;
                        start_block_ptr = b.offset;
                        const end_block_ptr = b.offset + @sizeOf(Block);
                        var current_block_ptr = start_block_ptr;

                        // Okay, start reading string lengths and skipping bytes.
                        const r = self.reader();

                        // While we can read at least a Len (4B).
                        while (end_block_ptr - current_block_ptr >= @sizeOf(Len)) {
                            if (bytes_to_eat == 0) {
                                // We're at the beginning of a new string.
                                if (string_ref.id == string_ref_counter) {
                                    // We found it.
                                    return self.readString(map_ptr, start_block_index, start_block_ptr, current_block_ptr);
                                }

                                try self.seek(current_block_ptr);
                                const len = try r.readInt(Len, .little);

                                current_block_ptr += @sizeOf(Len);
                                bytes_to_eat = len;
                                if (current_block_ptr + len > end_block_ptr) {
                                    // The string spills in the next block.
                                    const bytes_left_in_block = end_block_ptr - current_block_ptr;
                                    bytes_to_eat -= bytes_left_in_block;
                                    continue;
                                } else {
                                    // The string fits in the current block.
                                    current_block_ptr += bytes_to_eat;
                                    bytes_to_eat = 0;
                                    string_ref_counter += 1;
                                }
                            }
                        }
                    },
                    else => {
                        // Go to the next block.
                    },
                }
            }
            const last_block = Block.Map.capacity - 1;
            if (map.blocks[last_block].type == .map) {
                map_ptr = map.blocks[last_block].offset;
            } else if (map.blocks[last_block].type == .empty) {
                // no more strings.
                return error.NotFound;
            } else {
                // WTF? The last map's block is neither empty nor another map.
                assert(false);
            }
        }
    }
    /// Given the starting map in which the string was found, and the starting block
    fn readString(
        self: *Self,
        start_map_pos: u64, // Where does the map "start".
        start_block_index: u64, // # of block inside the map
        start_block_pos: u64, // Already computed, so just pass it.
        start_string_pos: u64, // Already computed, so just pass it.
    ) ![]const u8 {
        _ = .{self};
        _ = .{start_map_pos};
        _ = .{start_block_index};
        _ = .{start_block_pos};
        _ = .{start_string_pos};
        @panic("Impossible to implement without allocating!");
    }

    pub inline fn reader(self: *Self) Reader {
        return self.file.reader();
    }

    inline fn writer(self: *Self) Writer {
        return self.file.writer();
    }
};

fn longest_field(comptime T: type) usize {
    var longest: usize = 0;
    inline for (std.meta.fields(T)) |f| {
        longest = @max(longest, f.name.len);
    }
    return longest;
}

test "V1.sizes" {
    const debug = std.debug.print;

    debug("================= V1 sizes ==================\n", .{});
    debug("@sizeOf(Block)                         = {d:>5}\n", .{@sizeOf(Block)});
    debug("@sizeOf(Block.Map)                     = {d:>5}\n", .{@sizeOf(Block.Map)});
    debug("       (Block.Map.capcaity)            = {d:>5}\n", .{Block.Map.capacity});
    debug("       (Block.Map.waste)               = {d:>5}\n", .{Block.Map.waste});
    debug("@sizeOf(Block.Map.BlockPtr)            = {d:>5}\n", .{@sizeOf(Block.Map.BlockPtr)});
    debug("@sizeOf(Block.Map.Meta)                = {d:>5}\n", .{@sizeOf(Block.Map.Meta)});
    debug("@sizeOf(Block.History)                 = {d:>5}\n", .{@sizeOf(Block.History)});
    debug("       (Block.History.capacity)        = {d:>5}\n", .{Block.History.capacity});
    debug("       (Block.History.waste)           = {d:>5}\n", .{Block.History.waste});
    debug("@sizeOf(Block.History.Event)           = {d:>5}\n", .{@sizeOf(Block.History.Event)});
    debug("@sizeOf(Block.History.Event.Stamp)     = {d:>5}\n", .{@sizeOf(Block.History.Event.Stamp)});
    debug("@sizeOf(Block.History.Event.Data)      = {d:>5}\n", .{@sizeOf(Block.History.Event.Data)});

    const align_str = std.fmt.comptimePrint("{}", .{comptime longest_field(Block.History.Event.Data)});
    inline for (std.meta.fields(Block.History.Event.Data)) |f| {
        debug(
            "@sizeOf(Block.History.Event.Data.{s:<" ++ align_str ++ "}) = {d:>3}\n",
            .{ f.name, @sizeOf(f.type) },
        );
    }

    try std.testing.expectEqual(0, Block.Map.waste);
    try std.testing.expectEqual(0, Block.History.waste);
}
test "V1.readwrite.simple" {
    {
        const fsfile = try std.fs.cwd().createFile(".test.gfs1", .{
            .read = true,
            .truncate = true,
        });
        defer fsfile.close();
        var file = try V1.init(fsfile);

        const person1_strid = try file.addString("Person1");
        try std.testing.expectEqual(0, person1_strid.id);
        try std.testing.expectEqualStrings("Person1", try file.getString(person1_strid));
        try file.addHistoryEvent(.{
            .stamp = .{
                .event = .create_person,
                .timestamp = @intCast(std.time.timestamp() - file.prelude.file_created),
            },
            .data = .{
                .create_person = .{
                    .created_by = 0,
                    .name = person1_strid,
                },
            },
        });
    }
    {
        const fsfile = try std.fs.cwd().openFile(".test.gfs1", .{ .mode = .read_write });
        defer fsfile.close();
        var file = try V1.init(fsfile);
        const person1_strid = 0;
        try std.testing.expectEqualStrings("Person1", try file.getString(.{ .id = person1_strid }));
    }
}

/// V1 Format - History major
///
/// Store the entire history in a contiguous block
///
pub fn load(gofast: *Gofast, reader: Reader) !void {
    _ = .{ gofast, reader };
    return error.NotImplemented;
}
