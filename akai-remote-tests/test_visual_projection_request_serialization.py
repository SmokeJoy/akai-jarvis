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

# Timeout scheduling can fail when the worker Looper is shutting down.
# A request must fail closed instead of leaving its callback pending forever.
timeout = method[method.index("pendingTimeout = new Runnable()"):]
assert 'if (!worker.postDelayed(pendingTimeout, FRAME_TIMEOUT_MS))' in timeout
assert 'finishRequest(FrameResult.denied("FRAME_TIMEOUT_SCHEDULE_REJECTED"))' in timeout
assert timeout.index('if (!worker.postDelayed') < timeout.index('FRAME_TIMEOUT_SCHEDULE_REJECTED')
print("PASS: rejected timeout scheduling completes pending request with failure")

# Android may revoke MediaProjection while the worker Looper is shutting down.
# Rejected dispatch must still stop capture; stopSelf alone leaks resources.
callback = source[source.index("projection.registerCallback("):source.index("DisplayMetrics dm =", source.index("projection.registerCallback("))]
assert "boolean queued = handler != null && handler.post(new Runnable()" in callback
assert "if (!queued)" in callback
fallback = callback[callback.index("if (!queued)"):]
assert fallback.index("stopCapture();") < fallback.index("stopSelf();")
print("PASS: rejected MediaProjection revocation dispatch releases capture resources")
