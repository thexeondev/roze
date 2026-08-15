const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_REQ_AFFINITY_INFO(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_AFFINITY_INFO, @as(
        protobuf.gen.SC_Res_Affinity_Info,
        .init,
    ));
}
