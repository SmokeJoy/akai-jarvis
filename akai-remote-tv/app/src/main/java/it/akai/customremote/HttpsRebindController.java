package it.akai.customremote;

import java.io.IOException;
import java.net.InetSocketAddress;
import java.net.ServerSocket;
import java.net.Socket;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import javax.net.ssl.SSLContext;
import javax.net.ssl.SSLServerSocketFactory;

/**
 * Controller per la gestione atomica, thread-safe e fail-closed del ciclo di vita del listener HTTPS (porta 8443).
 * Gestisce:
 * 1. Chiusura preventiva del vecchio socket prima del nuovo bind (vincolo TCP SO_REUSEADDR)
 * 2. Loop di retry con backoff per permettere al kernel di rilasciare l'endpoint
 * 3. Coda latest-IP thread-safe (pendingTargetIp) per coalescing di cambi IP concorrenti senza perdite
 * 4. Stato fail-closed coerente (isReady=false) e invarianza di currentServerIp su errore per consentire retry con lo stesso IP
 * 5. Notifica reattiva di successo (onServerReady) e degrado (onServerDegraded)
 */
public class HttpsRebindController {
    private int port;
    private volatile ServerSocket activeSocket = null;
    private volatile String currentServerIp = null;
    private String pendingTargetIp = null;
    private final Object ipSyncLock = new Object();
    private boolean isWorkerRunning = false;
    private final ExecutorService workerExecutor;
    private final boolean ownsExecutor;
    private final boolean allowPlaintextForTesting;
    volatile Runnable testHookBeforeIdle = null;

    public interface SslContextProvider {
        SSLContext getSslContext(String ip) throws Exception;
    }

    public interface ListenerCallback {
        void onServerReady(String ip, int port);
        void onServerDegraded(String reason);
        void onClientConnected(Socket client);
    }

    private final SslContextProvider sslProvider;
    private final ListenerCallback callback;
    private volatile Thread currentAcceptorThread = null;
    private final java.util.concurrent.atomic.AtomicLong generationCounter = new java.util.concurrent.atomic.AtomicLong(0);
    private volatile boolean isRunning = true;

    // Costruttore di produzione: impone rigidamente TLS (ZERO bind in chiaro sulla porta HTTPS)
    public HttpsRebindController(int port, SslContextProvider sslProvider, ListenerCallback callback) {
        this(port, sslProvider, callback, Executors.newSingleThreadExecutor(), true, false);
    }

    public HttpsRebindController(int port, SslContextProvider sslProvider, ListenerCallback callback, ExecutorService executor, boolean ownsExecutor) {
        this(port, sslProvider, callback, executor, ownsExecutor, false);
    }

    // Costruttore per test host con flag esplicito per simulazioni mock di collisione porta TCP
    public HttpsRebindController(int port, SslContextProvider sslProvider, ListenerCallback callback, ExecutorService executor, boolean ownsExecutor, boolean allowPlaintextForTesting) {
        this.port = port;
        this.sslProvider = sslProvider;
        this.callback = callback;
        this.workerExecutor = executor;
        this.ownsExecutor = ownsExecutor;
        this.allowPlaintextForTesting = allowPlaintextForTesting;
    }

    public int getPort() {
        return port;
    }

    public void setPort(int port) {
        this.port = port;
    }

    public String getCurrentServerIp() {
        synchronized (ipSyncLock) {
            return currentServerIp;
        }
    }

    public boolean isReady() {
        ServerSocket s = activeSocket;
        return isRunning && s != null && !s.isClosed() && s.isBound();
    }

    public ServerSocket getActiveSocket() {
        return activeSocket;
    }

    public synchronized boolean reloadListener() {
        if (!isRunning) return false;
        String ip = getCurrentServerIp();
        if (ip == null) ip = "127.0.0.1";
        return reloadListenerForIp(ip);
    }

    private synchronized void stopActiveListener(String reason) {
        final ServerSocket oldSock = activeSocket;
        activeSocket = null;
        final Thread oldThread = currentAcceptorThread;
        currentAcceptorThread = null;

        if (oldSock != null && !oldSock.isClosed()) {
            try {
                oldSock.close();
            } catch (Exception ignored) {}
        }
        if (oldThread != null && oldThread.isAlive()) {
            try {
                oldThread.interrupt();
            } catch (Exception ignored) {}
        }
        if (reason != null && callback != null) {
            callback.onServerDegraded(reason);
        }
    }

