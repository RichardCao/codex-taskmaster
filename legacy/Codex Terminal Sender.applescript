set helperPath to "./codex_terminal_sender.sh"

on run
  set actionChoices to {"Start Loop", "Send Once", "Status", "Stop Loop", "Stop All Loops"}
  set actionChoice to choose from list actionChoices
  if actionChoice is false then return

  set chosenAction to item 1 of actionChoice

  if chosenAction is "Start Loop" then
    my startLoop(helperPath)
  else if chosenAction is "Send Once" then
    my sendOnce(helperPath)
  else if chosenAction is "Status" then
    my showStatus(helperPath)
  else if chosenAction is "Stop Loop" then
    my stopLoop(helperPath)
  else if chosenAction is "Stop All Loops" then
    my stopAllLoops(helperPath)
  end if
end run

on startLoop(helperPath)
  set targetValue to my promptValue("Session Name Or ID", "Enter the exact thread name or session id passed to `codex resume`.", "test")
  if targetValue is missing value then return

  set intervalValue to my promptValue("Interval Seconds", "Enter the loop interval in seconds.", "600")
  if intervalValue is missing value then return

  set messageValue to my promptValue("Message", "Enter the text to send each time.", "继续")
  if messageValue is missing value then return

  set shellCommand to quoted form of helperPath & " start -t " & quoted form of targetValue & " -i " & quoted form of intervalValue & " -m " & quoted form of messageValue
  set resultText to do shell script shellCommand
  display dialog resultText buttons {"OK"} default button "OK" with title "Loop Started"
end startLoop

on sendOnce(helperPath)
  set targetValue to my promptValue("Session Name Or ID", "Enter the exact thread name or session id passed to `codex resume`.", "test")
  if targetValue is missing value then return

  set messageValue to my promptValue("Message", "Enter the text to send once.", "继续")
  if messageValue is missing value then return

  set shellCommand to quoted form of helperPath & " send -t " & quoted form of targetValue & " -m " & quoted form of messageValue
  set resultText to do shell script shellCommand
  display dialog resultText buttons {"OK"} default button "OK" with title "Message Sent"
end sendOnce

on showStatus(helperPath)
  set targetValue to my promptValue("Session Name Or ID", "Leave blank to list all loops, or enter one target.", "")
  if targetValue is missing value then return

  if targetValue is "" then
    set shellCommand to quoted form of helperPath & " status"
  else
    set shellCommand to quoted form of helperPath & " status -t " & quoted form of targetValue
  end if

  set resultText to do shell script shellCommand
  display dialog resultText buttons {"OK"} default button "OK" with title "Loop Status"
end showStatus

on stopLoop(helperPath)
  set targetValue to my promptValue("Session Name Or ID", "Enter the loop target to stop.", "test")
  if targetValue is missing value then return

  set shellCommand to quoted form of helperPath & " stop -t " & quoted form of targetValue
  set resultText to do shell script shellCommand
  display dialog resultText buttons {"OK"} default button "OK" with title "Loop Stopped"
end stopLoop

on stopAllLoops(helperPath)
  set confirmed to button returned of (display dialog "Stop all running Codex Terminal Sender loops?" buttons {"Cancel", "Stop All"} default button "Stop All" cancel button "Cancel" with title "Stop All Loops")
  if confirmed is not "Stop All" then return

  set shellCommand to quoted form of helperPath & " stop --all"
  set resultText to do shell script shellCommand
  display dialog resultText buttons {"OK"} default button "OK" with title "All Loops Stopped"
end stopAllLoops

on promptValue(dialogTitle, promptText, defaultValue)
  try
    set responseRecord to display dialog promptText default answer defaultValue buttons {"Cancel", "OK"} default button "OK" with title dialogTitle
    return text returned of responseRecord
  on error number -128
    return missing value
  end try
end promptValue
