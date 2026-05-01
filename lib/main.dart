import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';
import 'package:path/path.dart' as p;
import 'package:provider/provider.dart';
import 'package:qr_flutter/qr_flutter.dart';
import 'package:sqflite/sqflite.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(ChangeNotifierProvider(create: (_) => PosStore()..init(), child: const TeaStallApp()));
}

const rupee = '₹';
const String kActivationRelease = 'tea-v1-device-activation';
const String kActivationAppKey = 'tea_stall_pos_android';
const String kActivationAppLabel = 'Tea Stall POS';
const String kActivationSecret = 'HINGLA-ACT-2026-KOT';
const String kSyncApiBase = String.fromEnvironment('SYNC_API_BASE', defaultValue: '');

T? firstOrNull<T>(Iterable<T> values) {
  final iterator = values.iterator;
  return iterator.moveNext() ? iterator.current : null;
}

int intValue(Object? value, [int fallback = 0]) {
  if (value == null) return fallback;
  if (value is int) return value;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString()) ?? fallback;
}

String activationDeviceCode(String seed) {
  var hash = 0;
  for (final unit in seed.toLowerCase().codeUnits) {
    hash = ((hash * 31) + unit) & 0x7fffffff;
  }
  final code = 100000 + (hash % 900000);
  return code.toString();
}

class ActivationDeviceInfo {
  const ActivationDeviceInfo({required this.deviceId, required this.deviceLabel});
  final String deviceId;
  final String deviceLabel;
}

class ActivationService {
  static const String _alphabet = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';

  static ActivationDeviceInfo getDeviceInfo(String deviceId) {
    final os = Platform.operatingSystem;
    return ActivationDeviceInfo(deviceId: deviceId, deviceLabel: '$os - ${Platform.localHostname.trim()}');
  }

  static String newInstallDeviceId() {
    final random = math.Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final seed = 'TEA|${Platform.operatingSystem}|${Platform.localHostname}|${DateTime.now().microsecondsSinceEpoch}|${base64Url.encode(bytes)}';
    return _tokenFromSeed(seed, 18);
  }

  static String normalizeMobile(String mobile) {
    final digits = mobile.replaceAll(RegExp(r'[^0-9]'), '');
    if (digits.length <= 10) return digits;
    return digits.substring(digits.length - 10);
  }

  static String buildRequestCode({
    required String shopName,
    required String mobileNumber,
    required String deviceId,
  }) {
    final seed = [
      shopName.trim().toUpperCase(),
      normalizeMobile(mobileNumber),
      deviceId.trim().toUpperCase(),
      kActivationSecret,
    ].join('|');
    return _formatCode(_tokenFromSeed('REQ|$seed', 16));
  }

  static String buildActivationCode({required String requestCode}) {
    final cleaned = _cleanCode(requestCode);
    if (cleaned.isEmpty) return '';
    return _formatCode(_tokenFromSeed('ACT|$cleaned|$kActivationSecret', 16));
  }

  static bool matchesActivationCode({required String requestCode, required String activationCode}) {
    final expected = buildActivationCode(requestCode: requestCode);
    return _cleanCode(expected) == _cleanCode(activationCode);
  }

  static String _tokenFromSeed(String seed, int length) {
    var state = 0x45D9F3B;
    final bytes = utf8.encode(seed);
    for (var i = 0; i < bytes.length; i++) {
      state = ((state * 1315423911) ^ (bytes[i] + i * 97 + 17)) & 0x7fffffff;
    }
    final buffer = StringBuffer();
    for (var i = 0; i < length; i++) {
      state = ((state * 1103515245) + 12345 + i * 53) & 0x7fffffff;
      buffer.write(_alphabet[state % _alphabet.length]);
    }
    return buffer.toString();
  }

  static String _formatCode(String raw) {
    final cleaned = _cleanCode(raw);
    final parts = <String>[];
    for (var i = 0; i < cleaned.length; i += 4) {
      parts.add(cleaned.substring(i, math.min(i + 4, cleaned.length)));
    }
    return parts.join('-');
  }

  static String _cleanCode(String raw) {
    return raw.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
  }
}

class TeaStallApp extends StatelessWidget {
  const TeaStallApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'Tea Stall POS',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: const Color(0xff0f766e)),
        useMaterial3: true,
        scaffoldBackgroundColor: const Color(0xfffbfaf6),
      ),
      home: const AppGate(),
    );
  }
}

class AppGate extends StatelessWidget {
  const AppGate({super.key});
  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    if (!store.ready) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    return store.activated ? const Shell() : const ActivationPage();
  }
}

class ActivationPage extends StatefulWidget {
  const ActivationPage({super.key});
  @override
  State<ActivationPage> createState() => _ActivationPageState();
}

class _ActivationPageState extends State<ActivationPage> {
  final shopController = TextEditingController();
  final mobileController = TextEditingController();
  final codeController = TextEditingController();
  String? error;
  bool loading = false;

  @override
  void initState() {
    super.initState();
    final store = context.read<PosStore>();
    shopController.text = store.activationShopName.isNotEmpty ? store.activationShopName : 'Tea Stall';
    mobileController.text = store.activationMobileNumber;
  }

  String get requestCode {
    final store = context.read<PosStore>();
    final shop = shopController.text.trim();
    final mobile = ActivationService.normalizeMobile(mobileController.text);
    if (shop.isEmpty || mobile.length != 10 || store.deviceCode.isEmpty) return '';
    return ActivationService.buildRequestCode(shopName: shop, mobileNumber: mobile, deviceId: store.deviceCode);
  }

  String qrPayload(PosStore store) {
    final code = requestCode;
    if (code.isEmpty) return '';
    return jsonEncode({
      'type': 'hingla_activation_request',
      'app': kActivationAppKey,
      'appKey': kActivationAppKey,
      'appLabel': kActivationAppLabel,
      'release': kActivationRelease,
      'hotelName': shopController.text.trim(),
      'shopName': shopController.text.trim(),
      'mobileNumber': ActivationService.normalizeMobile(mobileController.text),
      'deviceId': store.deviceCode,
      'deviceLabel': 'Android - Tea Stall POS',
      'requestCode': code,
      'generatedAt': DateTime.now().toIso8601String(),
    });
  }

  Future<void> copyRequest(PosStore store) async {
    final code = requestCode;
    if (code.isEmpty) {
      setState(() => error = 'Enter shop name and 10-digit mobile number');
      return;
    }
    await Clipboard.setData(ClipboardData(text: [
      'Product: $kActivationAppLabel',
      'Shop: ${shopController.text.trim()}',
      'Mobile: ${ActivationService.normalizeMobile(mobileController.text)}',
      'Device: ${store.deviceCode}',
      'Request Code: $code',
    ].join('\n')));
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Activation request copied')));
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    final payload = qrPayload(store);
    final code = requestCode;
    return Scaffold(
      body: Center(
        child: SizedBox(
          width: 460,
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: ListView(shrinkWrap: true, children: [
                const Text('Hingla Software', style: TextStyle(fontSize: 14, color: Colors.black54, fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                const Text('Device Activation', style: TextStyle(fontSize: 28, fontWeight: FontWeight.w900)),
                const SizedBox(height: 8),
                const Text('Enter shop details, show this QR code to the admin/master mobile, then enter the activation code.'),
                const SizedBox(height: 16),
                TextField(
                  controller: shopController,
                  decoration: const InputDecoration(labelText: 'Shop name'),
                  onChanged: (_) => setState(() => error = null),
                ),
                const SizedBox(height: 10),
                TextField(
                  controller: mobileController,
                  keyboardType: TextInputType.phone,
                  decoration: const InputDecoration(labelText: 'Mobile number', helperText: '10-digit number'),
                  onChanged: (_) => setState(() => error = null),
                ),
                const SizedBox(height: 10),
                TextField(
                  readOnly: true,
                  controller: TextEditingController(text: store.deviceCode),
                  decoration: const InputDecoration(labelText: 'Device ID'),
                ),
                const SizedBox(height: 16),
                if (payload.isNotEmpty) ...[
                  Center(
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      color: Colors.white,
                      child: QrImageView(data: payload, size: 210, backgroundColor: Colors.white),
                    ),
                  ),
                  const SizedBox(height: 10),
                  SelectableText(code, textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w900)),
                  const SizedBox(height: 10),
                  OutlinedButton.icon(onPressed: () => copyRequest(store), icon: const Icon(Icons.copy), label: const Text('Copy Activation Request')),
                ] else
                  const Text('Enter shop name and 10-digit mobile number to generate QR.'),
                const SizedBox(height: 16),
                TextField(
                  controller: codeController,
                  textCapitalization: TextCapitalization.characters,
                  decoration: InputDecoration(labelText: 'Activation code from admin app', errorText: error),
                ),
                const SizedBox(height: 16),
                FilledButton(
                  onPressed: loading
                      ? null
                      : () async {
                          setState(() {
                            loading = true;
                            error = null;
                          });
                          final ok = await context.read<PosStore>().activateWithCode(
                                shopName: shopController.text,
                                mobileNumber: mobileController.text,
                                activationCode: codeController.text,
                              );
                          if (!mounted) return;
                          setState(() {
                            loading = false;
                            error = ok ? null : 'Invalid activation key';
                          });
                        },
                  child: Text(loading ? 'Checking...' : 'Activate'),
                ),
              ]),
            ),
          ),
        ),
      ),
    );
  }
}

class Item {
  Item({required this.id, required this.name, required this.category, required this.price, required this.favorite});
  final int id;
  final String name;
  final String category;
  final int price;
  final bool favorite;

  factory Item.fromMap(Map<String, Object?> row) => Item(
        id: row['id'] as int,
        name: row['name'] as String,
        category: row['category'] as String,
        price: row['price'] as int,
        favorite: (row['isFavorite'] as int) == 1,
      );
}

class Session {
  Session({required this.id, required this.label, required this.total, required this.createdAt, this.lastItem});
  final int id;
  final String label;
  final int total;
  final int createdAt;
  final String? lastItem;

  factory Session.fromMap(Map<String, Object?> row) => Session(
        id: row['id'] as int,
        label: row['label'] as String,
        total: row['totalAmount'] as int,
        createdAt: row['createdAt'] as int,
        lastItem: row['lastAddedItem'] as String?,
      );
}

class Customer {
  Customer({required this.id, required this.name, this.phone, required this.balance, required this.updatedAt});
  final int id;
  final String name;
  final String? phone;
  final int balance;
  final int updatedAt;

  factory Customer.fromMap(Map<String, Object?> row) => Customer(
        id: row['id'] as int,
        name: row['name'] as String,
        phone: row['phone'] as String?,
        balance: row['currentBalance'] as int,
        updatedAt: row['updatedAt'] as int,
      );
}

class BillLine {
  BillLine({required this.name, required this.category, required this.price, required this.qty, required this.total, this.itemId});
  final String name;
  final String category;
  final int price;
  final int qty;
  final int total;
  final int? itemId;
}

class Ledger {
  Ledger({required this.id, required this.type, required this.amount, required this.description, required this.createdAt});
  final int id;
  final String type;
  final int amount;
  final String description;
  final int createdAt;

