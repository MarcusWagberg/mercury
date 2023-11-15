const std = @import("std");
const log = std.log;

const State = @import("../State.zig");

const common = @import("common.zig");

const HttpMethod = common.HttpMethod;
const HttpRequest = common.HttpRequest;
const HttpResult = common.HttpResult;

const InternalErrorResult = common.InternalErrorResult;
const InvalidQueryResult = common.InvalidQueryResult;

const parseQuery = common.parseQuery;
const getIdFromSlice = common.getIdFromSlice;
const getIdFromQuery = common.getIdFromQuery;

pub fn list(request: HttpRequest, state: *State) HttpResult {
    var query_map = parseQuery(state.alloc, request.query) catch |err| switch (err) {
        error.OutOfMemory => return InternalErrorResult,
        error.InvalidQuery => return InvalidQueryResult,
    };
    defer query_map.deinit();

    var attached_to_file: ?bool = null;
    var attached_to_id: ?[36]u8 = null;

    const attached_to_file_slice = query_map.get("attached_to_file");
    const attached_to_id_slice = query_map.get("attached_to_id");
    if (attached_to_id_slice) |id_slice| {
        attached_to_id = getIdFromSlice(id_slice) catch |err| switch (err) {
            error.InvalidLength => return HttpResult{ .code = 400, .body = "error: query param 'attached_to_id' of invalid length" },
            error.InvalidChar => return HttpResult{ .code = 400, .body = "error: query param 'attached_to_id' contains one or more invalid characters" },
        };

        attached_to_file = false;

        if (attached_to_file_slice) |file_slice| {
            if (std.mem.eql(u8, file_slice, "true")) {
                attached_to_file = true;
            } else if (std.mem.eql(u8, file_slice, "false")) {
                attached_to_file = false;
            } else {
                return HttpResult{ .code = 400, .body = "error: query param 'attached_to_file' is not either 'true' or 'false'" };
            }
        }
    }

    var files = state.file_store.list(state.alloc) catch |err| switch (err) {
        error.OutOfMemory => return InternalErrorResult,
    };
    defer files.free();

    if (attached_to_file == null and attached_to_id == null) {
        const json = std.json.stringifyAlloc(state.alloc, files.entries, .{}) catch |err| switch (err) {
            error.OutOfMemory => return InternalErrorResult,
        };
        return HttpResult{ .body = json, .free_body = true, .content_type = "application/json" };
    } else {
        var files_attached = state.alloc.alloc(*State.FileStore.LatestEntry, files.entries.len) catch {
            log.err("allocation failed!", .{});
            return InternalErrorResult;
        };
        defer state.alloc.free(files_attached);

        var files_attached_count: usize = 0;
        for (files.entries) |*file| {
            if (attached_to_file.? == file.data.attached_to_file and std.mem.eql(u8, &attached_to_id.?, &file.data.attached_to_id)) {
                files_attached[files_attached_count] = file;
                files_attached_count += 1;
            }
        }

        const json = std.json.stringifyAlloc(state.alloc, files_attached[0..files_attached_count], .{}) catch |err| switch (err) {
            error.OutOfMemory => return InternalErrorResult,
        };
        return HttpResult{ .body = json, .free_body = true, .content_type = "application/json" };
    }
}

pub fn create(request: HttpRequest, state: *State) HttpResult {
    const data = std.json.parseFromSlice(State.FileStore.LatestData, state.alloc, request.body, .{}) catch {
        log.err("failed to parse body", .{});
        return HttpResult{ .code = 400, .body = "error: invalid json data" };
    };
    defer data.deinit();

    state.file_store.create(data.value) catch |err| switch (err) {
        error.OsRandomFailed, error.OutOfMemory, error.PutFailed, error.SaveFailed => return InternalErrorResult,
    };

    return HttpResult{};
}

pub fn read(request: HttpRequest, state: *State) HttpResult {
    var id: [36]u8 = undefined;
    const get_id_err = getIdFromQuery(state.alloc, request.query, &id);
    if (get_id_err != null) return get_id_err.?;

    const file = state.file_store.read(state.alloc, id) catch |err| switch (err) {
        error.OutOfMemory => return InternalErrorResult,
        error.EntryNotFound => return HttpResult{ .code = 404, .body = "error: no file with provided id" },
    };
    defer file.free(state.alloc);

    const json = std.json.stringifyAlloc(state.alloc, file, .{}) catch |err| switch (err) {
        error.OutOfMemory => return InternalErrorResult,
    };
    return HttpResult{ .body = json, .free_body = true, .content_type = "application/json" };
}

pub fn update(request: HttpRequest, state: *State) HttpResult {
    var id: [36]u8 = undefined;
    const get_id_err = getIdFromQuery(state.alloc, request.query, &id);
    if (get_id_err != null) return get_id_err.?;

    const data = std.json.parseFromSlice(State.FileStore.LatestData, state.alloc, request.body, .{}) catch {
        log.err("failed to parse body", .{});
        return HttpResult{ .code = 400, .body = "error: invalid json data" };
    };
    defer data.deinit();

    state.file_store.update(id, data.value) catch |err| switch (err) {
        error.EntryNotFound => return HttpResult{ .code = 404, .body = "error: no file with provided id" },
        error.OutOfMemory, error.SaveFailed => return InternalErrorResult,
    };

    return HttpResult{};
}

pub fn delete(request: HttpRequest, state: *State) HttpResult {
    var id: [36]u8 = undefined;
    const get_id_err = getIdFromQuery(state.alloc, request.query, &id);
    if (get_id_err != null) return get_id_err.?;

    state.file_store.delete(id) catch |err| switch (err) {
        error.EntryNotFound => return HttpResult{ .code = 404, .body = "error: no file with provided id" },
        error.SaveFailed => return InternalErrorResult,
    };

    return HttpResult{};
}
