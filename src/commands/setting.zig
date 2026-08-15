const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_REQ_SETTING(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_SETTING, @as(
        protobuf.gen.SC_Res_Setting,
        .init,
    ));
}

pub fn CS_REQ_SET_SETTING(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_SET_SETTING, @as(
        protobuf.gen.SC_Res_Set_Setting,
        .init,
    ));
}
