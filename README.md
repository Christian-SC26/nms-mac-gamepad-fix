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

#### Способ 1: Скачать готовый файл из Releases (Без клонирования репозитория)
1. Перейдите на страницу **[Releases](../../releases)** и скачайте архив **`NoMansSky_Gamepad_Fix.zip`** (или напрямую файл `NoMansSky_Gamepad_Fix.command`).
2. Распакуйте архив и дважды кликните по файлу **`NoMansSky_Gamepad_Fix.command`**.
3. Скрипт сам найдёт игру `No Man's Sky.app` (на внешнем диске `/Volumes/*`, в `/Applications` или откроет системный выбор), установит нужные компоненты, переподпишет приложение и снимет ограничения macOS.

*(Если macOS при первом запуске напишет, что скрипт скачан из интернета — нажмите правой кнопкой мыши по файлу -> «Открыть», либо выполните в терминале: `chmod +x ~/Downloads/NoMansSky_Gamepad_Fix.command`)*

#### Способ 2: Через клонирование репозитория
1. Склонируйте репозиторий: `git clone https://github.com/Christian-SC26/nms-mac-gamepad-fix.git`
2. Запустите `./patch.command` (или дважды кликните по нему в Finder).

#### Как обновляться на новую версию игры?
Когда вы скачаете новую версию *No Man's Sky*, просто запустите `NoMansSky_Gamepad_Fix.command` (или `patch.command`) ещё раз — он мгновенно накатит фикс на новую версию!

---

## English

Automatic patch that enables full gamepad support (Xbox, PlayStation DualSense/DualShock 4, Nintendo Switch Pro, and other Bluetooth/USB gamepads) in cracked builds of *No Man's Sky* on macOS (Apple Silicon & Intel).
Features full support for Steam Input Action Set Layers (in-game Quick Menu, base building, button glyphs, and responsive tab switching via bumpers & D-Pad).

### Quick Installation

#### Method 1: Download Standalone Installer (No Git needed)
1. Go to the **[Releases](../../releases)** page.
2. Download **`NoMansSky_Gamepad_Fix.zip`** (or `NoMansSky_Gamepad_Fix.command`).
3. Extract the ZIP and double-click **`NoMansSky_Gamepad_Fix.command`**.
4. The installer will auto-detect `No Man's Sky.app`, install the fix, re-sign the app, and remove quarantine attributes.

#### Method 2: Git Clone
```bash
git clone https://github.com/Christian-SC26/nms-mac-gamepad-fix.git
cd nms-mac-gamepad-fix
./patch.command
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
