import 'dart:async';
import 'dart:convert';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:logging/logging.dart';
import 'package:noa/noa_api.dart';
import 'package:noa/bluetooth.dart';
import 'package:noa/util/state_machine.dart';
import 'package:shared_preferences/shared_preferences.dart';

final _log = Logger("App logic");

enum State {
  waitForLogin,
  getPairedDevice,
  scanning,
  found,
  connect,
  stopLuaApp,
  checkVersion,
  uploadMainLua,
  uploadGraphicsLua,
  uploadStateLua,
  triggerUpdate,
  updateFirmware,
  requiresRepair,
  connected,
  sendResponseToDevice,
  disconnected,
  logout,
  deleteAccount
}

enum Event {
  init,
  done,
  error,
  loggedIn,
  pairedDeviceFound,
  pairedDeviceNotFound,
  deviceFound,
  deviceLost,
  deviceConnected,
  deviceReconnected,
  updatableDeviceConnected,
  deviceDisconnected,
  deviceInvalid,
  buttonPressed,
  cancelPressed,
  logoutPressed,
  deletePressed,
  deviceUpToDate,
  deviceNeedsUpdate,
  deviceDataResponse,
  noaResponse,
}

enum TuneLength {
  shortest('shortest'),
  short('short'),
  standard('standard'),
  long('long'),
  longest('longest');

  const TuneLength(this.value);
  final String value;
}

class AppLogicModel extends ChangeNotifier {
  // Public state variables
  StateMachine state = StateMachine(State.waitForLogin);
  NoaUser noaUser = NoaUser();
  double bluetoothUploadProgress = 0;
  final List<NoaMessage> noaMessages = List.empty(growable: true);

  // User's tune preferences
  String _tuneStyle = "";
  String get tuneStyle => _tuneStyle;
  set tuneStyle(String value) {
    _tuneStyle = value;
    () async {
      final savedData = await SharedPreferences.getInstance();
      savedData.setString("tuneStyle", _tuneStyle);
    }();
  }

  String _tuneTone = "";
  String get tuneTone => _tuneTone;
  set tuneTone(String value) {
    _tuneTone = value;
    () async {
      final savedData = await SharedPreferences.getInstance();
      savedData.setString("tuneTone", _tuneTone);
    }();
  }

  String _tuneFormat = "";
  String get tuneFormat => _tuneFormat;
  set tuneFormat(String value) {
    _tuneFormat = value;
    () async {
      final savedData = await SharedPreferences.getInstance();
      savedData.setString("tuneFormat", _tuneFormat);
    }();
  }

  int _tuneTemperature = 50;
  int get tuneTemperature => _tuneTemperature;
  set tuneTemperature(int value) {
    _tuneTemperature = value;
    () async {
      final savedData = await SharedPreferences.getInstance();
      savedData.setInt("tuneTemperature", _tuneTemperature);
    }();
    notifyListeners();
  }

  TuneLength _tuneLength = TuneLength.standard;
  TuneLength get tuneLength => _tuneLength;
  set length(TuneLength value) {
    _tuneLength = value;
    () async {
      final savedData = await SharedPreferences.getInstance();
      savedData.setString("tuneLength", _tuneLength.name);
    }();
    notifyListeners();
  }

  // Private state variables
  StreamSubscription? _scanStream;
  StreamSubscription? _connectionStream;
  StreamSubscription? _luaResponseStream;
  StreamSubscription? _dataResponseStream;
  BrilliantScannedDevice? _nearbyDevice;
  BrilliantDevice? _connectedDevice;
  List<int> _audioData = List.empty(growable: true);
  List<int> _imageData = List.empty(growable: true);
  String? _userAuthToken;

  // Noa steam listeners
  final _noaResponseStreamController = StreamController<NoaMessage>();
  final _noaUserInfoStreamController = StreamController<NoaUser>();

