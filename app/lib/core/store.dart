import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

/// Small JSON key-value store. Everything the app needs offline lives here.
class Store {
  final SharedPreferences _p;
  Store(this._p);
  static Future<Store> open() async => Store(await SharedPreferences.getInstance());

  T? read<T>(String key) {
    final s = _p.getString(key);
    return s == null ? null : jsonDecode(s) as T;
  }

  Future<void> write(String key, Object? value) => value == null ? _p.remove(key) : _p.setString(key, jsonEncode(value));

  Future<void> clear() => _p.clear();
}
