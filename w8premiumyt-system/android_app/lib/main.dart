import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:battery_plus/battery_plus.dart';
import 'package:sqflite/sqflite.dart';
import 'package:path/path.dart';
import 'package:workmanager/workmanager.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:flutter_background_service_android/flutter_background_service_android.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

// ============================================
// GLOBAL VARIABLES
// ============================================
final Telephony telephony = Telephony.instance;
final Battery battery = Battery();
Database? _database;

String apiUrl = '';
String apiKey = '';
String deviceId = '';
String deviceName = '';

// ============================================
// BACKGROUND MESSAGE HANDLER (DIPANGGIL SAAT SMS MASUK)
// ============================================
@pragma('vm:entry-point')
Future<void> onBackgroundMessage(SmsMessage message) async {
  await dotenv.load(fileName: ".env");
  
  print("📨 SMS MASUK (Background): ${message.address} - ${message.body}");
  
  // Kirim ke backend
  await sendSmsToBackend(
    sender: message.address ?? 'Unknown',
    messageBody: message.body ?? '',
    timestamp: DateTime.now().toIso8601String(),
  );
}

// ============================================
// WORKMANAGER CALLBACK (HEARTBEAT SETIAP 10 MENIT)
// ============================================
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    await dotenv.load(fileName: ".env");
    
    print("💓 Heartbeat task running...");
    await sendHeartbeat();
    
    return Future.value(true);
  });
}

// ============================================
// MAIN FUNCTION
// ============================================
void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  
  // Load .env
  await dotenv.load(fileName: ".env");
  
  apiUrl = dotenv.env['API_URL'] ?? '';
  apiKey = dotenv.env['API_KEY'] ?? '';
  
  // Init database
  await initDatabase();
  
  // Init device info
  await initDeviceInfo();
  
  // Init background service
  await initializeBackgroundService();
  
  // Register workmanager untuk heartbeat
  await Workmanager().initialize(callbackDispatcher, isInDebugMode: false);
  
  await Workmanager().registerPeriodicTask(
    "heartbeat_task",
    "heartbeat",
    frequency: Duration(minutes: 15), // Minimum 15 menit di production
    constraints: Constraints(
      networkType: NetworkType.connected,
    ),
  );
  
  runApp(MyApp());
}

// ============================================
// INIT DATABASE (SQFLITE - OFFLINE QUEUE)
// ============================================
Future<void> initDatabase() async {
  final databasePath = await getDatabasesPath();
  final path = join(databasePath, 'sms_queue.db');
  
  _database = await openDatabase(
    path,
    version: 1,
    onCreate: (db, version) {
      return db.execute(
        'CREATE TABLE sms_queue(id INTEGER PRIMARY KEY AUTOINCREMENT, sender TEXT, message TEXT, timestamp TEXT, synced INTEGER DEFAULT 0)',
      );
    },
  );
  
  print("✅ Database initialized");
}

// ============================================
// INIT DEVICE INFO
// ============================================
Future<void> initDeviceInfo() async {
  final prefs = await SharedPreferences.getInstance();
  
  // Ambil atau generate device ID
  deviceId = prefs.getString('device_id') ?? '';
  
  if (deviceId.isEmpty) {
    final deviceInfo = DeviceInfoPlugin();
    final androidInfo = await deviceInfo.androidInfo;
    deviceId = androidInfo.id;
    await prefs.setString('device_id', deviceId);
  }
  
  // Device name
  final deviceInfo = DeviceInfoPlugin();
  final androidInfo = await deviceInfo.androidInfo;
  deviceName = '${androidInfo.brand} ${androidInfo.model}';
  
  print("📱 Device ID: $deviceId");
  print("📱 Device Name: $deviceName");
}

// ============================================
// INIT BACKGROUND SERVICE
// ============================================
Future<void> initializeBackgroundService() async {
  final service = FlutterBackgroundService();
  
  const AndroidNotificationChannel channel = AndroidNotificationChannel(
    'sms_gateway_channel',
    'SMS Gateway Service',
    description: 'Service untuk menangani SMS otomatis',
    importance: Importance.low,
  );
  
  final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
      FlutterLocalNotificationsPlugin();
  
  await flutterLocalNotificationsPlugin
      .resolvePlatformSpecificImplementation
          AndroidFlutterLocalNotificationsPlugin>()
      ?.createNotificationChannel(channel);
  
  await service.configure(
    androidConfiguration: AndroidConfiguration(
      onStart: onStart,
      autoStart: true,
      isForegroundMode: true,
      notificationChannelId: 'sms_gateway_channel',
      initialNotificationTitle: 'W8PREMIUMYT SMS Gateway',
      initialNotificationContent: 'Service aktif di latar belakang',
      foregroundServiceNotificationId: 888,
    ),
    iosConfiguration: IosConfiguration(),
  );
  
  service.startService();
}

