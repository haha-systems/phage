// Copyright (c) 2025 Haha Systems Limited
// Licensed under the MIT License. See LICENSE.md file in the project root.

const std = @import("std");
const linux = @import("std").os.linux;
const posix = @import("std").posix;
const Allocator = std.mem.Allocator;

const Chameleon = @import("chameleon");

pub const regex = @import("mvzr");
pub const protocol = @import("protocol/protocol.zig");

const index = @import("index.zig");
const io = @import("io/io.zig");
const IO = io.IO;
const Wal = io.wal.Wal;

const data_structures = @import("data_structures/data_structures.zig");
const AtomicStack = data_structures.AtomicStack;
const BufferPool = data_structures.BufferPool;
const Trie = data_structures.Trie;

pub const Phage = struct {
    allocator: Allocator,
    ring: linux.IoUring,
    fd: posix.fd_t,
    wal_fd: posix.fd_t,
    file_size: std.atomic.Value(u64),
    wal_file_size: std.atomic.Value(u64),
    index: index.IndexManager,
    buffer_pool: data_structures.BufferPool,
    pending_ops: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    server_fd: posix.fd_t = 0,
    store_path: []const u8 = "phage_store", // Default path for the main database file
    wal_path: []const u8 = "phage_store.wal", // Default path for the Write-Ahead Log (WAL)
    compaction_threshold: f64 = 0.5, // Trigger compaction at 50% waste
    compaction_in_progress: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    const RING_ENTRIES: u32 = 128;

    pub fn init(
        allocator: Allocator,
        file_path: []const u8,
    ) !Phage {
        std.log.info("Phage starting...", .{});

        // var options = std.mem.zeroInit(linux.io_uring_params, .{
        //     .flags = linux.IORING_SETUP_SQPOLL | linux.IORING_SETUP_CQSIZE,
        //     .sq_entries = RING_ENTRIES,
        //     .cq_entries = RING_ENTRIES,
        //     .features = linux.IORING_FEAT_SINGLE_MMAP | linux.IORING_FEAT_NODROP,
        //     .sq_thread_idle = 1,
        //     .sq_thread_cpu = 0,
        // });

        // const ring = linux.IoUring.init_params(RING_ENTRIES, &options) catch |err| {
        //     return err;
        // };

        const ring = linux.IoUring.init(RING_ENTRIES, 0) catch |err| {
            std.log.err("Failed to initialize io_uring: {s}", .{@errorName(err)});
            return err;
        };

        const fd = try std.posix.open(
            file_path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );
        if (fd < 0) {
            std.log.err("Failed to open database file: {s}", .{file_path});
            return error.FileOpenError;
        }

        const wal_path = std.fmt.allocPrint(allocator, "{s}.wal", .{file_path}) catch |err| {
            return err;
        };
        defer allocator.free(wal_path);

        const wal_fd = try std.posix.open(
            wal_path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );
        if (wal_fd < 0) {
            std.log.err("Failed to open WAL file: {s}", .{wal_path});
            return error.FileOpenError;
        }

        // stat the data files to get their current size
        const file_stat = try std.posix.fstat(fd);
        const wal_file_stat = try std.posix.fstat(wal_fd);

        const file_size = std.atomic.Value(u64).init(@intCast(file_stat.size));
        const wal_file_size = std.atomic.Value(u64).init(@intCast(wal_file_stat.size));
        const index_manager = try index.IndexManager.init(allocator);
        const buffer_pool = try BufferPool.init(allocator);

        var store = Phage{
            .allocator = allocator,
            .ring = ring,
            .fd = fd,
            .wal_fd = wal_fd,
            .file_size = file_size,
            .wal_file_size = wal_file_size,
            .index = index_manager,
            .buffer_pool = buffer_pool,
            .server_fd = 0,
            .store_path = file_path,
            .wal_path = wal_path,
            .compaction_threshold = 0.5, // Default compaction threshold
            .compaction_in_progress = std.atomic.Value(bool).init(false),
        };

        errdefer store.deinit();

        // rebuild the index from the main file
        std.log.info("Rebuilding index...", .{});
        try store.restoreIndex();
        std.log.info("Index rebuilt.", .{});

        // recover the WAL entries for consistency
        std.log.info("Checking WAL recovery entries...", .{});
        try Wal.recover(@ptrCast(&store));
        std.log.info("WAL recovery completed.", .{});

        std.log.info("Phage started successfully.", .{});

        return store;
    }

    pub fn deinit(self: *Phage) void {
        // std.posix.close(self.server_fd);
        // self.server_fd = 0;

        self.ring.deinit();
        posix.close(self.fd);
        posix.close(self.wal_fd);
        self.index.deinit(self.allocator);
        self.buffer_pool.deinit(self.allocator);
    }

    /// Writes a key-value pair to the database.
    ///
    /// This function performs the following steps:
    /// 1. Writes a provisional entry to the Write-Ahead Log (WAL).
    /// 2. Writes the key-value pair to the main database file.
    /// 3. Updates the WAL entry with the offset of the key-value pair in the main file.
    /// 4. Updates the index with the key and its offset in the main file.
    ///
    /// The key and value are duplicated, so the caller must ensure they are not
    /// freed until the database is closed or the entry is deleted.
    ///
    pub fn put(self: *Phage, key: []const u8, value: []const u8) !void {
        // Step 1: Write provisional entry to WAL, we'll get the offset later
        const provisional_wal_entry = try self.formatWalEntry(.put, key, value, 0);
        defer self.allocator.free(provisional_wal_entry);

        const wal_offset = self.wal_file_size.fetchAdd(provisional_wal_entry.len, .monotonic);

        var ops_submitted = try self.writeToWal(provisional_wal_entry, wal_offset);
        try self.waitForIO();
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        // Step 2: Write to main file to secure the offset
        const data_entry = try self.formatDataEntry(key, value);
        defer self.allocator.free(data_entry);

        const data_offset = self.file_size.fetchAdd(data_entry.len, .monotonic);
        ops_submitted = try IO.writeToFile(&self.pending_ops, self.fd, &self.ring, &data_entry, data_offset);

        try self.waitForIO();
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        // Step 3: Update WAL entry with the offset
        const final_wal_entry = try self.formatWalEntry(.put, key, value, data_offset);
        defer self.allocator.free(final_wal_entry);
        ops_submitted = try self.writeToWal(final_wal_entry, wal_offset);
        try self.waitForIO();
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        // Step 4: Finally, we update the index
        try self.index.put(self.allocator, key, .{
            .offset = data_offset,
            .len = data_entry.len,
            .key_len = key.len,
            .val_len = value.len,
        });

        // Step 4a: Truncate the WAL file now that the entry is complete
        try std.posix.ftruncate(self.wal_fd, 0);
        self.wal_file_size.store(0, .monotonic);

        // Step 4b: Check if compaction is needed (non-blocking)
        self.checkAndScheduleCompaction() catch |err| {
            std.log.warn("Failed to schedule compaction: {s}", .{@errorName(err)});
        };
    }

    /// Reads a value from the database using the provided key.
    ///
    /// This function performs the following steps:
    /// 1. Retrieves the entry from the index using the key.
    /// 2. Allocates a buffer to read the entry from the main database file.
    /// 3. Reads the entry from the main database file.
    /// 4. Validates the key and extracts the value.
    /// 5. Returns the value to the caller.
    ///
    /// The caller is responsible for freeing the returned value.
    /// If the key is not found, an error is returned.
    pub fn get(self: *Phage, key: []const u8) ![]u8 {
        std.log.info("Getting key: {s}", .{key});

        // strip newline characters from key first
        const trimmed_key = std.mem.trimRight(u8, key, "\r\n");

        const entry = self.index.get(trimmed_key) orelse {
            std.log.info("Key not found: {s}", .{key});
            return error.KeyNotFound;
        };

        const buf = try self.allocator.alloc(u8, entry.len);
        defer self.allocator.free(buf);

        const ops_submitted = try IO.readFromFile(&self.pending_ops, self.fd, &self.ring, &buf, entry.offset);
        if (ops_submitted < 1) {
            return error.ReadError;
        }

        try waitForIO(self);

        const key_start = @sizeOf(index.EntryHeader);
        const stored_key = buf[key_start..][0..entry.key_len];
        if (!std.mem.eql(u8, stored_key, trimmed_key)) return error.KeyMismatch;

        const val_start = key_start + entry.key_len;
        const value = buf[val_start..][0..entry.val_len];

        // note: caller (and their allocator) now owns the value
        return try self.allocator.dupe(u8, value);
    }

    /// Deletes a key-value pair from the database using the provided key.
    ///
    /// This function performs the following steps:
    /// 1. Writes a delete entry to the Write-Ahead Log (WAL).
    /// 2. Updates the index to remove the key.
    /// 3. Returns true if the key was successfully deleted, false otherwise.
    ///
    /// The key is duplicated, so the caller must ensure it is not freed until the
    /// database is closed or the entry is deleted.
    ///
    /// If the key is not found, an error is returned.
    pub fn delete(self: *Phage, key: []const u8) !bool {
        const wal_entry = try self.formatWalEntry(.delete, key, null, 0);
        defer self.allocator.free(wal_entry);

        const wal_offset = self.wal_file_size.fetchAdd(wal_entry.len, .monotonic);

        const ops_submitted = try self.writeToWal(wal_entry, wal_offset);
        try waitForIO(self);
        if (ops_submitted < 1) {
            return error.WriteError;
        }

        return try self.index.delete(self.allocator, key);
    }

    /// Rebuilds the index from the main database file.
    pub fn restoreIndex(self: *Phage) !void {
        var offset: usize = 0;
        const file_stat = try std.posix.fstat(self.fd);
        const file_size = file_stat.size;

        while (offset < file_size) {
            var header_buf: [@sizeOf(index.EntryHeader)]u8 = undefined;
            const header_read = try std.posix.pread(self.fd, &header_buf, offset);
            if (header_read < @sizeOf(index.EntryHeader)) break;

            const header: index.EntryHeader = @bitCast(header_buf);

            // Read key
            const key_buf = try self.allocator.alloc(u8, header.key_len);
            defer self.allocator.free(key_buf);
            const key_read = try std.posix.pread(self.fd, key_buf, offset + @sizeOf(index.EntryHeader));
            if (key_read < header.key_len) break;

            // Insert into index
            try self.index.put(self.allocator, key_buf, .{
                .offset = offset,
                .len = @sizeOf(index.EntryHeader) + header.key_len + header.val_len,
                .key_len = header.key_len,
                .val_len = header.val_len,
            });

            offset += @sizeOf(index.EntryHeader) + header.key_len + header.val_len;
        }
    }

    /// Restores the database from the Write-Ahead Log (WAL).
    /// This function reads entries from the WAL and applies them to the main database file.
    /// It updates the index accordingly.
    pub fn restoreWAL(self: *Phage) !void {
        Wal.recover(self) catch |err| {
            std.log.err("Failed to restore WAL: {s}", .{@errorName(err)});
            return err;
        };
        std.log.debug("WAL restored successfully.", .{});
    }

    // /// Returns the key-value pairs matching the provided pattern from the database.
    // /// The pattern is a regular expression that is used to match keys.
    pub fn findKeys(self: *Phage, pattern: []const u8) !?[][]const u8 {
        if (pattern.len == 0) {
            std.log.debug("No pattern provided", .{});
            return error.InvalidPattern;
        }

        // Trim whitespace from the pattern
        const clean_pattern = std.mem.trimRight(u8, pattern, " \t\n\r");

        // Build a trie from the keys in the index
        var trie = try Trie.init(self.allocator);
        defer trie.deinit();

        for (self.index.shards) |*shard| {
            var it = shard.map.keyIterator();
            while (it.next()) |key| {
                try trie.insert(key.*);
            }
        }

        // Find keys matching the pattern
        var matches = std.ArrayList([]const u8).init(self.allocator);
        defer matches.deinit();

        if (std.mem.eql(u8, clean_pattern, "*")) {
            // wildcard pattern, so modify the pattern to match everything
            std.log.debug("Wildcard pattern detected, matching all keys", .{});
            try trie.matchRegex(".*", &matches);
        } else {
            try trie.matchRegex(clean_pattern, &matches);
        }

        if (matches.items.len == 0) {
            // TODO: swap this to a custom logger
            std.log.debug("No keys found matching pattern: {s}", .{clean_pattern});
            return null;
        } else {
            return matches.items;
        }
    }

    pub fn printKeys(self: *Phage, pattern: []const u8, writer: *std.io.AnyWriter) !void {
        var c = Chameleon.initRuntime(.{
            .allocator = self.allocator,
            .detect_no_color = true,
        });
        defer c.deinit();

        if (self.index.count() == 0) {
            try writer.print("0\n", .{});
            return;
        }

        if (pattern.len == 0) {
            try writer.print("KEYS: No pattern provided\n", .{});
            return;
        }

        std.log.debug("Pattern: {s}", .{pattern});

        var final_pattern: []const u8 = std.mem.trimRight(u8, pattern, " \t\n\r");
        if (std.mem.eql(u8, final_pattern, "*")) {
            final_pattern = ".*";
        }

        std.log.debug("Final pattern: {s}", .{final_pattern});
        const r = regex.compile(final_pattern);
        if (r == null) {
            try writer.print("KEYS: Invalid regex pattern: {s}\n", .{final_pattern});
            return;
        }

        var selected_count: usize = 0;
        for (self.index.shards) |*shard| {
            var it = shard.map.keyIterator();
            while (it.next()) |key| {
                const match = r.?.isMatch(key.*);
                if (match) {
                    const entry = shard.map.get(key.*) orelse continue;
                    const k = try c.red().fmt("{s}", .{key.*});
                    const v = try c.redBright().fmt("{s}", .{try self.get(key.*)});
                    try writer.print("{s}: {s} ({d})\n", .{ k, v, entry.offset });
                    selected_count += 1;
                }
            }
        }

        const count_str = std.fmt.allocPrint(self.allocator, "{d} of {d} keys", .{ selected_count, self.index.count() }) catch |err| {
            return err;
        };
        errdefer self.allocator.free(count_str);
        defer self.allocator.free(count_str);

        try writer.print("[{s}]\n", .{count_str});
    }

    pub fn parseCommand(cmd: []const u8) !protocol.Command {
        const command = protocol.command.parseCommand(cmd) catch |err| {
            // std.log.err("Failed to parse command: {s}", .{cmd});
            return err;
        };

        if (protocol.command.validateCommand(cmd)) {
            return command;
        } else {
            // std.log.err("Invalid command: {s}", .{cmd});
            return error.InvalidCommand;
        }
    }

    pub fn executeCommand(self: *Phage, command: protocol.Command) ![]const u8 {
        // std.log.debug("Executing command: {s}", .{command.name()});

        switch (command.command) {
            // .put => |put_cmd| {
            //     try self.put(put_cmd.key, put_cmd.value);
            //     return "OK\n";
            // },
            // .get => |get_cmd| {
            //     const value = try self.get(get_cmd.key);
            //     return value;
            // },
            // .delete => |delete_cmd| {
            //     const deleted = try self.delete(delete_cmd.key);
            //     if (deleted) {
            //         return "OK\n";
            //     } else {
            //         return "NOT_FOUND\n";
            //     }
            // },

            .Keys => |_| {
                const keys = try self.findKeys(command.payload.Keys.pattern);
                if (keys) |k| {
                    return try std.fmt.allocPrint(self.allocator, "{s}\n", .{try std.mem.join(self.allocator, "\n", k)});
                } else {
                    return "0\n";
                }
            },
            else => {
                std.log.err("Unknown command: {s}", .{command.name()});
                return error.UnknownCommand;
            },
        }
    }

    /// -----------------------------------------------------------------------------------------------
    /// Calculate the waste ratio in the main database file.
    /// Returns a value between 0.0 and 1.0 where 1.0 means 100% waste.
    pub fn calculateMainFileWasteRatio(self: *Phage) f64 {
        const file_size = self.file_size.load(.monotonic);
        if (file_size == 0) return 0.0;

        // Calculate total size of all reachable entries
        var useful_size: usize = 0;
        for (self.index.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            var it = shard.map.valueIterator();
            while (it.next()) |entry| {
                useful_size += entry.len;
            }
        }

        if (useful_size == 0) return 0.0;

        const useful_ratio = @as(f64, @floatFromInt(useful_size)) / @as(f64, @floatFromInt(file_size));
        return @max(0.0, 1.0 - useful_ratio); // Ensure non-negative result
    }

    fn calculateWalWasteRatio(self: *Phage) f64 {
        const wal_size = self.wal_file_size.load(.monotonic);
        const main_file_size = self.file_size.load(.monotonic);
        if (main_file_size == 0) return 0.0; // Avoid division by zero

        // Calculate the ratio of WAL size to main file size (preserve precision)
        const wal_size_f: f64 = @floatFromInt(wal_size);
        const main_size_f: f64 = @floatFromInt(main_file_size);
        return wal_size_f / main_size_f;
    }

    /// Check if compaction is needed and schedule it if necessary.
    /// This function is non-blocking and will not interfere with ongoing operations.
    fn checkAndScheduleCompaction(self: *Phage) !void {
        // Skip if compaction is already in progress
        if (self.compaction_in_progress.load(.acquire)) {
            return;
        }

        const waste_ratio = self.calculateMainFileWasteRatio();
        if (waste_ratio >= self.compaction_threshold) {
            std.log.info("Compaction triggered: waste ratio {d:.2}% >= threshold {d:.2}%", .{ waste_ratio * 100, self.compaction_threshold * 100 });

            // Set compaction flag atomically
            if (self.compaction_in_progress.cmpxchgWeak(false, true, .acquire, .acquire) == null) {
                // We successfully set the flag, schedule background compaction
                try self.performCompaction();
                self.compaction_in_progress.store(false, .release);
                std.log.info("Compaction completed successfully", .{});
            }
        }
    }

    /// Perform the actual compaction by rewriting the database file.
    /// This function creates a new file with only reachable entries.
    fn performCompaction(self: *Phage) !void {
        const temp_path = try std.fmt.allocPrint(self.allocator, "{s}.compact.tmp", .{self.store_path});
        defer self.allocator.free(temp_path);

        // Create temporary file for compacted data
        const temp_fd = try std.posix.open(
            temp_path,
            .{
                .ACCMODE = .RDWR,
                .CREAT = true,
                .TRUNC = true,
                .CLOEXEC = true,
            },
            std.posix.S.IRUSR | std.posix.S.IWUSR,
        );
        defer std.posix.close(temp_fd);

        var new_offset: usize = 0;
        var entries_compacted: usize = 0;

        // Iterate through all entries in the index and write them to the new file
        for (self.index.shards) |*shard| {
            shard.mutex.lock();
            defer shard.mutex.unlock();

            var it = shard.map.iterator();
            while (it.next()) |entry| {
                const index_entry = entry.value_ptr.*;

                // Read the entry from the current file
                const entry_buf = try self.allocator.alloc(u8, index_entry.len);
                defer self.allocator.free(entry_buf);

                const bytes_read = try std.posix.pread(self.fd, entry_buf, index_entry.offset);
                if (bytes_read != index_entry.len) {
                    return error.CorruptedEntry;
                }

                // Write to the new file
                const bytes_written = try std.posix.pwrite(temp_fd, entry_buf, new_offset);
                if (bytes_written != entry_buf.len) {
                    return error.WriteError;
                }

                // Update the index entry with the new offset
                entry.value_ptr.*.offset = new_offset;
                new_offset += entry_buf.len;
                entries_compacted += 1;
            }
        }

        // Atomically replace the old file with the new one
        try self.atomicFileSwap(temp_path, self.store_path);

        // Update file size
        self.file_size.store(new_offset, .monotonic);

        std.log.info("Compaction completed: compacted {d} entries, new file size: {d} bytes", .{ entries_compacted, new_offset });
    }

    /// Atomically swap the temporary compacted file with the main database file.
    fn atomicFileSwap(self: *Phage, temp_path: []const u8, target_path: []const u8) !void {
        // Close the current file descriptor
        std.posix.close(self.fd);

        // Rename temp file to target (atomic on most filesystems)
        try std.posix.rename(temp_path, target_path);

        // Reopen the file
        self.fd = try std.posix.open(
            target_path,
            .{
                .ACCMODE = .RDWR,
                .CLOEXEC = true,
            },
            0,
        );
    }

    /// Waits for all pending I/O operations to complete.
    fn waitForIO(self: *Phage) !void {
        while (self.pending_ops.load(.acquire) > 0) {
            // var cqe: linux.io_uring_cqe = undefined;
            const cqe = try self.ring.copy_cqe();
            if (cqe.res < 0) return error.IOUringError;
            const completed = self.pending_ops.fetchSub(1, .monotonic);
            if (completed == 0) {
                // No more pending operations
                break;
            }
        }
    }

    /// Formats a WAL entry with the given operation, key, value, and offset.
    /// Returns a buffer containing the serialized entry.
    /// The caller is responsible for freeing the buffer.
    /// The offset is used to store the location of the entry in the main database file.
    /// The value is optional and should be null for delete operations.
    ///
    /// See `Wal.WalEntryHeader` for the format of the entry.
    fn formatWalEntry(self: *Phage, op: Wal.WalOperation, key: []const u8, value: ?[]const u8, offset: usize) ![]u8 {
        // Calculate sizes
        const header_size = @sizeOf(Wal.WalEntryHeader); // 32 bytes
        const total_size = header_size + key.len;

        // Allocate buffer
        const buf = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(buf);

        const val_len = if (op == Wal.WalOperation.put) value.?.len else 0;

        // Create header
        const header = Wal.WalEntryHeader{
            .op_type = op,
            .key_len = key.len,
            .val_len = val_len,
            .offset = offset,
            .checksum = Wal.calculateChecksum(op, @intCast(key.len), @intCast(val_len), offset, key),
            .padding = 0,
        };

        // Serialize header
        @memcpy(buf[0..header_size], std.mem.asBytes(&header));

        // Append key
        @memcpy(buf[header_size..], key);

        return buf;
    }

    /// Formats a data entry with the given key and value.
    /// Returns a buffer containing the serialized entry.
    /// The caller is responsible for freeing the buffer.
    ///
    /// See `EntryHeader` for the format of the entry.
    fn formatDataEntry(self: *Phage, key: []const u8, value: []const u8) ![]u8 {
        // Validate sizes to prevent overflow
        if (key.len > std.math.maxInt(u32) or value.len > std.math.maxInt(u32)) {
            return error.ValueTooLarge;
        }

        // Calculate sizes
        const header_size = @sizeOf(index.EntryHeader); // 8 bytes
        const total_size = header_size + key.len + value.len;

        // Allocate buffer
        const buf = try self.allocator.alloc(u8, total_size);
        errdefer self.allocator.free(buf);

        // Create header
        const header = index.EntryHeader{
            .key_len = @intCast(key.len),
            .val_len = @intCast(value.len),
        };

        // Serialize header
        @memcpy(buf[0..header_size], std.mem.asBytes(&header));

        // Append key and value
        @memcpy(buf[header_size .. header_size + key.len], key);
        @memcpy(buf[header_size + key.len ..], value);

        return buf;
    }

    fn readFromWal(store: *Phage, buf: []u8, offset: usize) !usize {
        var sqe = try store.ring.get_sqe();
        sqe.prep_read(
            store.wal_fd,
            buf,
            offset,
        );
        sqe.flags |= linux.IOSQE_ASYNC;
        sqe.user_data = @intFromPtr(buf.ptr);
        const submitted = try store.ring.submit();
        const pending = try store.pending_ops.fetchAdd(1, .monotonic);
        return submitted + pending;
    }

    fn writeToWal(store: *Phage, buf: []u8, offset: usize) !usize {
        var sqe = try store.ring.get_sqe();
        sqe.prep_write(
            store.wal_fd,
            buf,
            offset,
        );
        sqe.flags |= linux.IOSQE_ASYNC;
        sqe.user_data = @intFromPtr(buf.ptr);
        const submitted = try store.ring.submit();
        const pending = store.pending_ops.fetchAdd(submitted, .monotonic);
        return submitted + pending;
    }
};

