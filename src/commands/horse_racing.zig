const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_REQ_HORSE_TRACK_INFO(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_HORSE_TRACK_INFO, @as(
        protobuf.gen.SC_Res_Horse_Track_Info,
        .init,
    ));
}
