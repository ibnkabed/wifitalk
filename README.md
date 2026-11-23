# WiFiTalk

**Your iPhone becomes your Windows computer's AI assistant, keyboard, trackpad, microphone and speaker, over your Wi-Fi.**

Say "open Chrome and search for flights to Riyadh", "write a short thank-you email to my team", or "lock the computer", and it happens on the computer. All the thinking happens on the iPhone, with hybrid AI through **Firebase AI Logic**:

- **On the iPhone** with Apple's on-device model (Foundation Models), for a short request in a language it supports, such as English. Private, free, and works with no internet.
- **In the cloud** with Gemini through Firebase AI Logic, for longer writing, Arabic, and phones without Apple Intelligence.

The Windows side is a tiny companion: an icon beside the clock that does exactly what the phone says (type this, press these keys, move the mouse, open that program) and nothing else. It runs no AI and holds no keys.

[العربية](README.ar.md)

## What it does

- **Assistant:** speak or type a request. The phone turns it into plain actions and shows them as they run, with a label saying which engine understood it: **this iPhone** or **Gemini in the cloud**. Shutting down, restarting and sleeping the computer are confirmed on the phone first.
- **Dictation:** speak, and your words are typed where the cursor is, in any app.
- **Trackpad:** move, tap to click, two-finger tap to right-click, two fingers to scroll, long press to drag.
- **Keyboard:** type on the iPhone in any language it has, Arabic included, and the text appears on the computer as you type. There are keys for Esc, Tab, the arrows, copy, paste, undo, switching apps and more.
- **Controls:** volume, media, lock, sleep, restart and shut down.
- **Hear the computer on the iPhone:** the computer's sound plays on the phone or its headphones.
- **The iPhone as the computer's microphone:** your voice reaches every Windows app. This needs the free [VB-CABLE](https://vb-audio.com/Cable/) driver.

## How the hybrid AI works

All AI calls are in [`ios/WiFiTalk/AI/FirebaseHybrid.swift`](ios/WiFiTalk/AI/FirebaseHybrid.swift), and the assistant's prompt is in [`ios/WiFiTalk/AI/Assistant.swift`](ios/WiFiTalk/AI/Assistant.swift).

1. **Speech to text:** Apple's speech recognizer runs on the iPhone when it supports the language.
2. **Request to actions, on the device first:** the request is sent to the on-device model when three things are true:
   - Apple Intelligence is available on the phone.
   - The request is in a supported language.
   - It fits the on-device context.

   The model answers with a small JSON plan.
3. **Cloud fallback:** otherwise, or if the on-device model fails or returns something that isn't JSON, the same request goes to Gemini through Firebase AI Logic. The lighter Gemini model is tried first, and a second model takes over when the first is busy.
4. **Checked before it runs:** the phone keeps only the known action types (open, text, keys, wait, power), within limits, and asks before power actions.
5. **Firebase:**
   - **App Check** protects the AI calls.
   - **Remote Config** holds the cloud model names and an on-device switch.

## Install

### Windows computer

1. Download `WiFiTalk.exe` from the [latest release](https://github.com/ibnkabed/wifitalk/releases/latest).
2. Run it. It needs no installation and no administrator rights.
   - Windows SmartScreen may warn that the program is unsigned. Choose **More info**, then **Run anyway**.
   - When Windows Firewall asks, allow it on **private networks**.
3. Its icon appears beside the clock. Click it to see the computer's address and a 6-digit PIN. Right-click it for:
   - **Start with Windows**
   - **Unpair all phones**
   - **Close**

### iPhone

1. Download `WiFiTalk-unsigned.ipa` from the [latest release](https://github.com/ibnkabed/wifitalk/releases/latest).
2. Install it with [Sideloadly](https://sideloadly.io) and a free Apple ID. It needs iOS 17 or later; on-device AI needs an iPhone with Apple Intelligence on iOS 26 or later.
3. Open WiFiTalk, then enter the computer's address and PIN. Both devices must be on the same Wi-Fi.

## Security

- **Local network only:** the companion accepts connections only from the local network, never from the internet.
- **Pairing:** a phone pairs once with the PIN shown on the computer, and then uses a private token. After five wrong PINs, pairing locks for a minute. **Unpair all phones** makes a new PIN and drops every paired phone.
- **Fixed actions:** the companion runs only the fixed set of actions in [`windows/WiFiTalk.cs`](windows/WiFiTalk.cs), and nothing the phone could send runs a shell command.

## Build it yourself

- **Windows:** run `windows/build.ps1`. It uses the C# compiler that ships with Windows, so there is no SDK to install. Then run `windows/test_companion.py` against the running program to check the protocol.
- **iPhone:** [XcodeGen](https://github.com/yonaskolb/XcodeGen) with `ios/project.yml`. GitHub Actions builds both in [`.github/workflows/build.yml`](.github/workflows/build.yml).
  - The Firebase config (`GoogleService-Info.plist`) and the App Check debug token come from repository secrets and are never committed.
  - Without them, the app builds with the assistant switched off.

## Protocol

There is one TCP connection on port 47821. Each frame is one byte of type, four bytes of big-endian length, then the payload:

| Type | Direction | Payload |
|---|---|---|
| 1 | both | JSON |
| 2 | phone → computer | The phone's microphone: PCM int16, mono, 48 kHz |
| 3 | computer → phone | The computer's sound: PCM int16, stereo, with the rate announced in JSON |

The phone first sends `{"hello":{"pin":"123456"}}` (or a saved token), then actions such as:

```json
{"id": 7, "do": [{"t": "open", "s": "notepad"}, {"t": "wait", "ms": 1500}, {"t": "text", "s": "Hello"}]}
```

## License

MIT. See [LICENSE](LICENSE).

Copyright (c) 2026 IbnKabed
