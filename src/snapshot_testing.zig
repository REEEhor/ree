const std = @import("std");
const gen = @import("root.zig");

const Io = std.Io;
const Dir = Io.Dir;

const FmtTerminal = gen.FmtTerminal;

pub const DbgTerminal = struct {
    inner: FmtTerminal,
    pub fn print(t: DbgTerminal, comptime fmt: []const u8, args: anytype) void {
        t.inner.print(fmt, args) catch {};
        t.inner.writer.flush() catch {};
    }
};

/// Both `out` and `err_out` will get flushed after the function returns.
/// The callee does not have to flush them.
///
/// If there is a problem with the `input` itself, it an error should not get returned but the error should be written
/// to `err_out`. Probably in a similiar way to:
/// ```zig
///     err_out.print("Got error: {t}\n", .{some_error});
/// ```
/// Other errors should be reported via the return value (out of memory, could not initialize some support object, ...)
pub const OutputProducer = fn (input: []const u8, std.mem.Allocator, out: *std.Io.Writer, err_out: *std.Io.Writer) anyerror!void;

pub const TestOptions = struct {
    /// Path to the directory containing snapshots.
    snapshots_dir: []const u8,

    /// Path to the input that is used for tests.
    test_inputs_dir: []const u8,

    test_name: []const u8,

    producer: OutputProducer,

    be_verbose: bool,

    show_diff: bool,

    /// When a test does not have a corresponding snapshot, create it from the test's output
    accept_new_snapshots: bool,
};

pub const erase_entire_line = "\x1b[2K";
pub const ERR = "{BOLD}{RED}";
pub const WARN = "{BOLD}{YELLOW}";