test "root:init" {
    const allocator = std.testing.allocator;
    const file_path = "test.db";

    var store = try Phage.init(allocator, file_path);
    defer store.deinit();
}

test "root:formatWalEntry" {
    const allocator = std.testing.allocator;

    var store = try Phage.init(allocator, "test.db");
    defer store.deinit();

    const buf = try store.formatWalEntry(.put, "test_key", "test_value", 0);
    defer allocator.free(buf);

    try std.testing.expectEqual(@sizeOf(Wal.WalEntryHeader) + 8, buf.len);
    const header: *const Wal.WalEntryHeader = @ptrCast(@alignCast(buf.ptr));
    try std.testing.expectEqual(Wal.WalOperation.put, header.op_type);
    try std.testing.expectEqual(8, header.key_len);
    try std.testing.expectEqual(10, header.val_len);

    // cleanup test db
    try testCleanup();
}

test "root:formatDataEntry" {
    const allocator = std.testing.allocator;

    var store = try Phage.init(allocator, "test.db");
    defer store.deinit();

    const buf = try store.formatDataEntry("test_key", "test_value");
    defer allocator.free(buf);

    try std.testing.expectEqual(@sizeOf(index.EntryHeader) + 8 + 10, buf.len);
    const header: *const index.EntryHeader = @ptrCast(@alignCast(buf.ptr));
    try std.testing.expectEqual(8, header.key_len);
    try std.testing.expectEqual(10, header.val_len);

    // cleanup test db
    try testCleanup();
}

