const std = @import("std");
const assert = std.debug.assert;
const ArrayList = std.ArrayList;

const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;
const assets = roze.assets;

pub fn CS_REQ_UNLOCKED_WIND_ROADS(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_RES_UNLOCKED_WIND_ROADS, @as(
        protobuf.gen.SC_Res_Unlocked_Wind_Roads,
        .init,
    ));
}

pub fn CS_REQ_REGION_PROGRESS(scope: *Scope) Scope.Error!void {
    var regions: [assets.tables.region.len]protobuf.gen.RegionProgress = undefined;
    var sub_region_buf: [assets.tables.sub_region_config_read_target.len]protobuf.gen.SubRegionProgress = undefined;
    var sub_region_list: ArrayList(protobuf.gen.SubRegionProgress) = .initBuffer(&sub_region_buf);

    const progress_entries_count = comptime count: {
        var count: usize = 0;
        for (@typeInfo(assets.tables.region_progress_sheets).@"struct".decl_names) |decl_name| {
            for (@field(assets.tables.region_progress_sheets, decl_name)) |sub_region_config| {
                count += sub_region_config.sequence_id.len;
            }
        }

        break :count count;
    };

    var progress_buf: [progress_entries_count]protobuf.gen.ProgressData = undefined;
    var progress_list: ArrayList(protobuf.gen.ProgressData) = .initBuffer(&progress_buf);

    for (&regions, assets.tables.region) |*region_progress, region_config| {
        const sub_regions = sub_region_list.addManyAsSliceAssumeCapacity(region_config.sub_region_id.len);
        var sub_region_i: usize = 0;

        for (assets.tables.sub_region_config_read_target) |sub_region_config| {
            if (sub_region_config.id / 1000 != region_config.id) continue;
            defer sub_region_i += 1;

            const progress_config = scope.asset_index.sub_region_progress.get(sub_region_config.id).?;
            const progress = progress_list.addManyAsSliceAssumeCapacity(progress_config.sequence_id.len);

            for (progress, progress_config.sequence_id) |*progress_data, sequence_id| {
                progress_data.* = .{ .sequence_id = sequence_id, .count = 1 };
            }

            sub_regions[sub_region_i] = .{
                .sub_region_id = sub_region_config.id,
                .progress = progress,
                .cur_progress = 100,
            };
        }

        region_progress.* = .{
            .region_id = region_config.id,
            .sub_region_progress = sub_regions,
        };
    }

    try scope.sink.send(.SC_RES_REGION_PROGRESS, @as(
        protobuf.gen.SC_Res_Region_Progress,
        .{
            .region_progress = &regions,
        },
    ));
}
