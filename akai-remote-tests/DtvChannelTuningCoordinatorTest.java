package it.akai.customremote;

import java.util.ArrayList;
import java.util.Arrays;
import java.util.Collections;
import java.util.List;
import java.util.concurrent.CountDownLatch;
import java.util.concurrent.TimeUnit;
import java.util.concurrent.atomic.AtomicBoolean;
import java.util.concurrent.atomic.AtomicInteger;
import java.util.concurrent.atomic.AtomicLong;
import java.util.concurrent.atomic.AtomicReference;

/**
 * Host unit & concurrency tests for {@link DtvChannelTuningCoordinator}:
 * covers reproducible real-thread interrupt injection during the initial 600 ms
 * wait and inter-digit 250 ms wait, pre-existing interrupt flag, digit/ENTER
 * injection errors, invalid channel bounds, unavailable UInput, DTV switch
 * failure, and happy-path COMMAND_SENT semantics.
 */
public class DtvChannelTuningCoordinatorTest {
    private static void assertTrue(boolean cond, String msg) {
        if (!cond) {
            throw new AssertionError("DtvChannelTuningCoordinatorTest failed: " + msg);
        }
    }

    private static void assertEquals(Object expected, Object actual, String msg) {
        if (expected == null ? actual != null : !expected.equals(actual)) {
            throw new AssertionError("DtvChannelTuningCoordinatorTest failed [" + msg + "]: expected=" + expected + " actual=" + actual);
        }
    }

    private static final class RecordingBridge implements DtvChannelTuningCoordinator.HardwareBridge {
        final boolean uinputReady;
        final boolean dtvSwitchOk;
        final List<Integer> sentKeys = Collections.synchronizedList(new ArrayList<Integer>());
        final List<Long> sleepDurations = Collections.synchronizedList(new ArrayList<Long>());
        final AtomicInteger dtvSwitchCalls = new AtomicInteger(0);
        int failKeyIndex = -1; // 1-based sendKey call index to fail, or -1 for never
        final AtomicInteger sendKeyAttempt = new AtomicInteger(0);
        final boolean realSleep;
        final long triggerLatchOnSleepMs;
        final CountDownLatch sleepEnteredLatch;
        final CountDownLatch sleepAfterFirstDigitLatch;

        RecordingBridge(boolean uinputReady, boolean dtvSwitchOk, boolean realSleep,
                        long triggerLatchOnSleepMs, CountDownLatch sleepEnteredLatch,
                        CountDownLatch sleepAfterFirstDigitLatch) {
            this.uinputReady = uinputReady;
            this.dtvSwitchOk = dtvSwitchOk;
            this.realSleep = realSleep;
            this.triggerLatchOnSleepMs = triggerLatchOnSleepMs;
            this.sleepEnteredLatch = sleepEnteredLatch;
            this.sleepAfterFirstDigitLatch = sleepAfterFirstDigitLatch;
        }

        @Override
        public boolean isUInputAvailable() {
            return uinputReady;
        }

        @Override
        public CommandResult switchToDtv() {
            dtvSwitchCalls.incrementAndGet();
            return dtvSwitchOk
                    ? new CommandResult(true, "Richiesta ingresso Digitale Terrestre inviata")
                    : new CommandResult(false, "Nessun gestore TIF disponibile");
        }

        @Override
        public boolean sendKey(int keyCode) {
            int attempt = sendKeyAttempt.incrementAndGet();
            sentKeys.add(keyCode);
            if (failKeyIndex > 0 && attempt == failKeyIndex) {
                return false;
            }
            return true;
        }

        @Override
        public void sleepMs(long ms) throws InterruptedException {
            sleepDurations.add(ms);
            if (sleepEnteredLatch != null && (triggerLatchOnSleepMs < 0 || triggerLatchOnSleepMs == ms)) {
                sleepEnteredLatch.countDown();
            }
            if (sleepAfterFirstDigitLatch != null && !sentKeys.isEmpty() && ms == DtvChannelTuningCoordinator.DIGIT_INTERVAL_MS) {
                sleepAfterFirstDigitLatch.countDown();
            }
            if (realSleep) {
                Thread.sleep(ms);
            }
        }
    }