  factory Ledger.fromMap(Map<String, Object?> row) => Ledger(
        id: row['id'] as int,
        type: row['type'] as String,
        amount: row['amount'] as int,
        description: row['description'] as String,
        createdAt: row['createdAt'] as int,
      );
}

class ReportData {
  ReportData({
    required this.totalSales,
    required this.cashReceived,
    required this.upiReceived,
    required this.kathaAdded,
    required this.kathaReceived,
    required this.pendingKatha,
    required this.openSittingCount,
    required this.topItems,
  });
  final int totalSales;
  final int cashReceived;
  final int upiReceived;
  final int kathaAdded;
  final int kathaReceived;
  final int pendingKatha;
  final int openSittingCount;
  final List<MapEntry<String, int>> topItems;
}

class PosStore extends ChangeNotifier {
  Database? _db;
  Timer? _syncTimer;
  Timer? _syncKickTimer;
  bool _syncInProgress = false;
  bool ready = false;
  bool activated = false;
  String shopDisplayName = 'Tea Stall POS';
  String currencySymbol = rupee;
  String deviceCode = '';
  String activationShopName = '';
  String activationMobileNumber = '';
  String activationDeviceId = '';
  String activationRequestCode = '';
  String activationApprovedOn = '';
  String cloudShopId = '';
  String registeredCloudDeviceId = '';
  String syncStatus = 'Not started';
  String syncError = '';
  int pendingSyncCount = 0;
  int lastPushedCount = 0;
  int lastPulledCount = 0;
  int lastPulledEventId = 0;
  List<Item> items = [];
  List<Session> openSessions = [];
  List<Customer> customers = [];
  List<Ledger> ledger = [];
  Map<int, List<BillLine>> bills = {};
  Map<int, List<BillLine>> permanentBills = {};
  int? selectedCustomerId;

  Future<void> init() async {
    final dbPath = p.join(await getDatabasesPath(), 'tea_stall_pos.db');
    _db = await openDatabase(dbPath, version: 1, onCreate: _create);
    await _ensureSettingsTable();
    await _ensureSyncTables();
    deviceCode = await _loadOrCreateDeviceCode();
    activationDeviceId = deviceCode;
    await _backfillSyncMapFromOutbox();
    await _loadActivation();
    await _seed();
    await reload();
    ready = true;
    notifyListeners();
    _startSyncLoop();
  }

  Future<String> _loadOrCreateDeviceCode() async {
    final rows = await _db!.query('app_settings', where: 'key = ?', whereArgs: ['install_device_id'], limit: 1);
    if (rows.isNotEmpty) {
      final value = (rows.first['value'] as String?) ?? '';
      if (value.isNotEmpty) return value;
    }
    final id = ActivationService.newInstallDeviceId();
    await _db!.insert('app_settings', {'key': 'install_device_id', 'value': id}, conflictAlgorithm: ConflictAlgorithm.replace);
    return id;
  }

  Future<void> _create(Database db, int version) async {
    await db.execute('CREATE TABLE items(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, category TEXT, price INTEGER, isFavorite INTEGER, isActive INTEGER, createdAt INTEGER, updatedAt INTEGER)');
    await db.execute('CREATE TABLE customers(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT, phone TEXT, type TEXT, currentBalance INTEGER, createdAt INTEGER, updatedAt INTEGER)');
    await db.execute('CREATE TABLE katha_sessions(id INTEGER PRIMARY KEY AUTOINCREMENT, customerId INTEGER, label TEXT, type TEXT, status TEXT, totalAmount INTEGER, paidAmount INTEGER, balanceAmount INTEGER, lastAddedItem TEXT, createdAt INTEGER, closedAt INTEGER)');
    await db.execute('CREATE TABLE katha_items(id INTEGER PRIMARY KEY AUTOINCREMENT, sessionId INTEGER, itemId INTEGER, itemNameSnapshot TEXT, categorySnapshot TEXT, priceSnapshot INTEGER, quantity INTEGER, lineTotal INTEGER, createdAt INTEGER)');
    await db.execute('CREATE TABLE payments(id INTEGER PRIMARY KEY AUTOINCREMENT, customerId INTEGER, sessionId INTEGER, amount INTEGER, mode TEXT, note TEXT, createdAt INTEGER)');
    await db.execute('CREATE TABLE customer_ledger(id INTEGER PRIMARY KEY AUTOINCREMENT, customerId INTEGER, type TEXT, amount INTEGER, description TEXT, sessionId INTEGER, createdAt INTEGER)');
    await db.execute('CREATE TABLE app_settings(key TEXT PRIMARY KEY, value TEXT)');
    await db.execute('CREATE TABLE sync_outbox(id INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT, entityClientId TEXT, operation TEXT, payload TEXT, sent INTEGER DEFAULT 0, createdAt INTEGER)');
    await db.execute('CREATE TABLE sync_state(key TEXT PRIMARY KEY, value TEXT)');
    await db.execute('CREATE TABLE sync_map(clientId TEXT PRIMARY KEY, entity TEXT, localId INTEGER)');
  }

  Future<void> _ensureSettingsTable() async {
    await _db!.execute('CREATE TABLE IF NOT EXISTS app_settings(key TEXT PRIMARY KEY, value TEXT)');
  }

  Future<void> _ensureSyncTables() async {
    await _db!.execute('CREATE TABLE IF NOT EXISTS sync_outbox(id INTEGER PRIMARY KEY AUTOINCREMENT, entity TEXT, entityClientId TEXT, operation TEXT, payload TEXT, sent INTEGER DEFAULT 0, createdAt INTEGER)');
    await _db!.execute('CREATE TABLE IF NOT EXISTS sync_state(key TEXT PRIMARY KEY, value TEXT)');
    await _db!.execute('CREATE TABLE IF NOT EXISTS sync_map(clientId TEXT PRIMARY KEY, entity TEXT, localId INTEGER)');
  }

  Future<void> _backfillSyncMapFromOutbox() async {
    final rows = await _db!.query('sync_outbox');
    for (final row in rows) {
      final entity = (row['entity'] as String?) ?? '';
      final clientId = (row['entityClientId'] as String?) ?? '';
      final localId = int.tryParse(clientId.split(':').last);
      if (entity.isEmpty || clientId.isEmpty || localId == null) continue;
      await _db!.insert('sync_map', {'clientId': clientId, 'entity': entity, 'localId': localId}, conflictAlgorithm: ConflictAlgorithm.ignore);
    }
  }