  AppLogicModel() {
    // Uncomment to create AppStore images
    // noaMessages.add(NoaMessage(
    //   message: "Recommend me some pizza places I near Union Square",
    //   from: NoaRole.user,
    //   time: DateTime.now().add(const Duration(seconds: 2)),
    // ));

    // noaMessages.add(NoaMessage(
    //   message:
    //       "You might want to check out Bravo Pizza, Union Square Pizza, or Joe's Pizza for some good pizza near Union Square.",
    //   from: NoaRole.noa,
    //   time: DateTime.now().add(const Duration(seconds: 3)),
    // ));

    // noaMessages.add(NoaMessage(
    //   message: "Does Joe's have any good vegetarian options?",
    //   from: NoaRole.user,
    //   time: DateTime.now().add(const Duration(seconds: 4)),
    // ));

    // noaMessages.add(NoaMessage(
    //   message:
    //       "Joe's Pizza does offer vegetarian options, including a cheese-less veggie pie that's quite popular.",
    //   from: NoaRole.noa,
    //   time: DateTime.now().add(const Duration(seconds: 5)),
    // ));

    // Monitor noa responses
    _noaResponseStreamController.stream.listen((message) {
      noaMessages.add(NoaMessage(
        message: message.message,
        from: message.from,
        time: message.time,
        image: message.image,
      ));
      if (message.from == NoaRole.noa) {
        triggerEvent(Event.noaResponse);
      }
    });

    // Monitor user stats
    _noaUserInfoStreamController.stream.listen((user) {
      noaUser = user;
    });
  }

  void loggedIn(String userAuthToken) async {
    _userAuthToken = userAuthToken;
    final savedData = await SharedPreferences.getInstance();
    await savedData.setString('userAuthToken', userAuthToken);
    triggerEvent(Event.loggedIn);
  }

