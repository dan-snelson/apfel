# apfel demos

Real-world shell scripts powered by Apple Intelligence via `apfel`.

## mac-narrator

Your Mac's inner monologue. Collects system state (processes, memory, disk, battery) and narrates what's happening in dry British humor.

```bash
# One-shot — print a single observation and exit
./mac-narrator

# Watch mode — continuous narration every 60 seconds
./mac-narrator --watch

# Custom interval
./mac-narrator --watch --interval 30
```

**Example output:**

```
[14:23:07] Ah, the eternal dance — Claude Code consuming 8.2% CPU whilst
its human presumably waits for it to finish. Meanwhile, WindowServer
soldiers on at 3.1%, dutifully rendering pixels that nobody is looking at.

[14:24:07] Safari has spawned no fewer than 12 helper processes, collectively
hoarding 2.3GB of RAM. One suspects at least 11 of those tabs haven't been
looked at since Tuesday.
```

### Requirements

- `apfel` installed and on PATH (`make install`)
- Apple Intelligence enabled in System Settings
- macOS 26+, Apple Silicon