  Future<void> _loadActivation() async {
    final rows = await _db!.query('app_settings');
    final map = {for (final row in rows) row['key'] as String: (row['value'] as String?) ?? ''};
    shopDisplayName = map['shop_display_name'] ?? shopDisplayName;
    currencySymbol = map['currency_symbol'] ?? currencySymbol;
    activated = map['activated_release'] == kActivationRelease;
    activationShopName = map['activation_shop_name'] ?? '';
    activationMobileNumber = map['activation_mobile_number'] ?? '';
    activationDeviceId = map['activation_device_id'] ?? deviceCode;
    activationRequestCode = map['activation_request_code'] ?? '';
    activationApprovedOn = map['activation_approved_on'] ?? '';
    cloudShopId = map['cloud_shop_id'] ?? '';
    registeredCloudDeviceId = map['registered_cloud_device_id'] ?? '';
    final syncRows = await _db!.query('sync_state', where: 'key = ?', whereArgs: ['last_pulled_event_id'], limit: 1);
    lastPulledEventId = syncRows.isEmpty ? 0 : int.tryParse((syncRows.first['value'] as String?) ?? '0') ?? 0;
    if (map['sync_replay_v2_done'] != 'true') {
      lastPulledEventId = 0;
      await _db!.insert('sync_state', {'key': 'last_pulled_event_id', 'value': '0'}, conflictAlgorithm: ConflictAlgorithm.replace);
      await _db!.insert('app_settings', {'key': 'sync_replay_v2_done', 'value': 'true'}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    pendingSyncCount = Sqflite.firstIntValue(await _db!.rawQuery('SELECT COUNT(*) FROM sync_outbox WHERE sent = 0')) ?? 0;
  }

  Future<bool> activateWithCode({required String shopName, required String mobileNumber, required String activationCode}) async {
    final normalizedShop = shopName.trim();
    final normalizedMobile = ActivationService.normalizeMobile(mobileNumber);
    if (normalizedShop.isEmpty || normalizedMobile.length != 10) return false;
    final requestCode = ActivationService.buildRequestCode(
      shopName: normalizedShop,
      mobileNumber: normalizedMobile,
      deviceId: deviceCode,
    );
    if (!ActivationService.matchesActivationCode(requestCode: requestCode, activationCode: activationCode)) {
      return false;
    }
    final cloudActivation = await _registerCloudActivation(
      shopName: normalizedShop,
      mobileNumber: normalizedMobile,
      requestCode: requestCode,
      activationCode: activationCode,
    );
    if (cloudActivation == 'limit') {
      return false;
    }
    final values = {
      'activated_release': kActivationRelease,
      'activation_shop_name': normalizedShop,
      'activation_mobile_number': normalizedMobile,
      'activation_device_id': deviceCode,
      'activation_request_code': requestCode,
      'activation_approved_on': DateTime.now().toIso8601String(),
    };
    for (final entry in values.entries) {
      await _db!.insert('app_settings', {'key': entry.key, 'value': entry.value}, conflictAlgorithm: ConflictAlgorithm.replace);
    }
    activated = true;
    activationShopName = normalizedShop;
    activationMobileNumber = normalizedMobile;
    activationDeviceId = deviceCode;
    activationRequestCode = requestCode;
    activationApprovedOn = values['activation_approved_on']!;
    notifyListeners();
    _startSyncLoop();
    return true;
  }

  Future<String> _registerCloudActivation({
    required String shopName,
    required String mobileNumber,
    required String requestCode,
    required String activationCode,
  }) async {
    if (kSyncApiBase.isEmpty) return 'disabled';
    try {
      final res = await http.post(
        Uri.parse('$kSyncApiBase/api/activation/device'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'shopName': shopName,
          'mobileNumber': mobileNumber,
          'deviceId': deviceCode,
          'deviceLabel': 'Tea Stall POS',
          'appKey': kActivationAppKey,
          'release': kActivationRelease,
          'requestCode': requestCode,
          'activationCode': activationCode,
        }),
      ).timeout(const Duration(seconds: 8));
      if (res.statusCode == 409) return 'limit';
      if (res.statusCode >= 400) return 'failed';
      final json = jsonDecode(res.body) as Map<String, dynamic>;
      cloudShopId = (json['shopId'] ?? '').toString();
      if (cloudShopId.isNotEmpty) {
        await _db!.insert('app_settings', {'key': 'cloud_shop_id', 'value': cloudShopId}, conflictAlgorithm: ConflictAlgorithm.replace);
        registeredCloudDeviceId = deviceCode;
        await _db!.insert('app_settings', {'key': 'registered_cloud_device_id', 'value': registeredCloudDeviceId}, conflictAlgorithm: ConflictAlgorithm.replace);
        notifyListeners();
        return 'registered';
      }
    } catch (_) {
      return 'failed';
    }
    return 'failed';
  }

  Future<void> resetActivation() async {
    await _db!.delete('app_settings', where: "key LIKE 'activation_%' OR key = 'activated_release' OR key = 'cloud_shop_id' OR key = 'registered_cloud_device_id'");
    activated = false;
    activationShopName = '';
    activationMobileNumber = '';
    activationRequestCode = '';
    activationApprovedOn = '';
    cloudShopId = '';
    registeredCloudDeviceId = '';
    notifyListeners();
  }

  Future<void> saveSettings({required String shopName, required String currency}) async {
    final cleanShop = shopName.trim().isEmpty ? 'Tea Stall POS' : shopName.trim();
    final cleanCurrency = currency.trim().isEmpty ? rupee : currency.trim();
    shopDisplayName = cleanShop;
    currencySymbol = cleanCurrency;
    await _db!.insert('app_settings', {'key': 'shop_display_name', 'value': shopDisplayName}, conflictAlgorithm: ConflictAlgorithm.replace);
    await _db!.insert('app_settings', {'key': 'currency_symbol', 'value': currencySymbol}, conflictAlgorithm: ConflictAlgorithm.replace);
    notifyListeners();
  }

  Future<void> enqueueSync(String entity, String entityClientId, String operation, Map<String, Object?> payload) async {
    await _db!.insert('sync_outbox', {
      'entity': entity,
      'entityClientId': entityClientId,
      'operation': operation,
      'payload': jsonEncode(payload),
      'sent': 0,
      'createdAt': DateTime.now().millisecondsSinceEpoch,
    });
  }

  void _startSyncLoop() {
    _syncTimer?.cancel();
    if (!activated || kSyncApiBase.isEmpty) return;
    _scheduleSyncSoon();
    _syncTimer = Timer.periodic(const Duration(seconds: 2), (_) => syncNow());
  }

  void _scheduleSyncSoon() {
    if (!activated || kSyncApiBase.isEmpty) return;
    _syncKickTimer?.cancel();
    _syncKickTimer = Timer(const Duration(milliseconds: 300), () => unawaited(syncNow()));
  }

  Future<bool> _ensureCloudShopRegistered() async {
    if (cloudShopId.isNotEmpty && registeredCloudDeviceId == deviceCode) return true;
    if (!activated || kSyncApiBase.isEmpty || activationShopName.isEmpty || activationMobileNumber.isEmpty || activationRequestCode.isEmpty) {
      syncStatus = 'Waiting for cloud activation';
      return false;
    }
    final activationCode = ActivationService.buildActivationCode(requestCode: activationRequestCode);
    final result = await _registerCloudActivation(
      shopName: activationShopName,
      mobileNumber: activationMobileNumber,
      requestCode: activationRequestCode,
      activationCode: activationCode,
    );
    syncStatus = result == 'registered' ? 'Cloud activation linked' : 'Cloud activation retry failed: $result';
    return result == 'registered' || registeredCloudDeviceId == deviceCode;
  }

  Future<void> syncNow() async {
    try {
      if (_syncInProgress) return;
      if (kSyncApiBase.isEmpty) {
        syncStatus = 'Sync API URL missing';
        syncError = 'Build APK with --dart-define=SYNC_API_BASE=...';
        notifyListeners();
        return;
      }
      _syncInProgress = true;
      syncStatus = 'Syncing...';
      syncError = '';
      notifyListeners();
      if (!await _ensureCloudShopRegistered()) return;
      final pending = await _db!.query('sync_outbox', where: 'sent = 0', orderBy: 'id ASC', limit: 100);
      pendingSyncCount = pending.length;
      lastPushedCount = 0;
      lastPulledCount = 0;
      if (pending.isNotEmpty) {
        final events = pending.map((row) {
          final id = row['id'] as int;
          return {
            'clientEventId': '$deviceCode-$id',
            'entity': row['entity'],
            'entityClientId': row['entityClientId'],
            'operation': row['operation'],
            'payload': jsonDecode(row['payload'] as String),
            'clientUpdatedAt': row['createdAt'],
          };
        }).toList();
        final res = await http.post(
          Uri.parse('$kSyncApiBase/api/sync/push'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'shopId': cloudShopId, 'deviceId': deviceCode, 'events': events}),
        );
        if (res.statusCode < 400) {
          for (final row in pending) {
            await _db!.update('sync_outbox', {'sent': 1}, where: 'id = ?', whereArgs: [row['id']]);
          }
          lastPushedCount = pending.length;
        } else {
          syncError = 'Push failed ${res.statusCode}: ${res.body}';
          syncStatus = 'Push failed';
          notifyListeners();
          return;
        }
      }
      final pull = await http.post(
        Uri.parse('$kSyncApiBase/api/sync/pull'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'shopId': cloudShopId, 'deviceId': deviceCode, 'since': lastPulledEventId}),
      );
      if (pull.statusCode < 400) {
        final body = jsonDecode(pull.body) as Map<String, dynamic>;
        final events = (body['events'] as List? ?? [])
            .whereType<Map>()
            .map((event) => Map<String, dynamic>.from(event))
            .toList()
          ..sort((a, b) => _syncEntityPriority(a['entity']).compareTo(_syncEntityPriority(b['entity'])));
        for (final event in events) {
          await _applyPulledEvent(event);
        }
        lastPulledCount = events.length;
        lastPulledEventId = intValue(body['latest'], lastPulledEventId);
        await _db!.insert('sync_state', {'key': 'last_pulled_event_id', 'value': '$lastPulledEventId'}, conflictAlgorithm: ConflictAlgorithm.replace);
        if (events.isNotEmpty) await reload();
        pendingSyncCount = Sqflite.firstIntValue(await _db!.rawQuery('SELECT COUNT(*) FROM sync_outbox WHERE sent = 0')) ?? 0;
        syncStatus = 'Synced ${DateFormat('hh:mm:ss a').format(DateTime.now())}';
      } else {
        syncError = 'Pull failed ${pull.statusCode}: ${pull.body}';
        syncStatus = 'Pull failed';
      }
      notifyListeners();
    } catch (error) {
      syncError = error.toString();
      syncStatus = 'Sync error';
      notifyListeners();
      return;
    } finally {
      _syncInProgress = false;
    }
  }

  Future<void> forceFullResync() async {
    cloudShopId = '';
    registeredCloudDeviceId = '';
    lastPulledEventId = 0;
    await _db!.delete('app_settings', where: "key = 'cloud_shop_id' OR key = 'registered_cloud_device_id'");
    await _db!.insert('sync_state', {'key': 'last_pulled_event_id', 'value': '0'}, conflictAlgorithm: ConflictAlgorithm.replace);
    syncStatus = 'Full resync and relink started';
    notifyListeners();
    await syncNow();
  }

  int _syncEntityPriority(Object? entity) {
    switch ((entity ?? '').toString()) {
      case 'item':
        return 0;
      case 'customer':
        return 1;
      case 'session':
        return 2;
      case 'katha_item':
        return 3;
      case 'payment':
        return 4;
      default:
        return 9;
    }
  }

  @override
  void dispose() {
    _syncTimer?.cancel();
    _syncKickTimer?.cancel();
    super.dispose();
  }

  Future<int?> _mappedLocalId(String clientId) async {
    final rows = await _db!.query('sync_map', where: 'clientId = ?', whereArgs: [clientId], limit: 1);
    if (rows.isEmpty) return null;
    return intValue(rows.first['localId']);
  }

  Future<void> _rememberRemote(String clientId, String entity, int localId) async {
    await _db!.insert('sync_map', {'clientId': clientId, 'entity': entity, 'localId': localId}, conflictAlgorithm: ConflictAlgorithm.replace);
  }

  Future<String> _clientIdFor(String entity, int localId) async {
    final rows = await _db!.query('sync_map', where: 'entity = ? AND localId = ?', whereArgs: [entity, localId], limit: 1);
    if (rows.isNotEmpty) return rows.first['clientId'] as String;
    final prefix = entity == 'katha_item' ? 'katha_item' : entity;
    return '$deviceCode:$prefix:$localId';
  }

  Future<void> _applyPulledEvent(Map<String, dynamic> event) async {
    final entity = (event['entity'] ?? '').toString();
    final clientId = (event['entity_client_id'] ?? event['entityClientId'] ?? '').toString();
    final rawPayload = event['payload'];
    final payload = rawPayload is Map<String, dynamic>
        ? rawPayload
        : rawPayload is Map
            ? Map<String, dynamic>.from(rawPayload)
            : <String, dynamic>{};
    if (clientId.isEmpty || payload.isEmpty) return;

    if (entity == 'session') {
      final existingId = await _mappedLocalId(clientId);
      final customerClientId = (payload['customerClientId'] ?? '').toString();
      final customerId = customerClientId.isEmpty ? null : await _mappedLocalId(customerClientId);
      final values = {
        'customerId': customerId,
        'label': (payload['label'] ?? '').toString(),
        'type': (payload['type'] ?? 'SITTING').toString(),
        'status': (payload['status'] ?? 'OPEN').toString(),
        'totalAmount': intValue(payload['totalAmount']),
        'paidAmount': intValue(payload['paidAmount']),
        'balanceAmount': intValue(payload['balanceAmount']),
        'lastAddedItem': payload['lastAddedItem']?.toString(),
        'createdAt': intValue(payload['createdAt'], DateTime.now().millisecondsSinceEpoch),
        'closedAt': payload['closedAt'] == null ? null : intValue(payload['closedAt']),
      };
      if (existingId == null) {
        final id = await _db!.insert('katha_sessions', values);
        await _rememberRemote(clientId, entity, id);
        await _upsertLedgerForRemoteSession(id, values);
      } else {
        await _db!.update('katha_sessions', values, where: 'id = ?', whereArgs: [existingId]);
        await _upsertLedgerForRemoteSession(existingId, values);
      }
      return;
    }

    if (entity == 'item') {
      final existingId = await _mappedLocalId(clientId);
      final now = DateTime.now().millisecondsSinceEpoch;
      final values = {
        'name': (payload['name'] ?? '').toString(),
        'category': (payload['category'] ?? 'Other').toString(),
        'price': intValue(payload['price']),
        'isFavorite': payload['isFavorite'] == false ? 0 : 1,
        'isActive': payload['isActive'] == false ? 0 : 1,
        'updatedAt': now,
      };
      if (existingId == null) {
        final matched = await _db!.query(
          'items',
          where: 'name = ? AND category = ? AND price = ?',
          whereArgs: [values['name'], values['category'], values['price']],
          limit: 1,
        );
        if (matched.isEmpty) {
          final id = await _db!.insert('items', {...values, 'createdAt': now});
          await _rememberRemote(clientId, entity, id);
        } else {
          final id = matched.first['id'] as int;
          await _db!.update('items', values, where: 'id = ?', whereArgs: [id]);
          await _rememberRemote(clientId, entity, id);
        }
      } else {
        await _db!.update('items', values, where: 'id = ?', whereArgs: [existingId]);
      }
      return;
    }

    if (entity == 'customer') {
      final existingId = await _mappedLocalId(clientId);
      final now = DateTime.now().millisecondsSinceEpoch;
      final values = {
        'name': (payload['name'] ?? '').toString(),
        'phone': payload['phone']?.toString(),
        'type': (payload['type'] ?? 'PERMANENT').toString(),
        'currentBalance': intValue(payload['currentBalance']),
        'updatedAt': now,
      };
      if (existingId == null) {
        final id = await _db!.insert('customers', {...values, 'createdAt': now});
        await _rememberRemote(clientId, entity, id);
      } else {
        await _db!.update('customers', values, where: 'id = ?', whereArgs: [existingId]);
      }
      return;
    }

    if (entity == 'katha_item') {
      final sessionClientId = (payload['sessionClientId'] ?? '').toString();
      final sessionId = await _mappedLocalId(sessionClientId);
      if (sessionId == null) return;
      final existingId = await _mappedLocalId(clientId);
      final itemClientId = (payload['itemClientId'] ?? '').toString();
      final itemName = (payload['itemNameSnapshot'] ?? '').toString();
      final category = (payload['categorySnapshot'] ?? 'Other').toString();
      final price = intValue(payload['priceSnapshot']);
      final mappedItemId = itemClientId.isEmpty ? null : await _mappedLocalId(itemClientId);
      final matchedItem = mappedItemId == null
          ? await _db!.query('items', where: 'name = ? AND category = ? AND price = ?', whereArgs: [itemName, category, price], limit: 1)
          : const <Map<String, Object?>>[];
      final values = {
        'sessionId': sessionId,
        'itemId': mappedItemId ?? (matchedItem.isEmpty ? null : matchedItem.first['id']),
        'itemNameSnapshot': itemName,
        'categorySnapshot': category,
        'priceSnapshot': price,
        'quantity': intValue(payload['quantity'], 1),
        'lineTotal': intValue(payload['lineTotal']),
        'createdAt': intValue(payload['createdAt'], DateTime.now().millisecondsSinceEpoch),
      };
      if (existingId == null) {
        final id = await _db!.insert('katha_items', values);
        await _rememberRemote(clientId, entity, id);
      } else {
        await _db!.update('katha_items', values, where: 'id = ?', whereArgs: [existingId]);
      }
      return;
    }

    if (entity == 'payment') {
      final sessionClientId = (payload['sessionClientId'] ?? '').toString();
      final customerClientId = (payload['customerClientId'] ?? '').toString();
      final sessionId = await _mappedLocalId(sessionClientId);
      final customerId = customerClientId.isEmpty ? null : await _mappedLocalId(customerClientId);
      final existingId = await _mappedLocalId(clientId);
      if (existingId != null) return;
      final amount = intValue(payload['amount']);
      final mode = (payload['mode'] ?? 'CASH').toString();
      final createdAt = intValue(payload['createdAt'], DateTime.now().millisecondsSinceEpoch);
      final id = await _db!.insert('payments', {
        'sessionId': sessionId,
        'customerId': customerId,
        'amount': amount,
        'mode': mode,
        'note': payload['note']?.toString(),
        'createdAt': createdAt,
      });
      await _rememberRemote(clientId, entity, id);
      if (customerId != null) {
        await _db!.insert('customer_ledger', {
          'customerId': customerId,
          'type': 'PAYMENT',
          'amount': amount,
          'description': '$mode payment',
          'createdAt': createdAt,
        });
      }
    }
  }

  Future<void> _upsertLedgerForRemoteSession(int sessionId, Map<String, Object?> values) async {
    final customerId = values['customerId'] == null ? null : intValue(values['customerId']);
    if (customerId == null || values['type'] != 'PERMANENT_ENTRY') return;
    final amount = intValue(values['balanceAmount'], intValue(values['totalAmount']));
    final description = (values['label'] as String?)?.isEmpty == false ? values['label'] as String : 'Permanent purchase';
    final createdAt = intValue(values['createdAt'], DateTime.now().millisecondsSinceEpoch);
    final existing = await _db!.query('customer_ledger', where: 'customerId = ? AND sessionId = ?', whereArgs: [customerId, sessionId], limit: 1);
    final ledgerValues = {'customerId': customerId, 'type': 'PURCHASE', 'amount': amount, 'description': description, 'sessionId': sessionId, 'createdAt': createdAt};
    if (existing.isEmpty) {
      await _db!.insert('customer_ledger', ledgerValues);
    } else {
      await _db!.update('customer_ledger', ledgerValues, where: 'id = ?', whereArgs: [existing.first['id']]);
    }
  }

  Future<void> _seed() async {
    final db = _db!;
    final count = Sqflite.firstIntValue(await db.rawQuery('SELECT COUNT(*) FROM items')) ?? 0;
    if (count > 0) return;
    final seed = [
      ['Chocolate', 'Chocolates', 1, 1],
      ['Biscuit', 'Biscuits', 5, 1],
      ['Gutka', 'Gutka/Pan Masala', 10, 1],
      ['Tea', 'Tea/Coffee', 10, 1],
      ['Coffee', 'Tea/Coffee', 15, 1],
      ['Gold Flake', 'Cigarettes', 20, 1],
      ['Classic', 'Cigarettes', 20, 1],
      ['Marlboro', 'Cigarettes', 25, 1],
      ['Beedi', 'Cigarettes', 10, 1],
    ];
    final now = DateTime.now().millisecondsSinceEpoch;
    for (final row in seed) {
      await db.insert('items', {'name': row[0], 'category': row[1], 'price': row[2], 'isFavorite': row[3], 'isActive': 1, 'createdAt': now, 'updatedAt': now});
    }
  }

  Future<void> reload() async {
    final db = _db!;
    items = (await db.query('items', where: 'isActive = 1', orderBy: 'isFavorite DESC, category, price, name')).map(Item.fromMap).toList();
    openSessions = (await db.query('katha_sessions', where: "type = 'SITTING' AND status = 'OPEN'", orderBy: 'createdAt DESC')).map(Session.fromMap).toList();
    customers = (await db.query('customers', where: "type = 'PERMANENT'", orderBy: 'currentBalance DESC, updatedAt DESC')).map(Customer.fromMap).toList();
    bills = {};
    for (final s in openSessions) {
      bills[s.id] = await billLines(s.id);
    }
    if (selectedCustomerId != null) await loadLedger(selectedCustomerId!);
    notifyListeners();
  }

  Map<String, List<Item>> groupedItems() {
    final map = <String, List<Item>>{};
    for (final item in items) {
      map.putIfAbsent(item.category, () => []).add(item);
    }
    return Map.fromEntries(map.entries.toList()..sort((a, b) => a.key.compareTo(b.key)));
  }

  Future<int> newSitting(String label, String note) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db!.insert('katha_sessions', {
      'label': note.trim().isEmpty ? label.trim() : '${label.trim()} - ${note.trim()}',
      'type': 'SITTING',
      'status': 'OPEN',
      'totalAmount': 0,
      'paidAmount': 0,
      'balanceAmount': 0,
      'createdAt': now,
    });
    await _rememberRemote('$deviceCode:session:$id', 'session', id);
    await enqueueSync('session', '$deviceCode:session:$id', 'upsert', {
      'label': note.trim().isEmpty ? label.trim() : '${label.trim()} - ${note.trim()}',
      'type': 'SITTING',
      'status': 'OPEN',
      'totalAmount': 0,
      'paidAmount': 0,
      'balanceAmount': 0,
      'createdAt': now,
    });
    await reload();
    _scheduleSyncSoon();
    return id;
  }

  Future<void> addItemToSession(int sessionId, Item item, [int qty = 1]) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final total = item.price * qty;
    final itemRowId = await _db!.insert('katha_items', {'sessionId': sessionId, 'itemId': item.id, 'itemNameSnapshot': item.name, 'categorySnapshot': item.category, 'priceSnapshot': item.price, 'quantity': qty, 'lineTotal': total, 'createdAt': now});
    await _db!.rawUpdate('UPDATE katha_sessions SET totalAmount = totalAmount + ?, balanceAmount = balanceAmount + ?, lastAddedItem = ? WHERE id = ?', [total, total, item.name, sessionId]);
    final session = (await _db!.query('katha_sessions', where: 'id = ?', whereArgs: [sessionId])).first;
    final sessionClientId = await _clientIdFor('session', sessionId);
    await _rememberRemote('$deviceCode:katha_item:$itemRowId', 'katha_item', itemRowId);
    await enqueueSync('katha_item', '$deviceCode:katha_item:$itemRowId', 'upsert', {
      'sessionClientId': sessionClientId,
      'itemClientId': '$deviceCode:item:${item.id}',
      'itemNameSnapshot': item.name,
      'categorySnapshot': item.category,
      'priceSnapshot': item.price,
      'quantity': qty,
      'lineTotal': total,
      'createdAt': now,
    });
    await enqueueSync('session', sessionClientId, 'upsert', {
      'label': session['label'],
      'type': session['type'],
      'status': session['status'],
      'totalAmount': session['totalAmount'],
      'paidAmount': session['paidAmount'],
      'balanceAmount': session['balanceAmount'],
      'lastAddedItem': item.name,
      'createdAt': session['createdAt'],
      'closedAt': session['closedAt'],
    });
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> removeOneFromSession(int sessionId, BillLine line) async {
    final rows = await _db!.query('katha_items', where: 'sessionId = ? AND itemNameSnapshot = ? AND priceSnapshot = ?', whereArgs: [sessionId, line.name, line.price], orderBy: 'createdAt DESC', limit: 1);
    if (rows.isEmpty) return;
    final row = rows.first;
    final id = row['id'] as int;
    final qty = row['quantity'] as int;
    if (qty > 1) {
      await _db!.update('katha_items', {'quantity': qty - 1, 'lineTotal': (row['lineTotal'] as int) - line.price}, where: 'id = ?', whereArgs: [id]);
    } else {
      await _db!.delete('katha_items', where: 'id = ?', whereArgs: [id]);
    }
    await _db!.rawUpdate('UPDATE katha_sessions SET totalAmount = totalAmount - ?, balanceAmount = balanceAmount - ? WHERE id = ?', [line.price, line.price, sessionId]);
    await reload();
  }

  Future<List<BillLine>> billLines(int sessionId) async {
    final rows = await _db!.rawQuery('''
      SELECT itemNameSnapshot, categorySnapshot, priceSnapshot, SUM(quantity) quantity, SUM(lineTotal) lineTotal, MIN(itemId) itemId
      FROM katha_items WHERE sessionId = ?
      GROUP BY itemNameSnapshot, categorySnapshot, priceSnapshot ORDER BY MAX(createdAt) DESC
    ''', [sessionId]);
    return rows.map((r) => BillLine(name: r['itemNameSnapshot'] as String, category: r['categorySnapshot'] as String, price: r['priceSnapshot'] as int, qty: r['quantity'] as int, total: r['lineTotal'] as int, itemId: r['itemId'] as int?)).toList();
  }

  Future<void> closeSession(int sessionId, String mode) async {
    final row = (await _db!.query('katha_sessions', where: 'id = ?', whereArgs: [sessionId])).first;
    final total = row['totalAmount'] as int;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db!.insert('payments', {'sessionId': sessionId, 'amount': total, 'mode': mode, 'createdAt': now});
    await _db!.update('katha_sessions', {'status': 'CLOSED', 'paidAmount': total, 'balanceAmount': 0, 'closedAt': now}, where: 'id = ?', whereArgs: [sessionId]);
    final sessionClientId = await _clientIdFor('session', sessionId);
    await enqueueSync('payment', '$deviceCode:payment:$sessionId:$now', 'upsert', {'sessionClientId': sessionClientId, 'amount': total, 'mode': mode, 'createdAt': now});
    await enqueueSync('session', sessionClientId, 'upsert', {
      'label': row['label'],
      'type': row['type'],
      'status': 'CLOSED',
      'totalAmount': total,
      'paidAmount': total,
      'balanceAmount': 0,
      'lastAddedItem': row['lastAddedItem'],
      'createdAt': row['createdAt'],
      'closedAt': now,
    });
    await reload();
    _scheduleSyncSoon();
  }

  Future<int> createCustomer(String name, String phone) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db!.insert('customers', {'name': name.trim(), 'phone': phone.trim().isEmpty ? null : phone.trim(), 'type': 'PERMANENT', 'currentBalance': 0, 'createdAt': now, 'updatedAt': now});
    await _rememberRemote('$deviceCode:customer:$id', 'customer', id);
    await enqueueSync('customer', '$deviceCode:customer:$id', 'upsert', {'name': name.trim(), 'phone': phone.trim().isEmpty ? null : phone.trim(), 'type': 'PERMANENT', 'currentBalance': 0});
    await reload();
    _scheduleSyncSoon();
    return id;
  }

  Future<void> addPermanentItem(int customerId, Item item) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final start = DateTime.now();
    final dayStart = DateTime(start.year, start.month, start.day).millisecondsSinceEpoch;
    final existing = await _db!.rawQuery('''
      SELECT ki.* FROM katha_items ki JOIN katha_sessions ks ON ks.id = ki.sessionId
      WHERE ks.customerId = ? AND ks.type = 'PERMANENT_ENTRY' AND ki.itemId = ? AND ki.priceSnapshot = ? AND ki.createdAt >= ?
      ORDER BY ki.createdAt DESC LIMIT 1
    ''', [customerId, item.id, item.price, dayStart]);
    if (existing.isNotEmpty) {
      final row = existing.first;
      final qty = (row['quantity'] as int) + 1;
      final lineTotal = (row['lineTotal'] as int) + item.price;
      final sessionId = row['sessionId'] as int;
      await _db!.update('katha_items', {'quantity': qty, 'lineTotal': lineTotal}, where: 'id = ?', whereArgs: [row['id']]);
      await _db!.rawUpdate('UPDATE katha_sessions SET totalAmount = totalAmount + ?, balanceAmount = balanceAmount + ?, label = ?, lastAddedItem = ? WHERE id = ?', [item.price, item.price, '${item.name} x $qty', item.name, sessionId]);
      await _db!.update('customer_ledger', {'amount': lineTotal, 'description': '${item.name} ${item.price} x $qty'}, where: 'customerId = ? AND sessionId = ?', whereArgs: [customerId, sessionId]);
      final sessionClientId = await _clientIdFor('session', sessionId);
      final kathaItemClientId = await _clientIdFor('katha_item', row['id'] as int);
      await _queuePermanentSession(customerId, sessionId, item.name);
      await enqueueSync('katha_item', kathaItemClientId, 'upsert', {
        'sessionClientId': sessionClientId,
        'itemClientId': '$deviceCode:item:${item.id}',
        'itemNameSnapshot': item.name,
        'categorySnapshot': item.category,
        'priceSnapshot': item.price,
        'quantity': qty,
        'lineTotal': lineTotal,
        'createdAt': row['createdAt'],
      });
    } else {
      final sessionId = await _db!.insert('katha_sessions', {'customerId': customerId, 'label': '${item.name} x 1', 'type': 'PERMANENT_ENTRY', 'status': 'CLOSED', 'totalAmount': item.price, 'paidAmount': 0, 'balanceAmount': item.price, 'lastAddedItem': item.name, 'createdAt': now, 'closedAt': now});
      final itemRowId = await _db!.insert('katha_items', {'sessionId': sessionId, 'itemId': item.id, 'itemNameSnapshot': item.name, 'categorySnapshot': item.category, 'priceSnapshot': item.price, 'quantity': 1, 'lineTotal': item.price, 'createdAt': now});
      await _db!.insert('customer_ledger', {'customerId': customerId, 'type': 'PURCHASE', 'amount': item.price, 'description': '${item.name} ${item.price} x 1', 'sessionId': sessionId, 'createdAt': now});
      await _rememberRemote('$deviceCode:session:$sessionId', 'session', sessionId);
      await _rememberRemote('$deviceCode:katha_item:$itemRowId', 'katha_item', itemRowId);
      final sessionClientId = await _clientIdFor('session', sessionId);
      await _queuePermanentSession(customerId, sessionId, item.name);
      await enqueueSync('katha_item', '$deviceCode:katha_item:$itemRowId', 'upsert', {
        'sessionClientId': sessionClientId,
        'itemClientId': '$deviceCode:item:${item.id}',
        'itemNameSnapshot': item.name,
        'categorySnapshot': item.category,
        'priceSnapshot': item.price,
        'quantity': 1,
        'lineTotal': item.price,
        'createdAt': now,
      });
    }
    await _db!.rawUpdate('UPDATE customers SET currentBalance = currentBalance + ?, updatedAt = ? WHERE id = ?', [item.price, now, customerId]);
    await _queueCustomer(customerId);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> addManualPermanent(int customerId, int amount, String note) async {
    if (amount <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db!.rawUpdate('UPDATE customers SET currentBalance = currentBalance + ?, updatedAt = ? WHERE id = ?', [amount, now, customerId]);
    final description = note.isEmpty ? 'Manual purchase' : note;
    final sessionId = await _db!.insert('katha_sessions', {'customerId': customerId, 'label': description, 'type': 'PERMANENT_ENTRY', 'status': 'CLOSED', 'totalAmount': amount, 'paidAmount': 0, 'balanceAmount': amount, 'lastAddedItem': description, 'createdAt': now, 'closedAt': now});
    await _db!.insert('customer_ledger', {'customerId': customerId, 'type': 'PURCHASE', 'amount': amount, 'description': description, 'sessionId': sessionId, 'createdAt': now});
    await _rememberRemote('$deviceCode:session:$sessionId', 'session', sessionId);
    await _queuePermanentSession(customerId, sessionId, description);
    await _queueCustomer(customerId);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> receivePayment(int customerId, int amount, String mode) async {
    if (amount <= 0) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db!.rawUpdate('UPDATE customers SET currentBalance = CASE WHEN currentBalance - ? < 0 THEN 0 ELSE currentBalance - ? END, updatedAt = ? WHERE id = ?', [amount, amount, now, customerId]);
    await _db!.insert('payments', {'customerId': customerId, 'amount': amount, 'mode': mode, 'note': 'Permanent payment', 'createdAt': now});
    await _db!.insert('customer_ledger', {'customerId': customerId, 'type': 'PAYMENT', 'amount': amount, 'description': '$mode payment', 'createdAt': now});
    final customerClientId = await _clientIdFor('customer', customerId);
    await enqueueSync('payment', '$deviceCode:payment:customer:$customerId:$now', 'upsert', {'customerClientId': customerClientId, 'amount': amount, 'mode': mode, 'note': 'Permanent payment', 'createdAt': now});
    await _queueCustomer(customerId);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> _queueCustomer(int customerId) async {
    final rows = await _db!.query('customers', where: 'id = ?', whereArgs: [customerId], limit: 1);
    if (rows.isEmpty) return;
    final row = rows.first;
    final customerClientId = await _clientIdFor('customer', customerId);
    await enqueueSync('customer', customerClientId, 'upsert', {
      'name': row['name'],
      'phone': row['phone'],
      'type': row['type'],
      'currentBalance': row['currentBalance'],
    });
  }

  Future<void> _queuePermanentSession(int customerId, int sessionId, String lastAddedItem) async {
    final rows = await _db!.query('katha_sessions', where: 'id = ?', whereArgs: [sessionId], limit: 1);
    if (rows.isEmpty) return;
    final row = rows.first;
    final sessionClientId = await _clientIdFor('session', sessionId);
    final customerClientId = await _clientIdFor('customer', customerId);
    await enqueueSync('session', sessionClientId, 'upsert', {
      'customerClientId': customerClientId,
      'label': row['label'],
      'type': row['type'],
      'status': row['status'],
      'totalAmount': row['totalAmount'],
      'paidAmount': row['paidAmount'],
      'balanceAmount': row['balanceAmount'],
      'lastAddedItem': lastAddedItem,
      'createdAt': row['createdAt'],
      'closedAt': row['closedAt'],
    });
  }

  Future<void> loadLedger(int customerId) async {
    selectedCustomerId = customerId;
    ledger = (await _db!.query('customer_ledger', where: 'customerId = ?', whereArgs: [customerId], orderBy: 'createdAt DESC')).map(Ledger.fromMap).toList();
    permanentBills[customerId] = await permanentBillLines(customerId);
    notifyListeners();
  }

  Future<List<BillLine>> permanentBillLines(int customerId) async {
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final rows = await _db!.rawQuery('''
      SELECT ki.itemNameSnapshot, ki.categorySnapshot, ki.priceSnapshot, SUM(ki.quantity) quantity, SUM(ki.lineTotal) lineTotal, MIN(ki.itemId) itemId
      FROM katha_items ki JOIN katha_sessions ks ON ks.id = ki.sessionId
      WHERE ks.customerId = ? AND ks.type = 'PERMANENT_ENTRY' AND ki.createdAt >= ?
      GROUP BY ki.itemNameSnapshot, ki.categorySnapshot, ki.priceSnapshot
      ORDER BY MAX(ki.createdAt) DESC
    ''', [customerId, dayStart]);
    return rows
        .map((r) => BillLine(
              name: r['itemNameSnapshot'] as String,
              category: r['categorySnapshot'] as String,
              price: r['priceSnapshot'] as int,
              qty: r['quantity'] as int,
              total: r['lineTotal'] as int,
              itemId: r['itemId'] as int?,
            ))
        .toList();
  }

  Future<void> removePermanentItem(int customerId, BillLine line) async {
    if (line.itemId == null) return;
    final now = DateTime.now();
    final dayStart = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final rows = await _db!.rawQuery('''
      SELECT ki.* FROM katha_items ki JOIN katha_sessions ks ON ks.id = ki.sessionId
      WHERE ks.customerId = ? AND ks.type = 'PERMANENT_ENTRY' AND ki.itemId = ? AND ki.priceSnapshot = ? AND ki.createdAt >= ?
      ORDER BY ki.createdAt DESC LIMIT 1
    ''', [customerId, line.itemId, line.price, dayStart]);
    if (rows.isEmpty) return;
    final row = rows.first;
    final itemRowId = row['id'] as int;
    final sessionId = row['sessionId'] as int;
    final qty = row['quantity'] as int;
    final newQty = qty - 1;
    final newLineTotal = (row['lineTotal'] as int) - line.price;
    if (newQty > 0) {
      await _db!.update('katha_items', {'quantity': newQty, 'lineTotal': newLineTotal}, where: 'id = ?', whereArgs: [itemRowId]);
      await _db!.update('customer_ledger', {'amount': newLineTotal, 'description': '${line.name} ${line.price} x $newQty'}, where: 'customerId = ? AND sessionId = ?', whereArgs: [customerId, sessionId]);
      await _db!.rawUpdate('UPDATE katha_sessions SET totalAmount = totalAmount - ?, balanceAmount = balanceAmount - ?, label = ? WHERE id = ?', [line.price, line.price, '${line.name} x $newQty', sessionId]);
    } else {
      await _db!.delete('katha_items', where: 'id = ?', whereArgs: [itemRowId]);
      await _db!.delete('customer_ledger', where: 'customerId = ? AND sessionId = ?', whereArgs: [customerId, sessionId]);
      await _db!.rawUpdate('UPDATE katha_sessions SET totalAmount = 0, balanceAmount = 0, label = ? WHERE id = ?', ['${line.name} x 0', sessionId]);
    }
    await _db!.rawUpdate('UPDATE customers SET currentBalance = currentBalance - ?, updatedAt = ? WHERE id = ?', [line.price, DateTime.now().millisecondsSinceEpoch, customerId]);
    final sessionClientId = await _clientIdFor('session', sessionId);
    final kathaItemClientId = await _clientIdFor('katha_item', itemRowId);
    await _queuePermanentSession(customerId, sessionId, line.name);
    await enqueueSync('katha_item', kathaItemClientId, 'upsert', {
      'sessionClientId': sessionClientId,
      'itemClientId': '$deviceCode:item:${line.itemId}',
      'itemNameSnapshot': line.name,
      'categorySnapshot': line.category,
      'priceSnapshot': line.price,
      'quantity': math.max(newQty, 0),
      'lineTotal': math.max(newLineTotal, 0),
      'createdAt': row['createdAt'],
    });
    await _queueCustomer(customerId);
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> saveItem(String name, String category, int price, bool favorite) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    final id = await _db!.insert('items', {'name': name.trim(), 'category': category.trim(), 'price': price, 'isFavorite': favorite ? 1 : 0, 'isActive': 1, 'createdAt': now, 'updatedAt': now});
    await _rememberRemote('$deviceCode:item:$id', 'item', id);
    await enqueueSync('item', '$deviceCode:item:$id', 'upsert', {'name': name.trim(), 'category': category.trim(), 'price': price, 'isFavorite': favorite, 'isActive': true});
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> deactivateItem(int itemId) async {
    await _db!.update(
      'items',
      {'isActive': 0, 'updatedAt': DateTime.now().millisecondsSinceEpoch},
      where: 'id = ?',
      whereArgs: [itemId],
    );
    final row = (await _db!.query('items', where: 'id = ?', whereArgs: [itemId], limit: 1)).first;
    final itemClientId = await _clientIdFor('item', itemId);
    await enqueueSync('item', itemClientId, 'upsert', {'name': row['name'], 'category': row['category'], 'price': row['price'], 'isFavorite': row['isFavorite'] == 1, 'isActive': false});
    await reload();
    _scheduleSyncSoon();
  }

  Future<void> quickSale(List<Item> cart, String mode) async {
    if (cart.isEmpty) return;
    final now = DateTime.now().millisecondsSinceEpoch;
    final total = cart.fold(0, (sum, item) => sum + item.price);
    final sessionId = await _db!.insert('katha_sessions', {'label': 'Quick Sale', 'type': 'QUICK_SALE', 'status': 'CLOSED', 'totalAmount': total, 'paidAmount': total, 'balanceAmount': 0, 'createdAt': now, 'closedAt': now});
    await _rememberRemote('$deviceCode:session:$sessionId', 'session', sessionId);
    final sessionClientId = await _clientIdFor('session', sessionId);
    for (final entry in cart.groupById().entries) {
      final item = entry.value.first;
      final qty = entry.value.length;
      final itemRowId = await _db!.insert('katha_items', {'sessionId': sessionId, 'itemId': item.id, 'itemNameSnapshot': item.name, 'categorySnapshot': item.category, 'priceSnapshot': item.price, 'quantity': qty, 'lineTotal': item.price * qty, 'createdAt': now});
      await _rememberRemote('$deviceCode:katha_item:$itemRowId', 'katha_item', itemRowId);
      await enqueueSync('katha_item', '$deviceCode:katha_item:$itemRowId', 'upsert', {
        'sessionClientId': sessionClientId,
        'itemClientId': '$deviceCode:item:${item.id}',
        'itemNameSnapshot': item.name,
        'categorySnapshot': item.category,
        'priceSnapshot': item.price,
        'quantity': qty,
        'lineTotal': item.price * qty,
        'createdAt': now,
      });
    }
    await _db!.insert('payments', {'sessionId': sessionId, 'amount': total, 'mode': mode, 'createdAt': now});
    await enqueueSync('session', sessionClientId, 'upsert', {'label': 'Quick Sale', 'type': 'QUICK_SALE', 'status': 'CLOSED', 'totalAmount': total, 'paidAmount': total, 'balanceAmount': 0, 'createdAt': now, 'closedAt': now});
    await enqueueSync('payment', '$deviceCode:payment:$sessionId:$now', 'upsert', {'sessionClientId': sessionClientId, 'amount': total, 'mode': mode, 'createdAt': now});
    await reload();
    _scheduleSyncSoon();
  }

  Future<ReportData> reportsToday() async {
    final db = _db!;
    final now = DateTime.now();
    final start = DateTime(now.year, now.month, now.day).millisecondsSinceEpoch;
    final end = DateTime(now.year, now.month, now.day + 1).millisecondsSinceEpoch - 1;
    Future<int> singleInt(String sql, [List<Object?> args = const []]) async {
      return Sqflite.firstIntValue(await db.rawQuery(sql, args)) ?? 0;
    }

    final topRows = await db.rawQuery('''
      SELECT itemNameSnapshot name, SUM(quantity) qty
      FROM katha_items
      WHERE createdAt BETWEEN ? AND ?
      GROUP BY itemNameSnapshot
      ORDER BY qty DESC
      LIMIT 10
    ''', [start, end]);

    return ReportData(
      totalSales: await singleInt("SELECT COALESCE(SUM(totalAmount), 0) FROM katha_sessions WHERE status = 'CLOSED' AND closedAt BETWEEN ? AND ?", [start, end]),
      cashReceived: await singleInt("SELECT COALESCE(SUM(amount), 0) FROM payments WHERE mode = 'CASH' AND createdAt BETWEEN ? AND ?", [start, end]),
      upiReceived: await singleInt("SELECT COALESCE(SUM(amount), 0) FROM payments WHERE mode = 'UPI' AND createdAt BETWEEN ? AND ?", [start, end]),
      kathaAdded: await singleInt("SELECT COALESCE(SUM(amount), 0) FROM customer_ledger WHERE type = 'PURCHASE' AND createdAt BETWEEN ? AND ?", [start, end]),
      kathaReceived: await singleInt("SELECT COALESCE(SUM(amount), 0) FROM customer_ledger WHERE type = 'PAYMENT' AND createdAt BETWEEN ? AND ?", [start, end]),
      pendingKatha: customers.fold(0, (sum, c) => sum + c.balance),
      openSittingCount: openSessions.length,
      topItems: topRows.map((row) => MapEntry(row['name'] as String, row['qty'] as int)).toList(),
    );
  }
}

extension CartGroup on List<Item> {
  Map<int, List<Item>> groupById() {
    final map = <int, List<Item>>{};
    for (final item in this) {
      map.putIfAbsent(item.id, () => []).add(item);
    }
    return map;
  }
}

class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> {
  int tab = 0;
  @override
  Widget build(BuildContext context) {
    final pages = [const HomePage(), const ItemsPage(), const CustomersPage(), const ReportsPage(), const SettingsPage()];
    return Scaffold(
      body: pages[tab],
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (value) => setState(() => tab = value),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home), label: 'Home'),
          NavigationDestination(icon: Icon(Icons.inventory_2), label: 'Items'),
          NavigationDestination(icon: Icon(Icons.people), label: 'Customers'),
          NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Reports'),
          NavigationDestination(icon: Icon(Icons.settings), label: 'Settings'),
        ],
      ),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});
  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with SingleTickerProviderStateMixin {
  late final TabController controller = TabController(length: 3, vsync: this, initialIndex: 1);
  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    return Scaffold(
      appBar: AppBar(title: Text(store.shopDisplayName), bottom: TabBar(controller: controller, tabs: const [Tab(text: 'Quick'), Tab(text: 'Sitting'), Tab(text: 'Permanent')])),
      body: TabBarView(controller: controller, children: const [QuickSalePage(), SittingPage(), CustomersPage(embed: true)]),
    );
  }
}

