# No Man's Sky Mac (Cracked) Gamepad Fix 🎮

[English](#english) | [Русский](#русский)

---

## Русский

Автоматический патч для включения полной поддержки геймпадов (Xbox, PlayStation DualSense/DualShock 4, Nintendo Switch Pro и сторонних Bluetooth/USB-контроллеров) в «No Man's Sky» для macOS (Apple Silicon / Intel).

### Почему геймпады не работали из коробки?
1. **Steam Input Callbacks:** Движок ввода игры (`cTkInputManagerSteam`) ожидает системные события Steamworks:
   - `SteamInputDeviceConnected_t` (2801) — инициирует синхронизацию контроллера (`SyncControllers`).
   - `SteamInputConfigurationLoaded_t` (2803) — инициирует загрузку действий (`LoadSteamActions`).
   В эмуляторе Goldberg метод `EnableDeviceCallbacks()` был пустышкой (`ret`) — эти события никогда не отправлялись, и игра не опрашивала контроллер.
2. **Асинхронные тайминги GameController на macOS:** В момент запуска процесса список подключённых геймпадов `[GCController controllers]` пуст ещё 20–50 мс, пока `gamecontrollerd` опрашивает устройства. Эмулятор проверял устройства лишь однажды на старте и навсегда считал контроллер отключённым.
3. **Обновление ввода:** Игра не вызывает `RunFrame()`, а полагается на `SteamAPI_RunCallbacks()`. Эмулятор не синхронизировал ввод внутри `RunCallbacks`.

### Как работает патч?
* Внедряется нативный мост `libsteam_api.dylib`, который перехватывает `SteamAPI_RunCallbacks()` и `_GamepadIsConnected()`.
* Состояние стиков, кнопок и триггеров непрерывно считывается напрямую через системный `GameController.framework`.
* Поддерживается горячее подключение (hotplug / пробуждение контроллера из спящего режима).
* Полная поддержка динамических слоев управления (**Action Set Layers**) для меню быстрого использования (Quick Menu: лечение, призыв корабля, карта) и режимов строительства с отображением глифов кнопок.
* Встроены готовые наборы действий Steam Input (`FRONTEND`, `OnFootControls`, `OnFootQuickMenu`, `ShipControls`, `ShipQuickMenu` и др.).

---

### Быстрая установка (1 клик)

#### Вариант 1: Через Finder
1. Дважды кликните по файлу **`patch.command`**.
2. Скрипт сам найдёт `No Man's Sky.app` (на внешнем диске `/Volumes/*`, в `/Applications` или через окно выбора файла).
3. Патч применится автоматически, переподпишет dylib и снимет карантин macOS.

#### Вариант 2: Через Терминал
```bash
# Автопоиск:
./patch.command

# Либо с указанием пути к игре:
./patch.command "/Volumes/Data/No Man's Sky.app"
```

#### Как обновляться на новую версию игры?
Когда вы скачаете новую версию *No Man's Sky*, просто запустите `patch.command` ещё раз — он перезапишет библиотеки и применит патч к новой версии!

---

## English

Automatic patch that enables full gamepad support (Xbox, PlayStation DualSense/DualShock 4, Nintendo Switch Pro, and other Bluetooth/USB gamepads) in cracked builds of *No Man's Sky* on macOS (Apple Silicon & Intel).
Features full support for Steam Input Action Set Layers (in-game Quick Menu, base building, button glyphs, and responsive tab switching via bumpers & D-Pad).

### Quick Installation

#### Method 1: Double-click in Finder
1. Double-click **`patch.command`**.
2. The script will auto-detect `No Man's Sky.app` (on external drives `/Volumes/*`, `/Applications`, or via a native file chooser).
3. The patch will be applied, binaries ad-hoc signed, and quarantine attributes cleared.

#### Method 2: Terminal
```bash
./patch.command "/path/to/No Man's Sky.app"
```

### Building from Source (Optional)
If you want to recompile the universal dylib (`arm64` + `x86_64`) yourself:
```bash
./build.sh
```

---

### Project Structure
* `patch.command` / `install.sh` — Interactive double-clickable installer.
* `build.sh` — Compiles the universal bridge dylib using `clang`.
* `src/gamepad_bridge.m` — Native Objective-C bridge linking `GameController.framework` and Goldberg emulator.
* `bin/` — Universal precompiled binaries (`libsteam_api.dylib`, `libsteam_emu.dylib`).
* `steam_settings/` — Steam Input action sets and config files for *No Man's Sky*.
