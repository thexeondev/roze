const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_GAMETIME_ALIGN_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_GAMETIME_ALIGN_RSP, @as(
        protobuf.gen.SC_GameTime_Align_Rsp,
        .{
            .cur_time = 360,
            .cur_weather = 1,
        },
    ));
}
