const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_INTEL_RISK_VALUE_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_INTEL_RISK_VALUE_RSP, @as(
        protobuf.gen.SC_Intel_Risk_Value_Rsp,
        .init,
    ));
}

pub fn CS_FAVORITE_GAMEPLAY_FULL_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_FAVORITE_GAMEPLAY_FULL_RSP, @as(
        protobuf.gen.SC_Favorite_Gameplay_Full_Rsp,
        .init,
    ));
}

pub fn CS_INTEL_CENTER_INFO_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_INTEL_CENTER_INFO_RSP, @as(
        protobuf.gen.SC_Intel_Center_Info_Rsp,
        .init,
    ));
}
