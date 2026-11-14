package it.akai.customremote;

import org.json.JSONArray;

public class TvController {
    public static class CommandResult extends it.akai.customremote.CommandResult {
        public CommandResult(boolean executed, String message) {
            super(executed, message);
        }

        public CommandResult(boolean executed, String message, boolean error) {
            super(executed, message, error);
        }
    }

    public CommandResult executeActionSequence(JSONArray actions) {
        return new CommandResult(true, "Stub executed");
    }
}
