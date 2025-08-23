import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';

void main() => runApp(const MyApp());

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'BLE Demo',
    theme: ThemeData(
      useMaterial3: true,
      colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
        elevation: 4,
        titleTextStyle: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.bold,
          color: Colors.white,
        ),
      ),
      elevatedButtonTheme: ElevatedButtonThemeData(
        style: ElevatedButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(25),
          ),
        ),
      ),
      textTheme: const TextTheme(
        bodyMedium: TextStyle(fontSize: 16, color: Colors.black87),
      ),
    ),
    home: MyHomePage(title: 'Flutter BLE Demo'),
  );
}

class MyHomePage extends StatefulWidget {
  MyHomePage({super.key, required this.title});

  final String title;
  final List<BluetoothDevice> devicesList = <BluetoothDevice>[];
  final Map<Guid, List<int>> readValues = <Guid, List<int>>{};
  // 新增：存储通知数据的映射
  final Map<Guid, String> notifyData = <Guid, String>{};

  @override
  MyHomePageState createState() => MyHomePageState();
}

class MyHomePageState extends State<MyHomePage> {
  final _writeController = TextEditingController();
  // 为每个 characteristic 存储 TextEditingController
  final Map<Guid, TextEditingController> _notifyControllers = {};
  // 为每个 characteristic 存储 ScrollController
  final Map<Guid, ScrollController> _scrollControllers = {};
  // 用于管理通知订阅
  final Map<Guid, StreamSubscription<List<int>>> _subscriptions = {};
  // 跟踪每个特征的NOTIFY状态
  final Map<Guid, bool> _notifyEnabled = {};
  BluetoothDevice? _connectedDevice;
  List<BluetoothService> _services = [];
  int _currentMtu = 23; // 当前协商的MTU值

  _addDeviceTolist(final BluetoothDevice device) {
    // 过滤掉没有广播名的设备
    if (device.advName.isEmpty) {
      return;
    }
    
    if (!widget.devicesList.contains(device)) {
      setState(() {
        widget.devicesList.add(device);
      });
    }
  }

