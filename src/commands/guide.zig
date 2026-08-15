const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const assets = roze.assets;
const Scope = roze.Scope;

pub fn CS_REQ_GUIDE_INFO(scope: *Scope) Scope.Error!void {
    var guide_list: [assets.tables.guide.len]protobuf.gen.GuideInfo = undefined;

    for (&guide_list, assets.tables.guide) |*guide, config|
        guide.* = .{
            .guide_id = config.id,
            .state = .ENM_GUIDE_STATE_READED,
        };

    try scope.sink.send(.SC_RES_GUIDE_INFO, @as(
        protobuf.gen.SC_Res_Guide_Info,
        .{ .guide_list = &guide_list },
    ));
}
