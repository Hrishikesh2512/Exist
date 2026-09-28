// JSON shapes returned by the backend's /me/schedule.
class SessionInfo {
  final Map<String, dynamic> j;
  SessionInfo(this.j);

  String get key => j['key'];
  int get shortId => j['shortId'];
  String get kind => j['kind'];
  String? get title => j['title'];
  List<String> get sectionIds => List<String>.from(j['sectionIds']);
  String get teacherId => j['teacherId'];
  String? get teacherName => j['teacherName'];
  String? get roomId => j['roomId'];
  int get scheduledStart => j['scheduledStart'];
  int get scheduledEnd => j['scheduledEnd'];
  String get state => j['state'];
  String? get cancelReason => j['cancelReason'];
  String? get myStatus => j['myStatus'];
  List<String> get myReasons => List<String>.from(j['myReasons'] ?? const []);
  bool get substitutePending => j['substitutePending'] == true;
  String get label => (j['label'] as String?) ?? title ?? sectionIds.join(' + ');
  Map<String, dynamic> get plan => Map<String, dynamic>.from(j['plan'] ?? const {});
  bool get autoStart => j['autoStart'] != false;
}

class RosterEntry {
  final String id, name;
  final String? rollNo, deviceId, publicKeySpki;
  RosterEntry(Map<String, dynamic> j)
    : id = j['id'],
      name = j['name'],
      rollNo = j['rollNo'],
      deviceId = j['deviceId'],
      publicKeySpki = j['publicKeySpki'];
  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'rollNo': rollNo,
    'deviceId': deviceId,
    'publicKeySpki': publicKeySpki,
  };
}

/// A subject group I study or teach this semester.
class Subject {
  final Map<String, dynamic> j;
  Subject(this.j);
  String get id => j['id'];
  String get label => j['label'] ?? id;
  String? get code => j['subject']?['code'];
  String? get name => j['subject']?['name'];
  String? get groupName => j['groupName'];
  Map<String, dynamic> get plan => Map<String, dynamic>.from(j['plan'] ?? const {});
  bool get autoStart => j['autoStart'] != false;
}
