# Accessibility Permission Specification

## Core Requirement
The application **must** be able to trigger the native macOS Accessibility permission prompt ("VoiceFlow would like to control this computer...") when permission is not granted.

Crucially, this must work in two distinct scenarios:
1.  **First Launch:** The user has never seen the prompt.
2.  **After Removal:** The user has manually removed the app from `System Settings > Privacy & Security > Accessibility` using the "−" (minus) button.

## The Problem
Simply checking `AXIsProcessTrusted()` returns `false` in both scenarios, but it does **not** trigger a prompt. Opening the System Settings URL is helpful but insufficient if the app isn't in the list, as the user has no "+" button to easily add it back in modern macOS versions (or it's hidden/cumbersome).

## The Solution (Implementation)
To force the system to re-evaluate the app's standing and potentially show the prompt again (or at least register the app in the list so it can be toggled), we must use:

```swift
let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
let trusted = AXIsProcessTrustedWithOptions(options)
```

**File:** `Sources/Models/AppState.swift`
**Function:** `checkAccessibilityPermission(silent: Bool)`

### Logic Flow
1.  **Silent Check:** Call `AXIsProcessTrusted()` (no prompt). Update state.
2.  **Explicit Request (User Click):**
    *   Call `AXIsProcessTrusted()` first. If true, return.
    *   **CRITICAL:** Call `AXIsProcessTrustedWithOptions` with `prompt: true`.
    *   If that returns `true` immediately, we are done.
    *   If not, wait briefly (0.5s) and *then* open System Settings (`x-apple.systempreferences:...`).
    *   Start polling `AXIsProcessTrusted()` to detect when the user toggles the switch.

## Verification Steps

### 1. Happy Path (First Time)
1.  Reset permissions: `tccutil reset Accessibility com.jacobcole.voiceflow.dev`
2.  Run the app.
3.  Click "Request" for Accessibility.
4.  **Expectation:** The system dialog appears ("...would like to control this computer").

### 2. The "Minus Button" Path (Regression Test)
1.  Grant permission and verify the app works.
2.  Open System Settings > Privacy & Security > Accessibility.
3.  Select "VoiceFlow-Dev" and click the **"−" (Minus)** button to remove it entirely.
4.  Switch back to the app. It should show "Not Granted".
5.  Click "Request" again.
6.  **Expectation:** The system dialog **must** appear again.
    *   *Failure Mode:* The settings window opens, but the app is not in the list, and no prompt appears.

## Troubleshooting / Reset
To completely reset the permission state for testing:
```bash
tccutil reset Accessibility com.jacobcole.voiceflow.dev
```
(Replace bundle ID with `com.jacobcole.voiceflow` for the release build)
