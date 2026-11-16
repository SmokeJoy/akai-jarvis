package it.akai.customremote;

public class CommandResult {
    public final boolean success;
    public final String message;
    public final boolean unsupported;

    public CommandResult(boolean success, String message) {
        this(success, message, false);
    }

    public CommandResult(boolean success, String message, boolean unsupported) {
        this.success = success;
        this.message = message;
        this.unsupported = unsupported;
    }

    public boolean isSuccess() {
        return success;
    }

    public String getMessage() {
        return message;
    }

    public boolean isUnsupported() {
        return unsupported;
    }
}