pub fn run_snapshot_tests(options: TestOptions) !void {
    const gpa = std.testing.allocator;
    const io = std.testing.io;

    var stderr_buffer: [512]u8 = undefined;
    var stderr_writer = std.Io.File.stderr().writer(io, &stderr_buffer);
    const stderr: *std.Io.Writer = &stderr_writer.interface;

    const t = setup_terminal: {
        const color_mode = get_color_mode: {
            const no_color: bool = false;
            const cli_color_force: bool = true;
            const detected = std.Io.Terminal.Mode.detect(io, std.Io.File.stderr(), no_color, cli_color_force) catch .no_color;
            break :get_color_mode detected;
        };
        const term = std.Io.Terminal{
            .mode = color_mode,
            .writer = stderr,
        };
        break :setup_terminal DbgTerminal{ .inner = FmtTerminal.from_std_terminal(term) };
    };

    var inputs_dir: Dir = try std.Io.Dir.cwd().openDir(io, options.test_inputs_dir, .{ .iterate = true });
    defer inputs_dir.close(io);

    Dir.cwd().createDirPath(io, options.snapshots_dir) catch {};
    var snapshots_dir: Dir = std.Io.Dir.cwd().openDir(io, options.snapshots_dir, .{}) catch |err| {
        t.print(ERR ++ "Could not open directory {s}, because: {t}\n", .{ options.snapshots_dir, err });
        return err;
    };
    defer snapshots_dir.close(io);

    var total_tests_count: i32 = 0;
    var failed_tests_count: i32 = 0;
    var tests_without_snapshots_count: i32 = 0;
    var error_tests_count: i32 = 0;
    var ok_tests_count: i32 = 0;
    var updated_snapshots_count: i32 = 0;
    var different_to_snapshot_count: i32 = 0;

    t.print("\nRunning the tests '{BOLD}{s}{RESET}' from: {s}\n", .{ options.test_name, options.test_inputs_dir });
    var inputs_dir_it = inputs_dir.iterate();
    next_test: while (try inputs_dir_it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        total_tests_count += 1;

        var test_is_ok: bool = false;
        defer {
            if (!options.be_verbose and test_is_ok) {
                t.print(erase_entire_line ++ "\r", .{});
            } else {
                t.print("\n", .{});
            }
        }

        // Read in the file
        const source_code: []const u8 = inputs_dir.readFileAlloc(io, entry.name, gpa, .unlimited) catch |err| {
            error_tests_count += 1;
            t.print(ERR ++ "Could not open file {s}, because: {s}{RESET}", .{ entry.name, @errorName(err) });
            continue :next_test;
        };
        defer gpa.free(source_code);

        // Generate the test name
        const current_test_name: []const u8 = blk: {
            break :blk std.mem.sliceTo(entry.name, '.');
        };

        // Run the test
        const program_output: []const u8 = running_the_tested_function: {
            var writer = std.Io.Writer.Allocating.init(gpa);
            defer writer.deinit();
            var err_writer = std.Io.Writer.Allocating.init(gpa);
            defer err_writer.deinit();
            //
            t.print(" - Test {BOLD}{s}{RESET}", .{current_test_name});
            { // Print the dots after the test name
                for (current_test_name.len..@max(current_test_name.len, 40)) |_| {
                    try t.inner.writer.writeByte('.');
                }
                try t.inner.writer.flush();
            }
            options.producer(source_code, gpa, &writer.writer, &err_writer.writer) catch |err| {
                failed_tests_count += 1;
                t.print(ERR ++ "Error occured: {t}{RESET}\n", .{err});
                continue;
            };
            try err_writer.writer.flush();
            const err_output: []u8 = try err_writer.toOwnedSlice();
            defer gpa.free(err_output);
            if (err_output.len != 0) {
                _ = try writer.writer.print("\n======== ERROR OUTPUT FROM THE PROGRAM ========\n", .{});
                _ = try writer.writer.write(err_output);
            }
            try writer.writer.flush();

            t.print("{GREEN}DONE!{RESET} ", .{});
            if (err_output.len == 0) {
                t.print("(output:  ok) ", .{});
            } else {
                t.print("(output: {RED}{DIM}err{RESET}) ", .{});
            }
            t.print("| ", .{});

            break :running_the_tested_function try writer.toOwnedSlice();
        };
        defer gpa.free(program_output);

        // Write the program output into a file
        var write_program_output_as_file: bool = false;
        defer write_program_output: {
            if (write_program_output_as_file) {
                const program_output_filename: []const u8 = std.mem.concat(gpa, u8, &[_][]const u8{ current_test_name, ".new.txt" }) catch break :write_program_output;
                defer gpa.free(program_output_filename);
                snapshots_dir.writeFile(io, .{ .data = program_output, .sub_path = program_output_filename }) catch |err| {
                    t.print(ERR ++ " Error while writing the program output into a file, because: {t}{RESET}", .{err});
                    error_tests_count += 1;
                };
            }
        }

        // Check that the snapshot exists
        const snapshot_contents: []const u8 = get_snapshot_contents: {
            const snapshot_filename = try std.mem.concat(gpa, u8, &[_][]const u8{ current_test_name, ".snapshot.txt" });
            defer gpa.free(snapshot_filename);

            if (snapshots_dir.readFileAlloc(io, snapshot_filename, gpa, .unlimited)) |snapshot_contents| {
                break :get_snapshot_contents snapshot_contents;
            } else |file_open_err| if (file_open_err == error.FileNotFound) {
                if (options.accept_new_snapshots) {
                    snapshots_dir.writeFile(io, .{ .data = program_output, .sub_path = snapshot_filename }) catch |file_write_err| {
                        error_tests_count += 1;
                        t.print(ERR ++ "Could not update the snapshot file, because: {t}{RESET}", .{file_write_err});
                        continue :next_test;
                    };
                    updated_snapshots_count += 1;
                    t.print("{BOLD}{GREEN}CREATED NEW SNAPSHOT!{RESET}", .{});
                    continue :next_test;
                } else {
                    tests_without_snapshots_count += 1;
                    write_program_output_as_file = true;
                    t.print(WARN ++ "SNAPSHOT NOT FOUND!{RESET}", .{});
                    continue :next_test;
                }
            } else {
                error_tests_count += 1;
                t.print(ERR ++ "Could open the snapshot file, because: {t}{RESET}\n", .{file_open_err});
                continue :next_test;
            }
        };
        defer gpa.free(snapshot_contents);

        // Compare the snapshot to the program of the output
        const diff = switch (find_diff(program_output, snapshot_contents)) {
            .same => {
                test_is_ok = true;
                ok_tests_count += 1;
                t.print("{GREEN}{BOLD}OK!{RESET}", .{});
                continue :next_test;
            },
            .different => |diff| diff,
        };
        t.print(ERR ++ "SNAPSHOT DIFFERS!{RESET}", .{});
        write_program_output_as_file = true;

        different_to_snapshot_count += 1;
        if (options.show_diff) {
            // Print diff
            t.print(ERR ++ "\n" ++ "=" ** 87 ++ "{RESET}\n", .{}); // Separator line
            //
            t.print("   - {CYAN}Snapshot contains{RESET} / {YELLOW}Program output contains{RESET}:\n", .{});
            //
            t.print("{DIM}     (line number {d}) >{RESET}{CYAN}", .{diff.first_different_line_number});
            if (diff.expected_line) |expected_line| {
                t.print("{f}{RESET}", .{std.ascii.hexEscape(expected_line, .upper)});
            } else {
                t.print("{DIM}(this line is not in the snapshot){RESET}", .{});
            }
            t.print("{DIM}<\n{RESET}", .{});
            //
            t.print("{DIM}     (line number {d}) >{RESET}{YELLOW}", .{diff.first_different_line_number});
            if (diff.actual_line) |actual_line| {
                t.print("{f}{RESET}", .{std.ascii.hexEscape(actual_line, .upper)});
            } else {
                t.print("{DIM}(this line is not in the program output){RESET}", .{});
            }

            t.print("{DIM}<\n{RESET}", .{});
            //
            t.print(ERR ++ "=" ** 87 ++ "{RESET}\n", .{}); // Separator line
        }
    }

    // Print results
    const all_tests_passed = ok_tests_count == total_tests_count;
    if (all_tests_passed and !options.be_verbose) {
        t.print(erase_entire_line ++ "\r", .{});
        t.print("{GREEN}All {BOLD}{d}{RESET}{GREEN} tests passed!{RESET}\n", .{total_tests_count});
    } else {
        t.print("{BOLD}Stats:{RESET}\n", .{});
        t.print(" - total test count: {d}\n", .{total_tests_count});
        if (tests_without_snapshots_count != 0) {
            t.print(WARN ++ " - tests without a snapshot: {d}{RESET}\n", .{tests_without_snapshots_count});
            if (!options.accept_new_snapshots) {
                t.print("{DIM}{YELLOW}     Run the tests with `{BOLD}-Dsnap-accept-all=true{RESET}{DIM}{YELLOW}` (or `{BOLD}-Dsa=true{RESET}{DIM}{YELLOW}` for short)\n", .{});
                t.print("     to accept program outputs as new snapshots for the ones that are missing.{RESET}\n", .{});
            }
        }
        if (updated_snapshots_count != 0) {
            t.print("{GREEN} - created new snapshots: {d}{RESET}\n", .{updated_snapshots_count});
        }
        if (different_to_snapshot_count != 0) {
            t.print(ERR ++ " - tests where the snapshot was different: {d}{RESET}\n", .{different_to_snapshot_count});
        }
        if (failed_tests_count != 0) {
            t.print(ERR ++ " - tests where the program returned an error: {d}{RESET}\n", .{failed_tests_count});
        }
        if (error_tests_count != 0) {
            t.print(ERR ++ " - tests where there was some file error: {d}{RESET}\n", .{error_tests_count});
        }
        if (ok_tests_count == total_tests_count) {
            t.print("{GREEN}All {BOLD}{d}{RESET}{GREEN} tests passed!{RESET}\n", .{total_tests_count});
        } else {
            t.print(" - ok tests: {d}\n", .{ok_tests_count});
        }
    }
}