    public synchronized boolean reloadListenerForIp(String ip) {
        if (!isRunning) return false;
        try {
            SSLContext sslContext = (sslProvider != null) ? sslProvider.getSslContext(ip) : null;
            if (sslContext == null && !allowPlaintextForTesting) {
                // FAIL-CLOSED: Chiude immediatamente il vecchio socket e rifiuta bind plaintext
                stopActiveListener("SSLContext non disponibile per IP " + ip + ". Rifiuto bind plaintext.");
                return false;
            }
            SSLServerSocketFactory factory = (sslContext != null) ? sslContext.getServerSocketFactory() : null;
            if (factory == null && !allowPlaintextForTesting) {
                // FAIL-CLOSED: Chiude immediatamente il vecchio socket
                stopActiveListener("SSLServerSocketFactory non disponibile. Rifiuto bind plaintext.");
                return false;
            }

            // 1. Chiusura preventiva del socket precedente e stop del vecchio acceptor per liberare l'endpoint TCP
            final ServerSocket oldSocket = activeSocket;
            final Thread oldThread = currentAcceptorThread;
            activeSocket = null;
            currentAcceptorThread = null;

            if (oldSocket != null && !oldSocket.isClosed()) {
                try {
                    oldSocket.close();
                } catch (Exception ignored) {}
            }
            if (oldThread != null && oldThread.isAlive()) {
                try {
                    oldThread.interrupt();
                } catch (Exception ignored) {}
            }

            // 2. Creazione e bind del nuovo socket con retries e backoff
            ServerSocket newServer = null;
            int retries = 5;
            IOException lastBindEx = null;
            while (retries > 0) {
                try {
                    if (factory != null) {
                        newServer = factory.createServerSocket();
                    } else if (allowPlaintextForTesting) {
                        newServer = new ServerSocket();
                    } else {
                        throw new IOException("Nessuna SSLServerSocketFactory valida configurata per porta HTTPS " + port);
                    }
                    newServer.setReuseAddress(true);
                    newServer.bind(new InetSocketAddress(port));
                    lastBindEx = null;
                    break;
                } catch (IOException e) {
                    lastBindEx = e;
                    retries--;
                    if (newServer != null) {
                        try { newServer.close(); } catch (Exception ignored) {}
                        newServer = null;
                    }
                    if (retries > 0) {
                        try { Thread.sleep(60); } catch (InterruptedException ignored) {}
                    }
                }
            }

            if (newServer == null || !newServer.isBound()) {
                stopActiveListener((lastBindEx != null) ? lastBindEx.getMessage() : "Impossibile effettuare il bind su porta " + port);
                return false;
            }

            // 3. Associazione del nuovo socket e avvio del thread acceptor dedicato alla specifica istanza (P0 Reliability fix)
            final long generation = generationCounter.incrementAndGet();
            final ServerSocket boundSocket = newServer;
            activeSocket = boundSocket;

            Thread newAcceptor = new Thread(new Runnable() {
                @Override
                public void run() {
                    while (isRunning && !boundSocket.isClosed() && boundSocket.isBound()) {
                        try {
                            final Socket client = boundSocket.accept();
                            if (callback != null) {
                                callback.onClientConnected(client);
                            }
                        } catch (IOException e) {
                            if (!isRunning || boundSocket.isClosed()) {
                                break;
                            }
                            try { Thread.sleep(100); } catch (InterruptedException ignored) { break; }
                        }
                    }
                }
            }, "AkaiHttpsAcceptor-Gen" + generation);

            currentAcceptorThread = newAcceptor;
            newAcceptor.start();
            return true;
        } catch (Exception e) {
            stopActiveListener("Eccezione durante reloadListenerForIp: " + e.getMessage());
            return false;
        }
    }

    public void notifyIpAddressChanged(final String newIp) {
        if (newIp == null || newIp.trim().isEmpty() || "127.0.0.1".equals(newIp.trim())) {
            return;
        }
        final String targetIp = newIp.trim();
        synchronized (ipSyncLock) {
            // Se già pronto e sincronizzato sull'IP target e non ci sono cambi pendenti, no-op
            if (targetIp.equals(currentServerIp) && pendingTargetIp == null && isReady()) {
                return;
            }
            pendingTargetIp = targetIp;
            if (isWorkerRunning) {
                return; // Il worker attualmente attivo raccoglierà pendingTargetIp nel suo loop
            }
            isWorkerRunning = true;
        }

        workerExecutor.execute(new Runnable() {
            @Override
            public void run() {
                processIpQueue();
            }
        });
    }

    private void processIpQueue() {
        while (true) {
            String targetIp;
            if (testHookBeforeIdle != null) {
                try { testHookBeforeIdle.run(); } catch (Exception ignored) {}
            }
            synchronized (ipSyncLock) {
                targetIp = pendingTargetIp;
                if (targetIp == null) {
                    // ATOMICO: azzeramento e transizione a idle avvengono nello stesso blocco sincronizzato
                    // eliminando la finestra di lost wakeup tra controllo targetIp==null e isWorkerRunning=false
                    isWorkerRunning = false;
                    break;
                }
                pendingTargetIp = null;
            }

            boolean alreadySynced = false;
            synchronized (ipSyncLock) {
                if (targetIp.equals(currentServerIp) && isReady()) {
                    alreadySynced = true;
                }
            }
            if (alreadySynced) {
                continue;
            }

            boolean reloaded = reloadListenerForIp(targetIp);
            if (reloaded) {
                synchronized (ipSyncLock) {
                    currentServerIp = targetIp;
                }
                if (callback != null) {
                    callback.onServerReady(targetIp, port);
                }
            } else {
                // Fail-closed: currentServerIp NON viene aggiornato per consentire retry con lo stesso IP
                if (callback != null) {
                    callback.onServerDegraded("Bind HTTPS non riuscito su porta " + port + " per IP " + targetIp);
                }
            }
        }
    }

    public synchronized void close() {
        isRunning = false;
        stopActiveListener(null);
        if (ownsExecutor && workerExecutor != null) {
            try { workerExecutor.shutdownNow(); } catch (Exception ignored) {}
        }
    }
}
