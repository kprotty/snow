const std = @import("std");
const io = @import("io.zig");
const sync = @import("sync.zig");
const pike = @import("pike/pike.zig");

const net = std.net;

pub const Side = packed enum(u1) {
    client,
    server,
};

pub const Options = packed struct {
    max_connections_per_client: usize = 16,
    max_connections_per_server: usize = 128,

    protocol_type: type = void,
    message_type: type = []const u8,

    write_queue_size: usize = 128,
    read_buffer_size: usize = 4 * 1024 * 1024,
    write_buffer_size: usize = 4 * 1024 * 1024,
};

pub fn yield() void {
    suspend {
        var task = pike.Task.init(@frame());
        pike.dispatch(&task, .{ .use_lifo = true });
    }
}

pub fn Socket(comptime side: Side, comptime opts: Options) type {
    return struct {
        const Self = @This();

        pub const Reader = io.Reader(pike.Socket, opts.read_buffer_size);
        pub const Writer = io.Writer(pike.Socket, opts.write_buffer_size);

        const WriteQueue = sync.Queue(opts.message_type, opts.write_queue_size);
        const Protocol = opts.protocol_type;

        inner: pike.Socket,
        address: net.Address,
        write_queue: WriteQueue = .{},

        pub fn init(inner: pike.Socket, address: net.Address) Self {
            return Self{ .inner = inner, .address = address };
        }

        pub fn deinit(self: *Self) void {
            self.write_queue.close();
            self.inner.deinit();
        }

        pub inline fn unwrap(self: *Self) *pike.Socket {
            return &self.inner;
        }

        pub fn write(self: *Self, message: opts.message_type) !void {
            try self.write_queue.push(message);
        }

        pub fn run(self: *Self, protocol: Protocol) !void {
            var reader = Reader.init(self.unwrap());

            var writer = async self.runWriter(protocol);
            defer await writer catch {};

            yield();

            try protocol.read(side, self, &reader);
        }

        fn runWriter(self: *Self, protocol: Protocol) !void {
            var writer = Writer.init(self.unwrap());
            var queue: @TypeOf(self.write_queue.items) = undefined;

            yield();

            while (true) {
                const num_items = try self.write_queue.pop(queue[0..]);
                try protocol.write(side, self, &writer, queue[0..num_items]);
            }
        }
    };
}
