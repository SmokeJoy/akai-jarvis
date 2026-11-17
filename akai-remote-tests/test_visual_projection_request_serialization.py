"""Source-level regression guard for Android MediaProjection request serialization.

The Android service is compiled by the APK CI step; this checks that concurrent
requests cannot replace the in-flight callback or consume a second quota slot.
It is not a device concurrency test.
"""
from pathlib import Path

source = Path("akai-remote-tv/app/src/main/java/it/akai/customremote/VisualProjectionService.java").read_text()
start = source.index("private void requestOnWorker(")
end = source.index("private void consumeOnlyOnDemand(", start)
method = source[start:end]
guard = method.index("if (pending != null)")
denial = method.index('FrameResult.denied("FRAME_REQUEST_BUSY")', guard)
return_pos = method.index("return;", denial)
reserve = method.index("gate.reserveNextFrame(", return_pos)
assign = method.index("pending = callback;", reserve)
assert guard < denial < return_pos < reserve < assign
assert "callback.onFrame(FrameResult.denied" in method[guard:reserve]
assert method.count("pending = callback;") == 1
print("PASS: overlapping frame request rejected before quota reservation and callback assignment")

# A racing stop may quit the worker before post() accepts the request.
# requestFrame must propagate Handler.post(false), not report a phantom capture.
entry = source[source.index("public static boolean requestFrame("):source.index("public static boolean isSessionActive()")]
assert "return service.worker.post(new Runnable()" in entry
assert "service.worker.post(new Runnable()" in entry
assert "return true;" not in entry
print("PASS: stopped worker cannot falsely acknowledge a queued frame")
