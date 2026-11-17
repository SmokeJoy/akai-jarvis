"""Source-level regression guard for Android MediaProjection request serialization.

The Android service is compiled by the APK CI step; this checks that concurrent
requests cannot replace the in-flight callback or consume a second quota slot.
It is not a device concurrency test.
"""
from pathlib import Path

source = Path("akai-remote-tv/app/src/main/java/it/akai/customremote/VisualProjectionService.java").read_text()
start = source.index("private synchronized void requestOnWorker(")
end = source.index("private void consumeOnlyOnDemand(", start)
method = source[start:end]
guard = method.index("if (pending != null)")
denial = method.index('deliverDenied(callback, "FRAME_REQUEST_BUSY")', guard)
return_pos = method.index("return;", denial)
reserve = method.index("gate.reserveNextFrame(", return_pos)
assign = method.index("pending = callback;", reserve)
assert "private synchronized void requestOnWorker(" in source
assert "private synchronized void finishRequest(" in source
assert "private synchronized void stopCapture(" in source
assert guard < denial < return_pos < reserve < assign
assert 'deliverDenied(callback, "FRAME_REQUEST_BUSY")' in method[guard:reserve]
assert method.count("pending = callback;") == 1
print("PASS: frame reservation, completion and STOP share the same service monitor")
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

# If the Looper rejects the session-expiry timer, no session may remain active.
startup = source[source.index("if (!VisualObservationProvider.install("):source.index("} catch (Exception failure)")]
assert "if (!worker.postDelayed(expiration, VisualCaptureSessionGate.MAX_SESSION_MS))" in startup
reject = startup[startup.index("if (!worker.postDelayed(expiration,"):]
assert reject.index("stopCapture();") < reject.index("stopSelf();")
print("PASS: rejected session-expiry scheduling releases MediaProjection resources")

# A rejected request callback is untrusted and must not terminate the worker.
helper = source[source.index("private static void deliverDenied("):source.index("private synchronized void requestOnWorker(")]
assert "try { callback.onFrame(FrameResult.denied(reason)); }" in helper
assert "catch (RuntimeException ignored)" in helper
assert 'deliverDenied(callback, "SESSION_CLOSED")' in method
assert 'deliverDenied(callback, verdict.reason)' in method
print("PASS: denied frame callbacks cannot crash the worker")

# Accessibility or cloud-consent reads may throw during OEM UI transitions.
# A failed context read must fail closed without reserving quota or attaching
# the VirtualDisplay surface, and must notify the original frame caller.
context = method[method.index("final ScreenPerceptionEngine.PerceptionSnapshot snap;"):method.index("gate.reserveNextFrame(")]
assert "try {" in context and "catch (RuntimeException unavailable)" in context
assert 'deliverDenied(callback, "FRAME_CONTEXT_UNAVAILABLE")' in context
assert context.index('deliverDenied(callback, "FRAME_CONTEXT_UNAVAILABLE")') < context.index("return;", context.index('deliverDenied(callback, "FRAME_CONTEXT_UNAVAILABLE")'))
assert "ScreenPerceptionEngine.capture(this)" in context
assert "hasCloudContextConsent()" in context
print("PASS: failed Accessibility/context read denies capture before quota reservation")
