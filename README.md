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
At the top of the script:
```autohotkey
global TASKBAR_GAP := 0        ; Gap between window and taskbar
global SCREEN_EDGE_MARGIN := 2 ; Gap between window and screen edges
```

## Requirements
- [AutoHotkey v2](https://www.autohotkey.com/)
- Windows 10/11

## Installation
1. Install AutoHotkey v2
2. Clone or download the repository
3. Run `WindowSnapGrid.ahk`, or add it to your startup folder