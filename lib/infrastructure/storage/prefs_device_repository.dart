import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../../domain/entities/remote_device.dart';
import '../../domain/ports/device_repository.dart';
import '../../domain/xml_entities.dart';

/// Persistência dos dispositivos (dados não sensíveis) em SharedPreferences.
class PrefsDeviceRepository implements DeviceRepository {
  static const _key = 'kremote.devices.v1';

  @override
  Future<List<RemoteDevice>> loadAll() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_key);
    if (raw == null) return [];
    try {
      final list = jsonDecode(raw) as List<dynamic>;
      // Cadastros feitos antes da decodificação de entidades XML
      // (ex.: `43&quot; FHD`) são corrigidos na leitura.
      return list.map((e) {
        final d = RemoteDevice.fromJson(e as Map<String, dynamic>);
        final name = decodeXmlEntities(d.name);
        final model = d.model == null ? null : decodeXmlEntities(d.model!);
        return name == d.name && model == d.model ? d : d.copyWith(name: name, model: model);
      }).toList();
    } on FormatException {
      return [];
    }
  }

  @override
  Future<void> saveAll(List<RemoteDevice> devices) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_key, jsonEncode(devices.map((d) => d.toJson()).toList()));
  }
}
