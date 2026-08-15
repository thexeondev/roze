const SinglyLinkedListWithTail = @This();
const std = @import("std");
const assert = std.debug.assert;

pub const Node = struct {
    next: ?*Node,

    pub const init: Node = .{ .next = null };
};

head: ?*Node,
tail: ?*Node,

pub const init: SinglyLinkedListWithTail = .{ .head = null, .tail = null };

pub fn append(list: *SinglyLinkedListWithTail, node: *Node) void {
    node.next = null;

    if (list.tail) |tail| {
        assert(list.head != null); // if `tail` is not null, `head` must be too.
        tail.next = node;
        list.tail = node;
    } else {
        assert(list.head == null); // if `tail` is null, `head` must be too.
        list.head = node;
        list.tail = node;
    }
}

pub fn popFirst(list: *SinglyLinkedListWithTail) ?*Node {
    if (list.head) |head| {
        if (head.next == null) {
            assert(list.tail == list.head);
            list.tail = null;
        }

        list.head = head.next;
        return head;
    }

    assert(list.tail == null);
    return null;
}