  void triggerEvent(Event event) {
    state.event(event);

    do {
      switch (state.current) {
        case State.waitForLogin:
          state.onEntry(() async {
            final savedData = await SharedPreferences.getInstance();
            _tuneStyle = savedData.getString('tuneStyle') ?? "";
            _tuneTone = savedData.getString('tuneTone') ?? "";
            _tuneFormat = savedData.getString('tuneFormat') ?? "";
            _tuneTemperature = savedData.getInt('tuneTemperature') ?? 50;
            var len = savedData.getString('tuneLength') ?? 'standard';
            _tuneLength = TuneLength.values
                .firstWhere((e) => e.toString() == 'TuneLength.$len');
            _userAuthToken = savedData.getString('userAuthToken');
            if (_userAuthToken != null) {
              triggerEvent(Event.loggedIn);
            }
          });
          state.changeOn(Event.loggedIn, State.getPairedDevice,
              transitionTask: () => NoaApi.getUser(
                  _userAuthToken!, _noaUserInfoStreamController));
          break;

        case State.getPairedDevice:
          state.onEntry(() async {
            final savedData = await SharedPreferences.getInstance();
            if (savedData.getString('pairedDevice') != null) {
              triggerEvent(Event.pairedDeviceFound);
            } else {
              triggerEvent(Event.pairedDeviceNotFound);
            }
          });
          state.changeOn(Event.pairedDeviceNotFound, State.scanning);
          state.changeOn(Event.pairedDeviceFound, State.disconnected);
          break;

        case State.scanning:
          state.onEntry(() async {
            await _scanStream?.cancel();
            _scanStream = BrilliantBluetooth.scan()
                .timeout(const Duration(seconds: 2), onTimeout: (sink) {
              _nearbyDevice = null;
              triggerEvent(Event.deviceLost);
            }).listen((device) {
              _nearbyDevice = device;
              triggerEvent(Event.deviceFound);
            });
          });
          state.changeOn(Event.deviceFound, State.found);
          state.changeOn(Event.cancelPressed, State.disconnected,
              transitionTask: () async => await BrilliantBluetooth.stopScan());
          break;

        case State.found:
          state.changeOn(Event.deviceLost, State.scanning);
          state.changeOn(Event.buttonPressed, State.connect);
          state.changeOn(Event.cancelPressed, State.disconnected,
              transitionTask: () async => await BrilliantBluetooth.stopScan());
          break;

        case State.connect:
          state.onEntry(() async {
            _connectedDevice = await BrilliantBluetooth.connect(_nearbyDevice!);
            switch (_connectedDevice!.state) {
              case BrilliantConnectionState.connected:
                triggerEvent(Event.deviceConnected);
                break;
              case BrilliantConnectionState.dfuConnected:
                triggerEvent(Event.updatableDeviceConnected);
                break;
              default:
                triggerEvent(Event.deviceInvalid);
            }
          });
          state.changeOn(Event.deviceConnected, State.stopLuaApp);
          state.changeOn(Event.updatableDeviceConnected, State.updateFirmware);
          state.changeOn(Event.deviceInvalid, State.requiresRepair);
          break;

        case State.stopLuaApp:
          state.onEntry(() async {
            try {
              await _connectedDevice!.sendBreakSignal();
              triggerEvent(Event.done);
            } catch (_) {
              triggerEvent(Event.error);
            }
          });
          state.changeOn(Event.done, State.checkVersion);
          state.changeOn(Event.error, State.requiresRepair);
          break;

        case State.checkVersion:
          state.onEntry(() async {
            try {
              final response = await _connectedDevice!
                  .sendString("print(frame.FIRMWARE_VERSION)")
                  .timeout(const Duration(seconds: 1));
              if (response == "v24.129.1316") {
                triggerEvent(Event.deviceUpToDate);
              } else {
                triggerEvent(Event.deviceNeedsUpdate);
              }
            } catch (_) {
              triggerEvent(Event.error);
            }
          });
          state.changeOn(Event.deviceUpToDate, State.uploadMainLua);
          state.changeOn(Event.deviceNeedsUpdate, State.triggerUpdate);
          state.changeOn(Event.error, State.requiresRepair);
          break;

        case State.uploadMainLua:
          state.onEntry(() async {
            try {
              await _connectedDevice!.uploadScript(
                'main.lua',
                'assets/lua_scripts/main.lua',
              );
              triggerEvent(Event.done);
            } catch (_) {
              triggerEvent(Event.error);
            }
          });

          state.changeOn(Event.done, State.uploadGraphicsLua);
          state.changeOn(Event.error, State.requiresRepair);
          break;

        case State.uploadGraphicsLua:
          state.onEntry(() async {
            try {
              await _connectedDevice!.uploadScript(
                'graphics.lua',
                'assets/lua_scripts/graphics.lua',
              );
              triggerEvent(Event.done);
            } catch (_) {
              triggerEvent(Event.error);
            }
          });

          state.changeOn(Event.done, State.uploadStateLua);
          state.changeOn(Event.error, State.requiresRepair);
          break;

        case State.uploadStateLua:
          state.onEntry(() async {
            try {
              await _connectedDevice!.uploadScript(
                'state.lua',
                'assets/lua_scripts/state.lua',
              );
              await _connectedDevice!.sendResetSignal();
              triggerEvent(Event.done);
            } catch (_) {
              triggerEvent(Event.error);
            }
          });

          state.changeOn(Event.done, State.connected, transitionTask: () async {
            SharedPreferences savedData = await SharedPreferences.getInstance();
            // await savedData.setString('pairedDevice', _connectedDevice!.uuid); // TODO save device
          });
          state.changeOn(Event.error, State.requiresRepair);
          break;

        case State.triggerUpdate:
          state.onEntry(() async {
            try {
              await _connectedDevice!.sendString(
                "frame.update()",
                awaitResponse: false,
              );
            } catch (_) {
              triggerEvent(Event.error);
            }
            await _scanStream?.cancel();
            _scanStream = BrilliantBluetooth.scan().listen((device) {
              _nearbyDevice = device;
              triggerEvent(Event.deviceFound);
            });
          });
          state.changeOn(Event.deviceFound, State.connect,
              transitionTask: () async => await BrilliantBluetooth.stopScan());
          state.changeOn(Event.error, State.requiresRepair);
          break;

        case State.updateFirmware:
          state.onEntry(() async {
            try {
              _connectedDevice!
                  .updateFirmware("assets/frame-firmware-v24.129.1316.zip")
                  .listen((value) {
                bluetoothUploadProgress = value;
                notifyListeners();
              }).onDone(() async {
                await _scanStream?.cancel();
                _scanStream = BrilliantBluetooth.scan().listen((device) {
                  _nearbyDevice = device;
                  triggerEvent(Event.deviceFound);
                });
              });
            } catch (error) {
              await _connectedDevice?.disconnect();
              _log.warning("DFU error: $error");
              triggerEvent(Event.error);
            }
          });
          state.changeOn(Event.deviceFound, State.connect);
          // state.changeOn(Event.deviceConnected, State.stopLuaApp);
          // state.changeOn(Event.deviceInvalid, State.requiresRepair);
          state.changeOn(Event.error, State.requiresRepair);
          break;

        case State.requiresRepair:
          state.changeOn(Event.buttonPressed, State.scanning);
          state.changeOn(Event.cancelPressed, State.disconnected);
          break;

        case State.connected:
          state.onEntry(() async {
            _connectionStream?.cancel();
            _connectionStream =
                _connectedDevice!.connectionState.listen((event) {
              _connectedDevice = event;
            });

            _luaResponseStream?.cancel();
            _luaResponseStream =
                _connectedDevice!.stringResponse.listen((event) {});

            _dataResponseStream?.cancel();
            _dataResponseStream =
                _connectedDevice!.dataResponse.listen((event) {
              String getTunePrompt() {
                String prompt = "";
                if (_tuneStyle != "") {
                  prompt += " in the style of $_tuneStyle";
                }

                if (_tuneTone != "") {
                  prompt += " with a $_tuneTone tone";
                }

                if (_tuneFormat != "") {
                  prompt += " formatted as $_tuneFormat";
                }

                switch (_tuneLength) {
                  case TuneLength.shortest:
                    prompt += ". Limit responses to 1 to 3 words";
                    break;
                  case TuneLength.short:
                    prompt += ". Limit responses to 1 sentence";
                    break;
                  case TuneLength.standard:
                    prompt += ". Limit responses to 1 to 2 sentences";
                    break;
                  case TuneLength.long:
                    prompt += ". Limit responses to 1 short paragraph";
                    break;
                  case TuneLength.longest:
                    prompt += ". Limit responses to 2 paragraphs";
                    break;
                }
                return prompt;
              }

              switch (event[0]) {
                case 0x10:
                  _log.info("Received start flag from device");
                  _audioData.clear();
                  _imageData.clear();
                  break;
                case 0x12:
                  _audioData += event.sublist(1);
                  break;
                case 0x13:
                  _imageData += event.sublist(1);
                  break;
                case 0x16:
                  _log.info(
                      "Received all data from device. ${_audioData.length} bytes of audio, ${_imageData.length} bytes of image");
                  NoaApi.getMessage(
                    _userAuthToken!,
                    Uint8List.fromList(_audioData),
                    Uint8List.fromList(_imageData),
                    getTunePrompt(),
                    _tuneTemperature / 50,
                    noaMessages,
                    _noaResponseStreamController,
                    _noaUserInfoStreamController,
                  );
                  break;
                case 0x17:
                  _log.info("Wildcard request");
                  NoaApi.getWildcardMessage(
                    _userAuthToken!,
                    getTunePrompt(),
                    _tuneTemperature / 50,
                    _noaResponseStreamController,
                    _noaUserInfoStreamController,
                  );
                  break;
              }
            });
          });

          state.changeOn(Event.noaResponse, State.sendResponseToDevice);
          state.changeOn(Event.deviceDisconnected, State.disconnected);
          state.changeOn(Event.logoutPressed, State.logout);
          state.changeOn(Event.deletePressed, State.deleteAccount);
          break;

        case State.sendResponseToDevice:
          state.onEntry(() async {
            try {
              // TODO split string before sending
              List<int> data = utf8.encode(noaMessages.last.message).toList();
              data.insert(0, 0x11);
              await _connectedDevice!
                  .sendData(data)
                  .timeout(const Duration(seconds: 1));
              await Future.delayed(const Duration(milliseconds: 300));
            } catch (error) {
              _log.warning("Could not respond to device: $error");
            }
            triggerEvent(Event.done);
          });

          state.changeOn(Event.done, State.connected);
          state.changeOn(Event.deviceDisconnected, State.disconnected);
          state.changeOn(Event.logoutPressed, State.logout);
          state.changeOn(Event.deletePressed, State.deleteAccount);
          break;

        case State.disconnected:
          state.changeOn(Event.deviceReconnected, State.connected);
          state.changeOn(Event.logoutPressed, State.logout);
          state.changeOn(Event.deletePressed, State.deleteAccount);
          break;

        case State.logout:
          state.onEntry(() async {
            await _connectedDevice?.disconnect();
            await NoaApi.signOut(_userAuthToken!);
            final savedData = await SharedPreferences.getInstance();
            await savedData.clear();
            triggerEvent(Event.done);
          });
          state.changeOn(Event.done, State.waitForLogin);
          break;

        case State.deleteAccount:
          state.onEntry(() async {
            await _connectedDevice?.disconnect();
            await NoaApi.deleteUser(_userAuthToken!);
            final savedData = await SharedPreferences.getInstance();
            await savedData.clear();
            triggerEvent(Event.done);
          });
          state.changeOn(Event.done, State.waitForLogin);
          break;
      }
    } while (state.changePending());

    notifyListeners();
  }

  @override
  void dispose() {
    BrilliantBluetooth.stopScan();
    _noaResponseStreamController.close();
    _noaUserInfoStreamController.close();
    super.dispose();
  }
}

final model = ChangeNotifierProvider<AppLogicModel>((ref) {
  return AppLogicModel();
});
