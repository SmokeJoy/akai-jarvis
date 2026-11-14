package it.akai.customremote;

/**
 * Interfaccia per la notifica reattiva di avvenuto bind e avvio dei listener HTTP/HTTPS.
 * Utilizzata da MainActivity per eliminare race condition al cold-start.
 */
public interface ServiceStateListener {
    void onServerReady(String localIpAddress, int httpPort, int httpsPort);
    default void onServerDegraded(String reason) {}
}