  _initBluetooth() async {
    var subscription = FlutterBluePlus.onScanResults.listen(
          (results) {
        if (results.isNotEmpty) {
          for (ScanResult result in results) {
            _addDeviceTolist(result.device);
          }
        }
      },
      onError: (e) => ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.toString()),
        ),
      ),
    );

    FlutterBluePlus.cancelWhenScanComplete(subscription);

    await FlutterBluePlus.adapterState.where((val) => val == BluetoothAdapterState.on).first;

    await FlutterBluePlus.startScan();

    await FlutterBluePlus.isScanning.where((val) => val == false).first;
    FlutterBluePlus.connectedDevices.map((device) {
      _addDeviceTolist(device);
    });
  }

  StreamSubscription<BluetoothConnectionState>? _connectionSubscription;

  @override
  void initState() {
    () async {
      var status = await Permission.location.status;
      if (status.isDenied) {
        final status = await Permission.location.request();
        if (status.isGranted || status.isLimited) {
          _initBluetooth();
        }
      } else if (status.isGranted || status.isLimited) {
        _initBluetooth();
      }

      if (await Permission.location.status.isPermanentlyDenied) {
        openAppSettings();
      }
    }();
    

    
    super.initState();
  }

  @override
  void dispose() {
    // 清理连接状态订阅
    _connectionSubscription?.cancel();
    // 清理所有 TextEditingController 以防止内存泄漏
    for (var controller in _notifyControllers.values) {
      controller.dispose();
    }
    // 清理所有 ScrollController 以防止内存泄漏
    for (var controller in _scrollControllers.values) {
      controller.dispose();
    }
    _writeController.dispose();
    super.dispose();
  }

  ListView _buildListViewOfDevices() {
    List<Widget> containers = <Widget>[];
    for (BluetoothDevice device in widget.devicesList) {
      containers.add(
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          elevation: 3,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        device.platformName == '' ? '(unknown device)' : device.advName,
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 16,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        device.remoteId.toString(),
                        style: const TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blue,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(20),
                    ),
                  ),
                  child: const Text('连接'),
                  onPressed: () async {
                    FlutterBluePlus.stopScan();
                    try {
                      await device.connect();
                      _services = await device.discoverServices();
                      // 查询协商的MTU值
                      final int negotiatedMtu = await device.mtu.first;
                      setState(() {
                        _connectedDevice = device;
                        _currentMtu = negotiatedMtu;
                      });
                      
                      // 为连接的设备设置连接状态监听器
                      _connectionSubscription?.cancel();
                      _connectionSubscription = device.connectionState.listen((state) {
                        if (state == BluetoothConnectionState.disconnected && _connectedDevice != null) {
                          // 设备断开连接时清理状态
                          setState(() {
                            _connectedDevice = null;
                            _services = [];
                            _notifyEnabled.clear();
                            // 取消所有通知订阅
                            for (var subscription in _subscriptions.values) {
                              subscription.cancel();
                            }
                            _subscriptions.clear();
                          });
                        }
                      });
                    } on PlatformException catch (e) {
                      if (e.code != 'already_connected') {
                        // 连接失败时显示错误信息
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('连接失败: ${e.message}'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                        rethrow;
                      } else {
                        // 已经连接的情况下，直接获取服务和MTU
                        _services = await device.discoverServices();
                        final int negotiatedMtu = await device.mtu.first;
                        setState(() {
                          _connectedDevice = device;
                          _currentMtu = negotiatedMtu;
                        });
                        
                        // 为连接的设备设置连接状态监听器
                        _connectionSubscription?.cancel();
                        _connectionSubscription = device.connectionState.listen((state) {
                          if (state == BluetoothConnectionState.disconnected && _connectedDevice != null) {
                            // 设备断开连接时清理状态
                            setState(() {
                              _connectedDevice = null;
                              _services = [];
                              _notifyEnabled.clear();
                              // 取消所有通知订阅
                              for (var subscription in _subscriptions.values) {
                                subscription.cancel();
                              }
                              _subscriptions.clear();
                            });
                          }
                        });
                      }
                    } catch (e) {
                      // 处理其他连接异常
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text('连接失败: $e'),
                          duration: const Duration(seconds: 2),
                        ),
                      );
                    }
                  },
                ),
              ],
            ),
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(8),
      children: <Widget>[
        ...containers,
      ],
    );
  }

  List<Widget> _buildReadWriteNotifyButton(BluetoothCharacteristic characteristic) {
    List<Widget> buttons = <Widget>[];

    if (characteristic.properties.read) {
      buttons.add(
        SizedBox(
          width: 80,
          height: 36,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.blue,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('READ'),
            onPressed: () async {
              var sub = characteristic.lastValueStream.listen((value) {
                setState(() {
                  widget.readValues[characteristic.uuid] = value;
                });
              });
              await characteristic.read();
              sub.cancel();
            },
          ),
        ),
      );
    }
    if (characteristic.properties.write) {
      buttons.add(
        SizedBox(
          width: 80,
          height: 36,
          child: ElevatedButton(
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.orange,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(20),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 12),
            ),
            child: const Text('WRITE'),
            onPressed: () async {
              await showDialog(
                  context: context,
                  builder: (BuildContext context) {
                    return AlertDialog(
                      title: const Text("Write"),
                      content: Row(
                        children: <Widget>[
                          Expanded(
                            child: TextField(
                              controller: _writeController,
                            ),
                          ),
                        ],
                      ),
                      actions: <Widget>[
                        TextButton(
                          child: const Text("Send"),
                          onPressed: () {
                            characteristic.write(utf8.encode(_writeController.value.text));
                            Navigator.pop(context);
                          },
                        ),
                        TextButton(
                          child: const Text("Cancel"),
                          onPressed: () {
                            Navigator.pop(context);
                          },
                        ),
                      ],
                    );
                  });
            },
          ),
        ),
      );
    }
    if (characteristic.properties.notify) {
      buttons.add(
        SizedBox(
          width: 140,
          height: 36,
          child: ElevatedButton(
          // 动态设置按钮文本和颜色
          style: ElevatedButton.styleFrom(
            backgroundColor: _notifyEnabled[characteristic.uuid] == true ? Colors.red : Colors.green,
            foregroundColor: Colors.white,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12),
          ),
          onPressed: () async {
            // 检查NOTIFY是否已启用
            if (_notifyEnabled[characteristic.uuid] == true) {
              // 禁用NOTIFY
              print('Disabling NOTIFY for ${characteristic.uuid}');
              setState(() {
                _notifyEnabled[characteristic.uuid] = false;
              });
              await characteristic.setNotifyValue(false);
              _subscriptions[characteristic.uuid]?.cancel();
              return;
            }
            // 设置NOTIFY状态为已启用
            setState(() {
              _notifyEnabled[characteristic.uuid] = true;
            });
            // 修复1：确保每次订阅前取消之前的订阅
            await characteristic.setNotifyValue(false);
            // 取消现有的订阅
            _subscriptions[characteristic.uuid]?.cancel();
            // 清空之前的通知数据，避免重复显示
            widget.notifyData[characteristic.uuid] = '';
            final controller = _notifyControllers.putIfAbsent(
              characteristic.uuid, 
              () => TextEditingController(),
            );
            controller.text = '';
            // 添加一个标志来忽略重新订阅后的第一次数据
            bool isFirstNotification = true;
            // 创建新的订阅并保存
            _subscriptions[characteristic.uuid] = characteristic.lastValueStream.listen((value) {
              // 如果是第一次通知，则忽略
              if (isFirstNotification) {
                isFirstNotification = false;
                return;
              }
              setState(() {
                // 修复2：正确将字节转换为字符串（支持中文等多字节字符）
                String stringValue = utf8.decode(value, allowMalformed: true);
                // 保存原始字节值（用于显示）
                widget.readValues[characteristic.uuid] = value;
                // 累加通知数据
                widget.notifyData[characteristic.uuid] = 
                    '${widget.notifyData[characteristic.uuid] ?? ''}$stringValue';
                
                // 更新对应的 TextEditingController
                controller.text = widget.notifyData[characteristic.uuid] ?? '';
                // 不再主动设置光标位置，让reverse属性自动处理显示位置
                
                // 自动滚动到底部
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  final scrollController = _scrollControllers[characteristic.uuid];
                  if (scrollController != null && scrollController.hasClients) {
                    // 使用 animateTo 确保平滑滚动
                    Future.delayed(const Duration(milliseconds: 10), () {
                      if (scrollController.hasClients) {
                        scrollController.animateTo(
                          scrollController.position.maxScrollExtent,
                          duration: const Duration(milliseconds: 50),
                          curve: Curves.easeOut,
                        );
                      }
                    });
                  }
                });
                
                // 调试信息，添加时间戳以便分析重复问题
                final now = DateTime.now();
                final timestamp = '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:${now.second.toString().padLeft(2, '0')}.${now.millisecond.toString().padLeft(3, '0')}';
                print('Received notify data: [$timestamp] $stringValue');
                // 输出当前订阅数量，帮助调试
                print('Current subscription count: ${_subscriptions.length}');
              });
            });
            await characteristic.setNotifyValue(true); // 开启通知
            print('NOTIFY enabled for ${characteristic.uuid}');
          },
          // 动态设置按钮文本和颜色
          child: Text(
            _notifyEnabled[characteristic.uuid] == true ? 'DISABLE NOTIFY' : 'NOTIFY',
            style: const TextStyle(fontSize: 12),
          ),
        ),
        ),
      );
    }

    return buttons;
  }

  ListView _buildConnectDeviceView() {
    List<Widget> containers = <Widget>[];

    for (BluetoothService service in _services) {
      List<Widget> characteristicsWidget = <Widget>[];

      for (BluetoothCharacteristic characteristic in service.characteristics) {
        String uuidStr = characteristic.uuid.toString();
        String shortUuid = uuidStr.length >= 8 ? uuidStr.substring(0, 8) : uuidStr;
        characteristicsWidget.add(
          Container(
            margin: const EdgeInsets.symmetric(vertical: 8),
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(12),
              boxShadow: [
                BoxShadow(
                  color: Colors.grey.withOpacity(0.2),
                  spreadRadius: 1,
                  blurRadius: 5,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        characteristic.uuid.toString(),
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    ..._buildReadWriteNotifyButton(characteristic),
                  ],
                ),
                // 新增：显示通知数据的文本框
                if (characteristic.properties.notify) ...[
                  const SizedBox(height: 12),
                  Container(
                    height: 300,
                    decoration: BoxDecoration(
                      border: Border.all(color: Colors.grey.withOpacity(0.5)),
                      borderRadius: BorderRadius.circular(8),
                      color: Colors.grey[50],
                    ),
                    child: SingleChildScrollView(
                      controller: _scrollControllers.putIfAbsent(
                        characteristic.uuid,
                        () => ScrollController()..addListener(() {
                          // print('Scroll extent: \${ScrollController().position.maxScrollExtent}');
                        }),
                      ),
                      scrollDirection: Axis.vertical,
                      reverse: false,
                      child: TextField(
                        decoration: InputDecoration(
                          labelText: 'Notify Data ($shortUuid)',
                          labelStyle: const TextStyle(color: Colors.blue),
                          border: InputBorder.none,
                          contentPadding: const EdgeInsets.all(12),
                        ),
                        maxLines: null,
                        readOnly: true,
                        textAlign: TextAlign.left,
                        controller: _notifyControllers.putIfAbsent(
                          characteristic.uuid,
                          () => TextEditingController(),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: Colors.redAccent,
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(20),
                        ),
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                      ),
                      onPressed: () {
                        setState(() {
                          widget.notifyData[characteristic.uuid] = '';
                          final controller = _notifyControllers[characteristic.uuid];
                          if (controller != null) {
                            controller.text = '';
                          }
                          
                          // 滚动到顶部
                          final scrollController = _scrollControllers[characteristic.uuid];
                          if (scrollController != null && scrollController.hasClients) {
                            scrollController.jumpTo(0);
                          }
                        });
                      },
                      child: const Text('清除日志', style: TextStyle(fontSize: 12)),
                    ),
                  ),
                ],
              ],
            ),
          ),
        );
      }
      containers.add(
        Card(
          margin: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
          elevation: 2,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          child: ExpansionTile(
            title: Text(
              service.uuid.toString(),
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                color: Colors.blue,
              ),
            ),
            children: characteristicsWidget,
          ),
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(8),
      children: <Widget>[
        ...containers,
      ],
    );
  }

  ListView _buildView() {
    if (_connectedDevice != null) {
      return _buildConnectDeviceView();
    }
    return _buildListViewOfDevices();
  }

  void _showMtuConfiguration(BuildContext context) {
    int mtuValue = _currentMtu; // 使用当前存储的MTU值作为默认值
    showDialog(
      context: context,
      builder: (BuildContext context) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('配置MTU'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('设置MTU值 (23-517):'),
                  const SizedBox(height: 16),
                  Slider(
                    value: mtuValue.toDouble(),
                    min: 23,
                    max: 517,
                    divisions: 494,
                    label: mtuValue.toString(),
                    onChanged: (double value) {
                      setState(() {
                        mtuValue = value.toInt();
                      });
                    },
                  ),
                  const SizedBox(height: 8),
                  Text('当前值: $mtuValue', style: const TextStyle(fontWeight: FontWeight.bold)),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(context).pop();
                  },
                  child: const Text('取消'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    if (_connectedDevice != null) {
                      try {
                        await _connectedDevice!.requestMtu(mtuValue);
                        setState(() {
                          _currentMtu = mtuValue; // 更新存储的MTU值
                        });
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('MTU已设置为: $mtuValue'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      } catch (e) {
                        ScaffoldMessenger.of(context).showSnackBar(
                          SnackBar(
                            content: Text('设置MTU失败: $e'),
                            duration: const Duration(seconds: 2),
                          ),
                        );
                      }
                    }
                    Navigator.of(context).pop();
                  },
                  child: const Text('应用'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: Text(widget.title),
      centerTitle: true,
      elevation: 4,
      shadowColor: Colors.blue.withOpacity(0.3),
      leading: _connectedDevice != null
          ? IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: () async {
                // 断开设备连接并返回扫描界面
                if (_connectedDevice != null) {
                  try {
                    // 取消所有通知订阅
                    for (var subscription in _subscriptions.values) {
                      await subscription.cancel();
                    }
                    _subscriptions.clear();
                    
                    // 断开设备连接
                    await _connectedDevice!.disconnect();
                  } catch (e) {
                    // 忽略断开连接时的错误
                  }
                  setState(() {
                    _connectedDevice = null;
                    _services = [];
                    _notifyEnabled.clear();
                  });
                }
              },
            )
          : null,
      actions: [
        if (_connectedDevice == null)
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: () {
              // 重新扫描设备
              setState(() {
                widget.devicesList.clear();
              });
              _initBluetooth();
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: const Text('正在重新扫描设备...'),
                  duration: const Duration(seconds: 2),
                ),
              );
            },
          ),
        if (_connectedDevice != null)
          IconButton(
            icon: const Icon(Icons.bluetooth_connected),
            onPressed: () {
              // 显示连接设备的信息和当前MTU值
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text('已连接到: ${_connectedDevice!.platformName}\n当前MTU: $_currentMtu'),
                  duration: const Duration(seconds: 3),
                ),
              );
            },
          ),
        if (_connectedDevice != null)
          IconButton(
            icon: const Icon(Icons.settings),
            onPressed: () {
              // 显示MTU配置折叠栏
              _showMtuConfiguration(context);
            },
          ),
      ],
    ),
    body: _buildView(),
  );
}