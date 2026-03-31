const app = Application.currentApplication();
app.includeStandardAdditions = true;

const helperPath = "./codex_terminal_sender.sh";

function shellQuote(value) {
  return "'" + String(value).replace(/'/g, "'\\''") + "'";
}

function runShell(command) {
  return app.doShellScript(command);
}

function promptValue(title, prompt, defaultAnswer) {
  try {
    const result = app.displayDialog(prompt, {
      withTitle: title,
      defaultAnswer,
      buttons: ["Cancel", "OK"],
      defaultButton: "OK",
      cancelButton: "Cancel",
    });
    return result.textReturned;
  } catch (error) {
    if (error.errorNumber === -128) {
      return null;
    }
    throw error;
  }
}

function showMessage(title, text) {
  app.displayDialog(text, {
    withTitle: title,
    buttons: ["OK"],
    defaultButton: "OK",
  });
}

function showShellError(error) {
  const details = error.message || String(error);
  showMessage("Codex Terminal Sender Error", details);
}

function startLoop() {
  const target = promptValue(
    "Session Name Or ID",
    "Enter the exact thread name or session id passed to `codex resume`.",
    "game",
  );
  if (target === null) return;

  const interval = promptValue(
    "Interval Seconds",
    "Enter the loop interval in seconds.",
    "600",
  );
  if (interval === null) return;

  const message = promptValue(
    "Message",
    "Enter the text to send each time.",
    "继续",
  );
  if (message === null) return;

  const command =
    `${shellQuote(helperPath)} start -t ${shellQuote(target)} ` +
    `-i ${shellQuote(interval)} -m ${shellQuote(message)}`;
  showMessage("Loop Started", runShell(command));
}

function sendOnce() {
  const target = promptValue(
    "Session Name Or ID",
    "Enter the exact thread name or session id passed to `codex resume`.",
    "game",
  );
  if (target === null) return;

  const message = promptValue(
    "Message",
    "Enter the text to send once.",
    "继续",
  );
  if (message === null) return;

  const command =
    `${shellQuote(helperPath)} send -t ${shellQuote(target)} -m ${shellQuote(message)}`;
  showMessage("Message Sent", runShell(command));
}

function showStatus() {
  const target = promptValue(
    "Session Name Or ID",
    "Leave blank to list all loops, or enter one target.",
    "",
  );
  if (target === null) return;

  const command =
    target === ""
      ? `${shellQuote(helperPath)} status`
      : `${shellQuote(helperPath)} status -t ${shellQuote(target)}`;
  showMessage("Loop Status", runShell(command));
}

function stopLoop() {
  const target = promptValue(
    "Session Name Or ID",
    "Enter the loop target to stop.",
    "game",
  );
  if (target === null) return;

  const command =
    `${shellQuote(helperPath)} stop -t ${shellQuote(target)}`;
  showMessage("Loop Stopped", runShell(command));
}

function stopAllLoops() {
  try {
    app.displayDialog("Stop all running Codex Terminal Sender loops?", {
      withTitle: "Stop All Loops",
      buttons: ["Cancel", "Stop All"],
      defaultButton: "Stop All",
      cancelButton: "Cancel",
    });
  } catch (error) {
    if (error.errorNumber === -128) return;
    throw error;
  }

  const command = `${shellQuote(helperPath)} stop --all`;
  showMessage("All Loops Stopped", runShell(command));
}

function run(argv) {
  try {
    const action = app.chooseFromList(
      ["Start Loop", "Send Once", "Status", "Stop Loop", "Stop All Loops"],
      {
        withPrompt: "Choose an action",
        defaultItems: ["Start Loop"],
      },
    );

    if (!action) return;

    switch (action[0]) {
      case "Start Loop":
        startLoop();
        break;
      case "Send Once":
        sendOnce();
        break;
      case "Status":
        showStatus();
        break;
      case "Stop Loop":
        stopLoop();
        break;
      case "Stop All Loops":
        stopAllLoops();
        break;
      default:
        showMessage("Codex Terminal Sender", `Unknown action: ${action[0]}`);
    }
  } catch (error) {
    showShellError(error);
  }
}
