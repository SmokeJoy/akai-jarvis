package it.akai.customremote;

import android.app.ActivityManager;
import android.content.Context;
import android.os.Debug;
import android.os.PowerManager;
import android.os.Process;
import android.os.SystemClock;
import android.util.Log;

import org.json.JSONObject;

import java.io.BufferedReader;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.FileReader;
import java.io.FileWriter;
import java.io.InputStreamReader;
import java.io.PrintWriter;
import java.text.SimpleDateFormat;
import java.util.Date;
import java.util.List;
import java.util.Locale;
import java.util.TimeZone;
import java.util.concurrent.Executors;
import java.util.concurrent.ScheduledExecutorService;
import java.util.concurrent.ScheduledFuture;
import java.util.concurrent.TimeUnit;

/**
 * LocalDiagnosticsManager
 *
 * Sistema di telemetria e diagnostica autonoma a bordo della TV AKAI AKTV5037N.
 * Raccoglie metriche di memoria, swap, launcher PSS e stabilità senza richiedere
 * connessione attiva al PC né wake-lock invasivi durante lo standby.
 */
public class LocalDiagnosticsManager {
    private static final String TAG = "AKAI_Diagnostics";
    private static final String LOG_FILE_NAME = "akai_diagnostics.jsonl";
    private static final String OLD_LOG_FILE_NAME = "akai_diagnostics.old.jsonl";
    private static final long MAX_FILE_SIZE_BYTES = 1024 * 1024; // 1 MB limite (max ~10.000 campioni)
    private static final long SAMPLE_INTERVAL_MINUTES = 15; // Campionamento ogni 15 minuti

    private static LocalDiagnosticsManager sInstance = null;

    private final Context context;
    private final PowerManager powerManager;
    private final ActivityManager activityManager;
    private final File logFile;
    private final File oldLogFile;
    private final File sdcardFile;
    private final ScheduledExecutorService scheduler;
    private ScheduledFuture<?> periodicTask = null;
    private final SimpleDateFormat isoFormatter;

    private volatile boolean wasInteractive = true;

    public static synchronized LocalDiagnosticsManager getInstance(Context context) {
        if (sInstance == null) {
            sInstance = new LocalDiagnosticsManager(context.getApplicationContext());
        }
        return sInstance;
    }

    private LocalDiagnosticsManager(Context context) {
        this.context = context;
        this.powerManager = (PowerManager) context.getSystemService(Context.POWER_SERVICE);
        this.activityManager = (ActivityManager) context.getSystemService(Context.ACTIVITY_SERVICE);

        this.logFile = new File(context.getFilesDir(), LOG_FILE_NAME);
        this.oldLogFile = new File(context.getFilesDir(), OLD_LOG_FILE_NAME);
        this.sdcardFile = new File("/sdcard/" + LOG_FILE_NAME);

        this.scheduler = Executors.newSingleThreadScheduledExecutor();

        this.isoFormatter = new SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss'Z'", Locale.US);
        this.isoFormatter.setTimeZone(TimeZone.getTimeZone("UTC"));

        Log.i(TAG, "LocalDiagnosticsManager inizializzato. File log: " + logFile.getAbsolutePath());
    }

    public synchronized void start() {
        if (periodicTask != null && !periodicTask.isCancelled()) {
            return;
        }

        // Registra evento di avvio (boot o service start)
        recordBootEvent();

        // Pianifica il campionamento periodico (rispetta lo standby, zero wakelock)
        periodicTask = scheduler.scheduleWithFixedDelay(new Runnable() {
            @Override
            public void run() {
                try {
                    boolean interactive = isScreenInteractive();
                    if (!interactive) {
                        // Se la TV è in standby, non risvegliare la CPU né fare I/O pesante
                        if (wasInteractive) {
                            wasInteractive = false;
                            recordEvent("standby_enter", "TV entrata in standby a basso consumo");
                        }
                        return;
                    }

                    if (!wasInteractive) {
                        wasInteractive = true;
                        recordEvent("standby_exit", "TV riaccesa dallo standby");
                    }

                    recordTelemetrySample("periodic");
                } catch (Throwable t) {
                    Log.e(TAG, "Errore durante campionamento diagnostico: " + t.getMessage());
                }
            }
        }, 1, SAMPLE_INTERVAL_MINUTES, TimeUnit.MINUTES);

        Log.i(TAG, "Monitoraggio diagnostico periodico avviato (intervallo: " + SAMPLE_INTERVAL_MINUTES + " min).");
    }

