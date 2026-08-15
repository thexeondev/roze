const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_HOUSE_INFO_REQ(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_HOUSE_INFO_RSP, @as(
        protobuf.gen.SC_House_Info_Rsp,
        .{ .house_sys_info = .{ .level = 1 } },
    ));
}