test "root:put_and_get_key_value" {
    const allocator = std.testing.allocator;
    var store = try Phage.init(allocator, "test.db");
    defer store.deinit();
    errdefer testCleanup() catch unreachable;

    try store.put("key1", "value1");
    try store.put("key2", "value2");

    const val1 = try store.get("key1");
    defer allocator.free(val1);
    try std.testing.expectEqualStrings("value1", val1);

    const val2 = try store.get("key2");
    defer allocator.free(val2);
    try std.testing.expectEqualStrings("value2", val2);

    // cleanup test db
    try testCleanup();
}

test "root:delete_key" {
    const allocator = std.testing.allocator;
    var store = try Phage.init(allocator, "test.db");
    defer store.deinit();
    errdefer testCleanup() catch unreachable;

    try store.put("key1", "value1");
    const deleted = try store.delete("key1");
    try std.testing.expect(deleted);

    // We expect a KeyNotFound error here
    const result = store.get("key1");
    try std.testing.expectError(error.KeyNotFound, result);

    // cleanup test db
    try testCleanup();
}

test "root:findKeys" {
    const allocator = std.testing.allocator;
    var store = try Phage.init(allocator, "test.db");
    defer store.deinit();
    errdefer testCleanup() catch unreachable;

    try store.put("key1", "value1s");
    try store.put("key2", "value2");
    try store.put("key3", "value3");

    // Find keys with a specific pattern
    _ = try store.findKeys("key*");

    // cleanup test db
    try testCleanup();
}

fn testCleanup() !void {
    std.posix.unlink("test.db") catch {};
    std.posix.unlink("test.db.wal") catch {};
}