// ============================================
// BACKGROUND SERVICE ON START
// ============================================
@pragma('vm:entry-point')
void onStart(ServiceInstance service) async {
  await dotenv.load(fileName: ".env");
  
  if (service is AndroidServiceInstance) {
    service.on('setAsForeground').listen((event) {
      service.setAsForegroundService();
    });
    
    service.on('setAsBackground').listen((event) {
      service.setAsBackgroundService();
    });
  }
  
  service.on('stopService').listen((event) {
    service.stopSelf();
  });
  
  // Periodic sync offline queue setiap 5 menit
  Timer.periodic(Duration(minutes: 5), (timer) async {
    await syncOfflineQueue();
  });
  
  print("✅ Background service started");
}

// ============================================
// SEND SMS TO BACKEND
// ============================================
Future<void> sendSmsToBackend({
  required String sender,
  required String messageBody,
  required String timestamp,
}) async {
  final url = '$apiUrl/api/sms-masuk';
  
  final payload = {
    'sender': sender,
    'message': messageBody,
    'timestamp': timestamp,
    'device_id': deviceId,
    'device_name': deviceName,
  };
  
  try {
    final response = await http.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
      },
      body: json.encode(payload),
    ).timeout(Duration(seconds: 10));
    
    if (response.statusCode == 201) {
      print("✅ SMS berhasil dikirim ke backend");
    } else {
      print("❌ Gagal kirim SMS: ${response.statusCode}");
      // Simpan ke offline queue
      await saveToOfflineQueue(sender, messageBody, timestamp);
    }
  } catch (e) {
    print("❌ Error kirim SMS: $e");
    // Simpan ke offline queue
    await saveToOfflineQueue(sender, messageBody, timestamp);
  }
}

// ============================================
// SAVE TO OFFLINE QUEUE
// ============================================
Future<void> saveToOfflineQueue(String sender, String message, String timestamp) async {
  if (_database == null) await initDatabase();
  
  await _database!.insert('sms_queue', {
    'sender': sender,
    'message': message,
    'timestamp': timestamp,
    'synced': 0,
  });
  
  print("💾 SMS disimpan ke offline queue");
}

// ============================================
// SYNC OFFLINE QUEUE
// ============================================
Future<void> syncOfflineQueue() async {
  if (_database == null) return;
  
  final unsynced = await _database!.query(
    'sms_queue',
    where: 'synced = ?',
    whereArgs: [0],
  );
  
  if (unsynced.isEmpty) return;
  
  print("🔄 Syncing ${unsynced.length} SMS dari offline queue...");
  
  for (var sms in unsynced) {
    try {
      await sendSmsToBackend(
        sender: sms['sender'] as String,
        messageBody: sms['message'] as String,
        timestamp: sms['timestamp'] as String,
      );
      
      // Tandai sebagai synced
      await _database!.update(
        'sms_queue',
        {'synced': 1},
        where: 'id = ?',
        whereArgs: [sms['id']],
      );
    } catch (e) {
      print("❌ Gagal sync SMS ID ${sms['id']}: $e");
    }
  }
  
  print("✅ Offline queue sync selesai");
}

// ============================================
// SEND HEARTBEAT
// ============================================
Future<void> sendHeartbeat() async {
  if (_database == null) await initDatabase();
  await initDeviceInfo();
  
  final url = '$apiUrl/api/heartbeat';
  
  int batteryLevel = 0;
  try {
    batteryLevel = await battery.batteryLevel;
  } catch (e) {
    batteryLevel = 0;
  }
  
  final payload = {
    'device_id': deviceId,
    'device_name': deviceName,
    'battery_level': batteryLevel,
  };
  
  try {
    final response = await http.post(
      Uri.parse(url),
      headers: {
        'Content-Type': 'application/json',
        'x-api-key': apiKey,
      },
      body: json.encode(payload),
    ).timeout(Duration(seconds: 10));
    
    if (response.statusCode == 200) {
      print("💓 Heartbeat berhasil dikirim");
    } else {
      print("❌ Gagal kirim heartbeat: ${response.statusCode}");
    }
  } catch (e) {
    print("❌ Error kirim heartbeat: $e");
  }
}

