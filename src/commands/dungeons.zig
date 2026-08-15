const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_DUNGEONS_FULL_DATA(scope: *Scope) Scope.Error!void {
    try scope.sink.send(
        .SC_DUNGEONS_FULL_DATA,
        @as(protobuf.gen.SC_Dungeons_Full_Data, .{
            .data = .{
                .common_data = .init,
                .horde_data = .init,
                .wait_reward_data = .init,
                .group_state_data = .init,
            },
        }),
    );
}
