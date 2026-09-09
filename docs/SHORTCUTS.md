# Apple Shortcuts

Choragus publishes its playback actions through the App Intents framework, so they appear in the Shortcuts app, in Spotlight and in Siri. Choragus has to be running with its window open; an action that fires while it is closed returns without reaching the speakers.

Every action takes a **Room** (a Sonos room or group, by its sidebar name). Rooms, presets and inputs are read from the live Sonos system when the shortcut is built and resolved again on every run, so a renamed room keeps working and a removed one reports a clear error.

## Actions

| Action | Parameters | Effect |
|--------|------------|--------|
| **Play** | Room | Resume playback |
| **Pause** | Room | Pause playback |
| **Toggle Play/Pause** | Room | Pause if playing, play if paused |
| **Next Track** | Room | Skip forward in the queue |
| **Previous Track** | Room | Skip back in the queue |
| **Set Volume** | Room, Level 0–100 | Set every speaker in the room to the level |
| **Activate Preset** | Preset | Apply a saved group preset: grouping, volumes and EQ |
| **Select Input** | Input, Room | Play a speaker's line-in or TV input in the room |

**Select Input** lists every speaker with a physical input: analog line-in on Play:5, Five, Connect, Connect:Amp, Amp and Move; HDMI/optical on Arc, Beam, Playbar, Playbase and Ray. The input and the room can differ, so a Play:5's line-in can play in another room or group. Selecting an input that is already playing leaves it playing, which makes the action safe to run repeatedly.

## Siri phrases

- "Play / Resume Choragus in *Room*"
- "Pause / Stop Choragus in *Room*"
- "Toggle Choragus in *Room*"
- "Next track / Skip on Choragus in *Room*"
- "Previous track / Back on Choragus in *Room*"
- "Set / Change Choragus volume in *Room*" (Siri asks for the level)
- "Activate / Apply Choragus preset *Preset*"
- "Play / Select Choragus input *Input*" (Siri asks for the room)

App Intents allows one spoken placeholder per phrase, so a second parameter is always collected as a follow-up question.

## Running an action on a schedule

Two routes, depending on the interval.

**Shortcuts automations (macOS 26 and later).** In the Shortcuts app open the Automation tab, add a Time of Day automation, choose the shortcut and set it to run immediately. Triggers repeat daily, weekly or monthly; an hourly cadence needs one automation per hour.

**launchd (any macOS version).** Save the shortcut under a name, then create `~/Library/LaunchAgents/com.example.choragus-linein.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.example.choragus-linein</string>
    <key>ProgramArguments</key>
    <array>
        <string>/usr/bin/shortcuts</string>
        <string>run</string>
        <string>Kitchen Line-In</string>
    </array>
    <key>StartInterval</key><integer>3600</integer>
</dict>
</plist>
```

Load it once:

```bash
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.example.choragus-linein.plist
```

`StartInterval` is seconds between runs. For clock-aligned runs replace it with `StartCalendarInterval` and `Hour` / `Minute` keys. `launchctl bootout gui/$(id -u)/com.example.choragus-linein` removes it.

`cron` also works (`0 * * * * /usr/bin/shortcuts run "Kitchen Line-In"`), but on recent macOS versions cron needs Full Disk Access under Privacy & Security before it can run shortcuts; launchd does not.

## Example: keep a line-in selected

A speaker with line-in Autoplay enabled drops the input after a stretch of silence and re-detects it when audio returns, clipping the start. The Sonos-side fix is to turn Autoplay off for that speaker in the Sonos app and select Line-In manually. To guard against the speaker forgetting the selection, a shortcut with a single **Select Input** action (the speaker's line-in, played in its own room) run hourly by the launchd agent above re-selects it.

## Troubleshooting

- **Action fails with "no longer in your Sonos system"**: the room, preset or input was renamed or removed after the shortcut was built. Open the shortcut and pick it again.
- **Nothing happens and no error**: Choragus was not running. Add an Open App action for Choragus before the Choragus action, with a short Wait after it.
- **Actions missing from the Shortcuts app**: launch Choragus once after installing; macOS registers App Intents on first launch.