    public void onScreenStateChanged(boolean isInteractive) {
        scheduler.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    if (isInteractive) {
                        wasInteractive = true;
                        recordEvent("screen_on", "Schermo acceso");
                        recordTelemetrySample("screen_wake");
                    } else {
                        wasInteractive = false;
                        recordEvent("screen_off", "Schermo spento (standby)");
                    }
                } catch (Throwable ignored) {}
            }
        });
    }

    public void recordError(final String source, final String message) {
        scheduler.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONObject json = new JSONObject();
                    json.put("type", "error");
                    json.put("time", formatTimestamp(System.currentTimeMillis()));
                    json.put("uptime_s", SystemClock.elapsedRealtime() / 1000);
                    json.put("source", source);
                    json.put("message", message != null ? message : "");
                    appendJsonLine(json);
                } catch (Throwable ignored) {}
            }
        });
    }

    public void recordEvent(final String eventName, final String detail) {
        scheduler.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONObject json = new JSONObject();
                    json.put("type", "event");
                    json.put("event", eventName);
                    json.put("time", formatTimestamp(System.currentTimeMillis()));
                    json.put("uptime_s", SystemClock.elapsedRealtime() / 1000);
                    json.put("screen_on", isScreenInteractive());
                    if (detail != null) json.put("detail", detail);
                    appendJsonLine(json);
                } catch (Throwable ignored) {}
            }
        });
    }

    private void recordBootEvent() {
        scheduler.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONObject json = new JSONObject();
                    json.put("type", "boot");
                    json.put("time", formatTimestamp(System.currentTimeMillis()));
                    json.put("uptime_s", SystemClock.elapsedRealtime() / 1000);
                    json.put("device", "AKTV5037N");
                    json.put("version", "1.1.0-Phase10");
                    json.put("screen_on", isScreenInteractive());
                    appendJsonLine(json);

                    // Esegui anche un primo campione immediato
                    recordTelemetrySample("boot_initial");
                } catch (Throwable t) {
                    Log.e(TAG, "Errore recordBootEvent: " + t.getMessage());
                }
            }
        });
    }

    public void triggerManualSample(final String reason) {
        scheduler.execute(new Runnable() {
            @Override
            public void run() {
                recordTelemetrySample(reason);
            }
        });
    }

    private void recordTelemetrySample(String triggerReason) {
        try {
            JSONObject json = new JSONObject();
            json.put("type", "sample");
            json.put("trigger", triggerReason);
            json.put("time", formatTimestamp(System.currentTimeMillis()));
            json.put("uptime_s", SystemClock.elapsedRealtime() / 1000);
            json.put("screen_on", isScreenInteractive());

            // 1. Memoria di sistema da /proc/meminfo
            MemInfo mem = readProcMeminfo();
            json.put("mem_total_mb", mem.totalKb / 1024);
            json.put("mem_free_mb", mem.freeKb / 1024);
            json.put("mem_avail_mb", mem.availKb / 1024);
            json.put("swap_total_mb", mem.swapTotalKb / 1024);
            json.put("swap_used_mb", (mem.swapTotalKb - mem.swapFreeKb) / 1024);

            // 2. Memoria del Launcher AKAI Custom Home v7
            int launcherPid = findProcessPid("it.akai.customhome");
            int launcherPssMb = -1;
            if (launcherPid > 0 && activityManager != null) {
                Debug.MemoryInfo[] minfo = activityManager.getProcessMemoryInfo(new int[]{launcherPid});
                if (minfo != null && minfo.length > 0) {
                    launcherPssMb = minfo[0].getTotalPss() / 1024;
                }
            }
            json.put("launcher_pss_mb", launcherPssMb);

            // 3. Memoria del telecomando (questo processo)
            int myPid = Process.myPid();
            int remotePssMb = -1;
            if (activityManager != null) {
                Debug.MemoryInfo[] minfo = activityManager.getProcessMemoryInfo(new int[]{myPid});
                if (minfo != null && minfo.length > 0) {
                    remotePssMb = minfo[0].getTotalPss() / 1024;
                }
            }
            json.put("remote_pss_mb", remotePssMb);

            // 4. Sessioni attive telecomando (conteggio anonimo, zero token)
            RemoteServerService rss = RemoteServerService.getInstance();
            if (rss != null && rss.getSecurityManager() != null) {
                json.put("active_sessions", rss.getSecurityManager().getActiveSessionCount());
            }

            appendJsonLine(json);
            Log.d(TAG, "Campione diagnostico salvato (" + triggerReason + "): Avail=" + (mem.availKb / 1024) + "MB, SwapUsed=" + ((mem.swapTotalKb - mem.swapFreeKb) / 1024) + "MB, Launcher=" + launcherPssMb + "MB");
        } catch (Throwable t) {
            Log.e(TAG, "Errore salvataggio campione: " + t.getMessage());
        }
    }

    private synchronized void appendJsonLine(JSONObject json) {
        PrintWriter writer = null;
        try {
            checkLogRotation();

            writer = new PrintWriter(new FileWriter(logFile, true));
            writer.println(json.toString());
            writer.flush();

            // Specchio di sicurezza su /sdcard se accessibile per comodo adb pull
            try {
                PrintWriter sdWriter = new PrintWriter(new FileWriter(sdcardFile, true));
                sdWriter.println(json.toString());
                sdWriter.flush();
                sdWriter.close();
            } catch (Throwable ignored) {}

        } catch (Throwable t) {
            Log.e(TAG, "Errore scrittura su log: " + t.getMessage());
        } finally {
            if (writer != null) {
                try { writer.close(); } catch (Throwable ignored) {}
            }
        }
    }

    private void checkLogRotation() {
        try {
            if (logFile.exists() && logFile.length() > MAX_FILE_SIZE_BYTES) {
                Log.i(TAG, "Dimensione log (" + logFile.length() + " bytes) supera 1MB. Rotazione in corso...");
                if (oldLogFile.exists()) {
                    oldLogFile.delete();
                }
                logFile.renameTo(oldLogFile);

                if (sdcardFile.exists() && sdcardFile.length() > MAX_FILE_SIZE_BYTES) {
                    sdcardFile.delete();
                }
            }
        } catch (Throwable t) {
            Log.e(TAG, "Errore rotazione log: " + t.getMessage());
        }
    }

    private boolean isScreenInteractive() {
        if (powerManager != null) {
            return powerManager.isInteractive();
        }
        return true;
    }

    private String formatTimestamp(long epochMs) {
        synchronized (isoFormatter) {
            return isoFormatter.format(new Date(epochMs));
        }
    }

    private int findProcessPid(String packageName) {
        try {
            File procDir = new File("/proc");
            String[] list = procDir.list();
            if (list != null) {
                for (String name : list) {
                    if (name.length() > 0 && Character.isDigit(name.charAt(0))) {
                        File cmdFile = new File("/proc/" + name + "/cmdline");
                        if (cmdFile.exists()) {
                            BufferedReader br = null;
                            try {
                                br = new BufferedReader(new FileReader(cmdFile));
                                String cmd = br.readLine();
                                if (cmd != null && cmd.contains(packageName)) {
                                    return Integer.parseInt(name);
                                }
                            } catch (Throwable ignored) {
                            } finally {
                                if (br != null) try { br.close(); } catch (Throwable ignored) {}
                            }
                        }
                    }
                }
            }
        } catch (Throwable ignored) {}

        if (activityManager == null) return -1;
        List<ActivityManager.RunningAppProcessInfo> procs = activityManager.getRunningAppProcesses();
        if (procs == null) return -1;
        for (ActivityManager.RunningAppProcessInfo p : procs) {
            if (p.processName != null && p.processName.equals(packageName)) {
                return p.pid;
            }
        }
        return -1;
    }

    private static class MemInfo {
        long totalKb = 0;
        long freeKb = 0;
        long availKb = 0;
        long swapTotalKb = 0;
        long swapFreeKb = 0;
    }

    private MemInfo readProcMeminfo() {
        MemInfo mi = new MemInfo();
        BufferedReader reader = null;
        try {
            reader = new BufferedReader(new FileReader("/proc/meminfo"));
            String line;
            while ((line = reader.readLine()) != null) {
                if (line.startsWith("MemTotal:")) {
                    mi.totalKb = parseMemKb(line);
                } else if (line.startsWith("MemFree:")) {
                    mi.freeKb = parseMemKb(line);
                } else if (line.startsWith("MemAvailable:")) {
                    mi.availKb = parseMemKb(line);
                } else if (line.startsWith("SwapTotal:")) {
                    mi.swapTotalKb = parseMemKb(line);
                } else if (line.startsWith("SwapFree:")) {
                    mi.swapFreeKb = parseMemKb(line);
                }
            }
        } catch (Throwable ignored) {
        } finally {
            if (reader != null) {
                try { reader.close(); } catch (Throwable ignored) {}
            }
        }
        return mi;
    }

    private long parseMemKb(String line) {
        try {
            String[] parts = line.split("\\s+");
            if (parts.length >= 2) {
                return Long.parseLong(parts[1]);
            }
        } catch (Throwable ignored) {}
        return 0;
    }

    public File getLogFile() {
        return logFile;
    }

    public File getOldLogFile() {
        return oldLogFile;
    }

    public synchronized void stop() {
        if (periodicTask != null) {
            periodicTask.cancel(true);
            periodicTask = null;
        }
        recordEvent("service_stopped", "Demone diagnostico arrestato");
    }
}
