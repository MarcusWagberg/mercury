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
    _ = request;

    var groups = state.group_store.list(state.alloc) catch |err| switch (err) {
        error.OutOfMemory => return InternalErrorResult,
    };
    defer groups.free();

    const json = std.json.stringifyAlloc(state.alloc, groups.entries, .{}) catch |err| switch (err) {
        error.OutOfMemory => return InternalErrorResult,
    };
    return HttpResult{ .body = json, .free_body = true, .content_type = "application/json" };
}

pub fn create(request: HttpRequest, state: *State) HttpResult {
    const data = std.json.parseFromSlice(State.GroupStore.LatestData, state.alloc, request.body, .{}) catch {
        log.err("failed to parse body", .{});
        return HttpResult{ .code = 400, .body = "error: invalid json data" };
    };
    defer data.deinit();

    state.group_store.create(data.value) catch |err| switch (err) {
        error.OsRandomFailed, error.OutOfMemory, error.PutFailed, error.SaveFailed => return InternalErrorResult,
    };

    return HttpResult{};
}

pub fn read(request: HttpRequest, state: *State) HttpResult {
    var id: [36]u8 = undefined;
    const get_id_err = getIdFromQuery(state.alloc, request.query, &id);
    if (get_id_err != null) return get_id_err.?;

    const group = state.group_store.read(state.alloc, id) catch |err| switch (err) {
        error.OutOfMemory => return InternalErrorResult,
        error.EntryNotFound => return HttpResult{ .code = 404, .body = "error: no group with provided id" },
    };
    defer group.free(state.alloc);

    const json = std.json.stringifyAlloc(state.alloc, group, .{}) catch |err| switch (err) {
        error.OutOfMemory => return InternalErrorResult,
    };
    return HttpResult{ .body = json, .free_body = true, .content_type = "application/json" };
}

pub fn update(request: HttpRequest, state: *State) HttpResult {
    var id: [36]u8 = undefined;
    const get_id_err = getIdFromQuery(state.alloc, request.query, &id);
    if (get_id_err != null) return get_id_err.?;

    const data = std.json.parseFromSlice(State.GroupStore.LatestData, state.alloc, request.body, .{}) catch {
        log.err("failed to parse body", .{});
        return HttpResult{ .code = 400, .body = "error: invalid json data" };
    };
    defer data.deinit();

    state.group_store.update(id, data.value) catch |err| switch (err) {
        error.EntryNotFound => return HttpResult{ .code = 404, .body = "error: no group with provided id" },
        error.OutOfMemory, error.SaveFailed => return InternalErrorResult,
    };

    return HttpResult{};
}

pub fn delete(request: HttpRequest, state: *State) HttpResult {
    var id: [36]u8 = undefined;
    const get_id_err = getIdFromQuery(state.alloc, request.query, &id);
    if (get_id_err != null) return get_id_err.?;

    state.group_store.delete(id) catch |err| switch (err) {
        error.EntryNotFound => return HttpResult{ .code = 404, .body = "error: no group with provided id" },
        error.SaveFailed => return InternalErrorResult,
    };

    return HttpResult{};
}
