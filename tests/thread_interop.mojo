"""Validate Mojo allocation and error boundaries on native POSIX threads."""
from std.collections import Dict
from std.ffi import external_call
from std.memory import OptionalPointer, Pointer
from std.runtime import initialize_runtime
from std.testing import assert_equal
from mojolt.websockets.treading.thread import ThreadContext, ThreadFunction


def allocate_objects(context: ThreadContext) raises:
    var values = List[String]()
    var mapping = Dict[String, Int]()
    for i in range(256):
        var text = String("item-", i)
        values.append(text)
        mapping[text] = i
    if len(values) != 256 or mapping["item-255"] != 255:
        raise Error("Allocation or object construction failed")
    if context.value()[] == 2:
        raise Error("Worker initialization rejected")
    context.value()[] = 1


def exercise(context: ThreadContext) abi("C") -> ThreadContext:
    initialize_runtime()
    try:
        allocate_objects(context)
    except:
        context.value()[] = 3
    return context


def main() raises:
    initialize_runtime()
    var entry: ThreadFunction = exercise
    for _ in range(32):
        var states = List[UInt8](length=8, fill=0)
        states[7] = 2
        var handles = List[ThreadContext](length=8, fill=None)
        for i in range(8):
            var context = (
                states.unsafe_ptr()
                .unsafe_offset(i)
                .unsafe_origin_cast[MutUntrackedOrigin]()
            )
            assert_equal(
                external_call["mojolt_thread_create", Int32](
                    handles.unsafe_ptr().unsafe_offset(i), entry, context
                ),
                0,
            )
        for i in range(8):
            assert_equal(
                external_call["mojolt_thread_join", Int32](
                    handles.unsafe_ptr().unsafe_offset(i)
                ),
                0,
            )
            assert_equal(states[i], UInt8(3 if i == 7 else 1))
            assert_equal(Bool(handles[i]), False)
    print(
        "ok native Mojo interoperability: 256 threads, allocations and error"
        " containment"
    )
