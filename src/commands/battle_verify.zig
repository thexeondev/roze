const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_BATTLE_VERIFY_SWITCH_QUERY_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_BATTLE_VERIFY_SWITCH_QUERY_RSP, @as(
        protobuf.gen.SC_Battle_Verify_Switch_Query_Rsp,
        .{ .report_enabled = false },
    ));
}
