const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const assets = roze.assets;
const Scope = roze.Scope;

pub fn CS_ROOKIE_GUIDE_INFOS_REQ(scope: *Scope) Scope.Error!void {
    var guide_infos: [assets.tables.guide_platform.len]protobuf.gen.Rookie_Guide_Info = undefined;

    for (&guide_infos, assets.tables.guide_platform) |*guide_info, config|
        guide_info.* = .{
            .guide_id = config.id,
            .is_guide_complete = true,
        };

    try scope.sink.send(.SC_ROOKIE_GUIDE_INFOS_RES, @as(
        protobuf.gen.SC_Rookie_Guide_Infos_Res,
        .{
            .guide_infos = &guide_infos,
        },
    ));
}
