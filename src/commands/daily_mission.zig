const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_DAILY_MISSION_QUERY(scope: *Scope) Scope.Error!void {
    try scope.sink.send(
        .SC_DAILY_MISSION_QUERY,
        @as(protobuf.gen.SC_Daily_Mission_Query, .{
            .data = .{
                .mission_list_data = .init,
                .reward_data = .init,
            },
        }),
    );
}