    public static void main(String[] args) throws Exception {
        // 0. Exact keycode & timing parity with UInputDriver
        assertEquals(UInputDriver.KEY_0, DtvChannelTuningCoordinator.KEY_0, "KEY_0 parity");
        assertEquals(UInputDriver.KEY_1, DtvChannelTuningCoordinator.KEY_1, "KEY_1 parity");
        assertEquals(UInputDriver.KEY_ENTER, DtvChannelTuningCoordinator.KEY_ENTER, "KEY_ENTER parity");
        assertEquals(600L, DtvChannelTuningCoordinator.INITIAL_DTV_SETTLE_MS, "Initial DTV settle constant");
        assertEquals(250L, DtvChannelTuningCoordinator.DIGIT_INTERVAL_MS, "Digit interval constant");

        // 1. Negative Test 1: Real-thread interrupt during 600 ms initial DTV settle wait -> ZERO keys injected
        final CountDownLatch inInitialWaitLatch = new CountDownLatch(1);
        final RecordingBridge bridge1 = new RecordingBridge(true, true, true, 600L, inInitialWaitLatch, null);
        final AtomicReference<CommandResult> res1 = new AtomicReference<>();
        final AtomicBoolean workerInterrupted1 = new AtomicBoolean(false);
        final AtomicLong elapsed1 = new AtomicLong(-1L);

        Thread worker1 = new Thread(new Runnable() {
            @Override
            public void run() {
                long t0 = System.nanoTime();
                try {
                    CommandResult r = DtvChannelTuningCoordinator.tuneChannel(501, bridge1);
                    res1.set(r);
                    workerInterrupted1.set(Thread.currentThread().isInterrupted());
                } finally {
                    elapsed1.set((System.nanoTime() - t0) / 1_000_000L);
                }
            }
        }, "test-dtv-interrupt-600ms");
        worker1.start();
        assertTrue(inInitialWaitLatch.await(2, TimeUnit.SECONDS), "Worker entered 600 ms wait");
        worker1.interrupt();
        worker1.join(2000L);
        assertTrue(!worker1.isAlive(), "Worker1 exited promptly after interrupt");
        assertTrue(elapsed1.get() < 500L, "Aborted before full 600 ms wait (elapsed=" + elapsed1.get() + " ms)");
        assertTrue(res1.get() != null && !res1.get().success, "Interrupted 600 ms wait returns failure");
        assertTrue(workerInterrupted1.get(), "Interrupt flag restored on worker1 thread");
        assertEquals(1, bridge1.dtvSwitchCalls.get(), "switchToDtv called once");
        assertTrue(bridge1.sentKeys.isEmpty(), "ZERO keys injected after interrupt during 600 ms wait");

        // 2. Negative Test 2: Real-thread interrupt during 250 ms inter-digit wait -> stops immediately after KEY_1
        final CountDownLatch afterFirstDigitWaitLatch = new CountDownLatch(1);
        final RecordingBridge bridge2 = new RecordingBridge(true, true, true, -999L, null, afterFirstDigitWaitLatch);
        final AtomicReference<CommandResult> res2 = new AtomicReference<>();
        final AtomicBoolean workerInterrupted2 = new AtomicBoolean(false);

        Thread worker2 = new Thread(new Runnable() {
            @Override
            public void run() {
                CommandResult r = DtvChannelTuningCoordinator.tuneChannel(125, bridge2);
                res2.set(r);
                workerInterrupted2.set(Thread.currentThread().isInterrupted());
            }
        }, "test-dtv-interrupt-digit");
        worker2.start();
        assertTrue(afterFirstDigitWaitLatch.await(2, TimeUnit.SECONDS), "Worker entered post-digit 250 ms wait");
        worker2.interrupt();
        worker2.join(2000L);
        assertTrue(!worker2.isAlive(), "Worker2 exited cleanly after digit interrupt");
        assertTrue(res2.get() != null && !res2.get().success, "Interrupted digit wait returns failure");
        assertTrue(workerInterrupted2.get(), "Interrupt flag restored on worker2 thread");
        assertEquals(Collections.singletonList(DtvChannelTuningCoordinator.KEY_1), new ArrayList<>(bridge2.sentKeys),
                "Only first digit KEY_1 sent before interrupt; zero KEY_2/KEY_5/KEY_ENTER");

        // 3. Negative Test 3: Pre-existing interrupt flag before start -> zero switch, zero keys, flag preserved
        final RecordingBridge bridge3 = new RecordingBridge(true, true, false, -1L, null, null);
        final AtomicReference<CommandResult> res3 = new AtomicReference<>();
        final AtomicBoolean workerInterrupted3 = new AtomicBoolean(false);
        Thread worker3 = new Thread(new Runnable() {
            @Override
            public void run() {
                Thread.currentThread().interrupt();
                res3.set(DtvChannelTuningCoordinator.tuneChannel(5, bridge3));
                workerInterrupted3.set(Thread.currentThread().isInterrupted());
            }
        }, "test-dtv-pre-interrupted");
        worker3.start();
        worker3.join(2000L);
        assertTrue(res3.get() != null && !res3.get().success, "Pre-interrupted thread returns failure");
        assertTrue(workerInterrupted3.get(), "Pre-existing interrupt flag preserved");
        assertEquals(0, bridge3.dtvSwitchCalls.get(), "Zero switchToDtv calls when pre-interrupted");
        assertTrue(bridge3.sentKeys.isEmpty(), "Zero keys injected when pre-interrupted");

        // 4. Negative Test 4: Digit injection error (1st digit and 2nd digit)
        RecordingBridge bridge4a = new RecordingBridge(true, true, false, -1L, null, null);
        bridge4a.failKeyIndex = 1;
        CommandResult res4a = DtvChannelTuningCoordinator.tuneChannel(501, 0L, 0L, bridge4a);
        assertTrue(!res4a.success, "Fail when 1st digit sendKey returns false");
        assertEquals(1, bridge4a.sendKeyAttempt.get(), "Aborts after 1st failed digit attempt; zero further keys/ENTER");

        RecordingBridge bridge4b = new RecordingBridge(true, true, false, -1L, null, null);
        bridge4b.failKeyIndex = 2;
        CommandResult res4b = DtvChannelTuningCoordinator.tuneChannel(501, 0L, 0L, bridge4b);
        assertTrue(!res4b.success, "Fail when 2nd digit sendKey returns false");
        assertEquals(2, bridge4b.sendKeyAttempt.get(), "Aborts after 2nd failed digit attempt; zero 3rd digit or ENTER");

        // 5. Negative Test 5: KEY_ENTER injection error
        RecordingBridge bridge5 = new RecordingBridge(true, true, false, -1L, null, null);
        bridge5.failKeyIndex = 2; // 1st attempt is KEY_5, 2nd is KEY_ENTER
        CommandResult res5 = DtvChannelTuningCoordinator.tuneChannel(5, 0L, 0L, bridge5);
        assertTrue(!res5.success, "Fail when KEY_ENTER fails");
        assertEquals(Arrays.asList(UInputDriver.KEY_5, UInputDriver.KEY_ENTER), bridge5.sentKeys,
                "Attempted KEY_5 then failed on KEY_ENTER");

        // 6. Negative Test 6: Invalid channel bounds (0, -1, -50, 10000, MIN_VALUE, MAX_VALUE)
        for (int badCh : new int[] { 0, -1, -50, 10000, Integer.MIN_VALUE, Integer.MAX_VALUE }) {
            RecordingBridge bridgeBad = new RecordingBridge(true, true, false, -1L, null, null);
            CommandResult badRes = DtvChannelTuningCoordinator.tuneChannel(badCh, bridgeBad);
            assertTrue(!badRes.success, "Invalid channel rejected fail-closed: " + badCh);
            assertEquals(0, bridgeBad.dtvSwitchCalls.get(), "Zero switchToDtv for bad channel " + badCh);
            assertTrue(bridgeBad.sentKeys.isEmpty(), "Zero keys for bad channel " + badCh);
            assertTrue(bridgeBad.sleepDurations.isEmpty(), "Zero sleeps for bad channel " + badCh);
        }

        // 7. Negative Test 7: UInput unavailable and switchToDtv failure
        RecordingBridge bridgeNoUinput = new RecordingBridge(false, true, false, -1L, null, null);
        CommandResult resNoUinput = DtvChannelTuningCoordinator.tuneChannel(1, bridgeNoUinput);
        assertTrue(!resNoUinput.success, "Fails when UInput unavailable");
        assertEquals(0, bridgeNoUinput.dtvSwitchCalls.get(), "Zero switchToDtv when UInput unavailable");
        assertTrue(bridgeNoUinput.sentKeys.isEmpty(), "Zero keys when UInput unavailable");

        RecordingBridge bridgeSwitchFail = new RecordingBridge(true, false, false, -1L, null, null);
        CommandResult resSwitchFail = DtvChannelTuningCoordinator.tuneChannel(1, bridgeSwitchFail);
        assertTrue(!resSwitchFail.success, "Fails when switchToDtv fails");
        assertTrue(bridgeSwitchFail.sentKeys.isEmpty(), "Zero keys when switchToDtv fails");
        assertTrue(bridgeSwitchFail.sleepDurations.isEmpty(), "Zero sleeps when switchToDtv fails");

        // 8. Positive Test 8: Happy path channel 105 -> standard timings + COMMAND_SENT message (never STATE_VERIFIED)
        RecordingBridge bridgeOk = new RecordingBridge(true, true, false, -1L, null, null);
        CommandResult resOk = DtvChannelTuningCoordinator.tuneChannel(105, bridgeOk);
        assertTrue(resOk.success, "Happy path channel 105 returns success");
        assertEquals(1, bridgeOk.dtvSwitchCalls.get(), "One DTV switch");
        assertEquals(Arrays.asList(UInputDriver.KEY_1, UInputDriver.KEY_0, UInputDriver.KEY_5, UInputDriver.KEY_ENTER),
                bridgeOk.sentKeys, "Channel 105 key sequence");
        assertEquals(Arrays.asList(600L, 250L, 250L, 250L),
                bridgeOk.sleepDurations, "Standard 600ms initial + 250ms inter-digit sleeps");
        assertTrue(resOk.message != null && resOk.message.contains("non verificato") && !resOk.message.contains("STATE_VERIFIED"),
                "Happy path message clarifies COMMAND_SENT / non verificato, never STATE_VERIFIED");

        System.out.println("DtvChannelTuningCoordinatorTest PASS: real-thread 600ms/digit interrupts, bounds, error & COMMAND_SENT tests OK.");
    }
}
