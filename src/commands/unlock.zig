const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_UNLOCK_DATA_GET(scope: *Scope) Scope.Error!void {
    var feature_list: [41]protobuf.gen.UnlockFeatureData = undefined;

    // up to 41
    // TODO: use tables
    for (&feature_list, 1..42) |*feature, id|
        feature.* = .{
            .feature_id = @intCast(id),
            .is_read = true,
        };

    try scope.sink.send(.SC_UNLOCK_DATA_GET, @as(protobuf.gen.SC_Unlock_Data_Get, .{
        .unlock_feature_list = &feature_list,
    }));
}
