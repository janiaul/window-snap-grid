#Requires AutoHotkey v2.0
#NoTrayIcon
#SingleInstance Force

global TASKBAR_GAP := 0          ; Pixels between window and taskbar
global SCREEN_EDGE_MARGIN := 2   ; Pixels between window and screen edges (prevents frame bleed)

; Cache for expensive calls (file reads, window enumeration, registry reads)
; Values are reused within _CACHE_TTL milliseconds to avoid redundant work
global _cache := Map()
global _CACHE_TTL := 500

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
    return value
}

; Returns true if this hotkey+window combination was already triggered within the cache TTL
_IsHotkeyDuplicate(HotkeyName) {
    cacheKey := "HK_" . HotkeyName . "_" . WinExist("A")
    if (_CacheGet(cacheKey, &_))
        return true
    _CacheSet(cacheKey, true)
    return false
}

; Determine which monitor a window is on based on its coordinates
GetActiveMonitor(X, Y, W := 0, H := 0, WinTitle := "A") {
    if (WinTitle != "") {
        if (hWnd := WinExist(WinTitle)) {
            ; Create RECT structure
            RECT := Buffer(16)
            DllCall("GetWindowRect", "Ptr", hWnd, "Ptr", RECT)

            ; Get monitor from window rect
            MONITOR_DEFAULTTOPRIMARY := 0x1
            hMonitor := DllCall("MonitorFromRect", "Ptr", RECT, "UInt", MONITOR_DEFAULTTOPRIMARY, "Ptr")

            ; Get monitor info
            MONITORINFO := Buffer(40)
            NumPut("UInt", 40, MONITORINFO, 0)  ; cbSize
            if (DllCall("GetMonitorInfo", "Ptr", hMonitor, "Ptr", MONITORINFO)) {
                ; Loop through monitors to find matching one
                loop MonitorGetCount() {
                    MonitorGetWorkArea(A_Index, &Left, &Top, &Right, &Bottom)
                    testRECT := Buffer(16)
                    NumPut("Int", Left, testRECT, 0)
                    NumPut("Int", Top, testRECT, 4)
                    NumPut("Int", Right, testRECT, 8)
                    NumPut("Int", Bottom, testRECT, 12)

                    currHMonitor := DllCall("MonitorFromRect", "Ptr", testRECT, "UInt", MONITOR_DEFAULTTOPRIMARY)
                    if (currHMonitor = hMonitor)
                        return A_Index
                }
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

; Check if a window with the given title exists
WindowExists(WinTitle := "A") {
    return WinExist(WinTitle) != 0
}

; Get window frame thickness (for better positioning accuracy)
GetWindowFrameSize(WinTitle := "A") {
    if (!(hWnd := WinExist(WinTitle)))
        return { Left: 0, Top: 0, Right: 0, Bottom: 0 }

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

        ; Get client area position
        ClientPOINT := Buffer(8)
        NumPut("Int", 0, ClientPOINT, 0)
        NumPut("Int", 0, ClientPOINT, 4)
        DllCall("ClientToScreen", "Ptr", hWnd, "Ptr", ClientPOINT)
        ClientLeft := NumGet(ClientPOINT, 0, "Int")
        ClientTop := NumGet(ClientPOINT, 4, "Int")

        return {
            Left: ClientLeft - WinLeft,
            Top: ClientTop - WinTop,
            Right: WinRight - (ClientLeft + ClientWidth),
            Bottom: WinBottom - (ClientTop + ClientHeight)
        }
    } catch {
        return { Left: 0, Top: 0, Right: 0, Bottom: 0 }
    }
}

; Enhanced window moving function that accounts for window frames
MoveWindowSafelyEnhanced(X, Y, W := "", H := "", WinTitle := "A", ForceToBottom := false) {
    if (!WindowExists(WinTitle)) {
        MsgBox("The specified window does not exist.", "Error", 16)
        return
    }
    try {
        ; Get window frame information for more accurate positioning
        FrameSize := GetWindowFrameSize(WinTitle)
        ; If ForceToBottom is true, adjust the Y position to account for potential app-specific margins
        if (ForceToBottom) {
            ; Get current window info
            WinGetPos(&CurX, &CurY, &CurW, &CurH, WinTitle)
            ActiveMonitor := GetActiveMonitor(CurX, CurY, CurW, CurH, WinTitle)
            WorkArea := GetAdjustedWorkArea(ActiveMonitor)
            ; When taskbar is on top, snap to the true screen bottom with no gap
            AbsoluteBottom := IsTaskbarOnTop(ActiveMonitor) ? WorkArea[4] : WorkArea[4] - TASKBAR_GAP
            ; Account for window frame
            AdjustedY := AbsoluteBottom - CurH + FrameSize.Bottom
            ; Use the adjusted Y position
            Y := AdjustedY
        }
        if (W = "" && H = "") {
            WinMove(X, Y, , , WinTitle)
        } else if (W = "") {
            WinMove(X, Y, , H, WinTitle)
        } else if (H = "") {
            WinMove(X, Y, W, , WinTitle)
        } else {
            WinMove(X, Y, W, H, WinTitle)
        }
        ; Verify position and make final adjustment if needed for bottom snapping
        if (ForceToBottom) {
            Sleep(10)  ; Small delay to ensure the move completed
            WinGetPos(&NewX, &NewY, &NewW, &NewH, WinTitle)
            ActiveMonitor := GetActiveMonitor(NewX, NewY, NewW, NewH, WinTitle)
            WorkArea := GetAdjustedWorkArea(ActiveMonitor)
            ; If window still isn't at the correct position, try one more adjustment
            ExpectedBottom := IsTaskbarOnTop(ActiveMonitor) ? WorkArea[4] : WorkArea[4] - TASKBAR_GAP
            if (NewY + NewH < ExpectedBottom - 5) {  ; 5 pixel tolerance
                FinalY := ExpectedBottom - NewH
                WinMove(NewX, FinalY, , , WinTitle)
            }
        }
    } catch as err {
        if (InStr(err.Message, "Access is denied")) {
            MsgBox("Unable to move this window due to system restrictions. Try running the script as administrator.",
                "Access Denied", 48)
        } else {
            MsgBox("An unexpected error occurred: " . err.Message, "Error", 16)
        }
    }
}

; Safely move a window, handling potential errors
MoveWindowSafely(X, Y, W := "", H := "", WinTitle := "A") {
    MoveWindowSafelyEnhanced(X, Y, W, H, WinTitle, false)
}

; Get the height of the taskbar, accounting for display scaling
GetTaskbarHeight(MonitorIndex := 0) {
    ; If no monitor specified, use primary
    if (MonitorIndex = 0)
        MonitorIndex := MonitorGetPrimary()

    cacheKey := "TBH_" . MonitorIndex
    if (_CacheGet(cacheKey, &cached))
        return cached

    ; Try to get the taskbar window
    if (taskbar := WinExist("ahk_class Shell_TrayWnd")) {
        WinGetPos(&Left, &Top, &Width, &Height, taskbar)
        return _CacheSet(cacheKey, Height)
    }
    ; If taskbar window not found, estimate based on DPI scaling
    hDC := DllCall("GetDC", "Ptr", 0)
    dpi := DllCall("GetDeviceCaps", "Ptr", hDC, "Int", 88)  ; LOGPIXELSX
    DllCall("ReleaseDC", "Ptr", 0, "Ptr", hDC)
    scaleFactor := dpi / 96  ; 96 is the base DPI

    ; Base taskbar height is 48 pixels at 100% scaling
    return _CacheSet(cacheKey, Round(48 * scaleFactor))
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
            if (char = '{')
                braceCount++
            else if (char = '}') {
                braceCount--
                if (braceCount = 0)
                    endPos := pos
            }
            pos++
        }

        if (!endPos)
            return _CacheSet(cacheKey, false)

        modSection := SubStr(jsonContent, startPos, endPos - startPos)
        result := !InStr(modSection, '"disabled": true')
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

    DetectHiddenWindows(false)
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

; Get information about the currently focused window
GetFocusedWindowInfo() {
    if (!WindowExists("A")) {
        throw Error("No active window found.")
    }
    WinGetPos(&WinX, &WinY, &WinW, &WinH, "A")
    return { X: WinX, Y: WinY, W: WinW, H: WinH }
}

; Center window horizontally and vertically
$^+#s:: ; Ctrl+Shift+Win+S
{
    if (_IsHotkeyDuplicate(A_ThisHotkey))
        return
    try {
        WinInfo := GetFocusedWindowInfo()
        ActiveMonitor := GetActiveMonitor(WinInfo.X, WinInfo.Y, WinInfo.W, WinInfo.H, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        CenterX := WorkArea[1] + (WorkArea[3] - WorkArea[1] - WinInfo.W) // 2
        CenterY := WorkArea[2] + (WorkArea[4] - WorkArea[2] - WinInfo.H) // 2
        MoveWindowSafely(CenterX, CenterY)
    } catch as err {
        MsgBox("Error: " . err.Message, "Window Centering Error", 16)
    }
}

; Snap left (center vertically, align to left)
$^+#a:: ; Ctrl+Shift+Win+A
{
    if (_IsHotkeyDuplicate(A_ThisHotkey))
        return
    try {
        WinInfo := GetFocusedWindowInfo()
        ActiveMonitor := GetActiveMonitor(WinInfo.X, WinInfo.Y, WinInfo.W, WinInfo.H, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        FrameSize := GetWindowFrameSize("A")
        LeftX := WorkArea[1] - FrameSize.Left
        CenterY := WorkArea[2] + (WorkArea[4] - WorkArea[2] - WinInfo.H) // 2
        MoveWindowSafelyEnhanced(LeftX, CenterY, "", "", "A", false)
    } catch as err {
        MsgBox("Error: " . err.Message, "Window Positioning Error", 16)
    }
}

; Snap right (center vertically, align to right)
$^+#d:: ; Ctrl+Shift+Win+D
{
    if (_IsHotkeyDuplicate(A_ThisHotkey))
        return
    try {
        WinInfo := GetFocusedWindowInfo()
        ActiveMonitor := GetActiveMonitor(WinInfo.X, WinInfo.Y, WinInfo.W, WinInfo.H, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        FrameSize := GetWindowFrameSize("A")
        RightX := WorkArea[3] - WinInfo.W + FrameSize.Right
        CenterY := WorkArea[2] + (WorkArea[4] - WorkArea[2] - WinInfo.H) // 2
        MoveWindowSafelyEnhanced(RightX, CenterY, "", "", "A", false)
    } catch as err {
        MsgBox("Error: " . err.Message, "Window Positioning Error", 16)
    }
}

; Snap top (center horizontally, align to top)
$^+#w:: ; Ctrl+Shift+Win+W
{
    if (_IsHotkeyDuplicate(A_ThisHotkey))
        return
    try {
        WinInfo := GetFocusedWindowInfo()
        ActiveMonitor := GetActiveMonitor(WinInfo.X, WinInfo.Y, WinInfo.W, WinInfo.H, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        CenterX := WorkArea[1] + (WorkArea[3] - WorkArea[1] - WinInfo.W) // 2
        TopY := WorkArea[2]
        MoveWindowSafely(CenterX, TopY)
    } catch as err {
        MsgBox("Error: " . err.Message, "Window Positioning Error", 16)
    }
}

; Snap bottom (center horizontally, align to bottom)
$^+#x:: ; Ctrl+Shift+Win+X
{
    if (_IsHotkeyDuplicate(A_ThisHotkey))
        return
    try {
        WinInfo := GetFocusedWindowInfo()
        ActiveMonitor := GetActiveMonitor(WinInfo.X, WinInfo.Y, WinInfo.W, WinInfo.H, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        CenterX := WorkArea[1] + (WorkArea[3] - WorkArea[1] - WinInfo.W) // 2
        MoveWindowSafelyEnhanced(CenterX, 0, "", "", "A", true)
    } catch as err {
        MsgBox("Error: " . err.Message, "Window Positioning Error", 16)
    }
}

; Top-left corner
$^+#q:: ; Ctrl+Shift+Win+Q
{
    if (_IsHotkeyDuplicate(A_ThisHotkey))
        return
    try {
        WinInfo := GetFocusedWindowInfo()
        ActiveMonitor := GetActiveMonitor(WinInfo.X, WinInfo.Y, WinInfo.W, WinInfo.H, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        FrameSize := GetWindowFrameSize("A")
        LeftX := WorkArea[1] - FrameSize.Left
        TopY := WorkArea[2]
        MoveWindowSafelyEnhanced(LeftX, TopY, "", "", "A", false)
    } catch as err {
        MsgBox("Error: " . err.Message, "Window Positioning Error", 16)
    }
}

; Top-right corner
$^+#e:: ; Ctrl+Shift+Win+E
{
    if (_IsHotkeyDuplicate(A_ThisHotkey))
        return
    try {
        WinInfo := GetFocusedWindowInfo()
        ActiveMonitor := GetActiveMonitor(WinInfo.X, WinInfo.Y, WinInfo.W, WinInfo.H, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        FrameSize := GetWindowFrameSize("A")
        RightX := WorkArea[3] - WinInfo.W + FrameSize.Right
        TopY := WorkArea[2]
        MoveWindowSafelyEnhanced(RightX, TopY, "", "", "A", false)
    } catch as err {
        MsgBox("Error: " . err.Message, "Window Positioning Error", 16)
    }
}

; Bottom-left corner
$^+#z:: ; Ctrl+Shift+Win+Z
{
    if (_IsHotkeyDuplicate(A_ThisHotkey))
        return
    try {
        WinInfo := GetFocusedWindowInfo()
        ActiveMonitor := GetActiveMonitor(WinInfo.X, WinInfo.Y, WinInfo.W, WinInfo.H, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        FrameSize := GetWindowFrameSize("A")
        LeftX := WorkArea[1] - FrameSize.Left
        MoveWindowSafelyEnhanced(LeftX, 0, "", "", "A", true)
    } catch as err {
        MsgBox("Error: " . err.Message, "Window Positioning Error", 16)
    }
}

; Bottom-right corner
$^+#c:: ; Ctrl+Shift+Win+C
{
    if (_IsHotkeyDuplicate(A_ThisHotkey))
        return
    try {
        WinInfo := GetFocusedWindowInfo()
        ActiveMonitor := GetActiveMonitor(WinInfo.X, WinInfo.Y, WinInfo.W, WinInfo.H, "A")
        WorkArea := GetAdjustedWorkArea(ActiveMonitor)
        FrameSize := GetWindowFrameSize("A")
        RightX := WorkArea[3] - WinInfo.W + FrameSize.Right
        MoveWindowSafelyEnhanced(RightX, 0, "", "", "A", true)
    } catch as err {
        MsgBox("Error: " . err.Message, "Window Positioning Error", 16)
    }
}
