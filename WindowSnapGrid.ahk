#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Force

_cfg := A_ScriptDir "\config.ini"
global TASKBAR_GAP := Integer(IniRead(_cfg, "Settings", "TASKBAR_GAP", "0"))
global SCREEN_EDGE_MARGIN := Integer(IniRead(_cfg, "Settings", "SCREEN_EDGE_MARGIN", "0"))

; Cache for expensive calls (file reads, window enumeration, registry reads)
; Values are reused within _CACHE_TTL milliseconds to avoid redundant work
global _cache := Map()
global _CACHE_TTL := 500
global _HK_DEDUP_TTL := 150  ; shorter TTL for hotkey dedup to avoid suppressing intentional rapid use

_CacheGet(key, &value) {
    if (_cache.Has(key)) {
        entry := _cache[key]
        if (A_TickCount - entry.tick < _CACHE_TTL) {
            value := entry.value
            return true
        }
    }
    return false
}

_CacheSet(key, value) {
    _cache[key] := { value: value, tick: A_TickCount }
    if (_cache.Count > 40)
        _CachePrune()
    return value
}

; Remove all cache entries that have exceeded the TTL
_CachePrune() {
    now := A_TickCount
    toDelete := []
    for key, entry in _cache
        if (now - entry.tick >= _CACHE_TTL)
            toDelete.Push(key)
    for key in toDelete
        _cache.Delete(key)
}

; Returns true if this hotkey+window combination was already triggered within _HK_DEDUP_TTL
; Bypasses _CacheGet/_CacheSet to use _HK_DEDUP_TTL instead of _CACHE_TTL
_IsHotkeyDuplicate(HotkeyName) {
    cacheKey := "HK_" . HotkeyName . "_" . WinExist("A")
    if (_cache.Has(cacheKey) && A_TickCount - _cache[cacheKey].tick < _HK_DEDUP_TTL)
        return true
    _cache[cacheKey] := { value: true, tick: A_TickCount }
    return false
}

; Determine which monitor a window is on, falling back to coordinate-based detection
GetActiveMonitor(X, Y, W := 0, H := 0, WinTitle := "A") {
    if (hWnd := WinExist(WinTitle)) {
        MONITOR_DEFAULTTOPRIMARY := 0x1
        hMonitor := DllCall("MonitorFromWindow", "Ptr", hWnd, "UInt", MONITOR_DEFAULTTOPRIMARY, "Ptr")

        ; Read rcWork from MONITORINFO and match against AHK's MonitorGetWorkArea to get the AHK index.
        ; This avoids allocating a buffer and calling MonitorFromRect per loop iteration.
        ; MONITORINFO layout: cbSize(4) + rcMonitor(16) + rcWork(16) + dwFlags(4) = 40 bytes
        ; rcWork starts at offset 20: left(20), top(24), right(28), bottom(32)
        MONITORINFO := Buffer(40)
        NumPut("UInt", 40, MONITORINFO, 0)  ; cbSize
        if (DllCall("GetMonitorInfo", "Ptr", hMonitor, "Ptr", MONITORINFO)) {
            mLeft := NumGet(MONITORINFO, 20, "Int")
            mTop := NumGet(MONITORINFO, 24, "Int")
            mRight := NumGet(MONITORINFO, 28, "Int")
            mBot := NumGet(MONITORINFO, 32, "Int")

            loop MonitorGetCount() {
                MonitorGetWorkArea(A_Index, &Left, &Top, &Right, &Bottom)
                if (Left = mLeft && Top = mTop && Right = mRight && Bottom = mBot)
                    return A_Index
            }
        }
    }

    ; Fall back to coordinate-based detection
    PrimaryMonitor := MonitorGetPrimary()
    MonitorCount := MonitorGetCount()

    ; First check primary monitor
    MonitorGetWorkArea(PrimaryMonitor, &Left, &Top, &Right, &Bottom)
    if (X >= Left && X < Right && Y >= Top && Y < Bottom)
        return PrimaryMonitor

    ; Then check other monitors
    loop MonitorCount {
        if (A_Index = PrimaryMonitor)
            continue
        MonitorGetWorkArea(A_Index, &Left, &Top, &Right, &Bottom)
        if (X >= Left && X < Right && Y >= Top && Y < Bottom)
            return A_Index
    }
    return PrimaryMonitor
}

