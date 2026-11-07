package it.akai.customremote;

import android.app.Activity;
import android.content.Context;
import android.content.Intent;
import android.os.Build;
import android.os.Bundle;
import android.util.Log;
import android.view.View;
import android.widget.Button;
import android.widget.TextView;
import android.widget.Toast;

import java.net.InetAddress;
import java.net.NetworkInterface;
import java.util.Collections;
import java.util.List;

public class MainActivity extends Activity {
    private static final String TAG = "AKAI_MainActivity";

    private TextView tvServiceStatus;
    private TextView tvServerUrl;
    private TextView tvUinputStatus;
    private TextView tvPairedCount;

    private Button btnShowPin;
    private Button btnRevokeAll;
    private Button btnMinimize;

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        setContentView(R.layout.activity_main);
        Log.i(TAG, "MainActivity started. Launching RemoteServerService daemon.");

        tvServiceStatus = findViewById(R.id.tv_service_status);
        tvServerUrl = findViewById(R.id.tv_server_url);
        tvUinputStatus = findViewById(R.id.tv_uinput_status);
        tvPairedCount = findViewById(R.id.tv_paired_count);

        btnShowPin = findViewById(R.id.btn_show_pin);
        btnRevokeAll = findViewById(R.id.btn_revoke_all);
        btnMinimize = findViewById(R.id.btn_minimize);

        // Avvio del servizio autonomo in foreground
        Intent serviceIntent = new Intent(this, RemoteServerService.class);
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            startForegroundService(serviceIntent);
        } else {
            startService(serviceIntent);
        }

        updateUI();

        btnShowPin.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                RemoteServerService s = RemoteServerService.getInstance();
                if (s != null && s.getSecurityManager() != null) {
                    String pin = s.getSecurityManager().generateNewPin();
                    int remaining = s.getSecurityManager().getPinRemainingSeconds();
                    String url = "http://" + getLocalIpAddress() + ":" + RemoteServerService.HTTP_PORT;
                    PinOverlayDialog.show(MainActivity.this, pin, remaining, url);
                    Toast.makeText(MainActivity.this, "Codice PIN generato: " + pin, Toast.LENGTH_SHORT).show();
                } else {
                    Toast.makeText(MainActivity.this, "Avvio del server in corso...", Toast.LENGTH_SHORT).show();
                }
            }
        });

        btnRevokeAll.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                RemoteServerService s = RemoteServerService.getInstance();
                if (s != null && s.getSecurityManager() != null) {
                    s.getSecurityManager().revokeAll();
                    updateUI();
                    Toast.makeText(MainActivity.this, "Tutte le sessioni smartphone sono state revocate", Toast.LENGTH_SHORT).show();
                }
            }
        });

        btnMinimize.setOnClickListener(new View.OnClickListener() {
            @Override
            public void onClick(View v) {
                // Riduci a icona tornando a LTvLauncher senza arrestare il server
                finish();
            }
        });
    }

    @Override
    protected void onResume() {
        super.onResume();
        updateUI();
    }

    private void updateUI() {
        RemoteServerService s = RemoteServerService.getInstance();
        boolean running = (s != null);

        tvServiceStatus.setText(running ? "Stato Server: IN ASCOLTO (Porta " + RemoteServerService.HTTP_PORT + ")" : "Stato Server: In avvio...");
        tvServiceStatus.setTextColor(running ? 0xFF10B981 : 0xFFF59E0B);

        String ip = getLocalIpAddress();
        if (ip == null || ip.isEmpty()) {
            ip = "192.168.1.8";
        }
        tvServerUrl.setText("Apri su Safari / Chrome: http://" + ip + ":" + RemoteServerService.HTTP_PORT);

        boolean uinputOk = (s != null && s.getTvController() != null && s.getTvController().isUInputReady());
        tvUinputStatus.setText("Driver Hardware Linux: " + (uinputOk ? "/dev/uinput ATTIVO (fd pronto)" : "Inizializzazione in corso..."));
        tvUinputStatus.setTextColor(uinputOk ? 0xFF34D399 : 0xFFF59E0B);

        int activeSessions = (s != null && s.getSecurityManager() != null) ? s.getSecurityManager().getActiveSessionCount() : 0;
        tvPairedCount.setText("Dispositivi associati attivi: " + activeSessions);
    }

    private String getLocalIpAddress() {
        try {
            List<NetworkInterface> interfaces = Collections.list(NetworkInterface.getNetworkInterfaces());
            for (NetworkInterface intf : interfaces) {
                List<InetAddress> addrs = Collections.list(intf.getInetAddresses());
                for (InetAddress addr : addrs) {
                    if (!addr.isLoopbackAddress()) {
                        String sAddr = addr.getHostAddress();
                        if (sAddr != null && sAddr.indexOf(':') < 0 && (sAddr.startsWith("192.168.") || sAddr.startsWith("10."))) {
                            return sAddr;
                        }
                    }
                }
            }
        } catch (Exception ignored) {}
        return "192.168.1.8";
    }
}
