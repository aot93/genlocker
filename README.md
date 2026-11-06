# Genlocker

Forces an NVIDIA RTX / Quadro GPU fitted with a Quadro Sync II / RTX PRO Sync card to lock to an
external **house sync** reference on the Sync card's BNC input. It checks the current state, keeps
retrying when the lock doesn't take, and only reports success once the lock has **held continuously
for 10 seconds**. You can change that time with `-HoldSeconds`.

It uses NVAPI's GSync functions, the same driver API behind the NVIDIA Control Panel's
*Synchronize Displays* page. It's a single PowerShell script with the C# interop embedded, so it
runs on stock Windows 10/11 with no install and no compiler.

## Usage

Run from an **elevated** (Administrator) prompt. `Status` works without elevation.

```bat
genlocker.cmd                       :: lock, verify 10 s hold, exit (0 = locked, 1 = failed)
genlocker.cmd -Action Status        :: show the current state (0 = locked, 1 = not locked)
genlocker.cmd -Action Watch         :: lock, then keep watching and re-lock whenever it drops
genlocker.cmd -Action Unlock        :: remove all displays from the sync group
```

You can also call `genlocker.ps1` directly from 64-bit PowerShell. `genlocker.cmd` just runs it
with `-ExecutionPolicy Bypass`.

### What one attempt does

1. Checks a house sync signal is detected on the BNC input. If none is detected, the attempt fails
   straight away and Genlocker waits and retries.
2. Releases the current sync group. Starting from a clean slate is what usually makes a manual retry
   in the Control Panel work.
3. Sets the sync source to **house sync** on the Sync card. It keeps the signal type, polarity,
   skew and startup delay you already have unless you override them.
4. Re-forms the sync group: one server display and every other display as a client.
5. Re-applies house sync if the driver switched the source back to VSync.
6. Polls every 250 ms until every GPU in the group reports *synced*. The lock then has to stay good
   for `-HoldSeconds`. Any drop during that window counts as a failed attempt.

Failed attempts are retried with a growing back-off of 2 s, 4 s and so on, up to 10 s. Retrying
is skipped when it can't help: if an attempt fails while the house sync rate and the display
refresh rate differ, Genlocker reports a **rate mismatch** and stops with exit code 4. In Watch
mode it waits until the rates match, then carries on. The settle
time after releasing the group also grows on each attempt. If the card is already locked when
Genlocker starts, it only confirms the hold and changes nothing. Pass `-Force` to reconfigure
anyway.

### Options

| Option | Default | |
|---|---|---|
| `-HoldSeconds` | 10 | How long the lock must hold, without a break, to count as a success |
| `-LockTimeoutSeconds` | 20 | How long one attempt waits for the lock to appear |
| `-MaxAttempts` | 10 | `0` = retry forever. `Watch` always retries forever |
| `-SignalType` | `Keep` | `None`, `TTL`, `BiLevel` (black burst), `TriLevel` (HD tri-level), `Composite` |
| `-Polarity` | `Keep` | `Rising`, `Falling`, `Both` |
| `-MasterDisplayId` | auto | Server display, using the hex id shown by `-Action Status` |
| `-ExcludeDisplayId` | none | Displays to leave out of the group, such as a GUI monitor |
| `-Force` | off | Reconfigure even if the card is already locked |
| `-LossGraceSeconds` | 2 | Watch mode: how long a lost lock is tolerated before Genlocker re-locks |
| `-IgnoreRateMismatch` | off | Keep retrying even when the rates don't match |
| `-LogFile` | none | Also append the log to this file |

If you don't pass `-MasterDisplayId`, Genlocker keeps the current server display if it's on the card
receiving house sync. Otherwise it picks the first server-capable display on that card.

### Run at logon / boot

To have a media server lock itself at startup and keep the lock, run Genlocker as a scheduled task
in Watch mode. It must run as an administrator, after the displays come up:

```bat
schtasks /Create /TN Genlocker /RL HIGHEST /SC ONLOGON /DELAY 0000:30 ^
  /TR "\"C:\Tools\Genlocker\genlocker.cmd\" -Action Watch -LogFile C:\ProgramData\Genlocker.log"
```

## Things to check if it never locks

- **The rates must match.** The display timing has to match the house reference, for example 50 Hz
  output for a 50 Hz / 625i reference or 59.94 Hz for NTSC. Otherwise no amount of retrying will
  hold a lock. Genlocker prints both rates. If an attempt fails while they differ, it stops with a
  `RATE MISMATCH` error (exit code 4) instead of retrying. It only stops after a failed attempt, so
  a misread rate can't block a setup that would lock. Differences smaller than the reported
  precision are treated as a match, so 59.94 Hz reported as `60` doesn't trigger it.
- **`House sync: NOT DETECTED`.** Check the cable, the 75 Ω termination and the signal type. Try
  `-SignalType BiLevel` or `-SignalType TriLevel` explicitly.
- **Every display on a synced GPU must use identical timing.** Exclude any GUI monitor that runs a
  different mode, or the driver rejects the group with `NVAPI_INVALID_SYNC_TOPOLOGY`.
- **`NVAPI_INVALID_USER_PRIVILEGE` (-137)** means the prompt isn't elevated.

## Exit codes

`0` locked · `1` not locked / gave up · `2` no Sync device or an NVAPI error · `3` not running as Administrator · `4` stopped: house sync and display refresh rates don't match

## Notes

- 64-bit Windows only. Struct layouts and function IDs come from the public
  [NVAPI SDK](https://github.com/NVIDIA/nvapi) (MIT licensed). Genlocker falls back to older struct
  versions automatically on older drivers.
- NVAPI doesn't document the units of the refresh / house sync rate fields. Genlocker prints the raw
  values next to its Hz estimate.