const FindDiffResult = union(enum) {
    same,
    different: struct {
        first_different_line_number: usize,
        actual_line: ?[]const u8 = null,
        expected_line: ?[]const u8 = null,
        line_diff_idx: ?usize = null,
    },
};

fn find_diff(actual: []const u8, expected: []const u8) FindDiffResult {
    if (std.mem.eql(u8, actual, expected)) {
        return .same;
    }

    var actual_line_iter = std.mem.splitScalar(u8, actual, '\n');
    var expected_line_iter = std.mem.splitScalar(u8, expected, '\n');

    var line_idx: usize = 1;
    while (true) : (line_idx += 1) {
        const maybe_actual_line = actual_line_iter.next();
        const maybe_expected_line = expected_line_iter.next();

        if (maybe_actual_line == null and maybe_expected_line == null) {
            @panic("This should not happen. This means `std.mem.eql` returned `true` and we got to the end anyway.");
        }
        if (maybe_actual_line == null) {
            return .{ .different = .{ .expected_line = maybe_expected_line.?, .first_different_line_number = line_idx } };
        }
        if (maybe_expected_line == null) {
            return .{ .different = .{ .actual_line = maybe_actual_line.?, .first_different_line_number = line_idx } };
        }
        const actual_line, const expected_line = .{ maybe_actual_line.?, maybe_expected_line.? };
        if (std.mem.indexOfDiff(u8, actual_line, expected_line)) |diff_idx| {
            return .{ .different = .{
                .actual_line = actual_line,
                .expected_line = expected_line,
                .first_different_line_number = line_idx,
                .line_diff_idx = diff_idx,
            } };
        }
    }
}