class CategoryGrid extends StatelessWidget {
  const CategoryGrid({
    super.key,
    required this.onItem,
    required this.groupCounts,
    required this.onMinus,
    this.onDelete,
    this.dropdownMaxHeight = 140,
  });
  final void Function(Item) onItem;
  final int Function(Item) groupCounts;
  final void Function(Item) onMinus;
  final void Function(Item)? onDelete;
  final double dropdownMaxHeight;

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    final grouped = store.groupedItems();
    return _CategoryGridBody(grouped: grouped, onItem: onItem, groupCounts: groupCounts, onMinus: onMinus, onDelete: onDelete, dropdownMaxHeight: dropdownMaxHeight);
  }
}

class _CategoryGridBody extends StatefulWidget {
  const _CategoryGridBody({required this.grouped, required this.onItem, required this.groupCounts, required this.onMinus, required this.onDelete, required this.dropdownMaxHeight});
  final Map<String, List<Item>> grouped;
  final void Function(Item) onItem;
  final int Function(Item) groupCounts;
  final void Function(Item) onMinus;
  final void Function(Item)? onDelete;
  final double dropdownMaxHeight;
  @override
  State<_CategoryGridBody> createState() => _CategoryGridBodyState();
}

class _CategoryGridBodyState extends State<_CategoryGridBody> {
  String? open;
  @override
  Widget build(BuildContext context) {
    final entries = widget.grouped.entries.toList();
    return Column(children: [
      Expanded(
        child: GridView.builder(
          padding: const EdgeInsets.all(10),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(crossAxisCount: 2, mainAxisExtent: 52, mainAxisSpacing: 8, crossAxisSpacing: 8),
          itemCount: entries.length,
          itemBuilder: (_, index) {
            final entry = entries[index];
            if (entry.value.length == 1) {
              final item = entry.value.first;
              return ProductTile(label: '${item.name} $rupee${item.price}', onDelete: widget.onDelete == null ? null : () => widget.onDelete!(item), onTap: () {
                setState(() => open = null);
                widget.onItem(item);
              });
            }
            return ProductTile(label: entry.key, onTap: () => setState(() => open = open == entry.key ? null : entry.key));
          },
        ),
      ),
      if (open != null)
        CompactDropdown(
          title: open!,
          items: widget.grouped[open]!,
          count: widget.groupCounts,
          onMinus: widget.onMinus,
          onPlus: widget.onItem,
          onDelete: widget.onDelete,
          onClose: () => setState(() => open = null),
          maxHeight: widget.dropdownMaxHeight,
        ),
    ]);
  }
}

