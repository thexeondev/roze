const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_REQ_UNLOCKED_WIND_ROADS(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_UNLOCKED_WIND_ROADS, @as(
        protobuf.gen.SC_Res_Unlocked_Wind_Roads,
        .init,
    ));
}

pub fn CS_REQ_REGION_PROGRESS(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_REGION_PROGRESS, @as(
        protobuf.gen.SC_Res_Region_Progress,
        .init,
    ));
}