; Get window frame thickness (for better positioning accuracy)
; Accepts an hwnd directly; result is cached by hwnd since frame sizes are stable
GetWindowFrameSize(hWnd) {
    if (!hWnd)
        return { Left: 0, Top: 0, Right: 0, Bottom: 0 }

    cacheKey := "FS_" . hWnd
    if (_CacheGet(cacheKey, &cached))
        return cached

    try {
        ; Get window rect (including frame)
        WindowRECT := Buffer(16)
        DllCall("GetWindowRect", "Ptr", hWnd, "Ptr", WindowRECT)
        WinLeft := NumGet(WindowRECT, 0, "Int")
        WinTop := NumGet(WindowRECT, 4, "Int")
        WinRight := NumGet(WindowRECT, 8, "Int")
        WinBottom := NumGet(WindowRECT, 12, "Int")

        ; Get client rect (actual usable area)
        ClientRECT := Buffer(16)
        DllCall("GetClientRect", "Ptr", hWnd, "Ptr", ClientRECT)
        ClientWidth := NumGet(ClientRECT, 8, "Int")
        ClientHeight := NumGet(ClientRECT, 12, "Int")

        ; Get client area position in screen coordinates
        ClientPOINT := Buffer(8)
        NumPut("Int", 0, ClientPOINT, 0)
        NumPut("Int", 0, ClientPOINT, 4)
        DllCall("ClientToScreen", "Ptr", hWnd, "Ptr", ClientPOINT)
        ClientLeft := NumGet(ClientPOINT, 0, "Int")
        ClientTop := NumGet(ClientPOINT, 4, "Int")

        return _CacheSet(cacheKey, {
            Left: ClientLeft - WinLeft,
            Top: ClientTop - WinTop,
            Right: WinRight - (ClientLeft + ClientWidth),
            Bottom: WinBottom - (ClientTop + ClientHeight)
        })
    } catch {
        return _CacheSet(cacheKey, { Left: 0, Top: 0, Right: 0, Bottom: 0 })
    }
}

; Enhanced window moving function that accounts for window frames
MoveWindowSafelyEnhanced(X, Y, W := "", H := "", WinTitle := "A", ForceToBottom := false) {
    if (!(hWnd := WinExist(WinTitle)))
        return
    try {
        ; Restore before querying size so CurH reflects the actual post-restore height,
        ; not the maximized screen height which would make ForceToBottom Y wrong
        if (WinGetMinMax(WinTitle) = 1)
            WinRestore(WinTitle)
        ; hWnd is obtained once above and reused throughout to avoid redundant WinExist calls
        FrameSize := GetWindowFrameSize(hWnd)
        ; If ForceToBottom is true, adjust the Y position to account for potential app-specific margins
        if (ForceToBottom) {
            ; Get current window info (post-restore so CurH is the restored height)
            WinGetPos(&CurX, &CurY, &CurW, &CurH, WinTitle)
            ActiveMonitor := GetActiveMonitor(CurX, CurY, CurW, CurH, WinTitle)
            WorkArea := GetAdjustedWorkArea(ActiveMonitor)
            ; When taskbar is on top, snap to the true screen bottom with no gap
            AbsoluteBottom := IsTaskbarOnTop(ActiveMonitor) ? WorkArea[4] : WorkArea[4] - TASKBAR_GAP
            ; Same 1px nudge as X: keep the DWM border pixel within this monitor for apps with a
            ; non-client bottom frame. Discord/MusicBee (FrameSize.Bottom = 0) are unaffected.
            if (FrameSize.Bottom > 0 && SCREEN_EDGE_MARGIN = 0)
                AbsoluteBottom -= 1
            Y := AbsoluteBottom - CurH + FrameSize.Bottom
        }
        ; Use SWP_NOSENDCHANGING (0x0400) to suppress WM_WINDOWPOSCHANGING so apps with extended DWM
        ; frames cannot intercept and "correct" the position when the invisible border extends
        ; slightly past a monitor edge. Without this, those apps snap to the primary monitor
        ; on multi-monitor setups where an adjacent monitor borders the snap edge.
        if (W = "" && H = "") {
            DllCall("SetWindowPos", "Ptr", hWnd, "Ptr", 0, "Int", X, "Int", Y, "Int", 0, "Int", 0,
                "UInt", 0x0001 | 0x0004 | 0x0010 | 0x0400)  ; NOSIZE | NOZORDER | NOACTIVATE | NOSENDCHANGING
        } else {
            WinMove(X, Y, W, H, WinTitle)
        }
    } catch as err {
        Critical(false)
        if (InStr(err.Message, "Access is denied"))
            _ShowError("Cannot move window: run the script as administrator.")
        else
            _ShowError("Window move error: " . err.Message)
    }
}