class ProductTile extends StatelessWidget {
  const ProductTile({super.key, required this.label, required this.onTap, this.onDelete});
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onDelete;
  @override
  Widget build(BuildContext context) {
    return Stack(children: [
      Positioned.fill(
        child: FilledButton(
          onPressed: onTap,
          child: Padding(
            padding: EdgeInsets.only(right: onDelete == null ? 0 : 26),
            child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w800)),
          ),
        ),
      ),
      if (onDelete != null)
        Positioned(
          right: 2,
          top: 2,
          bottom: 2,
          child: IconButton(
            tooltip: 'Remove item',
            visualDensity: VisualDensity.compact,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints.tightFor(width: 30, height: 30),
            iconSize: 18,
            onPressed: onDelete,
            icon: const Icon(Icons.close),
          ),
        ),
    ]);
  }
}

class CompactDropdown extends StatelessWidget {
  const CompactDropdown({super.key, required this.title, required this.items, required this.count, required this.onMinus, required this.onPlus, this.onDelete, required this.onClose, this.maxHeight = 140});
  final String title;
  final List<Item> items;
  final int Function(Item) count;
  final void Function(Item) onMinus;
  final void Function(Item) onPlus;
  final void Function(Item)? onDelete;
  final VoidCallback onClose;
  final double maxHeight;
  @override
  Widget build(BuildContext context) {
    final sorted = [...items]..sort((a, b) => a.price.compareTo(b.price));
    return Card(
      margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Align(alignment: Alignment.centerLeft, child: Text(title, style: const TextStyle(fontWeight: FontWeight.bold))),
          ConstrainedBox(
            constraints: BoxConstraints(maxHeight: maxHeight),
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: sorted.length,
              itemBuilder: (_, index) {
                final item = sorted[index];
                return SizedBox(
                  height: 42,
                  child: Row(children: [
                    Expanded(child: Text('${item.name} $rupee${item.price}', maxLines: 1, overflow: TextOverflow.ellipsis)),
                    IconButton(onPressed: () => onMinus(item), icon: const Icon(Icons.remove)),
                    SizedBox(width: 28, child: Text('${count(item)}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.bold))),
                    IconButton(onPressed: () => onPlus(item), icon: const Icon(Icons.add)),
                    if (onDelete != null) IconButton(tooltip: 'Remove item', onPressed: () => onDelete!(item), icon: const Icon(Icons.close)),
                  ]),
                );
              },
            ),
          ),
          SizedBox(width: double.infinity, child: FilledButton(onPressed: onClose, child: const Text('Close'))),
        ]),
      ),
    );
  }
}

