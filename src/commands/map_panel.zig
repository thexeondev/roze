const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_MAP_GET_ALL_TARGETS(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_MAP_GET_ALL_TARGETS, @as(
        protobuf.gen.SC_Map_Get_All_Targets,
        .init,
    ));
}
