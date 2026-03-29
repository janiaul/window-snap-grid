# Window Snap Grid
An AutoHotkey v2 script that snaps windows to a 9-point grid across multiple monitors, with intelligent handling of various taskbar configurations.

## Hotkeys
| Hotkey | Action |
|--------|--------|
| `Ctrl+Shift+Win+S` | Center |
| `Ctrl+Shift+Win+W` | Top center |
| `Ctrl+Shift+Win+X` | Bottom center |
| `Ctrl+Shift+Win+A` | Left center |
| `Ctrl+Shift+Win+D` | Right center |
| `Ctrl+Shift+Win+Q` | Top-left |
| `Ctrl+Shift+Win+E` | Top-right |
| `Ctrl+Shift+Win+Z` | Bottom-left |
| `Ctrl+Shift+Win+C` | Bottom-right |

## Taskbar Compatibility
- **Standard Windows taskbar** — full multi-monitor support
- **[SmartTaskbar](https://github.com/Oliviaophia/SmartTaskbar)** — detects when taskbar is hidden and adjusts work area accordingly
- **[Windhawk](https://github.com/ramensoftware/windhawk) — taskbar-auto-hide-when-maximized** — reads the `primaryMonitorOnly` setting; secondary monitors using native auto-hide have their full screen height restored
- **[Windhawk](https://github.com/ramensoftware/windhawk) — taskbar-on-top** — reads per-monitor `taskbarLocation` and `taskbarLocationSecondary` registry settings and adjusts top/bottom boundaries per monitor accordingly

## Configuration
Edit `config.ini` (copy from `config.example.ini` if it doesn't exist):
```ini
[Settings]
# Pixels between window bottom and taskbar (0 = flush against taskbar)
TASKBAR_GAP=0

# Optional extra inset from all screen edges in pixels (0 = flush; per-app DWM frame bleed is handled automatically)
SCREEN_EDGE_MARGIN=0
```

## Requirements
- [AutoHotkey v2](https://www.autohotkey.com/)
- Windows 10/11

## Installation
1. Install AutoHotkey v2
2. Clone or download the repository
3. Copy `config.example.ini` to `config.ini` and adjust settings as needed
4. Run `WindowSnapGrid.ahk`, or add it to your startup folder