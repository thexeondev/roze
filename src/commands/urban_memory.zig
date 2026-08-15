const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_URBAN_MEMORY_GET_DATA(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_URBAN_MEMORY_GET_DATA, @as(
        protobuf.gen.SC_Urban_Memory_Get_Data,
        .init,
    ));
}

pub fn CS_URBAN_MEMORY_GET_TRACK_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_URBAN_MEMORY_GET_TRACK_RSP, @as(
        protobuf.gen.SC_Urban_Memory_Get_Track_Rsp,
        .init,
    ));
}
