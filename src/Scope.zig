const Scope = @This();
const roze = @import("roze.zig");
const Io = roze.Io;

time: Io.Timespec,
sink: roze.net.Sink,
command: roze.commands.Buffer,
gameplay: *roze.Gameplay,
asset_index: *const roze.assets.Index,
store: Store,

pub const Error = roze.net.Sink.Error ||
    roze.commands.Buffer.Error;

pub const Store = struct {
    role_id: u64,
    gameplay_state_save_requested: bool,

    pub fn requestGameplayStateSave(store: *Store) void {
        store.gameplay_state_save_requested = true;
    }
};