; Safely move a window, handling potential errors
MoveWindowSafely(X, Y, W := "", H := "", WinTitle := "A") {
    MoveWindowSafelyEnhanced(X, Y, W, H, WinTitle, false)
}

; Get the height of the taskbar for the given monitor
GetTaskbarHeight(MonitorIndex := 0) {
    ; If no monitor specified, use primary
    if (MonitorIndex = 0)
        MonitorIndex := MonitorGetPrimary()

    cacheKey := "TBH_" . MonitorIndex
    if (_CacheGet(cacheKey, &cached))
        return cached

    if (MonitorIndex = MonitorGetPrimary()) {
        ; Primary taskbar uses Shell_TrayWnd
        if (taskbar := WinExist("ahk_class Shell_TrayWnd")) {
            WinGetPos(, , , &Height, taskbar)
            return _CacheSet(cacheKey, Height)
        }
    } else {
        ; Secondary monitor taskbars use Shell_SecondaryTrayWnd; there may be multiple,
        ; so find the one whose position falls within this monitor's physical bounds
        MonitorGet(MonitorIndex, &MLeft, &MTop, &MRight, &MBottom)
        windows := WinGetList("ahk_class Shell_SecondaryTrayWnd")
        for hwnd in windows {
            WinGetPos(&tbX, &tbY, , &tbH, "ahk_id " . hwnd)
            if (tbX >= MLeft && tbX < MRight && tbY >= MTop && tbY < MBottom)
                return _CacheSet(cacheKey, tbH)
        }
    }

    ; Fallback: estimate from this monitor's DPI (base 48px at 100% / 96 DPI).
    ; Use GetDpiForMonitor rather than GetDC(NULL) which returns primary-monitor DPI only.
    MonitorGet(MonitorIndex, &MLeft, &MTop, &MRight, &MBottom)
    rcBuf := Buffer(16)
    NumPut("Int", MLeft, rcBuf, 0)
    NumPut("Int", MTop, rcBuf, 4)
    NumPut("Int", MLeft + 1, rcBuf, 8)
    NumPut("Int", MTop + 1, rcBuf, 12)
    hMonitor := DllCall("MonitorFromRect", "Ptr", rcBuf, "UInt", 0x1, "Ptr")
    dpiX := 96, dpiY := 96
    DllCall("Shcore\GetDpiForMonitor", "Ptr", hMonitor, "UInt", 0, "UInt*", &dpiX, "UInt*", &dpiY)
    return _CacheSet(cacheKey, Round(48 * dpiX / 96))
}

; Check if SmartTaskbar is running
IsSmartTaskbarRunning() {
    cacheKey := "STB_running"
    if (_CacheGet(cacheKey, &cached))
        return cached
    return _CacheSet(cacheKey, ProcessExist("SmartTaskbar.exe") != 0)
}