class QuickSalePage extends StatefulWidget {
  const QuickSalePage({super.key});
  @override
  State<QuickSalePage> createState() => _QuickSalePageState();
}

class _QuickSalePageState extends State<QuickSalePage> {
  final cart = <Item>[];
  @override
  Widget build(BuildContext context) {
    final store = context.read<PosStore>();
    return Column(children: [
      Expanded(
        child: CategoryGrid(
          dropdownMaxHeight: 110,
          onItem: (item) => setState(() => cart.add(item)),
          onMinus: (item) => setState(() => cart.remove(cart.lastWhere((e) => e.id == item.id, orElse: () => item))),
          groupCounts: (item) => cart.where((e) => e.id == item.id).length,
        ),
      ),
      CartBill(
        title: 'Quick Bill',
        lines: cartToLines(cart),
        linesProvider: () => cartToLines(cart),
        maxListHeight: 130,
        onAdd: (line) => setState(() => cart.add(store.items.firstWhere((e) => e.id == line.itemId))),
        onMinus: (line) => setState(() => cart.remove(cart.lastWhere((e) => e.id == line.itemId))),
      ),
      Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Expanded(child: FilledButton(onPressed: () async { await store.quickSale(cart, 'CASH'); setState(cart.clear); }, child: const Text('Cash'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: () async { await store.quickSale(cart, 'UPI'); setState(cart.clear); }, child: const Text('UPI'))),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton(onPressed: () => setState(cart.clear), child: const Text('Clear'))),
        ]),
      ),
    ]);
  }
}

