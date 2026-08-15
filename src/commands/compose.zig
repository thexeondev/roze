const roze = @import("../roze.zig");
const protobuf = roze.protobuf;
const Scope = roze.Scope;

pub fn CS_COMPOSE_GET_RECIPES(scope: *Scope) Scope.Error!void {
    try scope.sink.send(.SC_COMPOSE_GET_RECIPES, @as(
        protobuf.gen.SC_Compose_Get_Recipes,
        .init,
    ));
}