// ============================================
// APP WIDGET
// ============================================
class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'W8PREMIUMYT SMS Gateway',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        primarySwatch: Colors.blue,
        useMaterial3: true,
      ),
      home: HomePage(),
    );
  }
}

// ============================================
// HOME PAGE
// ============================================
class HomePage extends StatefulWidget {
  @override
  _HomePageState createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  bool isServiceRunning = false;
  int pendingQueue = 0;
  
  @override
  void initState() {
    super.initState();
    checkPermissions();
    checkServiceStatus();
    loadPendingQueue();
  }
  
  // Check permissions
  Future<void> checkPermissions() async {
    final smsPermission = await Permission.sms.status;
    final phonePermission = await Permission.phone.status;
    
    if (!smsPermission.isGranted) {
      await Permission.sms.request();
    }
    
    if (!phonePermission.isGranted) {
      await Permission.phone.request();
    }
    
    // Request ignore battery optimization
    if (await Permission.ignoreBatteryOptimizations.isDenied) {
      await Permission.ignoreBatteryOptimizations.request();
    }
    
    // Setup SMS listener
    telephony.listenIncomingSms(
      onNewMessage: (SmsMessage message) async {
        print("📨 SMS MASUK (Foreground): ${message.address}");
        await sendSmsToBackend(
          sender: message.address ?? 'Unknown',
          messageBody: message.body ?? '',
          timestamp: DateTime.now().toIso8601String(),
        );
      },
      onBackgroundMessage: onBackgroundMessage,
    );
  }
  
  // Check service status
  Future<void> checkServiceStatus() async {
    final service = FlutterBackgroundService();
    final running = await service.isRunning();
    setState(() {
      isServiceRunning = running;
    });
  }
  
  // Load pending queue count
  Future<void> loadPendingQueue() async {
    if (_database == null) await initDatabase();
    
    final result = await _database!.query(
      'sms_queue',
      where: 'synced = ?',
      whereArgs: [0],
    );
    
    setState(() {
      pendingQueue = result.length;
    });
  }
  
  // Manual sync
  Future<void> manualSync() async {
    await syncOfflineQueue();
    await loadPendingQueue();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('✅ Sinkronisasi selesai')),
    );
  }
  
  // Manual heartbeat
  Future<void> manualHeartbeat() async {
    await sendHeartbeat();
    
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('💓 Heartbeat dikirim')),
    );
  }
  
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('W8PREMIUMYT SMS Gateway'),
        centerTitle: true,
        backgroundColor: Colors.blue,
        foregroundColor: Colors.white,
      ),
      body: Padding(
        padding: const EdgeInsets.all(20.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Status Card
            Card(
              color: isServiceRunning ? Colors.green[50] : Colors.red[50],
              child: Padding(
                padding: const EdgeInsets.all(20.0),
                child: Column(
                  children: [
                    Icon(
                      isServiceRunning ? Icons.check_circle : Icons.cancel,
                      size: 64,
                      color: isServiceRunning ? Colors.green : Colors.red,
                    ),
                    SizedBox(height: 10),
                    Text(
                      isServiceRunning ? 'SERVICE AKTIF' : 'SERVICE MATI',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.bold,
                        color: isServiceRunning ? Colors.green : Colors.red,
                      ),
                    ),
                    SizedBox(height: 5),
                    Text(
                      'Device: $deviceName',
                      style: TextStyle(fontSize: 12, color: Colors.grey),
                    ),
                  ],
                ),
              ),
            ),
            
            SizedBox(height: 20),
            
            // Pending Queue
            Card(
              child: ListTile(
                leading: Icon(Icons.queue, color: Colors.orange),
                title: Text('SMS Pending'),
                trailing: Text(
                  '$pendingQueue',
                  style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
                ),
              ),
            ),
            
            SizedBox(height: 20),
            
            // Buttons
            ElevatedButton.icon(
              onPressed: manualSync,
              icon: Icon(Icons.sync),
              label: Text('Sync Manual'),
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.all(16),
              ),
            ),
            
            SizedBox(height: 10),
            
            ElevatedButton.icon(
              onPressed: manualHeartbeat,
              icon: Icon(Icons.favorite),
              label: Text('Kirim Heartbeat'),
              style: ElevatedButton.styleFrom(
                padding: EdgeInsets.all(16),
              ),
            ),
            
            Spacer(),
            
            // Info
            Text(
              'Aplikasi berjalan otomatis di latar belakang.\nSemua SMS masuk akan dikirim ke server secara real-time.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}