; Check if a specific Windhawk mod is installed and enabled
; Result is cached to avoid repeated file reads within the cache TTL
IsWindhawkModEnabled(ModName) {
    cacheKey := "WH_enabled_" . ModName
    if (_CacheGet(cacheKey, &cached))
        return cached

    if (!_IsWindhawkRunning())
        return _CacheSet(cacheKey, false)

    try {
        jsonPath := "C:\ProgramData\Windhawk\userprofile.json"
        if (!FileExist(jsonPath))
            return _CacheSet(cacheKey, false)

        jsonContent := FileRead(jsonPath)

        modKey := '"' . ModName . '": {'
        modPos := InStr(jsonContent, modKey)
        if (!modPos)
            return _CacheSet(cacheKey, false)

        startPos := modPos + StrLen(modKey)
        braceCount := 1
        pos := startPos
        endPos := 0
        jsonLen := StrLen(jsonContent)

        while (pos <= jsonLen && braceCount > 0) {
            char := SubStr(jsonContent, pos, 1)
            if (char = '"') {
                ; Skip string literal, respecting escape sequences, so that { or } inside
                ; a JSON string value does not corrupt the brace count
                pos++
                while (pos <= jsonLen) {
                    c := SubStr(jsonContent, pos, 1)
                    if (c = '\')
                        pos++  ; skip the escaped character
                    else if (c = '"')
                        break
                    pos++
                }
            } else if (char = '{') {
                braceCount++
            } else if (char = '}') {
                braceCount--
                if (braceCount = 0)
                    endPos := pos
            }
            pos++
        }

        if (!endPos)
            return _CacheSet(cacheKey, false)

        modSection := SubStr(jsonContent, startPos, endPos - startPos)
        result := !RegExMatch(modSection, '"disabled"\s*:\s*true')
        return _CacheSet(cacheKey, result)

    } catch {
        return _CacheSet(cacheKey, false)
    }
}

; Check if the Windhawk process is running (cached)
_IsWindhawkRunning() {
    cacheKey := "WH_running"
    if (_CacheGet(cacheKey, &cached))
        return cached
    return _CacheSet(cacheKey, ProcessExist("windhawk.exe") != 0)
}

; Check if a secondary monitor's taskbar is using native Windows auto-hide due to
; the taskbar-auto-hide-when-maximized mod's primaryMonitorOnly setting
IsNativeAutoHideOnSecondary(MonitorIndex) {
    if (MonitorIndex = MonitorGetPrimary())
        return false
    if (!IsWindhawkModEnabled("taskbar-auto-hide-when-maximized"))
        return false

    primaryMonitorOnly := _GetAutoHidePrimaryMonitorOnly()
    return primaryMonitorOnly = 1
}

; Check if the taskbar is currently hidden by the taskbar-auto-hide-when-maximized mod
; (i.e. mod is enabled and a window is maximized on the given monitor)
IsWindhawkAutoHideActive(MonitorIndex) {
    if (!IsWindhawkModEnabled("taskbar-auto-hide-when-maximized"))
        return false
    if (!IsWindowMaximized(MonitorIndex))
        return false
    if (MonitorIndex = MonitorGetPrimary())
        return true

    return _GetAutoHidePrimaryMonitorOnly() != 1
}

; Check if the taskbar-auto-hide-when-maximized mod applies to the given monitor
; (mod is enabled but taskbar is NOT currently hidden — no maximized window)
IsWindhawkAutoHideApplies(MonitorIndex) {
    if (!IsWindhawkModEnabled("taskbar-auto-hide-when-maximized"))
        return false
    if (IsWindowMaximized(MonitorIndex))
        return false
    if (MonitorIndex = MonitorGetPrimary())
        return true

    return _GetAutoHidePrimaryMonitorOnly() != 1
}

; Read and cache the primaryMonitorOnly registry setting for taskbar-auto-hide-when-maximized
_GetAutoHidePrimaryMonitorOnly() {
    cacheKey := "WH_primaryMonitorOnly"
    if (_CacheGet(cacheKey, &cached))
        return cached

    regBase := "HKLM\SOFTWARE\Windhawk\Engine\Mods\taskbar-auto-hide-when-maximized\Settings"
    return _CacheSet(cacheKey, RegRead(regBase, "primaryMonitorOnly", 0))
}

; Check if the taskbar-on-top mod places the taskbar at the top for the given monitor
IsTaskbarOnTop(MonitorIndex) {
    cacheKey := "WH_taskbarOnTop_" . MonitorIndex
    if (_CacheGet(cacheKey, &cached))
        return cached

    if (!IsWindhawkModEnabled("taskbar-on-top"))
        return _CacheSet(cacheKey, false)

    regBase := "HKLM\SOFTWARE\Windhawk\Engine\Mods\taskbar-on-top\Settings"
    primaryLocation := RegRead(regBase, "taskbarLocation", "top")

    if (MonitorIndex = MonitorGetPrimary())
        return _CacheSet(cacheKey, primaryLocation = "top")

    secondaryLocation := RegRead(regBase, "taskbarLocationSecondary", "sameAsPrimary")
    result := (secondaryLocation = "sameAsPrimary") ? (primaryLocation = "top") : (secondaryLocation = "top")
    return _CacheSet(cacheKey, result)
}

; Check if any window on the specified monitor is maximized
; Result is cached to avoid repeated window enumeration within the cache TTL
IsWindowMaximized(MonitorIndex) {
    cacheKey := "WM_" . MonitorIndex
    if (_CacheGet(cacheKey, &cached))
        return cached

    windows := WinGetList()

    for window in windows {
        try {
            if (WinGetMinMax("ahk_id " . window) != 1)
                continue
            WinGetPos(&wx, &wy, &ww, &wh, "ahk_id " . window)
            if (GetActiveMonitor(wx, wy, ww, wh, "ahk_id " . window) = MonitorIndex)
                return _CacheSet(cacheKey, true)
        } catch {
            continue
        }
    }
    return _CacheSet(cacheKey, false)
}

; Get the adjusted work area for a monitor, accounting for SmartTaskbar and Windhawk mods
GetAdjustedWorkArea(MonitorIndex) {
    MonitorGetWorkArea(MonitorIndex, &Left, &Top, &Right, &Bottom)
    Left += SCREEN_EDGE_MARGIN
    Top += SCREEN_EDGE_MARGIN
    Right -= SCREEN_EDGE_MARGIN
    Bottom -= SCREEN_EDGE_MARGIN

    PrimaryMonitor := MonitorGetPrimary()

    cacheKey := "MMTaskbar"
    if (!_CacheGet(cacheKey, &TaskbarSetting))
        TaskbarSetting := _CacheSet(cacheKey, RegRead(
            "HKCU\Software\Microsoft\Windows\CurrentVersion\Explorer\Advanced", "MMTaskbarEnabled", 0))

    TaskbarOnThisMonitor := (MonitorIndex = PrimaryMonitor || TaskbarSetting = 1)

    ; Evaluate each condition once
    TaskbarOnSecondaryCondition := MonitorIndex != PrimaryMonitor && TaskbarSetting = 1
    SmartTaskbarCondition := MonitorIndex = PrimaryMonitor && IsSmartTaskbarRunning() && !IsWindowMaximized(
        PrimaryMonitor)
    WindhawkCondition := TaskbarOnThisMonitor && IsWindhawkAutoHideApplies(MonitorIndex)
    TaskbarOnTop := IsTaskbarOnTop(MonitorIndex)
    AutoHideActive := TaskbarOnThisMonitor && (IsNativeAutoHideOnSecondary(MonitorIndex) || IsWindhawkAutoHideActive(
        MonitorIndex))

    if (TaskbarOnSecondaryCondition || SmartTaskbarCondition || WindhawkCondition)
        Bottom -= GetTaskbarHeight(MonitorIndex)

    ; Fetch physical monitor bounds once for both blocks that may need it
    if (TaskbarOnTop || AutoHideActive)
        MonitorGet(MonitorIndex, &MLeft, &MTop, &MRight, &MBottom)

    if (TaskbarOnTop) {
        Top := MTop + GetTaskbarHeight(MonitorIndex) + SCREEN_EDGE_MARGIN
        Bottom := MBottom - SCREEN_EDGE_MARGIN
    }

    if (AutoHideActive) {
        Bottom := MBottom - SCREEN_EDGE_MARGIN
        if (TaskbarOnTop)
            Top := MTop + SCREEN_EDGE_MARGIN
    }

    return [Left, Top, Right, Bottom]
}

; Show a brief non-blocking error tooltip that auto-dismisses after 3 seconds
_ShowError(msg) {
    ToolTip(msg)
    SetTimer(_ClearErrorTooltip, -3000)
}

_ClearErrorTooltip() {
    ToolTip()
}

; Snap the active window to the given position on its current monitor.
; HAlign: "left", "center", "right"
; VAlign: "top", "center", "bottom"
SnapWindow(HAlign, VAlign) {
    Critical
    try {
        if (!(hWnd := WinExist("A")))
            throw Error("No active window found.")
        WinGetPos(&WinX, &WinY, &WinW, &WinH, "A")
        ActiveMonitor := GetActiveMonitor(WinX, WinY, WinW, WinH, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        FrameSize := GetWindowFrameSize(hWnd)

        ; When SCREEN_EDGE_MARGIN = 0, apps with an invisible DWM extended frame (FrameSize > 0) have
        ; their 1px colored border land just outside the monitor, rendering on the adjacent monitor.
        ; Nudge 1px inward so the border pixel sits on the correct monitor. SCREEN_EDGE_MARGIN >= 1
        ; already provides enough gap, so no nudge is needed in that case.
        BleedPx := Max(0, 1 - SCREEN_EDGE_MARGIN)

        X := HAlign = "left" ? WorkArea[1] - FrameSize.Left + (FrameSize.Left > 0 ? BleedPx : 0)
            : HAlign = "right" ? WorkArea[3] - WinW + FrameSize.Right - (FrameSize.Right > 0 ? BleedPx : 0)
                : WorkArea[1] + (WorkArea[3] - WorkArea[1] - WinW) // 2  ; center

        ForceToBottom := VAlign = "bottom"
        Y := VAlign = "top" ? WorkArea[2]
            : VAlign = "bottom" ? 0
                : WorkArea[2] + (WorkArea[4] - WorkArea[2] - WinH) // 2  ; center

        MoveWindowSafelyEnhanced(X, Y, "", "", "A", ForceToBottom)
    } catch as err {
        Critical(false)
        _ShowError("Snap error: " . err.Message)
    }
}

; Center
$^+#s:: ; Ctrl+Shift+Win+S
{
    if (!_IsHotkeyDuplicate(A_ThisHotkey))
        SnapWindow("center", "center")
}

; Top center
$^+#w:: ; Ctrl+Shift+Win+W
{
    if (!_IsHotkeyDuplicate(A_ThisHotkey))
        SnapWindow("center", "top")
}

; Bottom center
$^+#x:: ; Ctrl+Shift+Win+X
{
    if (!_IsHotkeyDuplicate(A_ThisHotkey))
        SnapWindow("center", "bottom")
}

; Left center
$^+#a:: ; Ctrl+Shift+Win+A
{
    if (!_IsHotkeyDuplicate(A_ThisHotkey))
        SnapWindow("left", "center")
}

; Right center
$^+#d:: ; Ctrl+Shift+Win+D
{
    if (!_IsHotkeyDuplicate(A_ThisHotkey))
        SnapWindow("right", "center")
}

; Top-left
$^+#q:: ; Ctrl+Shift+Win+Q
{
    if (!_IsHotkeyDuplicate(A_ThisHotkey))
        SnapWindow("left", "top")
}

; Top-right
$^+#e:: ; Ctrl+Shift+Win+E
{
    if (!_IsHotkeyDuplicate(A_ThisHotkey))
        SnapWindow("right", "top")
}

; Bottom-left
$^+#z:: ; Ctrl+Shift+Win+Z
{
    if (!_IsHotkeyDuplicate(A_ThisHotkey))
        SnapWindow("left", "bottom")
}

; Bottom-right
$^+#c:: ; Ctrl+Shift+Win+C
{
    if (!_IsHotkeyDuplicate(A_ThisHotkey))
        SnapWindow("right", "bottom")
}