List<BillLine> cartToLines(List<Item> cart) => cart.groupById().values.map((group) {
      final item = group.first;
      return BillLine(name: item.name, category: item.category, price: item.price, qty: group.length, total: item.price * group.length, itemId: item.id);
    }).toList();

class CartBill extends StatelessWidget {
  const CartBill({super.key, required this.title, required this.lines, required this.onAdd, required this.onMinus, this.linesProvider, this.maxListHeight = 220});
  final String title;
  final List<BillLine> lines;
  final void Function(BillLine) onAdd;
  final void Function(BillLine) onMinus;
  final List<BillLine> Function()? linesProvider;
  final double maxListHeight;

  List<BillLine> get currentLines => linesProvider?.call() ?? lines;

  @override
  Widget build(BuildContext context) {
    final visibleLines = currentLines;
    final total = visibleLines.fold(0, (sum, line) => sum + line.total);
    final qty = visibleLines.fold(0, (sum, line) => sum + line.qty);
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: InkWell(
        onTap: () => _showBillSheet(context),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(children: [
            Expanded(child: Text('$title ($qty)', style: const TextStyle(fontSize: 18, fontWeight: FontWeight.bold))),
            Text('$rupee$total', style: const TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
            const SizedBox(width: 8),
            FilledButton.tonal(onPressed: () => _showBillSheet(context), child: const Text('Open')),
          ]),
        ),
      ),
    );
  }

  void _showBillSheet(BuildContext context) {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (context, setSheetState) {
            final sheetLines = currentLines;
            final total = sheetLines.fold(0, (sum, line) => sum + line.total);
            final qty = sheetLines.fold(0, (sum, line) => sum + line.qty);
            return SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Row(children: [
                    Expanded(child: Text('$title ($qty)', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900))),
                    IconButton(onPressed: () => Navigator.pop(sheetContext), icon: const Icon(Icons.keyboard_arrow_down)),
                  ]),
                  ConstrainedBox(
                    constraints: BoxConstraints(maxHeight: maxListHeight + 120),
                    child: sheetLines.isEmpty
                        ? const Padding(padding: EdgeInsets.all(16), child: Text('No items yet'))
                        : ListView.builder(
                            shrinkWrap: true,
                            itemCount: sheetLines.length,
                            itemBuilder: (_, index) {
                              final line = sheetLines[index];
                              return SizedBox(
                                height: 46,
                                child: Row(children: [
                                  Expanded(child: Text('${line.name} $rupee${line.price} x ${line.qty}', overflow: TextOverflow.ellipsis)),
                                  Text('$rupee${line.total}', style: const TextStyle(fontWeight: FontWeight.bold)),
                                  IconButton(
                                    onPressed: () {
                                      onMinus(line);
                                      setSheetState(() {});
                                    },
                                    icon: const Icon(Icons.remove),
                                  ),
                                  IconButton(
                                    onPressed: () {
                                      onAdd(line);
                                      setSheetState(() {});
                                    },
                                    icon: const Icon(Icons.add),
                                  ),
                                ]),
                              );
                            },
                          ),
                  ),
                  Row(children: [
                    Expanded(child: Text('Total = $rupee$total', style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w900))),
                    FilledButton(onPressed: () => Navigator.pop(sheetContext), child: const Text('Keep Down')),
                  ]),
                ]),
              ),
            );
          },
        );
      },
    );
  }
}

class SittingPage extends StatefulWidget {
  const SittingPage({super.key});
  @override
  State<SittingPage> createState() => _SittingPageState();
}

class _SittingPageState extends State<SittingPage> {
  Session? selected;
  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    if (selected != null) return SittingDetail(session: selected!, onBack: () => setState(() => selected = null));
    return Column(children: [
      Padding(padding: const EdgeInsets.all(10), child: SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: () => showSittingDialog(context), icon: const Icon(Icons.add), label: const Text('New Sitting Katha')))),
      Expanded(
        child: ListView.builder(
          itemCount: store.openSessions.length,
          itemBuilder: (_, index) {
            final s = store.openSessions[index];
            return Card(
              margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: ListTile(
                onTap: () => setState(() => selected = s),
                title: Text(s.label, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
                trailing: Text('$rupee${s.total}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
                subtitle: Text('Last: ${s.lastItem ?? '-'}  Open ${DateFormat('h:mm a').format(DateTime.fromMillisecondsSinceEpoch(s.createdAt))}'),
              ),
            );
          },
        ),
      ),
    ]);
  }
}

void showSittingDialog(BuildContext context) {
  final name = TextEditingController();
  final note = TextEditingController();
  showDialog(context: context, builder: (_) => AlertDialog(
    title: const Text('New Sitting Katha'),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Bench 1, Raju, Auto Driver')),
      TextField(controller: note, decoration: const InputDecoration(labelText: 'Optional note')),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () async { await context.read<PosStore>().newSitting(name.text.isEmpty ? 'Sitting Katha' : name.text, note.text); if (context.mounted) Navigator.pop(context); }, child: const Text('Create')),
    ],
  ));
}

class SittingDetail extends StatelessWidget {
  const SittingDetail({super.key, required this.session, required this.onBack});
  final Session session;
  final VoidCallback onBack;
  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    final liveSession = firstOrNull(store.openSessions.where((s) => s.id == session.id));
    if (liveSession == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) => onBack());
    }
    final current = liveSession ?? session;
    final lines = store.bills[current.id] ?? [];
    return Column(children: [
      Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          IconButton(onPressed: onBack, icon: const Icon(Icons.arrow_back)),
          Expanded(child: Text(current.label, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold))),
          Text('$rupee${current.total}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900)),
        ]),
      ),
      Expanded(child: CategoryGrid(
        onItem: (item) => store.addItemToSession(current.id, item),
        onMinus: (item) {
          final line = firstOrNull(lines.where((l) => l.itemId == item.id));
          if (line != null) store.removeOneFromSession(current.id, line);
        },
        groupCounts: (item) => firstOrNull(lines.where((l) => l.itemId == item.id))?.qty ?? 0,
      )),
      CartBill(title: 'Current Bill', lines: lines, linesProvider: () => store.bills[current.id] ?? [], onAdd: (line) {
        final item = store.items.firstWhere((e) => e.id == line.itemId);
        store.addItemToSession(current.id, item);
      }, onMinus: (line) => store.removeOneFromSession(current.id, line)),
      Padding(
        padding: const EdgeInsets.all(10),
        child: Row(children: [
          Expanded(child: FilledButton(onPressed: () async { await store.closeSession(current.id, 'CASH'); onBack(); }, child: const Text('Cash Paid'))),
          const SizedBox(width: 8),
          Expanded(child: FilledButton(onPressed: () async { await store.closeSession(current.id, 'UPI'); onBack(); }, child: const Text('UPI Paid'))),
        ]),
      ),
    ]);
  }
}

class CustomersPage extends StatelessWidget {
  const CustomersPage({super.key, this.embed = false});
  final bool embed;
  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    final content = Column(children: [
      Padding(padding: const EdgeInsets.all(10), child: SizedBox(width: double.infinity, child: FilledButton.icon(onPressed: () => showCustomerDialog(context), icon: const Icon(Icons.add), label: const Text('New Permanent Customer')))),
      Expanded(child: ListView.builder(
        itemCount: store.customers.length,
        itemBuilder: (_, index) {
          final c = store.customers[index];
          return Card(margin: const EdgeInsets.symmetric(horizontal: 10, vertical: 6), child: ListTile(
            onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => CustomerDetail(customer: c))),
            title: Text(c.name, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            subtitle: Text(c.phone ?? 'Phone optional'),
            trailing: Text('$rupee${c.balance}', style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w900, color: Colors.red)),
          ));
        },
      )),
    ]);
    return embed ? content : Scaffold(appBar: AppBar(title: const Text('Permanent Katha')), body: content);
  }
}

void showCustomerDialog(BuildContext context) {
  final name = TextEditingController();
  final phone = TextEditingController();
  showDialog(context: context, builder: (_) => AlertDialog(
    title: const Text('Permanent Customer'),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
      TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'Phone optional')),
    ]),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () async { await context.read<PosStore>().createCustomer(name.text.isEmpty ? 'Customer' : name.text, phone.text); if (context.mounted) Navigator.pop(context); }, child: const Text('Save')),
    ],
  ));
}

class CustomerDetail extends StatefulWidget {
  const CustomerDetail({super.key, required this.customer});
  final Customer customer;

  @override
  State<CustomerDetail> createState() => _CustomerDetailState();
}

class _CustomerDetailState extends State<CustomerDetail> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) context.read<PosStore>().loadLedger(widget.customer.id);
    });
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    final fresh = firstOrNull(store.customers.where((c) => c.id == widget.customer.id)) ?? widget.customer;
    return Scaffold(
      appBar: AppBar(title: Text(fresh.name)),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(10), child: Text('Total due $rupee${fresh.balance}', style: const TextStyle(fontSize: 28, fontWeight: FontWeight.w900, color: Colors.red))),
        Expanded(
          child: CategoryGrid(
            dropdownMaxHeight: 110,
            onItem: (item) => store.addPermanentItem(fresh.id, item),
            onMinus: (item) {
              final line = firstOrNull((store.permanentBills[fresh.id] ?? []).where((l) => l.itemId == item.id));
              if (line != null) store.removePermanentItem(fresh.id, line);
            },
            groupCounts: (item) => firstOrNull((store.permanentBills[fresh.id] ?? []).where((l) => l.itemId == item.id))?.qty ?? 0,
          ),
        ),
        Row(children: [
          Expanded(child: Padding(padding: const EdgeInsets.all(8), child: FilledButton(onPressed: () => showManualDialog(context, fresh.id), child: const Text('Manual Amount')))),
          Expanded(child: Padding(padding: const EdgeInsets.all(8), child: FilledButton(onPressed: () => showPaymentDialog(context, fresh.id), child: const Text('Receive Payment')))),
        ]),
        const Padding(
          padding: EdgeInsets.fromLTRB(12, 4, 12, 0),
          child: Align(alignment: Alignment.centerLeft, child: Text('Account History', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900))),
        ),
        Expanded(child: ListView.builder(
          itemCount: store.ledger.length,
          itemBuilder: (_, index) {
            final e = store.ledger[index];
            final isPayment = e.type == 'PAYMENT';
            return ListTile(
              title: Text(isPayment ? 'Payment received' : e.description),
              subtitle: Text(isPayment ? e.description : 'Purchase added'),
              trailing: Text(
                '${isPayment ? '-' : '+'}$rupee${e.amount}',
                style: TextStyle(fontWeight: FontWeight.w900, color: isPayment ? Colors.green : Colors.red),
              ),
            );
          },
        )),
      ]),
    );
  }
}

void showManualDialog(BuildContext context, int customerId) {
  final amount = TextEditingController();
  final note = TextEditingController();
  showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Manual Purchase'), content: Column(mainAxisSize: MainAxisSize.min, children: [
    TextField(controller: note, decoration: const InputDecoration(labelText: 'Note')),
    TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount')),
  ]), actions: [
    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
    FilledButton(onPressed: () async { await context.read<PosStore>().addManualPermanent(customerId, int.tryParse(amount.text) ?? 0, note.text); if (context.mounted) Navigator.pop(context); }, child: const Text('Save')),
  ]));
}

void showPaymentDialog(BuildContext context, int customerId) {
  final amount = TextEditingController();
  showDialog(context: context, builder: (_) => AlertDialog(title: const Text('Receive Payment'), content: TextField(controller: amount, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Amount')), actions: [
    TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
    FilledButton(onPressed: () async { await context.read<PosStore>().receivePayment(customerId, int.tryParse(amount.text) ?? 0, 'CASH'); if (context.mounted) Navigator.pop(context); }, child: const Text('Cash')),
    FilledButton(onPressed: () async { await context.read<PosStore>().receivePayment(customerId, int.tryParse(amount.text) ?? 0, 'UPI'); if (context.mounted) Navigator.pop(context); }, child: const Text('UPI')),
  ]));
}

class ItemsPage extends StatelessWidget {
  const ItemsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Items')),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => showItemDialog(context), icon: const Icon(Icons.add), label: const Text('Add Item')),
      body: ListView.builder(
        itemCount: store.items.length,
        itemBuilder: (_, index) {
          final item = store.items[index];
          return ListTile(
            title: Text('${item.name} $rupee${item.price}'),
            subtitle: Text(item.category),
            leading: Icon(item.favorite ? Icons.star : Icons.inventory_2),
            trailing: IconButton(
              tooltip: 'Delete item',
              icon: const Icon(Icons.close),
              onPressed: () => showDeleteItemDialog(context, item),
            ),
          );
        },
      ),
    );
  }
}

void showDeleteItemDialog(BuildContext context, Item item) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Remove item?'),
      content: Text('${item.name} $rupee${item.price} will be hidden from menus. Old bills and reports will stay safe.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            await context.read<PosStore>().deactivateItem(item.id);
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Remove'),
        ),
      ],
    ),
  );
}

void showItemDialog(BuildContext context) {
  final name = TextEditingController();
  final category = TextEditingController(text: 'Tea/Coffee');
  final price = TextEditingController();
  bool favorite = true;
  showDialog(context: context, builder: (_) => StatefulBuilder(builder: (context, setState) => AlertDialog(
    title: const Text('Add Item'),
    content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Item name')),
      TextField(controller: price, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Price')),
      TextField(controller: category, decoration: const InputDecoration(labelText: 'Category or new category')),
      Wrap(spacing: 6, children: ['Tea/Coffee', 'Cigarettes', 'Gutka/Pan Masala', 'Biscuits', 'Chocolates', 'Cool Drinks', 'Other'].map((c) => ActionChip(label: Text(c), onPressed: () => category.text = c)).toList()),
      SwitchListTile(value: favorite, title: const Text('Favorite'), onChanged: (v) => setState(() => favorite = v)),
    ])),
    actions: [
      TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
      FilledButton(onPressed: () async { await context.read<PosStore>().saveItem(name.text, category.text, int.tryParse(price.text) ?? 0, favorite); if (context.mounted) Navigator.pop(context); }, child: const Text('Save')),
    ],
  )));
}

class ReportsPage extends StatelessWidget {
  const ReportsPage({super.key});
  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    return Scaffold(
      appBar: AppBar(title: const Text('Reports')),
      body: FutureBuilder<ReportData>(
        future: store.reportsToday(),
        builder: (context, snapshot) {
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator());
          final report = snapshot.data!;
          return RefreshIndicator(
            onRefresh: store.reload,
            child: ListView(
              padding: const EdgeInsets.all(12),
              children: [
                const Text('Today', style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900)),
                reportTile('Total sales', '$rupee${report.totalSales}'),
                reportTile('Cash received', '$rupee${report.cashReceived}'),
                reportTile('UPI received', '$rupee${report.upiReceived}'),
                reportTile('Katha added', '$rupee${report.kathaAdded}'),
                reportTile('Katha received', '$rupee${report.kathaReceived}'),
                reportTile('Pending katha total', '$rupee${report.pendingKatha}'),
                reportTile('Open sitting kathas', '${report.openSittingCount}'),
                const SizedBox(height: 12),
                const Text('Top selling items', style: TextStyle(fontSize: 20, fontWeight: FontWeight.w900)),
                if (report.topItems.isEmpty) const ListTile(title: Text('No item sales today')),
                for (final item in report.topItems) reportTile(item.key, 'x ${item.value}'),
              ],
            ),
          );
        },
      ),
    );
  }

  Widget reportTile(String label, String value) => Card(child: ListTile(title: Text(label), trailing: Text(value, style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold))));
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});
  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  final shopController = TextEditingController();
  final currencyController = TextEditingController();
  bool loaded = false;

  @override
  void dispose() {
    shopController.dispose();
    currencyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<PosStore>();
    if (!loaded) {
      shopController.text = store.shopDisplayName;
      currencyController.text = store.currencySymbol;
      loaded = true;
    }
    return Scaffold(appBar: AppBar(title: const Text('Settings')), body: ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Shop Settings', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            TextField(controller: shopController, decoration: const InputDecoration(labelText: 'Shop display name')),
            const SizedBox(height: 8),
            TextField(controller: currencyController, decoration: const InputDecoration(labelText: 'Currency symbol')),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => context.read<PosStore>().saveSettings(shopName: shopController.text, currency: currencyController.text),
              icon: const Icon(Icons.save),
              label: const Text('Save Settings'),
            ),
          ]),
        ),
      ),
      const SizedBox(height: 12),
      ListTile(
        title: const Text('Activation'),
        subtitle: Text(store.activated
            ? 'Active - ${store.activationShopName} - ${store.activationMobileNumber}\nDevice ${store.deviceCode}'
            : 'Not active - Device ${store.deviceCode}'),
        trailing: OutlinedButton(
          onPressed: () => showResetActivationDialog(context),
          child: const Text('Reset'),
        ),
      ),
      Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Cloud Sync', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w900)),
            const SizedBox(height: 8),
            Text('Status: ${store.syncStatus}'),
            Text('API: ${kSyncApiBase.isEmpty ? 'Missing' : kSyncApiBase}'),
            Text('Shop ID: ${store.cloudShopId.isEmpty ? 'Not linked yet' : store.cloudShopId}'),
            Text('Device ID: ${store.deviceCode}'),
            Text('Pending: ${store.pendingSyncCount}  Pushed: ${store.lastPushedCount}  Pulled: ${store.lastPulledCount}'),
            Text('Last event: ${store.lastPulledEventId}'),
            if (store.syncError.isNotEmpty) Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(store.syncError, style: const TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            FilledButton.icon(
              onPressed: () => context.read<PosStore>().syncNow(),
              icon: const Icon(Icons.sync),
              label: const Text('Sync Now'),
            ),
            const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: () => context.read<PosStore>().forceFullResync(),
              icon: const Icon(Icons.restart_alt),
              label: const Text('Full Resync'),
            ),
          ]),
        ),
      ),
      const ListTile(title: Text('Backup database'), subtitle: Text('Placeholder')),
      const ListTile(title: Text('Restore database'), subtitle: Text('Placeholder')),
      const ListTile(title: Text('Printer settings'), subtitle: Text('Bluetooth printer module later')),
    ]));
  }
}

void showResetActivationDialog(BuildContext context) {
  showDialog(
    context: context,
    builder: (_) => AlertDialog(
      title: const Text('Reset activation?'),
      content: const Text('The app will ask for activation again on next screen.'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: () async {
            await context.read<PosStore>().resetActivation();
            if (context.mounted) Navigator.pop(context);
          },
          child: const Text('Reset'),
        ),
      ],
    ),
  );
}
